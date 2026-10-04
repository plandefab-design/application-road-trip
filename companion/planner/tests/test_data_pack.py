"""Packs published by GitHub for the iPhone. Synthetic OSM files only (no network)."""
import json
import zlib

from app.data_pack import alerts_pack, main, seasons_pack, write_packs


def feature(geometry, props):
    return json.dumps({"type": "Feature", "geometry": geometry, "properties": props}) + "\n"


def write_osm(tmp_path):
    osm = tmp_path / "osm"
    osm.mkdir()
    (osm / "speed_cameras.geojsonseq").write_text(
        feature({"type": "Point", "coordinates": [5.1, 43.6]}, {"highway": "speed_camera", "maxspeed": "80"}), encoding="utf-8")
    (osm / "hazards.geojsonseq").write_text(
        feature({"type": "Point", "coordinates": [5.2, 43.7]}, {"hazard": "falling_rocks"}), encoding="utf-8")
    straight = [[6.6 + i * 0.0001, 44.8] for i in range(11)]          # 10 points in line: only the ends are kept
    (osm / "closures.geojsonseq").write_text(
        feature({"type": "LineString", "coordinates": straight},
                {"highway": "secondary", "ref": "D 902", "motor_vehicle:conditional": "no @ (Oct 15-Jun 1)"})
        + feature({"type": "LineString", "coordinates": straight}, {"highway": "service", "access:conditional": "no @ (19:00-07:00)"}),
        encoding="utf-8")
    (osm / "passes.geojsonseq").write_text(
        feature({"type": "Point", "coordinates": [6.7, 44.8]}, {"mountain_pass": "yes", "name": "Col test", "ele": "2360"})
        + feature({"type": "Point", "coordinates": [6.8, 44.9]}, {"mountain_pass": "yes"}), encoding="utf-8")
    return tmp_path


def test_alerts_pack_rows(tmp_path):
    pack = alerts_pack(write_osm(tmp_path))
    assert pack == {"cameras": [[43.6, 5.1, 80, 0, "radar"]], "hazards": [[43.7, 5.2, "chutes de pierres"]]}


def test_seasons_pack_keeps_dated_closures_simplified_and_named_passes(tmp_path):
    pack = seasons_pack(write_osm(tmp_path))
    assert pack["closures"] == [["D 902", [[10, 15, 6, 1]], [44.8, 6.6, 44.8, 6.601]]]
    assert pack["passes"] == [[44.8, 6.7, 2360, "Col test"]]


def test_written_packs_are_raw_deflate_versioned_by_content(tmp_path):
    out = tmp_path / "out"
    content = {"cameras": [[43.6, 5.1, None, 0, "radar"]], "hazards": []}
    manifest = write_packs(out, {"alerts": content})
    entry = manifest["alerts"]
    pack = json.loads(zlib.decompress((out / entry["file"]).read_bytes(), -15))
    assert pack == {"version": entry["version"], **content}
    assert json.loads((out / "manifest.json").read_text(encoding="utf-8"))["alerts"] == entry
    assert write_packs(tmp_path / "again", {"alerts": content})["alerts"]["version"] == entry["version"]
    assert write_packs(tmp_path / "other", {"alerts": {**content, "hazards": [[1, 2, "x"]]}})["alerts"]["version"] != entry["version"]


def test_incomplete_data_is_never_published(tmp_path, monkeypatch):
    async def offline(_data_dir):
        return None
    monkeypatch.setattr("app.data_pack.refresh_sources", offline)
    assert main([str(write_osm(tmp_path)), str(tmp_path / "out")]) == 1      # one camera only: not a real pack
    assert not (tmp_path / "out").exists()
