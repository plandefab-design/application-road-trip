from app.planner import build_prompt
from app.trip_schema import extract_json_block, repair_trip, sanitize_trip, validate_trip


def test_extract_last_json_block():
    text = 'Voici.\n```json\n{"a": 1}\n```\nPuis\n```json\n{"id": "x", "b": 2}\n```\nFin'
    prose, data = extract_json_block(text)
    assert data == {"id": "x", "b": 2}
    assert "Voici." in prose and "Fin" in prose and "```" in prose  # first block kept as prose


def test_extract_without_block_or_with_invalid_json():
    assert extract_json_block("rien") == ("rien", None)
    prose, data = extract_json_block("x\n```json\n{bad}\n```")
    assert data is None


def test_sanitize():
    trip = {"pois": [
        {"id": "1", "verification": "verified", "source": "  "},
        {"id": "2", "verification": "verified", "source": "https://ex.org"},
        {"id": "3", "verification": "maybe", "source": "https://ex.org"},
    ]}
    out = sanitize_trip(trip)
    assert [p["verification"] for p in out["pois"]] == ["unverified", "verified", "unverified"]


def test_validate_fills_defaults_and_checks_indexes():
    trip = {"schemaVersion": 1, "id": "t", "name": "n", "status": "draft", "params": {},
            "days": [{"index": 2}]}
    errors = validate_trip(trip)
    assert "days[0].index must be 1" in errors
    assert trip["days"][0]["fuelStops"] == [] and trip["pois"] == []


def test_prompt_contains_trip_and_message():
    p = build_prompt("Ajoute la Bonnette", {"id": "t"})
    assert "Ajoute la Bonnette" in p and '"id": "t"' in p


def test_prompt_omits_geometry():
    trip = {"id": "t", "days": [{"index": 1, "track": {"points": [{"lat": 1, "lon": 2}] * 50},
                                 "instructions": [{"along": 0}], "highlights": [{"name": "Col"}]}]}
    prompt = build_prompt("Salut", trip)
    assert "track" not in prompt and "instructions" not in prompt and "Col" in prompt
    assert "track" in trip["days"][0]   # original untouched


def test_types_outside_the_schema_are_mapped():
    from app.trip_schema import sanitize_trip

    trip = {"days": [{"highlights": [{"name": "A", "type": "depart"}, {"name": "B", "type": "col"}, {"name": "C"}]}],
            "pois": [{"id": "p", "type": "hotel", "name": "H"}]}
    sanitize_trip(trip)
    assert [h["type"] for h in trip["days"][0]["highlights"]] == ["viewpoint", "pass", "viewpoint"]
    assert trip["pois"][0]["type"] == "lodging" and trip["pois"][0]["verification"] == "unverified"


def test_repair_needs_no_second_claude_turn():
    """Usual slips of a planner answer are fixed on the PC: the result validates without asking Claude again."""
    previous = {"id": "t1", "name": "Alpes", "status": "draft", "params": {"start": {"name": "A"}}}
    proposed = {"schemaVersion": 99, "id": "other", "days": [
        {"index": 3, "fuelStops": [{"name": "sans position", "kmFromStart": 80}],
         "meals": [{"poiId": "m1", "selected": True}, {"poiId": "ghost"}]},
        {"index": 7},
    ], "pois": [{"id": "m1", "type": "restaurant", "name": "Restaurant test", "verification": "verified"}]}
    trip = repair_trip(proposed, previous)
    assert validate_trip(trip) == []
    assert trip["id"] == "t1" and trip["name"] == "Alpes" and trip["params"] == previous["params"]
    assert trip["status"] == "proposed" and trip["schemaVersion"] == 9
    assert [d["index"] for d in trip["days"]] == [1, 2]
    assert trip["days"][0]["fuelStops"] == []                       # the iPhone places them on real stations
    assert [r["poiId"] for r in trip["days"][0]["meals"]] == ["m1"]
    assert trip["pois"][0]["type"] == "meal" and trip["pois"][0]["verification"] == "unverified"   # no source


def test_repair_keeps_a_good_answer():
    previous = {"id": "t1", "name": "Alpes", "status": "proposed", "params": {"start": {"name": "A"}}}
    proposed = {"schemaVersion": 8, "id": "t1", "name": "Alpes du Sud", "status": "proposed", "params": {"start": {"name": "B"}},
                "days": [{"index": 1, "highlights": [{"name": "Col test", "type": "pass"}]}], "pois": []}
    trip = repair_trip(proposed, previous)
    assert trip["name"] == "Alpes du Sud" and trip["params"] == {"start": {"name": "B"}}
    assert trip["days"][0]["highlights"] == [{"name": "Col test", "type": "pass"}]
