from app.planner import build_prompt
from app.trip_schema import extract_json_block, sanitize_trip, validate_trip


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
