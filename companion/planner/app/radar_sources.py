"""Speed-camera sources merged with OpenStreetMap.

- France: official list of the Sécurité routière map (radars.securite-routiere.gouv.fr), refreshed every 24 h.
- Elsewhere: OpenStreetMap highway=speed_camera (extracted from the local map).
The official source wins; an OSM camera within 60 m of an official one is dropped (its speed limit is kept).
"""
from __future__ import annotations

import asyncio
import json
import math
import time
from pathlib import Path
from typing import Any

import httpx

FR_URL = "https://radars.securite-routiere.gouv.fr/radars/all?_format=json"
USER_AGENT = "MotoTrip-companion/1.0 (personal trip planner; https://github.com/plandefab-design/application-road-trip)"
REFRESH_S = 24 * 3600
MERGE_M = 60

# Official type → (kind, spoken label)
FR_TYPES = {
    "fixes": ("speedCamera", "radar"),
    "discriminants": ("speedCamera", "radar discriminant"),
    "urbain": ("speedCamera", "radar urbain"),
    "itineraire": ("speedCamera", "zone de radar itinérant"),
    "troncons": ("sectionCamera", "radar tronçon"),
    "feux": ("redLightCamera", "radar feu rouge"),
    "niveaux": ("redLightCamera", "radar passage à niveau"),
}


def fr_file(data_dir: Path) -> Path:
    return data_dir / "osm" / "radars_fr.json"


async def refresh_fr(data_dir: Path, force: bool = False) -> bool:
    """Downloads the official French list when older than 24 h. Never raises: the previous file stays in use."""
    path = fr_file(data_dir)
    if not force and path.exists() and time.time() - path.stat().st_mtime < REFRESH_S:
        return False
    try:
        async with httpx.AsyncClient(timeout=60, headers={"User-Agent": USER_AGENT}) as client:
            r = await client.get(FR_URL)
        r.raise_for_status()
        rows = [x for x in r.json() if isinstance(x.get("lat"), (int, float)) and isinstance(x.get("lng"), (int, float))]
        if len(rows) < 1000:           # sanity check: a truncated answer must not replace a good list
            return False
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(rows), encoding="utf-8")
        tmp.replace(path)
        return True
    except (httpx.HTTPError, ValueError, OSError):
        return False


async def refresh_loop(data_dir: Path) -> None:
    while True:
        await refresh_fr(data_dir)
        await asyncio.sleep(3600)


def official_fr(data_dir: Path) -> list[dict[str, Any]]:
    """Official French cameras as features {"lat", "lon", "alert": {kind, label}}."""
    path = fr_file(data_dir)
    if not path.exists():
        return []
    try:
        rows = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    out = []
    for r in rows:
        kind, label = FR_TYPES.get(r.get("type"), ("speedCamera", "radar"))
        out.append({"lat": float(r["lat"]), "lon": float(r["lng"]), "alert": {"kind": kind, "label": label}})
    return out


def _close(a: dict[str, Any], b: dict[str, Any]) -> bool:
    dlat = (a["lat"] - b["lat"]) * 111_195
    dlon = (a["lon"] - b["lon"]) * 111_195 * math.cos(math.radians(a["lat"]))
    return dlat * dlat + dlon * dlon <= MERGE_M * MERGE_M


def merged_cameras(osm: list[dict[str, Any]], official: list[dict[str, Any]], camera_alert) -> list[dict[str, Any]]:
    """Features {"lat", "lon", "alert"} from both sources; official first, OSM duplicates dropped (limit kept)."""
    grid: dict[tuple[int, int], list[dict[str, Any]]] = {}
    for o in official:
        grid.setdefault((int(o["lat"] * 100), int(o["lon"] * 100)), []).append(o)
    out = [dict(o, alert=dict(o["alert"])) for o in official]
    by_id = {id(o): out[i] for i, o in enumerate(official)}
    for f in osm:
        alert = camera_alert(f["props"])
        ci, cj = int(f["lat"] * 100), int(f["lon"] * 100)
        twin = next((o for di in (-1, 0, 1) for dj in (-1, 0, 1)
                     for o in grid.get((ci + di, cj + dj), []) if _close(o, f)), None)
        if twin is not None:
            target = by_id[id(twin)]["alert"]
            if "maxspeed" in alert and "maxspeed" not in target:
                target["maxspeed"] = alert["maxspeed"]
            continue
        out.append({"lat": f["lat"], "lon": f["lon"], "alert": alert})
    return out
