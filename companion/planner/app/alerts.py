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


def load_features(path: Path) -> list[dict[str, Any]]:
    """GeoJSON sequence → [{"lat", "lon", "props"}], cached until the file changes."""
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
            geom = feat.get("geometry") or {}
            if geom.get("type") != "Point":
                continue
            lon, lat = geom["coordinates"][:2]
            features.append({"lat": lat, "lon": lon, "props": feat.get("properties") or {}})
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


def _project(track: list[dict[str, float]], lat: float, lon: float) -> tuple[float, float]:
    """(distance along the track to the closest point, lateral offset), metres, equirectangular."""
    cos_lat = math.cos(math.radians(lat))
    k = 111_195.0
    best_off, best_along, along = float("inf"), 0.0, 0.0
    for a, b in zip(track, track[1:]):
        ax, ay = (a["lon"] - lon) * k * cos_lat, (a["lat"] - lat) * k
        bx, by = (b["lon"] - lon) * k * cos_lat, (b["lat"] - lat) * k
        dx, dy = bx - ax, by - ay
        seg = math.hypot(dx, dy)
        t = 0.0 if seg == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / (seg * seg)))
        off = math.hypot(ax + t * dx, ay + t * dy)
        if off < best_off:
            best_off, best_along = off, along + t * seg
        along += seg
    return best_along, best_off


def alerts_along(track: list[dict[str, float]], cameras: list[dict[str, Any]],
                 hazards: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Alerts within MAX_OFFSET_M of the track, sorted by distance along it."""
    if len(track) < 2:
        return []
    margin = 0.001  # ≈ 100 m bounding-box prefilter
    lats = [p["lat"] for p in track]
    lons = [p["lon"] for p in track]
    box = (min(lats) - margin, max(lats) + margin, min(lons) - margin, max(lons) + margin)
    out: list[dict[str, Any]] = []
    for features, make in ((cameras, camera_alert), (hazards, hazard_alert)):
        for f in features:
            if not (box[0] <= f["lat"] <= box[1] and box[2] <= f["lon"] <= box[3]):
                continue
            along, offset = _project(track, f["lat"], f["lon"])
            if offset > MAX_OFFSET_M:
                continue
            alert = make(f["props"])
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
