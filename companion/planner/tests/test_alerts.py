import json

from app.alerts import alerts_along, camera_alert, hazard_alert, load_features

# Synthetic straight track going north: 0.01° of latitude ≈ 1 112 m per step.
TRACK = [{"lat": 43.0 + i * 0.01, "lon": 5.0} for i in range(4)]


def feature(lat, lon, **props):
    return {"lat": lat, "lon": lon, "props": props}


def test_cameras_and_hazards_near_the_track_are_positioned():
    cameras = [
        feature(43.005, 5.0001, highway="speed_camera", maxspeed="80"),       # ~8 m off, ~556 m along
        feature(43.015, 5.01, highway="speed_camera", maxspeed="90"),         # ~800 m off: another road
        feature(43.025, 5.0, highway="speed_camera", name="Radar Feu"),
    ]
    hazards = [feature(43.012, 5.0, hazard="falling_rocks"), feature(43.3, 5.0, hazard="curve")]
    alerts = alerts_along(TRACK, cameras, hazards)
    assert [a["kind"] for a in alerts] == ["speedCamera", "hazard", "redLightCamera"]
    assert alerts[0]["maxspeed"] == 80 and 540 < alerts[0]["along"] < 570
    assert alerts[1]["label"] == "chutes de pierres"
    assert alerts == sorted(alerts, key=lambda a: a["along"])


def test_duplicates_are_merged():
    cams = [feature(43.005, 5.0, maxspeed="80"), feature(43.0053, 5.0, maxspeed="80")]
    assert len(alerts_along(TRACK, cams, [])) == 1


def test_labels():
    assert camera_alert({"maxspeed": "50 mph"})["maxspeed"] == 50
    assert "maxspeed" not in camera_alert({"maxspeed": "signals"})
    assert hazard_alert({"hazard": "something_new"})["label"] == "danger"


def test_load_features_reads_geojson_sequence(tmp_path):
    f = tmp_path / "cams.geojsonseq"
    f.write_text("\x1e" + json.dumps({"type": "Feature", "geometry": {"type": "Point", "coordinates": [5.0, 43.0]},
                                      "properties": {"maxspeed": "80"}}) + "\n", encoding="utf-8")
    assert load_features(f) == [{"lat": 43.0, "lon": 5.0, "props": {"maxspeed": "80"}}]
    assert load_features(tmp_path / "missing") == []
