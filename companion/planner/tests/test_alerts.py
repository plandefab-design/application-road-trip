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


def test_stations_within_3km_in_route_order():
    from app.alerts import stations_along
    stations = [
        feature(43.02, 5.02, name="Loin"),                    # ~1.6 km east: kept (detour ≤ 3 km)
        feature(43.01, 5.001, brand="Marque"),                # on the road, earlier along
        feature(43.02, 5.2),                                  # ~16 km away: dropped
    ]
    out = stations_along(TRACK, stations)
    assert [s["name"] for s in out] == ["Marque", "Loin"]
    assert out[0]["point"] == {"lat": 43.01, "lon": 5.001}
    assert out[0]["id"].startswith("osm-")


def test_area_features_are_reduced_to_a_point(tmp_path):
    f = tmp_path / "fuel.geojsonseq"
    square = [[[5.0, 43.0], [5.002, 43.0], [5.002, 43.002], [5.0, 43.002]]]
    f.write_text(json.dumps({"type": "Feature", "geometry": {"type": "MultiPolygon", "coordinates": [square]},
                             "properties": {"name": "Station"}}) + "\n", encoding="utf-8")
    [st] = load_features(f)
    assert abs(st["lat"] - 43.001) < 1e-9 and abs(st["lon"] - 5.001) < 1e-9


def test_pauses_by_kind_spacing_and_distance():
    from app.alerts import pauses_along
    spots = [
        feature(43.005, 5.0005, amenity="cafe", name="Café du Col"),          # ~40 m off
        feature(43.006, 5.0005, amenity="cafe"),                               # same kind 110 m later: skipped
        feature(43.02, 5.004, tourism="viewpoint"),                            # ~330 m off: viewpoint ok
        feature(43.02, 5.004, amenity="cafe", name="Trop loin"),               # 330 m: too far for a café
        feature(43.03, 5.0, amenity="drinking_water"),
        feature(43.03, 5.0, shop="bakery"),                                    # not a pause spot
    ]
    out = pauses_along(TRACK, spots)
    assert [(p["kind"], p["name"]) for p in out] == [("cafe", "Café du Col"), ("viewpoint", "Point de vue"), ("water", "Point d'eau")]
    assert out == sorted(out, key=lambda p: p["along"])


def test_track_index_is_accurate_on_a_long_diagonal_stage():
    """Distances along a 300 km diagonal stage match haversine within 20 m (the old projection drifted 2 km)."""
    import math

    from app.alerts import TrackIndex

    track = [{"lat": 43.5 + i * 0.00035, "lon": 4.8 + i * 0.00045} for i in range(6000)]

    def hav(a, b):
        p1, p2 = math.radians(a["lat"]), math.radians(b["lat"])
        dp, dl = p2 - p1, math.radians(b["lon"] - a["lon"])
        h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
        return 2 * 6_371_008.8 * math.asin(math.sqrt(h))

    true_along = sum(hav(a, b) for a, b in zip(track[:5500], track[1:5501]))
    along, offset = TrackIndex(track).project(track[5500]["lat"] + 0.0001, track[5500]["lon"])
    assert abs(along - true_along) < 20 and offset < 15
    assert TrackIndex(track).project(40.0, 1.0) is None          # far from the route: rejected at once
