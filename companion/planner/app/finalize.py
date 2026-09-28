"""Trip finalisation: locate each day's waypoints and compute the road geometry (SPEC §4.2, M7).

Claude plans with place names; coordinates come from OpenStreetMap (Nominatim geocoding, cached,
1 request/s as required by its usage policy) and the roads from the local GraphHopper moto profile.
Nothing is invented: a place that cannot be located is reported, never guessed.
"""
from __future__ import annotations

import asyncio
import json
import math
import re
import time
from pathlib import Path
from typing import Any, Awaitable, Callable

import httpx

NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "MotoTrip-companion/1.0 (personal trip planner; https://github.com/plandefab-design/application-road-trip)"

Point = dict[str, float]
Locate = Callable[[str, "Point | None"], Awaitable["Point | None"]]
Route = Callable[[list[Point]], Awaitable[dict[str, Any]]]


def geocode_query(name: str) -> str:
    """'Col de Murs (D4, 626 m)' -> 'Col de Murs'; 'Sault — plateau' -> 'Sault'."""
    head = re.split(r"\s[—–-]\s|\(|:|/", name, maxsplit=1)[0]
    return head.strip(" ,.")


_GENERIC_PREFIX = re.compile(r"^(village|ville|bourg|site|descente|montée|traversée|passage|arrivée|départ)\s+(de\s+|du\s+|des\s+|d'|par\s+|vers\s+)?",
                             re.IGNORECASE)
_TAIL = re.compile(r"\s+(versant|par|via|puis|vers|et)\s.*$", re.IGNORECASE)


def geocode_candidates(name: str) -> list[str]:
    """Simplified names to try, most generic first, e.g.
    'Mont Ventoux versant Malaucène — Col des Tempêtes (1841 m)' -> ['Mont Ventoux',
    'Mont Ventoux versant Malaucène', 'Col des Tempêtes', …]; 'Village de Sault (lavande)' -> ['Sault', 'Village de Sault']."""
    out: list[str] = []
    for part in re.split(r"\s[—–-]\s|/|:", re.sub(r"\([^)]*\)", "", name)):
        part = part.strip(" ,.")
        # Most generic first: descriptive words ("Village de", "versant …") mislead the geocoder.
        for candidate in (_GENERIC_PREFIX.sub("", _TAIL.sub("", part)), _GENERIC_PREFIX.sub("", part), _TAIL.sub("", part), part):
            candidate = candidate.strip(" ,.")
            if len(candidate) >= 3 and candidate not in out:
                out.append(candidate)
    return out


def distance_km(a: Point, b: Point) -> float:
    lat1, lat2 = math.radians(a["lat"]), math.radians(b["lat"])
    dlat, dlon = lat2 - lat1, math.radians(b["lon"] - a["lon"])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * 6371.0088 * math.asin(math.sqrt(h))   # same radius as TripCore (Geo.earthRadius)


MAX_HOP_KM = 200   # a waypoint farther than this from the previous one is a homonym, not the intended place


def graphhopper_payload(points: list[tuple[float, float]], profile: str = "moto_curvy",
                        avoid_motorway: bool = True) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "profile": profile,
        "points": [[lon, lat] for lat, lon in points],   # GraphHopper expects [lon, lat]
        "points_encoded": False,
        "instructions": True,
        "details": ["road_class", "max_speed", "average_speed"],
        "locale": "fr",
    }
    if avoid_motorway:
        payload["custom_model"] = {"priority": [{"if": "road_class == MOTORWAY", "multiply_by": "0"}]}
    return payload


