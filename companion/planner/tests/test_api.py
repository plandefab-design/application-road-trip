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


def test_chat_runs_as_a_job_with_progress(client, monkeypatch):
    import app.main as main
    from app.planner import PlannerReply

    async def fake_chat(message, trip, on_progress=None):
        on_progress("Recherche : col de la Bonette")
        return PlannerReply(text="Voici le trip", trip=trip, questions=["Hôtel ou camping ?"])

    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "x")
    monkeypatch.setattr(main.planner, "chat", fake_chat)
    async def no_routes(trip, on_progress):
        return ""
    monkeypatch.setattr(main, "add_routes", no_routes)
    r = client.post("/trips/t1/chat", headers=AUTH, json={"message": "Salut", "trip": minimal_trip()})
    assert r.status_code == 202, r.text
    job_id = r.json()["jobId"]

    got = client.get(f"/trips/t1/chat/{job_id}", headers=AUTH).json()
    assert got["status"] == "done"
    assert got["progress"] == ["Recherche : col de la Bonette"]
    assert got["reply"]["text"] == "Voici le trip"
    assert got["reply"]["questions"] == ["Hôtel ou camping ?"]
    assert client.get("/trips/t1", headers=AUTH).status_code == 200   # proposed trip saved on the PC


def test_chat_job_reports_planner_errors(client, monkeypatch):
    import app.main as main

    async def failing_chat(message, trip, on_progress=None):
        raise RuntimeError("quota dépassé")

    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "x")
    monkeypatch.setattr(main.planner, "chat", failing_chat)
    job_id = client.post("/trips/t1/chat", headers=AUTH, json={"message": "Salut", "trip": minimal_trip()}).json()["jobId"]
    got = client.get(f"/trips/t1/chat/{job_id}", headers=AUTH).json()
    assert got["status"] == "error"
    assert "quota" in got["error"]


def test_unknown_chat_job_is_404(client):
    assert client.get("/trips/t1/chat/nope", headers=AUTH).status_code == 404
    assert client.get("/trips/t1/chat/nope").status_code == 401


def test_describe_tool_use():
    from app.planner import describe_tool_use
    assert describe_tool_use("WebSearch", {"query": "col du Galibier ouverture"}) == "Recherche : col du Galibier ouverture"
    assert describe_tool_use("WebFetch", {"url": "https://example.org"}).startswith("Lecture : ")


def test_finalize_job_returns_traced_trip(client, monkeypatch):
    import app.main as main

    async def fake_routes(trip, on_progress):
        trip["days"][0]["track"] = {"points": [{"lat": 1, "lon": 1}, {"lat": 2, "lon": 2}]}
        return "Tracé calculé pour 1/1 jour(s)."

    monkeypatch.setattr(main, "add_routes", fake_routes)
    r = client.post("/trips/t1/finalize", headers=AUTH, json={"trip": minimal_trip()})
    assert r.status_code == 202, r.text
    got = client.get(f"/trips/t1/jobs/{r.json()['jobId']}", headers=AUTH).json()
    assert got["status"] == "done"
    assert got["reply"]["trip"]["days"][0]["track"]["points"][1] == {"lat": 2, "lon": 2}
    assert got["reply"]["trip"]["pois"][0]["verification"] == "unverified"   # never-invent rule still applied


def test_sync_list_and_updated_at(client):
    t = minimal_trip()
    t["updatedAt"] = "2027-01-01T10:00:00Z"
    client.put("/trips/t1", headers=AUTH, json=t)
    assert client.get("/trips", headers=AUTH).json() == [{"id": "t1", "name": "Test", "updatedAt": "2027-01-01T10:00:00Z"}]
    t2 = minimal_trip("t2")
    client.put("/trips/t2", headers=AUTH, json=t2)                   # no date: stamped by the PC
    listed = {x["id"]: x for x in client.get("/trips", headers=AUTH).json()}
    assert listed["t2"]["updatedAt"].endswith("Z")
    assert client.get("/trips").status_code == 401


def test_rides_backup(client):
    assert client.put("/rides/r1", headers=AUTH, json={"km": 120}).status_code == 200
    assert client.get("/rides", headers=AUTH).json() == ["r1"]
    assert client.put("/rides/a.b", headers=AUTH, json={}).status_code == 400


def test_delete_trip_sets_it_aside(client):
    client.put("/trips/t1", headers=AUTH, json=minimal_trip())
    assert client.delete("/trips/t1", headers=AUTH).status_code == 204
    assert client.get("/trips/t1", headers=AUTH).status_code == 404
    assert [t["id"] for t in client.get("/trips", headers=AUTH).json()] == []
    assert client.delete("/trips/t1", headers=AUTH).status_code == 404


def test_ride_route_modes_and_stops(client, monkeypatch):
    from app import main

    seen = {}

    def fake_router(base_url, profile, avoid):
        async def route(points):
            seen.update(profile=profile, avoid=avoid, points=points)
            return {"distance": 12_345, "time": 900_000,
                    "points": {"coordinates": [[5.0, 43.0], [5.0, 43.05], [5.0, 43.1]]},
                    "instructions": [{"sign": 0, "interval": [0, 1], "text": "Continuez"},
                                     {"sign": 5, "interval": [1, 2], "text": "Étape"},
                                     {"sign": 4, "interval": [2, 2], "text": "Arrivée"}]}
        return route

    monkeypatch.setattr(main, "graphhopper_router", fake_router)
    body = {"points": [[43.0, 5.0], [43.05, 5.0], [43.1, 5.0]], "mode": "nomotorway"}
    r = client.post("/ride-route", headers=AUTH, json=body)
    assert r.status_code == 200
    data = r.json()
    assert seen["profile"] == "moto_fast" and seen["avoid"] is True and len(seen["points"]) == 3
    assert data["distanceKm"] == 12.3 and data["timeMin"] == 15 and len(data["track"]) == 3
    assert len(data["via"]) == 1 and 5_000 < data["via"][0] < 6_000
    assert client.post("/ride-route", headers=AUTH, json={**body, "mode": "teleport"}).status_code == 422


def test_validated_stops_become_waypoints():
    from app.finalize import insert_stops

    a, b = {"lat": 43.0, "lon": 5.0}, {"lat": 44.0, "lon": 5.0}
    meal, fuel = {"lat": 43.6, "lon": 5.02}, {"lat": 43.3, "lon": 4.98}
    out = insert_stops([a, b], [meal, fuel, {"lat": 43.0001, "lon": 5.0}])
    assert out == [a, fuel, meal, b]          # in route order, the stop on the start not added twice


def test_writes_are_atomic(client, tmp_path):
    from app.fsutil import write_atomic
    target = tmp_path / "t.json"
    write_atomic(target, "old")
    write_atomic(target, "new")
    assert target.read_text(encoding="utf-8") == "new"
    assert [p.name for p in tmp_path.iterdir()] == ["t.json"]      # no temporary file left behind


def test_finished_jobs_are_purged_after_an_hour():
    from app import main
    main.JOBS.clear()
    main.JOBS["old"] = main.ChatJob(jobId="old", tripId="t", status="done", startedAt=1_000)
    main.JOBS["slow"] = main.ChatJob(jobId="slow", tripId="t", status="running", startedAt=1_000)
    main.JOBS["new"] = main.ChatJob(jobId="new", tripId="t", status="done", startedAt=9_000)
    main.purge_jobs(now=10_000)
    assert sorted(main.JOBS) == ["new", "slow"]      # a running job is never dropped
    main.JOBS.clear()
