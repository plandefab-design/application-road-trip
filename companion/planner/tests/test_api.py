import json
import os

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("PLANNER_TOKEN", "secret-token")
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("GRAPHHOPPER_URL", "http://127.0.0.1:9")  # nothing listens there
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    import importlib

    import app.main as main
    importlib.reload(main)
    return TestClient(main.app)


AUTH = {"Authorization": "Bearer secret-token"}


def minimal_trip(trip_id="t1"):
    return {
        "schemaVersion": 1, "id": trip_id, "name": "Test", "status": "draft",
        "params": {"start": {"name": "A"}, "dateStart": "2027-06-01", "dateEnd": "2027-06-02"},
        "days": [{"index": 1, "meals": [{"poiId": "p1", "selected": True}]}],
        "pois": [{"id": "p1", "type": "meal", "name": "Fictif", "verification": "verified"}],
    }


def test_health_is_public_and_reports_down_services(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "graphhopper": "down", "planner": "no-auth"}


def test_token_required(client):
    assert client.get("/trips/t1").status_code == 401
    assert client.get("/trips/t1", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_put_then_get_trip_forces_unverified_without_source(client):
    r = client.put("/trips/t1", headers=AUTH, json=minimal_trip())
    assert r.status_code == 200, r.text
    got = client.get("/trips/t1", headers=AUTH).json()
    assert got["pois"][0]["verification"] == "unverified"
    assert got["days"][0]["fuelStops"] == []


def test_put_rejects_mismatched_id_and_bad_refs(client):
    assert client.put("/trips/t2", headers=AUTH, json=minimal_trip("t1")).status_code == 400
    bad = minimal_trip()
    bad["days"][0]["meals"] = [{"poiId": "ghost", "selected": False}]
    assert client.put("/trips/t1", headers=AUTH, json=bad).status_code == 422


def test_path_traversal_rejected(client):
    assert client.get("/trips/..%2F..%2Fetc", headers=AUTH).status_code in (400, 404)
    assert client.put("/trips/a.b", headers=AUTH, json=minimal_trip("a.b")).status_code == 400


def test_chat_without_claude_auth_returns_503(client):
    r = client.post("/trips/t1/chat", headers=AUTH, json={"message": "Salut", "trip": minimal_trip()})
    assert r.status_code == 503
    assert "setup-token" in r.json()["detail"]


def test_route_validates_input_and_reports_graphhopper_down(client):
    assert client.post("/route", headers=AUTH, json={"points": [[43.5, 5.4]]}).status_code == 422
    assert client.post("/route", headers=AUTH, json={"points": [[143.5, 5.4], [44, 6]]}).status_code == 422
    r = client.post("/route", headers=AUTH, json={"points": [[43.5, 5.4], [44.0, 6.0]]})
    assert r.status_code == 503
