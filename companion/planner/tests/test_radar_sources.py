import asyncio
import json

from app.alerts import camera_alert
from app.radar_sources import fr_file, merged_cameras, official_fr, refresh_fr


def test_official_types_and_merge(tmp_path):
    (tmp_path / "osm").mkdir()
    fr_file(tmp_path).write_text(json.dumps([
        {"id": "1", "type": "fixes", "lat": 43.6, "lng": 5.1},
        {"id": "2", "type": "troncons", "lat": 44.0, "lng": 5.0},
        {"id": "3", "type": "feux", "lat": 45.0, "lng": 5.0},
    ]), encoding="utf-8")
    official = official_fr(tmp_path)
    assert [o["alert"]["kind"] for o in official] == ["speedCamera", "sectionCamera", "redLightCamera"]
    osm = [
        {"lat": 43.6003, "lon": 5.1, "props": {"maxspeed": "80"}},     # ≈ 33 m from official #1: duplicate
        {"lat": 47.0, "lon": 8.0, "props": {"maxspeed": "120"}},       # Switzerland: OSM only
    ]
    merged = merged_cameras(osm, official, camera_alert)
    assert len(merged) == 4
    assert merged[0]["alert"] == {"kind": "speedCamera", "label": "radar", "maxspeed": 80}   # limit kept from OSM
    assert merged[-1]["alert"]["maxspeed"] == 120


def test_missing_file_and_offline_refresh(tmp_path):
    assert official_fr(tmp_path) == []
    # A recent file is not downloaded again (no network needed in tests).
    (tmp_path / "osm").mkdir()
    fr_file(tmp_path).write_text("[]", encoding="utf-8")
    assert asyncio.run(refresh_fr(tmp_path)) is False
