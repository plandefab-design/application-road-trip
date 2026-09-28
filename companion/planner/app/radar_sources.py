"""Speed-camera sources merged with OpenStreetMap.

- France: official list of the Sécurité routière map (radars.securite-routiere.gouv.fr), refreshed every 24 h.
- Spain: official DGT list (DATEX II, CC BY), refreshed every 24 h.
- Everywhere: OpenStreetMap highway=speed_camera (extracted from the local map).
- Everywhere: MapAtlas Camera Index (CC BY 4.0, 2024 snapshot), refreshed every 30 days.
Priority: official > OSM > MapAtlas; a lower-tier camera within 60 m of a kept one is dropped (its limit is kept).
"""
from __future__ import annotations

import asyncio
import json
import math
import os
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
        _write(path, rows)
        return True
    except (httpx.HTTPError, ValueError, OSError):
        return False


async def refresh_loop(data_dir: Path) -> None:
    while True:
        await refresh_fr(data_dir)
        await refresh_es(data_dir)
        await refresh_mapatlas(data_dir)
        await asyncio.sleep(3600)


# ---------------------------------------------------------------- Spain (DGT, official, CC BY)

ES_URL = "https://nap.dgt.es/datex2/dgt/PredefinedLocationsPublication/radares/content.xml"


def es_file(data_dir: Path) -> Path:
    return data_dir / "osm" / "radars_es.json"


def parse_dgt(xml: bytes) -> list[dict[str, Any]]:
    """DATEX II predefined locations → [{"lat", "lon", "type": fixed|section}] (first point of each location)."""
    import xml.etree.ElementTree as ET
    root = ET.fromstring(xml)
    rows: list[dict[str, Any]] = []
    for loc_set in root.iter():
        if not loc_set.tag.endswith("predefinedLocationSet"):
            continue
        kind = "section" if "VelocidadMedia" in (loc_set.get("id") or "") else "fixed"
        for loc in loc_set:
            if not loc.tag.endswith("predefinedLocation"):
                continue
            lat = next((e.text for e in loc.iter() if e.tag.endswith("latitude")), None)
            lon = next((e.text for e in loc.iter() if e.tag.endswith("longitude")), None)
            try:
                rows.append({"lat": float(lat), "lon": float(lon), "type": kind})
            except (TypeError, ValueError):
                continue
    return rows


async def refresh_es(data_dir: Path, force: bool = False) -> bool:
    path = es_file(data_dir)
    if not force and path.exists() and time.time() - path.stat().st_mtime < REFRESH_S:
        return False
    try:
        async with httpx.AsyncClient(timeout=60, headers={"User-Agent": USER_AGENT}) as client:
            r = await client.get(ES_URL)
        r.raise_for_status()
        rows = parse_dgt(r.content)
        if len(rows) < 200:
            return False
        _write(path, rows)
        return True
    except (httpx.HTTPError, ValueError, OSError, SyntaxError):
        return False


def official_es(data_dir: Path) -> list[dict[str, Any]]:
    out = []
    for r in _read(es_file(data_dir)):
        kind, label = ("sectionCamera", "radar tronçon") if r.get("type") == "section" else ("speedCamera", "radar")
        out.append({"lat": r["lat"], "lon": r["lon"], "alert": {"kind": kind, "label": label}})
    return out


# ---------------------------------------------------------------- MapAtlas Camera Index (CC BY 4.0, snapshot)

MAPATLAS_URL = "https://mapatlas.eu/data/camera-index/{code}.geojson"
MAPATLAS_REFRESH_S = 30 * 24 * 3600
# Countries within ~4 000 km of Salon-de-Provence (missing ones simply answer 404).
MAPATLAS_COUNTRIES = [
    "FR", "BE", "NL", "LU", "DE", "CH", "AT", "IT", "ES", "PT", "GB", "IE", "DK", "NO", "SE", "FI", "IS", "EE", "LV",
    "LT", "PL", "CZ", "SK", "HU", "SI", "HR", "BA", "RS", "ME", "MK", "AL", "GR", "BG", "RO", "MD", "UA", "BY", "RU",
    "TR", "CY", "MT", "MA", "DZ", "TN", "LY", "EG", "IL", "JO", "LB", "SY", "AD", "MC", "SM", "LI", "XK", "GE", "AM", "AZ",
]
MAPATLAS_CLASSES = {
    "spot": ("speedCamera", "radar"),
    "signal": ("redLightCamera", "radar feu rouge"),
    "corridor": ("sectionCamera", "radar tronçon"),
    "adaptive": ("speedCamera", "radar à limite variable"),
}


