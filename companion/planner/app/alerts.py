"""Road alerts along a day's track (schema v3): speed cameras and mapped hazards from OpenStreetMap.

Source files are extracted from the local OSM map by jobs/update_osm.ps1 (weekly):
data/osm/speed_cameras.geojsonseq (highway=speed_camera) and data/osm/hazards.geojsonseq (hazard=*).
Everything is embedded in the trip, so the iPhone announces them offline.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

MAX_OFFSET_M = 40          # an alert farther than this from the track belongs to another road
DEDUP_M = 80               # same kind closer than this along the track = one alert

HAZARD_LABELS = {
    "animal_crossing": "passage d'animaux",
    "curve": "virage dangereux",
    "curves": "virages dangereux",
    "turns": "virages dangereux",
    "dangerous_junction": "intersection dangereuse",
    "falling_rocks": "chutes de pierres",
    "rock_slide": "chutes de pierres",
    "landslide": "glissement de terrain",
    "children": "enfants",
    "school_zone": "zone scolaire",
    "slippery": "chaussée glissante",
    "slippery;ice": "chaussée glissante, verglas",
    "ice": "verglas",
    "bump": "ralentisseur",
    "crossing": "passage piéton",
    "frost_heave": "chaussée déformée",
    "loose_gravel": "gravillons",
    "damaged_road": "chaussée dégradée",
    "queues_likely": "bouchons fréquents",
    "side_winds": "vent latéral",
    "fog": "brouillard fréquent",
}

_cache: dict[Path, tuple[float, list[dict[str, Any]]]] = {}


def _representative_point(geom: dict[str, Any]) -> tuple[float, float] | None:
    """(lon, lat) of a point, or the average of the outline of a line / (multi)polygon (fuel stations are often areas)."""
    kind, coords = geom.get("type"), geom.get("coordinates")
    if not coords:
        return None
    if kind == "Point":
        return coords[0], coords[1]
    if kind == "LineString":
        ring = coords
    elif kind == "Polygon":
        ring = coords[0]
    elif kind == "MultiPolygon":
        ring = coords[0][0]
    else:
        return None
    return sum(c[0] for c in ring) / len(ring), sum(c[1] for c in ring) / len(ring)


USED_TAGS = ("name", "brand", "operator", "amenity", "tourism", "hazard", "maxspeed", "enforcement", "type")


def load_features(path: Path) -> list[dict[str, Any]]:
    """GeoJSON sequence → [{"lat", "lon", "props"}] (areas reduced to a point), cached until the file changes."""
    if not path.exists():
        return []
    mtime = path.stat().st_mtime
    cached = _cache.get(path)
    if cached and cached[0] == mtime:
        return cached[1]
    features = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip().lstrip("\x1e")
            if not line:
                continue
            feat = json.loads(line)
            point = _representative_point(feat.get("geometry") or {})
            if point is None:
                continue
            lon, lat = point
            props = feat.get("properties") or {}
            # Only the tags read by the planner: the rest of OSM's tags would cost hundreds of MB for 7 countries.
            features.append({"lat": lat, "lon": lon, "props": {k: props[k] for k in USED_TAGS if k in props}})
    _cache[path] = (mtime, features)
    return features


def camera_alert(props: dict[str, Any]) -> dict[str, Any]:
    name = (props.get("name") or "").lower()
    enforcement = (props.get("enforcement") or props.get("type") or "").lower()
    kind = "redLightCamera" if ("feu" in name or "traffic_signals" in enforcement) else "speedCamera"
    alert: dict[str, Any] = {"kind": kind, "label": "radar feu rouge" if kind == "redLightCamera" else "radar"}
    try:
        alert["maxspeed"] = int(str(props.get("maxspeed", "")).split()[0])
    except (ValueError, IndexError):
        pass
    return alert


def hazard_alert(props: dict[str, Any]) -> dict[str, Any]:
    value = str(props.get("hazard", "")).lower()
    return {"kind": "hazard", "label": HAZARD_LABELS.get(value, "danger")}


K_M = 111_195.0            # metres per degree of latitude
_GRID = 0.05               # degrees (≈ 5 km): coarse spatial index so Europe-sized files stay fast


def _cell(lat: float, lon: float) -> tuple[int, int]:
    return int(math.floor(lat / _GRID)), int(math.floor(lon / _GRID))


class TrackIndex:
    """A day's track indexed by grid cell: a feature is projected only on the segments near it (a few hundred
    instead of thousands), and features far from the route are rejected by a set lookup. Reach ≥ 4 km."""

    def __init__(self, track: list[dict[str, float]]):
        self.track = track
        self.cum = [0.0]
        for a, b in zip(track, track[1:]):
            cos_lat = math.cos(math.radians((a["lat"] + b["lat"]) / 2))
            self.cum.append(self.cum[-1] + math.hypot((b["lon"] - a["lon"]) * K_M * cos_lat, (b["lat"] - a["lat"]) * K_M))
        self.segments: dict[tuple[int, int], list[int]] = {}
        for i in range(len(track) - 1):
            cells = {_cell(track[i]["lat"], track[i]["lon"]), _cell(track[i + 1]["lat"], track[i + 1]["lon"])}
            for ci, cj in cells:
                for di in (-1, 0, 1):
                    for dj in (-1, 0, 1):
                        self.segments.setdefault((ci + di, cj + dj), []).append(i)

    def near(self, lat: float, lon: float) -> bool:
        return _cell(lat, lon) in self.segments

    def project(self, lat: float, lon: float) -> tuple[float, float] | None:
        """(distance along the track, lateral offset) in metres, or None when the point is far from the track."""
        segs = self.segments.get(_cell(lat, lon))
        if not segs:
            return None
        cos_lat = math.cos(math.radians(lat))
        best_off, best_along = float("inf"), 0.0
        for i in segs:
            a, b = self.track[i], self.track[i + 1]
            ax, ay = (a["lon"] - lon) * K_M * cos_lat, (a["lat"] - lat) * K_M
            dx, dy = (b["lon"] - a["lon"]) * K_M * cos_lat, (b["lat"] - a["lat"]) * K_M
            seg2 = dx * dx + dy * dy
            t = 0.0 if seg2 == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / seg2))
            off = math.hypot(ax + t * dx, ay + t * dy)
            if off < best_off:
                best_off, best_along = off, self.cum[i] + t * (self.cum[i + 1] - self.cum[i])
        return best_along, best_off


def alerts_along(track: list[dict[str, float]], cameras: list[dict[str, Any]],
                 hazards: list[dict[str, Any]], index: TrackIndex | None = None) -> list[dict[str, Any]]:
    """Alerts within MAX_OFFSET_M of the track, sorted by distance along it."""
    if len(track) < 2:
        return []
    index = index or TrackIndex(track)
    out: list[dict[str, Any]] = []
    for features, make in ((cameras, camera_alert), (hazards, hazard_alert)):
        for f in features:
            projected = index.project(f["lat"], f["lon"])
            if projected is None or projected[1] > MAX_OFFSET_M:
                continue
            along = projected[0]
            alert = dict(f["alert"]) if "alert" in f else make(f["props"])
            alert["along"] = round(along, 1)
            alert["point"] = {"lat": round(f["lat"], 6), "lon": round(f["lon"], 6)}
            out.append(alert)
    out.sort(key=lambda a: a["along"])
    deduped: list[dict[str, Any]] = []
    for a in out:
        if any(d["kind"] == a["kind"] and abs(d["along"] - a["along"]) < DEDUP_M for d in deduped[-3:]):
            continue
        deduped.append(a)
    return deduped


STATION_MAX_DETOUR_M = 3_000   # same as TripCore FuelPlanner.maxDetour


def stations_along(track: list[dict[str, float]], stations: list[dict[str, Any]],
                   index: TrackIndex | None = None) -> list[dict[str, Any]]:
    """Fuel stations within 3 km of the track (schema v4): the iPhone places the stops (TripCore FuelPlanner)."""
    if len(track) < 2:
        return []
    index = index or TrackIndex(track)
    out: list[tuple[float, dict[str, Any]]] = []
    for s in stations:
        projected = index.project(s["lat"], s["lon"])
        if projected is None or projected[1] > STATION_MAX_DETOUR_M:
            continue
        along = projected[0]
        props = s["props"]
        name = props.get("name") or props.get("brand") or props.get("operator") or "Station-service"
        station_id = f"osm-{round(s['lat'], 5)}-{round(s['lon'], 5)}"
        out.append((along, {"id": station_id, "name": name, "point": {"lat": round(s["lat"], 6), "lon": round(s["lon"], 6)}}))
    out.sort(key=lambda x: x[0])
    return [s for _, s in out]


# Pause spots (schema v6): max distance from the track per kind, and spacing between two spots of a kind.
PAUSE_RULES = {"cafe": 150, "viewpoint": 400, "water": 100}
PAUSE_SPACING_M = 3_000


def pause_kind(props: dict[str, Any]) -> str | None:
    if props.get("amenity") == "cafe":
        return "cafe"
    if props.get("tourism") == "viewpoint":
        return "viewpoint"
    if props.get("amenity") == "drinking_water":
        return "water"
    return None


def pauses_along(track: list[dict[str, float]], features: list[dict[str, Any]],
                 index: TrackIndex | None = None) -> list[dict[str, Any]]:
    """Cafés, viewpoints and drinking water near the track, one per kind every 3 km, in route order."""
    if len(track) < 2:
        return []
    index = index or TrackIndex(track)
    found: list[dict[str, Any]] = []
    for f in features:
        if not index.near(f["lat"], f["lon"]):
            continue
        kind = pause_kind(f["props"])
        if kind is None:
            continue
        projected = index.project(f["lat"], f["lon"])
        if projected is None or projected[1] > PAUSE_RULES[kind]:
            continue
        along = projected[0]
        name = f["props"].get("name") or {"cafe": "Café", "viewpoint": "Point de vue", "water": "Point d'eau"}[kind]
        found.append({"along": round(along, 1), "kind": kind, "name": name,
                      "point": {"lat": round(f["lat"], 6), "lon": round(f["lon"], 6)}})
    found.sort(key=lambda p: (p["along"], p["name"] in ("Café", "Point de vue", "Point d'eau")))
    kept: list[dict[str, Any]] = []
    last: dict[str, float] = {}
    for p in found:
        if p["along"] - last.get(p["kind"], -PAUSE_SPACING_M) >= PAUSE_SPACING_M:
            kept.append(p)
            last[p["kind"]] = p["along"]
    return kept
