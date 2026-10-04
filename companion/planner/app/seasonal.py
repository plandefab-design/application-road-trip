"""What the PC checks better than the planner, from sourced data, for each stage's date (added to `mustCheck`):

- seasonal closures written in OpenStreetMap (`access:conditional=no @ (Oct 20-May 31)` on pass roads…);
- the weather of the season: the last 10 years on that date at the stage's highest pass (Open-Meteo archive).

Nothing is invented: a road without dates in OSM, or weather that cannot be fetched, adds nothing.
"""
from __future__ import annotations

import asyncio
import math
import datetime as dt
import json
import re
from pathlib import Path
from typing import Any

import httpx

from .alerts import TrackIndex

CLOSURE_MARK = "📅 "
WEATHER_MARK = "🌦 "
MONTHS = {m: i for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
MONTH_FR = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]
CLOSURE_KEYS = ("motor_vehicle:conditional", "motorcycle:conditional", "vehicle:conditional", "access:conditional",
                "motorcar:conditional")
_PERIOD = re.compile(r"\b([A-Z][a-z]{2})\s*(\d{1,2})?\s*-\s*([A-Z][a-z]{2})\s*(\d{1,2})?\b")
ON_ROUTE_M = 30            # a closed way is on the route when two of its points are this close to the track
PASS_NEAR_M = 1_500        # a pass names a closed road within this distance
NEAR_BOUNDARY_DAYS = 14    # just after the reopening or before the closing: still worth checking

Period = tuple[int, int, int, int]   # start month, start day, end month, end day


def closure_periods(value: str) -> list[Period]:
    """`no @ (Oct 20-May 31)`, `no @ (Nov-Apr)`… → dated closing periods (other conditions are ignored)."""
    periods: list[Period] = []
    for part in str(value or "").split(";"):
        restriction, _, condition = part.partition("@")
        if restriction.strip().lower() != "no":
            continue
        for m1, d1, m2, d2 in _PERIOD.findall(condition):
            a, b = MONTHS.get(m1.lower()), MONTHS.get(m2.lower())
            if a and b:
                last = (dt.date(2001 if b != 12 else 2000, b % 12 + 1, 1) - dt.timedelta(days=1)).day
                periods.append((a, int(d1 or 1), b, int(d2 or last)))
    return periods


def is_closed(period: Period, day: dt.date) -> bool:
    start, end, x = (period[0], period[1]), (period[2], period[3]), (day.month, day.day)
    return start <= x <= end if start <= end else (x >= start or x <= end)


def days_from_boundary(period: Period, day: dt.date) -> int:
    """Days between `day` and the nearest opening or closing date of the period (any year)."""
    best = 366
    for month, d in ((period[0], period[1]), (period[2], period[3])):
        for year in (day.year - 1, day.year, day.year + 1):
            try:
                best = min(best, abs((dt.date(year, month, d) - day).days))
            except ValueError:
                continue
    return best


def fr_date(month: int, day: int) -> str:
    return f"{'1er' if day == 1 else day} {MONTH_FR[month - 1]}"


def _lines(geom: dict[str, Any]) -> list[list[tuple[float, float]]]:
    if geom.get("type") == "LineString":
        return [[(c[1], c[0]) for c in geom.get("coordinates") or []]]
    if geom.get("type") == "MultiLineString":
        return [[(c[1], c[0]) for c in line] for line in geom.get("coordinates") or []]
    return []


def load_closures(path: Path) -> list[dict[str, Any]]:
    """Ways of the OSM extract with a dated seasonal closure: points, periods, name."""
    out: list[dict[str, Any]] = []
    if not path.exists():
        return out
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip().lstrip("\x1e")
            if not line:
                continue
            feat = json.loads(line)
            props = feat.get("properties") or {}
            periods = [p for key in CLOSURE_KEYS for p in closure_periods(props.get(key, ""))]
            if not periods:
                continue
            for points in _lines(feat.get("geometry") or {}):
                out.append({"points": points, "periods": sorted(set(periods)),
                            "road": props.get("ref") or props.get("name") or "route"})
    return out