class Geocoder:
    """OSM Nominatim with an on-disk cache and the 1 request/second policy."""

    def __init__(self, cache_file: Path, min_interval: float = 1.1):
        self.cache_file = cache_file
        self.min_interval = min_interval
        self._lock = asyncio.Lock()
        self._last = 0.0

    def _cache(self) -> dict[str, Point | None]:
        if self.cache_file.exists():
            return json.loads(self.cache_file.read_text(encoding="utf-8"))
        return {}

    async def locate(self, name: str, near: Point | None = None) -> Point | None:
        """First simplified name found near the previous waypoint (or anywhere for the start)."""
        for query in geocode_candidates(name):
            for point in await self._search(query, near):
                if near is None or distance_km(near, point) <= MAX_HOP_KM:
                    return point
        return None

    async def _search(self, query: str, near: Point | None) -> list[Point]:
        params: dict[str, Any] = {"q": query, "format": "jsonv2", "limit": 5, "accept-language": "fr"}
        if near:  # search around the previous waypoint first (same names exist all over France)
            lat, lon = near["lat"], near["lon"]
            params["viewbox"] = f"{lon - 2:.2f},{lat + 2:.2f},{lon + 2:.2f},{lat - 2:.2f}"
            params["bounded"] = 1
        key = json.dumps(params, sort_keys=True, ensure_ascii=False)
        cache = self._cache()
        if key in cache:
            return cache[key]
        async with self._lock:
            wait = self.min_interval - (time.monotonic() - self._last)
            if wait > 0:
                await asyncio.sleep(wait)
            async with httpx.AsyncClient(timeout=10, headers={"User-Agent": USER_AGENT}) as client:
                r = await client.get(NOMINATIM_URL, params=params)
            self._last = time.monotonic()
        r.raise_for_status()
        points = [{"lat": round(float(x["lat"]), 6), "lon": round(float(x["lon"]), 6)} for x in r.json()]
        cache[key] = points
        self.cache_file.parent.mkdir(parents=True, exist_ok=True)
        self.cache_file.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
        return points


OFFROAD_LEVEL = {"sport": 0, "roadster": 0, "touring": 0, "custom": 0, "trail": 1, "enduro": 2}
PROFILE_LABELS = {"moto_curvy": "routes sinueuses", "moto_fast": "rapide", "moto_adventure": "trail (pistes roulantes)",
                  "moto_enduro": "enduro (chemins ouverts aux motos)"}


def route_profile(params: dict[str, Any]) -> str:
    """Mirror of TripCore TripParams.routeProfile: the most road-bound bike decides; « rapide » = fastest roads."""
    if params.get("tripStyle") == "rapide":
        return "moto_fast"
    levels = [OFFROAD_LEVEL.get(b.get("category"), 0) for b in params.get("bikes") or [] if b.get("category")]
    level = min(levels) if levels else 0
    return {2: "moto_enduro", 1: "moto_adventure"}.get(level, "moto_curvy")


def graphhopper_router(base_url: str, profile: str = "moto_curvy", avoid_motorway: bool = True) -> Route:
    async def route(points: list[Point]) -> dict[str, Any]:
        payload = graphhopper_payload([(p["lat"], p["lon"]) for p in points], profile, avoid_motorway)
        async with httpx.AsyncClient(timeout=120) as client:
            r = await client.post(f"{base_url}/route", json=payload)
        if r.status_code != 200:
            raise RuntimeError(f"GraphHopper {r.status_code} : {r.text[:200]}")
        return r.json()["paths"][0]
    return route


# GraphHopper instruction sign → trip.json maneuver (schema v2). Leaving a roundabout is silent.
SIGN_TO_MANEUVER = {
    -98: "uTurn", -8: "uTurn", 8: "uTurn", -7: "keepLeft", 7: "keepRight", -6: "straight", 6: "roundabout",
    -3: "sharpLeft", -2: "turnLeft", -1: "slightLeft", 0: "straight", 1: "slightRight", 2: "turnRight",
    3: "sharpRight", 4: "arrive", 5: "via",
}


def instructions_from_path(path: dict[str, Any]) -> list[dict[str, Any]]:
    """Turn-by-turn list positioned by distance along the track (same haversine as TripCore)."""
    coords = path.get("points", {}).get("coordinates", [])
    cumulative = [0.0]
    for (lon1, lat1, *_), (lon2, lat2, *_) in zip(coords, coords[1:]):
        cumulative.append(cumulative[-1] + distance_km({"lat": lat1, "lon": lon1}, {"lat": lat2, "lon": lon2}) * 1000)
    out: list[dict[str, Any]] = []
    for n, ins in enumerate(path.get("instructions", []) or []):
        start = (ins.get("interval") or [0])[0]
        if not 0 <= start < len(cumulative):
            continue
        item: dict[str, Any] = {
            "along": round(cumulative[start], 1),
            "maneuver": "depart" if n == 0 else SIGN_TO_MANEUVER.get(ins.get("sign"), "straight"),
            "text": ins.get("text", ""),
        }
        if ins.get("street_name"):
            item["street"] = ins["street_name"]
        if ins.get("exit_number"):
            item["exit"] = ins["exit_number"]
        out.append(item)
    return out


