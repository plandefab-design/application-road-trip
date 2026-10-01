"""trip.json helpers shared by the API and the planner (mirror of core/Sources/TripCore/Model/Trip.swift)."""
from __future__ import annotations

import json
import re
from typing import Any

SCHEMA_VERSION = 7          # v2 instructions, v3 alerts, v4 stations, v5 ride profile, v6 speed limits + pauses + updatedAt, v7 instruction ref + toward.
ACCEPTED_VERSIONS = {1, 2, 3, 4, 5, 6, 7}
POI_TYPES = {"meal", "lodging", "fuel", "pass", "viewpoint"}
STATUSES = {"draft", "proposed", "validated", "ready", "active", "done"}

_JSON_BLOCK = re.compile(r"```json\s*(\{.*?\})\s*```", re.DOTALL)


def closest_poi_type(value: Any) -> str:
    """A type outside the schema (« col », « hotel », « road », « ville »…) → the closest one (mirror of TripCore)."""
    s = str(value or "").lower()
    if s in POI_TYPES:
        return s
    if any(k in s for k in ("col", "pass", "summit", "sommet")):
        return "pass"
    if any(k in s for k in ("restau", "repas", "food", "cafe", "café", "lunch", "diner", "dîner")):
        return "meal"
    if any(k in s for k in ("hotel", "hôtel", "lodg", "gite", "gîte", "heberg", "héberg", "camping", "nuit")):
        return "lodging"
    if any(k in s for k in ("fuel", "essence", "station", "carbur")):
        return "fuel"
    return "viewpoint"


def sanitize_trip(trip: dict[str, Any]) -> dict[str, Any]:
    """Never-invent rule: a POI without a source is forced to 'unverified'. Types outside the schema are mapped."""
    for day in trip.get("days", []) or []:
        for highlight in day.get("highlights", []) or []:
            highlight["type"] = closest_poi_type(highlight.get("type"))
    for poi in trip.get("pois", []) or []:
        poi["type"] = closest_poi_type(poi.get("type"))
        source = (poi.get("source") or "").strip()
        if not source:
            poi["verification"] = "unverified"
        elif poi.get("verification") not in ("verified", "unverified"):
            poi["verification"] = "unverified"
    return trip


def validate_trip(trip: dict[str, Any]) -> list[str]:
    """Minimal structural validation (the iPhone runs the full TripValidator)."""
    errors: list[str] = []
    if trip.get("schemaVersion") in ACCEPTED_VERSIONS:
        trip["schemaVersion"] = SCHEMA_VERSION
    else:
        errors.append(f"schemaVersion must be {SCHEMA_VERSION}")
    for key in ("id", "name", "status", "params"):
        if key not in trip:
            errors.append(f"missing '{key}'")
    if trip.get("status") not in STATUSES:
        errors.append("invalid status")
    for i, day in enumerate(trip.get("days", []) or []):
        if day.get("index") != i + 1:
            errors.append(f"days[{i}].index must be {i + 1}")
        for key in ("highlights", "planBRefs", "fuelStops", "meals", "lodging"):
            day.setdefault(key, [])
        for f in day["fuelStops"]:
            if not isinstance(f.get("point"), dict) or "kmFromStart" not in f or "name" not in f:
                errors.append(f"days[{i}].fuelStops: name, point and kmFromStart are required")
    ids = {p.get("id") for p in trip.get("pois", []) or []}
    for poi in trip.get("pois", []) or []:
        if poi.get("type") not in POI_TYPES:
            errors.append(f"poi {poi.get('id')}: invalid type")
    for day in trip.get("days", []) or []:
        for ref in (day.get("meals") or []) + (day.get("lodging") or []):
            if ref.get("poiId") not in ids:
                errors.append(f"day {day.get('index')}: unknown poi {ref.get('poiId')}")
    trip.setdefault("pois", [])
    trip.setdefault("days", [])
    trip.setdefault("checklist", [])
    trip.setdefault("offlinePack", {"integrity": "unknown"})
    return errors


def extract_json_block(text: str) -> tuple[str, dict[str, Any] | None]:
    """Split a planner answer into (prose, trip JSON). The last ```json block wins."""
    matches = list(_JSON_BLOCK.finditer(text))
    if not matches:
        return text.strip(), None
    last = matches[-1]
    prose = (text[: last.start()] + text[last.end():]).strip()
    try:
        return prose, json.loads(last.group(1))
    except json.JSONDecodeError:
        return text.strip(), None