def load_passes(path: Path) -> list[dict[str, Any]]:
    """Named mountain passes: point, name, altitude."""
    out: list[dict[str, Any]] = []
    if not path.exists():
        return out
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip().lstrip("\x1e")
            if not line:
                continue
            feat = json.loads(line)
            props, geom = feat.get("properties") or {}, feat.get("geometry") or {}
            if geom.get("type") != "Point" or not props.get("name"):
                continue
            lon, lat = geom["coordinates"][:2]
            try:
                ele = int(float(str(props.get("ele", "")).replace(",", ".").split()[0]))
            except (ValueError, IndexError):
                ele = None
            out.append({"lat": lat, "lon": lon, "name": props["name"], "ele": ele})
    return out


def _distance_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    k = 111_195.0
    return math.hypot((a[1] - b[1]) * k * math.cos(math.radians((a[0] + b[0]) / 2)), (a[0] - b[0]) * k)


def passes_on_track(index: TrackIndex, passes: list[dict[str, Any]], max_offset: float = 300) -> list[dict[str, Any]]:
    return [p for p in passes if index.near(p["lat"], p["lon"])
            and (proj := index.project(p["lat"], p["lon"])) is not None and proj[1] <= max_offset]


def closure_warnings(index: TrackIndex, day: dt.date, closures: list[dict[str, Any]],
                     passes: list[dict[str, Any]]) -> list[str]:
    """Closed roads the stage uses on `day`, or just reopened / about to close: one line per road and period, named
    after the highest pass met along the closed stretches."""
    found: dict[tuple[str, Period], dict[str, Any]] = {}
    for c in closures:
        near = 0
        for lat, lon in c["points"]:
            if index.near(lat, lon) and (proj := index.project(lat, lon)) is not None and proj[1] <= ON_ROUTE_M:
                near += 1
                if near >= 2:
                    break
        if near < 2:
            continue
        mid = c["points"][len(c["points"]) // 2]
        pass_ = min(passes, key=lambda p: _distance_m(mid, (p["lat"], p["lon"])), default=None)
        if pass_ and _distance_m(mid, (pass_["lat"], pass_["lon"])) > PASS_NEAR_M:
            pass_ = None
        for period in c["periods"]:
            closed = is_closed(period, day)
            if not closed and days_from_boundary(period, day) > NEAR_BOUNDARY_DAYS:
                continue
            entry = found.setdefault((c["road"], period), {"closed": False, "pass": None})
            entry["closed"] |= closed
            if pass_ and (entry["pass"] is None or (pass_["ele"] or 0) > (entry["pass"]["ele"] or 0)):
                entry["pass"] = pass_
    lines = []
    for (road, period), entry in found.items():
        closed, pass_ = entry["closed"], entry["pass"]
        named = road if road != "route" else "Une route de l'étape"
        label = (f"{pass_['name']} ({road})" if road != "route" else pass_["name"]) if pass_ else named
        span = f"fermé du {fr_date(period[0], period[1])} au {fr_date(period[2], period[3])}"
        when = fr_date(day.month, day.day)
        if closed:
            lines.append(f"{CLOSURE_MARK}{label} : {span} (OpenStreetMap). Ton passage le {when} tombe dedans : "
                         "vérifie l'ouverture auprès du département ou prévois le plan B.")
        else:
            lines.append(f"{CLOSURE_MARK}{label} : {span} (OpenStreetMap). Ton passage le {when} est proche "
                         "de ces dates : vérifie l'ouverture effective.")
    return lines


# ------------------------------------------------------------------ weather of the season (Open-Meteo archive)

ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
YEARS = 10
RAINY_MM = 1.0


async def season_weather(lat: float, lon: float, day: dt.date, client: httpx.AsyncClient) -> dict[str, float] | None:
    """The same week over the last 10 years: share of rainy days, mean morning low and afternoon high (°C).
    Two requests at a time (the free service refuses more), one retry each; at least 8 years or nothing."""
    gate = asyncio.Semaphore(2)

    async def year(y: int) -> dict[str, Any] | None:
        try:
            centre = day.replace(year=y)
        except ValueError:                       # 29 February
            centre = day.replace(year=y, day=28)
        params = {"latitude": round(lat, 4), "longitude": round(lon, 4), "timezone": "auto",
                  "start_date": (centre - dt.timedelta(days=3)).isoformat(),
                  "end_date": (centre + dt.timedelta(days=3)).isoformat(),
                  "daily": "precipitation_sum,temperature_2m_min,temperature_2m_max"}
        for attempt in range(2):
            async with gate:
                try:
                    r = await client.get(ARCHIVE_URL, params=params, timeout=10)
                    if r.status_code == 200:
                        return r.json().get("daily")
                except (httpx.HTTPError, ValueError):
                    pass
            await asyncio.sleep(1 + attempt)
        return None

    results = [d for d in await asyncio.gather(*(year(day.year - k) for k in range(1, YEARS + 1))) if d]
    rain = [v for d in results for v in d.get("precipitation_sum") or [] if v is not None]
    lows = [v for d in results for v in d.get("temperature_2m_min") or [] if v is not None]
    highs = [v for d in results for v in d.get("temperature_2m_max") or [] if v is not None]
    if len(results) < YEARS - 2 or not rain or not lows or not highs:
        return None
    return {"rain": sum(1 for v in rain if v >= RAINY_MM) / len(rain),
            "low": sum(lows) / len(lows), "high": sum(highs) / len(highs)}


def weather_line(index: int, day: dt.date, place: str, w: dict[str, float]) -> str | None:
    """A line only when the season deserves attention: rain often, cold mornings or heat."""
    notes = []
    if w["rain"] >= 0.3:
        notes.append(f"pluie {round(w['rain'] * 10)} jours sur 10")
    if w["low"] <= 5:
        notes.append(f"{round(w['low'])} °C au petit matin")
    if w["high"] >= 32:
        notes.append(f"{round(w['high'])} °C l'après-midi")
    if not notes:
        return None
    return (f"{WEATHER_MARK}Météo de saison, jour {index} ({fr_date(day.month, day.day)}, {place}) : "
            f"{', '.join(notes)} (Open-Meteo, {YEARS} dernières années).")


def stage_date(trip: dict[str, Any], day: dict[str, Any]) -> dt.date | None:
    """The stage's date, else the trip's start plus its rank."""
    for value, offset in ((day.get("date"), 0), ((trip.get("params") or {}).get("dateStart"), int(day.get("index", 1)) - 1)):
        try:
            return dt.date.fromisoformat(str(value)) + dt.timedelta(days=offset)
        except (TypeError, ValueError):
            continue
    return None


async def seasonal_checks(trip: dict[str, Any], closures: list[dict[str, Any]], passes: list[dict[str, Any]],
                          weather: bool = True) -> list[str]:
    """Replaces the PC's previous lines in `mustCheck` with fresh ones; returns the new lines. Dates still to be
    chosen (schema v9): nothing to check yet, the best periods come with their own checks."""
    lines: list[str] = []
    if (trip.get("params") or {}).get("flexibleDates"):
        trip["mustCheck"] = [l for l in trip.get("mustCheck") or [] if not str(l).startswith((CLOSURE_MARK, WEATHER_MARK))]
        return lines
    async with httpx.AsyncClient(headers={"User-Agent": "MotoRoad-companion/1.0"}) as client:
        for day in trip.get("days") or []:
            track = (day.get("track") or {}).get("points") or []
            date = stage_date(trip, day)
            if len(track) < 2 or date is None:
                continue
            index = TrackIndex(track)
            lines += closure_warnings(index, date, closures, passes)
            if not weather:
                continue
            on_route = passes_on_track(index, passes)
            top = max(on_route, key=lambda p: p["ele"] or 0, default=None)
            spot = (top["lat"], top["lon"], top["name"]) if top else \
                (track[len(track) // 2]["lat"], track[len(track) // 2]["lon"], day.get("to") or f"étape {day.get('index')}")
            w = await season_weather(spot[0], spot[1], date, client)
            if w and (line := weather_line(int(day.get("index", 0)), date, spot[2], w)):
                lines.append(line)
    kept = [l for l in trip.get("mustCheck") or [] if not str(l).startswith((CLOSURE_MARK, WEATHER_MARK))]
    trip["mustCheck"] = kept + list(dict.fromkeys(lines))
    return lines


_files: dict[Path, tuple[float, list[dict[str, Any]]]] = {}


def cached(path: Path, loader) -> list[dict[str, Any]]:
    """A data file read once until it changes (monthly map update)."""
    if not path.exists():
        return []
    mtime = path.stat().st_mtime
    if path not in _files or _files[path][0] != mtime:
        _files[path] = (mtime, loader(path))
    return _files[path][1]