def mapatlas_file(data_dir: Path) -> Path:
    return data_dir / "osm" / "radars_mapatlas.json"


async def refresh_mapatlas(data_dir: Path, force: bool = False) -> bool:
    path = mapatlas_file(data_dir)
    if not force and path.exists() and time.time() - path.stat().st_mtime < MAPATLAS_REFRESH_S:
        return False
    rows: list[dict[str, Any]] = []
    try:
        async with httpx.AsyncClient(timeout=60, headers={"User-Agent": USER_AGENT}) as client:
            for code in MAPATLAS_COUNTRIES:
                r = await client.get(MAPATLAS_URL.format(code=code))
                if r.status_code != 200:
                    continue
                for f in r.json().get("features", []):
                    lon, lat = (f.get("geometry") or {}).get("coordinates", [None, None])[:2]
                    props = f.get("properties") or {}
                    if isinstance(lat, (int, float)) and isinstance(lon, (int, float)):
                        rows.append({"lat": lat, "lon": lon, "class": props.get("class"), "limit": props.get("limitKph")})
                await asyncio.sleep(0.5)          # gentle with a free service
    except (httpx.HTTPError, ValueError):
        return False
    if len(rows) < 1000:
        return False
    _write(path, rows)
    return True


def mapatlas(data_dir: Path) -> list[dict[str, Any]]:
    out = []
    for r in _read(mapatlas_file(data_dir)):
        kind, label = MAPATLAS_CLASSES.get(r.get("class"), ("speedCamera", "radar"))
        alert: dict[str, Any] = {"kind": kind, "label": label}
        if isinstance(r.get("limit"), (int, float)) and 0 < r["limit"] < 150:
            alert["maxspeed"] = int(r["limit"])
        out.append({"lat": r["lat"], "lon": r["lon"], "alert": alert})
    return out


def _write(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(f".{os.getpid()}.{id(rows)}.tmp")   # unique: the refresh loop may write concurrently
    tmp.write_text(json.dumps(rows), encoding="utf-8")
    tmp.replace(path)


def _read(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []


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


def merge_tiers(tiers: list[list[dict[str, Any]]]) -> list[dict[str, Any]]:
    """Features {"lat", "lon", "alert"} by priority tier (first wins): a later camera within 60 m of a kept one
    is a duplicate; its speed limit completes the kept camera when that one has none."""
    grid: dict[tuple[int, int], list[dict[str, Any]]] = {}
    out: list[dict[str, Any]] = []
    for tier in tiers:
        for f in tier:
            ci, cj = int(f["lat"] * 100), int(f["lon"] * 100)
            twin = next((o for di in (-1, 0, 1) for dj in (-1, 0, 1)
                         for o in grid.get((ci + di, cj + dj), []) if _close(o, f)), None)
            if twin is not None:
                if "maxspeed" in f["alert"] and "maxspeed" not in twin["alert"]:
                    twin["alert"]["maxspeed"] = f["alert"]["maxspeed"]
                continue
            kept = {"lat": f["lat"], "lon": f["lon"], "alert": dict(f["alert"])}
            grid.setdefault((ci, cj), []).append(kept)
            out.append(kept)
    return out


def merged_cameras(osm: list[dict[str, Any]], official: list[dict[str, Any]], camera_alert,
                   extra: list[dict[str, Any]] | None = None) -> list[dict[str, Any]]:
    """Official lists first, then OpenStreetMap, then MapAtlas (oldest snapshot) — duplicates dropped."""
    osm_features = [{"lat": f["lat"], "lon": f["lon"], "alert": camera_alert(f["props"])} for f in osm]
    return merge_tiers([official, osm_features, extra or []])
