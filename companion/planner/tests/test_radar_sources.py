import asyncio
import json

from app.alerts import camera_alert
from app.radar_sources import (es_file, fr_file, mapatlas, mapatlas_file, merge_tiers, merged_cameras, official_es,
                               official_fr, parse_dgt, refresh_fr)


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


DGT_XML = b"""<?xml version="1.0" encoding="UTF-8"?>
<d2LogicalModel xmlns:_0="http://datex2.eu/schema/1_0/1_0">
 <_0:payloadPublication>
  <_0:predefinedLocationSet id="GUID_Inventario_CabinasCinemometro">
   <_0:predefinedLocation id="a"><_0:predefinedLocation><_0:tpegpointLocation><_0:point><_0:pointCoordinates>
     <_0:latitude>40.5</_0:latitude><_0:longitude>-3.7</_0:longitude></_0:pointCoordinates></_0:point>
   </_0:tpegpointLocation></_0:predefinedLocation></_0:predefinedLocation>
  </_0:predefinedLocationSet>
  <_0:predefinedLocationSet id="GUID_Inventario_CinemometrosVelocidadMedia">
   <_0:predefinedLocation id="b">
     <_0:latitude>41.0</_0:latitude><_0:longitude>-4.0</_0:longitude>
     <_0:latitude>41.1</_0:latitude><_0:longitude>-4.1</_0:longitude>
   </_0:predefinedLocation>
   <_0:predefinedLocation id="c"><_0:latitude>bad</_0:latitude></_0:predefinedLocation>
  </_0:predefinedLocationSet>
 </_0:payloadPublication>
</d2LogicalModel>"""


def test_parse_dgt_fixed_and_section(tmp_path):
    rows = parse_dgt(DGT_XML)
    assert rows == [{"lat": 40.5, "lon": -3.7, "type": "fixed"}, {"lat": 41.0, "lon": -4.0, "type": "section"}]
    (tmp_path / "osm").mkdir()
    es_file(tmp_path).write_text(json.dumps(rows), encoding="utf-8")
    alerts = [f["alert"]["kind"] for f in official_es(tmp_path)]
    assert alerts == ["speedCamera", "sectionCamera"]


def test_mapatlas_mapping(tmp_path):
    (tmp_path / "osm").mkdir()
    mapatlas_file(tmp_path).write_text(json.dumps([
        {"lat": 45.0, "lon": 7.0, "class": "signal", "limit": None},
        {"lat": 45.1, "lon": 7.1, "class": "corridor", "limit": 110},
        {"lat": 45.2, "lon": 7.2, "class": "unknown", "limit": 999},
    ]), encoding="utf-8")
    alerts = [f["alert"] for f in mapatlas(tmp_path)]
    assert alerts == [{"kind": "redLightCamera", "label": "radar feu rouge"},
                      {"kind": "sectionCamera", "label": "radar tronçon", "maxspeed": 110},
                      {"kind": "speedCamera", "label": "radar"}]


def test_merge_tiers_priority_and_limit_completion():
    official = [{"lat": 43.0, "lon": 5.0, "alert": {"kind": "speedCamera", "label": "radar"}}]
    lower = [{"lat": 43.0002, "lon": 5.0002, "alert": {"kind": "speedCamera", "label": "x", "maxspeed": 90}},
             {"lat": 43.1, "lon": 5.1, "alert": {"kind": "speedCamera", "label": "radar"}}]
    merged = merge_tiers([official, lower])
    assert len(merged) == 2
    assert merged[0]["alert"] == {"kind": "speedCamera", "label": "radar", "maxspeed": 90}
    assert official[0]["alert"] == {"kind": "speedCamera", "label": "radar"}   # inputs untouched


def test_missing_files_are_empty(tmp_path):
    assert official_es(tmp_path) == [] and mapatlas(tmp_path) == []
