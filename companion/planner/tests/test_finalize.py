import asyncio

from app.finalize import finalize_trip, geocode_query, graphhopper_payload

# Fixture coordinates only (not real places): the finalisation logic is what is tested.
KNOWN = {
    "Départ": {"lat": 43.0, "lon": 5.0},
    "Col A": {"lat": 43.2, "lon": 5.2},
    "Hôtel B": {"lat": 43.5, "lon": 5.5},
}


async def fake_locate(name, near):
    return KNOWN.get(geocode_query(name))


def make_router(calls):
    async def route(points):
        calls.append(points)
        return {"distance": 123_400, "time": 7_200_000,
                "points": {"coordinates": [[p["lon"], p["lat"]] for p in points]}}
    return route


def trip(days):
    return {
        "params": {"start": {"name": "Départ"}},
        "days": days,
        "pois": [{"id": "h1", "type": "lodging", "name": "Hôtel B"}],
    }


def run(t, calls):
    return asyncio.run(finalize_trip(t, fake_locate, make_router(calls)))


def test_geocode_query_strips_details():
    assert geocode_query("Col de Murs (D4, 626 m)") == "Col de Murs"
    assert geocode_query("Sault — plateau de lavande") == "Sault"
    assert geocode_query("Uzès") == "Uzès"


def test_two_day_trip_is_traced_through_highlights_and_lodging():
    calls = []
    t = trip([
        {"index": 1, "highlights": [{"name": "Col A (D4)"}], "lodging": [{"poiId": "h1", "selected": True}]},
        {"index": 2, "highlights": []},
    ])
    warnings = run(t, calls)
    assert warnings == []
    # day 1: start -> col -> hotel ; day 2: hotel -> back to start (loop)
    assert calls[0] == [KNOWN["Départ"], KNOWN["Col A"], KNOWN["Hôtel B"]]
    assert calls[1] == [KNOWN["Hôtel B"], KNOWN["Départ"]]
    day1 = t["days"][0]
    assert len(day1["track"]["points"]) == 3
    assert day1["distanceKm"] == 123 and day1["drivingTimeMin"] == 120
    assert t["days"][0]["highlights"][0]["point"] == KNOWN["Col A"]
    assert t["pois"][0]["point"] == KNOWN["Hôtel B"]


def test_unknown_places_are_reported_not_invented():
    calls = []
    t = trip([{"index": 1, "highlights": [{"name": "Nulle part"}, {"name": "Col A"}]}])
    warnings = run(t, calls)
    assert any("Nulle part" in w for w in warnings)
    assert "point" not in t["days"][0]["highlights"][0]
    assert calls[0] == [KNOWN["Départ"], KNOWN["Col A"], KNOWN["Départ"]]


def test_unknown_start_stops_everything():
    t = trip([{"index": 1}])
    t["params"]["start"]["name"] = "Inconnu"
    warnings = run(t, [])
    assert "Départ introuvable" in warnings[0]
    assert "track" not in t["days"][0]


def test_routing_failure_is_a_warning():
    async def broken(points):
        raise RuntimeError("down")
    t = trip([{"index": 1}])
    warnings = asyncio.run(finalize_trip(t, fake_locate, broken))
    assert "route non calculée" in warnings[0]


def test_graphhopper_payload_swaps_to_lon_lat():
    p = graphhopper_payload([(43.0, 5.0), (44.0, 6.0)])
    assert p["points"] == [[5.0, 43.0], [6.0, 44.0]]
    assert p["custom_model"]["priority"][0]["multiply_by"] == "0"


def test_geocode_candidates_simplify_long_names():
    from app.finalize import geocode_candidates
    c = geocode_candidates("Mont Ventoux versant Malaucène — Col des Tempêtes (1841 m) puis sommet (1909 m)")
    assert c[:2] == ["Mont Ventoux", "Mont Ventoux versant Malaucène"]
    assert "Col des Tempêtes" in c
    assert geocode_candidates("Village de Sault (plateau, lavande)") == ["Sault", "Village de Sault"]
    assert geocode_candidates("Descente Mont Ventoux versant Sault — Chalet Reynard")[:2] == ["Mont Ventoux", "Mont Ventoux versant Sault"]


