"""Live road events from official open feeds (DATEX II), refreshed every 5 minutes.

- France, national road network: Bison Futé / DIR (tipi.bison-fute.gouv.fr), Licence Ouverte.
- Spain: DGT incidents (nap.dgt.es), CC BY.
Served to the iPhone in the TomTom Incident Details shape, so the app parses and announces them like TomTom
incidents (accidents, jams, closures, obstacles, roadworks). Optional while riding: the app never waits for them.
"""
from __future__ import annotations

import asyncio
import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import Any

import httpx

FEEDS = {
    "fr": "https://tipi.bison-fute.gouv.fr/bison-fute-ouvert/publicationsDIR/Evenementiel-DIR/grt/RRN/content.xml",
    "es": "https://nap.dgt.es/datex2/v3/dgt/SituationPublication/datex2_v37.xml",
}
USER_AGENT = "MotoTrip-companion/1.0 (personal trip planner; https://github.com/plandefab-design/application-road-trip)"
REFRESH_S = 300

# DATEX II sub-type value → TomTom iconCategory (ids ≥ 20 are MotoTrip additions, see TrafficIncident.Category).
# First match in this order wins: the most dangerous kind describes the event.
CATEGORIES: list[tuple[str, int]] = [
    ("accident", 1),
    ("vehicleOnFire", 23), ("forestFire", 26), ("fire", 26),
    ("peopleOnRoadway", 24), ("animalsOnTheRoad", 21), ("animalPresence", 21),
    ("rockfalls", 22), ("avalanches", 22), ("landslips", 22), ("mudslide", 22), ("subsidence", 25),
    ("objectOnTheRoad", 20), ("shedLoad", 20), ("obstructionOnTheRoad", 20), ("spillageOnTheRoad", 20),
    ("flooding", 11), ("snowOnTheRoad", 5), ("iceOnRoad", 5), ("blackIce", 5), ("frost", 5),
    ("fog", 2), ("denseFog", 2), ("strongWinds", 10), ("roadSurfaceInPoorCondition", 25),
    ("brokenDownVehicle", 14), ("vehicleStuck", 14), ("abandonedVehicle", 14),
    ("queuingTraffic", 6), ("stationaryTraffic", 6), ("slowTraffic", 6), ("heavyTraffic", 6),
    ("roadClosed", 8), ("carriagewayClosures", 8), ("closedPermanentlyForTheWinter", 8),
    ("laneClosures", 7), ("singleAlternateLineTraffic", 7), ("narrowLanes", 7), ("contraflow", 7), ("lanesDeviated", 7),
    ("roadworks", 9), ("maintenanceWork", 9), ("repairWork", 9), ("resurfacingWork", 9), ("constructionWork", 9),
    ("roadMarkingWork", 9), ("roadsideWork", 9), ("grassCuttingWork", 9),
]
LABELS = {1: "Accident", 2: "Brouillard", 5: "Verglas ou neige", 6: "Bouchon", 7: "Voie fermée", 8: "Route fermée",
          9: "Travaux", 10: "Vent violent", 11: "Inondation", 14: "Véhicule arrêté", 20: "Obstacle sur la route",
          21: "Animaux sur la route", 22: "Chute de pierres", 23: "Véhicule en feu", 24: "Piétons sur la chaussée",
          25: "Chaussée dégradée", 26: "Incendie"}
TYPE_TAGS = ("Type",)                       # accidentType, obstructionType, roadMaintenanceType, causeType…
ROAD = re.compile(r"^(A|AP|AG|N|RN|D|RD|M|E|C|CV|GI|BI)-?\s?\d{1,4}[a-zA-Z]?$")

_events: list[dict[str, Any]] = []
_fetched_at: float = 0.0
_status: dict[str, str] = {}


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _ended(text: str | None, now: datetime) -> bool:
    if not text:
        return False
    try:
        return datetime.fromisoformat(text.strip().replace("Z", "+00:00")) < now
    except ValueError:
        return False


def parse_datex(xml: bytes, source: str, now: datetime | None = None) -> list[dict[str, Any]]:
    """DATEX II v2/v3 SituationPublication → [{"id", "lat", "lon", "cat", "label", "road"}] (current, real events)."""
    now = now or datetime.now(timezone.utc)
    root = ET.fromstring(xml)
    out: list[dict[str, Any]] = []
    for situation in root.iter():
        if _local(situation.tag) != "situation":
            continue
        status = next((e.text for e in situation.iter() if _local(e.tag) == "informationStatus"), "real")
        if status != "real":                                      # skip tests and exercises
            continue
        for rec in situation:
            if _local(rec.tag) != "situationRecord":
                continue
            values = {e.text.strip() for e in rec.iter() if _local(e.tag).endswith(TYPE_TAGS) and e.text}
            cat = next((c for key, c in CATEGORIES if key in values), None)
            if cat is None:
                continue
            if _ended(next((e.text for e in rec.iter() if _local(e.tag) == "overallEndTime"), None), now):
                continue
            lat = next((e.text for e in rec.iter() if _local(e.tag) == "latitude"), None)
            lon = next((e.text for e in rec.iter() if _local(e.tag) == "longitude"), None)
            try:
                lat_f, lon_f = float(lat), float(lon)             # type: ignore[arg-type]
            except (TypeError, ValueError):
                continue
            road = next((t for t in (e.text.strip() for e in rec.iter() if e.text and _local(e.tag) in ("value", "roadNumber", "roadName"))
                         if ROAD.match(t)), None)
            out.append({"id": f"{source}-{rec.get('id') or len(out)}", "lat": lat_f, "lon": lon_f, "cat": cat,
                        "label": LABELS[cat], "road": road})
    return out


async def refresh() -> None:
    """Fetches every feed; a failing feed keeps its previous events (never raises)."""
    global _events, _fetched_at
    kept = {k: [e for e in _events if e["id"].startswith(k + "-")] for k in FEEDS}
    async with httpx.AsyncClient(timeout=60, headers={"User-Agent": USER_AGENT}, follow_redirects=True) as client:
        for key, url in FEEDS.items():
            try:
                r = await client.get(url)
                r.raise_for_status()
                kept[key] = await asyncio.to_thread(parse_datex, r.content, key)
                _status[key] = f"ok {len(kept[key])}"
            except (httpx.HTTPError, ET.ParseError, ValueError) as e:
                _status[key] = f"échec ({type(e).__name__})"
    _events = [e for events in kept.values() for e in events]
    _fetched_at = time.time()


async def refresh_loop() -> None:
    while True:
        await refresh()
        await asyncio.sleep(REFRESH_S)


def in_box(min_lon: float, min_lat: float, max_lon: float, max_lat: float,
           events: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """TomTom Incident Details v5 shape: {"incidents": [{geometry, properties{id, iconCategory, events}}]}."""
    items = []
    for e in (_events if events is None else events):
        if min_lat <= e["lat"] <= max_lat and min_lon <= e["lon"] <= max_lon:
            text = e["label"] + (f" · {e['road']}" if e.get("road") else "")
            items.append({"type": "Feature",
                          "geometry": {"type": "Point", "coordinates": [e["lon"], e["lat"]]},
                          "properties": {"id": e["id"], "iconCategory": e["cat"], "events": [{"description": text}]}})
    return {"incidents": items}


def status() -> dict[str, Any]:
    return {"events": len(_events), "fetchedAt": int(_fetched_at), "feeds": dict(_status)}
