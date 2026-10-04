"""Best period for a trip created without dates (schema v9).

Every start date of the next 12 months is scored on what the PC knows for each stage, all from sourced data:
- seasonal closures written in OpenStreetMap on the stage's roads (a closed pass rules the date out);
- the weather of the last 6 years at the stage's highest pass (Open-Meteo archive): rain, cold mornings, heat;
- the daylight left when the stage ends (leaving at 9:00, riding time + stops).
The three best periods (at least 10 days apart) are returned with their reasons and the stage checks of their dates.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import math
from pathlib import Path
from typing import Any

import httpx

from .alerts import TrackIndex
from .seasonal import (ARCHIVE_URL, closure_warnings, fr_date, is_closed, passes_on_track, weather_line)

HISTORY_YEARS = 6
FIRST_START_DAYS = 14          # not before two weeks from today (bookings, preparation)
HORIZON_DAYS = 365
OPTIONS = 3
APART_DAYS = 10
DEPARTURE_HOUR = 9
CACHE_DAYS = 180               # the history of a place is fetched again after six months


# ------------------------------------------------------------------ weather history of a place (cached on disk)

async def daily_history(lat: float, lon: float, client: httpx.AsyncClient, cache_dir: Path,
                        today: dt.date) -> list[tuple[dt.date, float, float, float]] | None:
    """Daily rain (mm), low and high (°C) of the last 6 full years at a place, one request then cached (places
    rounded to 0.05°: stages of the same area share it)."""
    lat_r, lon_r = round(lat * 20) / 20, round(lon * 20) / 20
    cache = cache_dir / f"{lat_r:.2f}_{lon_r:.2f}_{HISTORY_YEARS}y.json"
    if cache.exists() and (dt.datetime.now().timestamp() - cache.stat().st_mtime) < CACHE_DAYS * 86_400:
        rows = json.loads(cache.read_text(encoding="utf-8"))
    else:
        params = {"latitude": lat_r, "longitude": lon_r, "timezone": "auto",
                  "start_date": f"{today.year - HISTORY_YEARS}-01-01", "end_date": f"{today.year - 1}-12-31",
                  "daily": "precipitation_sum,temperature_2m_min,temperature_2m_max"}
        rows = None
        for attempt in range(3):
            try:
                r = await client.get(ARCHIVE_URL, params=params, timeout=60)
                if r.status_code == 200:
                    d = r.json().get("daily") or {}
                    rows = [[t, p, lo, hi] for t, p, lo, hi in zip(d.get("time") or [], d.get("precipitation_sum") or [],
                                                                     d.get("temperature_2m_min") or [], d.get("temperature_2m_max") or [])
                            if None not in (p, lo, hi)]
                    break
                if r.status_code != 429:
                    break
            except (httpx.HTTPError, ValueError):
                pass
            await asyncio.sleep(20 * (attempt + 1))        # the free service limits calls per minute
        if not rows:
            return None
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(rows, separators=(",", ":")), encoding="utf-8")
    return [(dt.date.fromisoformat(t), p, lo, hi) for t, p, lo, hi in rows]


class Climate:
    """A place's history indexed by day of the year: the same week of the year (± 3 days around a date), every
    year, in a few list lookups."""

    def __init__(self, history: list[tuple[dt.date, float, float, float]]):
        self.by_day: dict[int, list[tuple[float, float, float]]] = {}
        for date, rain, low, high in history:
            self.by_day.setdefault(min(date.timetuple().tm_yday, 365), []).append((rain, low, high))

    def stats(self, day: dt.date, half_width: int = 3) -> dict[str, float] | None:
        doy = min(day.timetuple().tm_yday, 365)
        rows = [r for k in range(-half_width, half_width + 1) for r in self.by_day.get((doy - 1 + k) % 365 + 1, [])]
        if len(rows) < 10:
            return None
        return {"rain": sum(1 for r in rows if r[0] >= 1.0) / len(rows),
                "low": sum(r[1] for r in rows) / len(rows), "high": sum(r[2] for r in rows) / len(rows)}


# ------------------------------------------------------------------ daylight

def _utc_offset(day: dt.date, lon: float) -> int:
    """Legal time in the covered countries: CET/CEST, Portugal WET/WEST; summer time from the last Sunday of March
    to the last Sunday of October."""
    base = 0 if lon < -6.5 else 1
    def last_sunday(month: int) -> dt.date:
        d = dt.date(day.year, month, 31)
        return d - dt.timedelta(days=(d.weekday() + 1) % 7)
    return base + (1 if last_sunday(3) <= day < last_sunday(10) else 0)


def sunset_hour(lat: float, lon: float, day: dt.date) -> float | None:
    """Local legal time of sunset, hours (NOAA approximation, a few minutes); None in polar day/night."""
    n = day.timetuple().tm_yday
    gamma = 2 * math.pi / 365 * (n - 1)
    eqtime = 229.18 * (0.000075 + 0.001868 * math.cos(gamma) - 0.032077 * math.sin(gamma)
                       - 0.014615 * math.cos(2 * gamma) - 0.040849 * math.sin(2 * gamma))
    decl = (0.006918 - 0.399912 * math.cos(gamma) + 0.070257 * math.sin(gamma) - 0.006758 * math.cos(2 * gamma)
            + 0.000907 * math.sin(2 * gamma) - 0.002697 * math.cos(3 * gamma) + 0.00148 * math.sin(3 * gamma))
    phi = math.radians(lat)
    cos_ha = math.cos(math.radians(90.833)) / (math.cos(phi) * math.cos(decl)) - math.tan(phi) * math.tan(decl)
    if not -1 <= cos_ha <= 1:
        return None
    ha = math.degrees(math.acos(cos_ha))
    minutes_utc = 720 - 4 * (lon - ha) - eqtime
    return minutes_utc / 60 + _utc_offset(day, lon)


def stage_hours(day: dict[str, Any]) -> float:
    """Hours from departure to arrival: riding (routing time) + a break every 1 h 30 + lunch on a long day."""
    riding = float(day.get("drivingTimeMin") or 0) / 60
    return riding + int(riding / 1.5) * 0.25 + (1.25 if riding >= 4 else 0)


# ------------------------------------------------------------------ the search

def _stage_spot(day: dict[str, Any], passes: list[dict[str, Any]]) -> tuple[TrackIndex, float, float, str] | None:
    track = (day.get("track") or {}).get("points") or []
    if len(track) < 2:
        return None
    index = TrackIndex(track)
    on_route = passes_on_track(index, passes)
    top = max(on_route, key=lambda p: p["ele"] or 0, default=None)
    if top:
        return index, top["lat"], top["lon"], top["name"]
    mid = track[len(track) // 2]
    return index, mid["lat"], mid["lon"], day.get("to") or f"étape {day.get('index')}"


def fr_period(start: dt.date, end: dt.date) -> str:
    if start == end:
        return f"le {fr_date(start.month, start.day)} {start.year}"
    if start.year != end.year:
        return f"du {fr_date(start.month, start.day)} {start.year} au {fr_date(end.month, end.day)} {end.year}"
    if start.month == end.month:
        return f"du {'1er' if start.day == 1 else start.day} au {fr_date(end.month, end.day)} {end.year}"
    return f"du {fr_date(start.month, start.day)} au {fr_date(end.month, end.day)} {end.year}"


async def best_periods(trip: dict[str, Any], closures: list[dict[str, Any]], passes: list[dict[str, Any]],
                       client: httpx.AsyncClient, cache_dir: Path, today: dt.date | None = None) -> list[dict[str, Any]]:
    today = today or dt.date.today()
    days = [d for d in trip.get("days") or [] if ((d.get("track") or {}).get("points") or [])]
    if not days:
        return []
    stages = []
    for day in days:
        spot = _stage_spot(day, passes)
        if spot is None:
            continue
        index, lat, lon, place = spot
        end = (day.get("track") or {}).get("points")[-1]
        # Closures of this stage's roads, whatever the date (checked per candidate below).
        closed = [c for c in closures if sum(1 for la, lo in c["points"]
                                             if index.near(la, lo) and (pr := index.project(la, lo)) and pr[1] <= 30) >= 2]
        history = await daily_history(lat, lon, client, cache_dir, today)
        stages.append({"day": day, "index": index, "place": place, "climate": Climate(history) if history else None,
                       "closed": closed,
                       "end": (end["lat"], end["lon"]), "hours": stage_hours(day)})

    scored = []
    for offset in range(FIRST_START_DAYS, HORIZON_DAYS):
        start = today + dt.timedelta(days=offset)
        score, ok, notes = 0.0, True, []
        for k, s in enumerate(stages):
            date = start + dt.timedelta(days=k)
            if any(is_closed(p, date) for c in s["closed"] for p in c["periods"]):
                ok = False
                break
            w = s["climate"].stats(date) if s["climate"] else None
            if w:
                score += 10 * w["rain"] + 0.8 * max(0.0, 4 - w["low"]) + 0.8 * max(0.0, w["high"] - 31)
                notes.append((s, w))
            sunset = sunset_hour(*s["end"], date)
            if sunset is not None:
                margin = sunset - (DEPARTURE_HOUR + s["hours"])
                score += 3 * max(0.0, 1.5 - margin)
        if ok:
            scored.append((score, start, notes))

    options: list[dict[str, Any]] = []
    for score, start, notes in sorted(scored, key=lambda x: (x[0], x[1])):
        if any(abs((start - dt.date.fromisoformat(o["start"])).days) < APART_DAYS for o in options):
            continue
        end = start + dt.timedelta(days=max(len(trip.get("days") or []), 1) - 1)
        options.append(_option(start, end, stages, notes, passes))
        if len(options) == OPTIONS:
            break
    return options


def _option(start: dt.date, end: dt.date, stages: list[dict[str, Any]], notes: list,
            passes: list[dict[str, Any]]) -> dict[str, Any]:
    reasons: list[str] = []
    if any(s["closed"] for s in stages):
        reasons.append("Cols et routes à fermeture saisonnière ouverts à ces dates (OpenStreetMap).")
    if notes:
        rain = sum(w["rain"] for _, w in notes) / len(notes)
        coldest = min(notes, key=lambda n: n[1]["low"])
        hottest = max(notes, key=lambda n: n[1]["high"])
        reasons.append(f"Pluie {round(rain * 10)} jour{'s' if round(rain * 10) > 1 else ''} sur 10 en moyenne "
                       f"sur les {HISTORY_YEARS} dernières années (Open-Meteo).")
        reasons.append(f"{round(coldest[1]['low'])} °C au petit matin vers {coldest[0]['place']}, "
                       f"{round(hottest[1]['high'])} °C l'après-midi au plus chaud.")
    margins = [sunset - (DEPARTURE_HOUR + s["hours"]) for k, s in enumerate(stages)
               if (sunset := sunset_hour(*s["end"], start + dt.timedelta(days=k))) is not None]
    if margins:
        m = max(0.0, min(margins))
        if m >= 3:
            reasons.append(f"Arrivée bien avant la nuit chaque jour (départ {DEPARTURE_HOUR} h).")
        else:
            hours, minutes = int(m), int(round((m - int(m)) * 60 / 15) * 15) % 60
            reasons.append(f"Étape la plus juste : arrivée {hours} h {minutes:02d} avant le coucher du soleil "
                           f"(départ {DEPARTURE_HOUR} h).")
    checks: list[str] = []
    for k, s in enumerate(stages):
        date = start + dt.timedelta(days=k)
        checks += closure_warnings(s["index"], date, s["closed"], passes)
        w = s["climate"].stats(date) if s["climate"] else None
        if w and (line := weather_line(int(s["day"].get("index", k + 1)), date, s["place"], w)):
            checks.append(line.replace("10 dernières années", f"{HISTORY_YEARS} dernières années"))
    return {"start": start.isoformat(), "end": end.isoformat(), "label": fr_period(start, end).capitalize(),
            "reasons": reasons, "checks": list(dict.fromkeys(checks))}