def _valid(point: Any) -> bool:
    return isinstance(point, dict) and isinstance(point.get("lat"), (int, float)) and isinstance(point.get("lon"), (int, float))


async def finalize_trip(trip: dict[str, Any], locate: Locate, route: Route,
                        on_progress: Callable[[str], None] | None = None,
                        alerts_for: Callable[[list[Point]], list[dict[str, Any]]] | None = None,
                        stations_for: Callable[[list[Point]], list[dict[str, Any]]] | None = None) -> list[str]:
    """Fills points, days[].track, distanceKm and drivingTimeMin in place. Returns warnings (French)."""
    progress = on_progress or (lambda _line: None)
    warnings: list[str] = []
    params = trip.get("params") or {}
    pois = {p.get("id"): p for p in trip.get("pois", []) or []}
    days = trip.get("days", []) or []

    async def place_point(place: dict[str, Any] | None, near: Point | None) -> Point | None:
        if not place:
            return None
        if _valid(place.get("point")) and near is not None and distance_km(near, place["point"]) > MAX_HOP_KM:
            del place["point"]      # homonym picked earlier: locate it again near the route
        if not _valid(place.get("point")):
            progress(f"Localisation : {place.get('name', '?')}")
            found = await locate(place.get("name", ""), near)
            if found:
                place["point"] = found
        return place.get("point") if _valid(place.get("point")) else None

    start = await place_point(params.get("start"), None)
    if start is None:
        return [f"Départ introuvable sur la carte : « {(params.get('start') or {}).get('name', '?')} »."]
    end_place = params.get("end") or params.get("start")        # loop when no end
    previous = start

    for n, day in enumerate(days):
        waypoints = [previous]
        for highlight in day.get("highlights", []) or []:
            point = await place_point(highlight, waypoints[-1])
            if point:
                waypoints.append(point)
            else:
                warnings.append(f"Jour {day.get('index')} : « {highlight.get('name')} » introuvable, ignoré.")

        is_last = n == len(days) - 1
        end: Point | None
        if is_last:
            end = await place_point(end_place, waypoints[-1])
        else:
            refs = day.get("lodging", []) or []
            ref = next((r for r in refs if r.get("selected")), refs[0] if refs else None)
            poi = pois.get(ref.get("poiId")) if ref else None
            end = None
            if poi is not None:
                if not _valid(poi.get("point")):
                    progress(f"Localisation : {poi.get('name', '?')}")
                    found = await locate(poi.get("address") or poi.get("name", ""), waypoints[-1])
                    if found:
                        poi["point"] = found
                end = poi.get("point") if _valid(poi.get("point")) else None
            if end is None:
                warnings.append(f"Jour {day.get('index')} : pas d'hébergement localisé, l'étape s'arrête au dernier point.")
        if end:
            waypoints.append(end)

        if len(waypoints) < 2:
            warnings.append(f"Jour {day.get('index')} : pas assez de points pour tracer l'étape.")
            continue
        progress(f"Calcul de la route du jour {day.get('index')}…")
        try:
            path = await route(waypoints)
        except Exception as exc:  # GraphHopper down or point off the road network
            warnings.append(f"Jour {day.get('index')} : route non calculée ({exc}).")
            continue
        coords = path.get("points", {}).get("coordinates", [])
        day["track"] = {"points": [{"lat": round(c[1], 6), "lon": round(c[0], 6)} for c in coords]}
        day["distanceKm"] = round(path.get("distance", 0) / 1000)
        day["drivingTimeMin"] = round(path.get("time", 0) / 60_000)
        day["instructions"] = instructions_from_path(path)
        if alerts_for is not None:
            day["alerts"] = alerts_for(day["track"]["points"])
        if stations_for is not None:
            day["stations"] = stations_for(day["track"]["points"])
        previous = waypoints[-1]
    return warnings