def test_distance_km():
    from app.finalize import distance_km
    assert round(distance_km({"lat": 0, "lon": 0}, {"lat": 1, "lon": 0})) == 111


def test_far_existing_point_is_located_again():
    calls = []
    t = trip([{"index": 1, "highlights": [{"name": "Col A", "point": {"lat": 48.0, "lon": 2.0}}]}])
    run(t, calls)
    assert t["days"][0]["highlights"][0]["point"] == KNOWN["Col A"]


def test_instructions_positioned_along_the_track():
    from app.finalize import instructions_from_path
    # Synthetic straight line: 3 points about 1.11 km apart (0.01° of latitude).
    path = {
        "points": {"coordinates": [[5.0, 43.0], [5.0, 43.01], [5.0, 43.02]]},
        "instructions": [
            {"text": "Continuez sur D1", "sign": 0, "interval": [0, 1], "street_name": "D1"},
            {"text": "Tournez à gauche sur D2", "sign": -2, "interval": [1, 2], "street_name": "D2"},
            {"text": "Au rond-point, prenez la 2e sortie", "sign": 6, "interval": [1, 2], "exit_number": 2},
            {"text": "Arrivée", "sign": 4, "interval": [2, 2]},
            {"text": "Hors limites", "sign": 2, "interval": [9, 9]},
        ],
    }
    out = instructions_from_path(path)
    assert [i["maneuver"] for i in out] == ["depart", "turnLeft", "roundabout", "arrive"]
    assert out[0]["along"] == 0 and out[0]["street"] == "D1"
    assert 1_100 < out[1]["along"] < 1_125
    assert out[2]["exit"] == 2
    assert 2_200 < out[3]["along"] < 2_250


def test_finalize_writes_instructions():
    calls = []
    t = trip([{"index": 1}])
    run(t, calls)
    assert t["days"][0]["instructions"] == []     # fake router returns no instructions


def test_schema_v1_is_upgraded():
    from app.trip_schema import validate_trip
    t = {"schemaVersion": 1, "id": "t", "name": "n", "status": "draft", "params": {}}
    assert validate_trip(t) == []
    assert t["schemaVersion"] == 6
    assert validate_trip({"schemaVersion": 7, "id": "t", "name": "n", "status": "draft", "params": {}})


def test_route_profile_mirrors_tripcore():
    from app.finalize import route_profile
    bikes = lambda *cats: {"bikes": [{"category": c} for c in cats]}
    assert route_profile(bikes("enduro")) == "moto_enduro"
    assert route_profile(bikes("trail", "enduro")) == "moto_adventure"
    assert route_profile(bikes("sport", "enduro")) == "moto_curvy"
    assert route_profile({"bikes": [{}]}) == "moto_curvy"
    assert route_profile({}) == "moto_curvy"
    assert route_profile({**bikes("enduro"), "tripStyle": "rapide"}) == "moto_fast"


def test_payload_uses_profile():
    p = graphhopper_payload([(43.0, 5.0), (44.0, 6.0)], "moto_enduro", avoid_motorway=False)
    assert p["profile"] == "moto_enduro" and "custom_model" not in p


def test_speed_limits_merged_along_the_track():
    from app.finalize import speed_limits_from_path
    path = {
        "points": {"coordinates": [[5.0, 43.0 + i * 0.01] for i in range(5)]},   # ≈ 1 112 m steps
        "details": {"max_speed": [[0, 1, 80], [1, 2, 80.0], [2, 3, None], [3, 4, 50], [4, 4, 90], [0, 1, "x"]]},
    }
    limits = speed_limits_from_path(path)
    assert [l["kmh"] for l in limits] == [80, 50]
    assert limits[0]["from"] == 0 and 2_200 < limits[0]["to"] < 2_250     # two 80 km/h stretches merged
    assert 3_300 < limits[1]["from"] < 3_350


def test_routing_error_explains_places_outside_the_maps():
    from app.finalize import routing_error

    out = routing_error(400, '{"message":"Cannot find point 1: 45.764,4.835"}')
    assert "hors des cartes" in out and "maps.txt" in out
    assert "pas de route" in routing_error(400, '{"message":"Connection between locations not found"}')
    assert routing_error(500, "boom") == "GraphHopper 500 : boom"
