"""MotoTrip companion API — reachable only through Tailscale (`tailscale serve --bg 8080`) + bearer token."""
from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import BackgroundTasks, Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from .alerts import alerts_along, camera_alert, hazard_alert, load_features, pauses_along, stations_along
from . import live_events
from .finalize import PROFILE_LABELS, Geocoder, finalize_trip, graphhopper_payload, graphhopper_router, route_profile
from .planner import Planner, is_configured
from .radar_sources import mapatlas, merged_cameras, official_es, official_fr, refresh_loop
from .trip_schema import sanitize_trip, validate_trip

DATA_DIR = Path(os.environ.get("DATA_DIR", "./data"))
GRAPHHOPPER_URL = os.environ.get("GRAPHHOPPER_URL", "http://localhost:8989")
TRIP_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Official camera lists refreshed in the background (never blocks the API): France, Spain daily, MapAtlas monthly.
    task = asyncio.create_task(refresh_loop(DATA_DIR))
    # Live accidents, jams, closures and obstacles (Bison Futé, DGT) every 5 min.
    live = asyncio.create_task(live_events.refresh_loop())
    yield
    task.cancel()
    live.cancel()


app = FastAPI(title="MotoTrip companion", version="0.1.0", lifespan=lifespan)
planner = Planner(DATA_DIR)


def require_token(authorization: str = Header(default="")) -> None:
    expected = os.environ.get("PLANNER_TOKEN", "")
    if not expected:
        raise HTTPException(503, "PLANNER_TOKEN non configuré sur le PC")
    given = authorization.removeprefix("Bearer ").strip()
    if not secrets.compare_digest(given, expected):
        raise HTTPException(401, "Jeton invalide")


def trips_dir() -> Path:
    d = DATA_DIR / "trips"
    d.mkdir(parents=True, exist_ok=True)
    return d


def trip_path(trip_id: str) -> Path:
    if not TRIP_ID.match(trip_id):
        raise HTTPException(400, "id de trip invalide")
    return trips_dir() / f"{trip_id}.json"


# ---------------------------------------------------------------- health

@app.get("/health")
async def health() -> dict[str, str]:
    gh = "down"
    try:
        async with httpx.AsyncClient(timeout=2) as client:
            r = await client.get(f"{GRAPHHOPPER_URL}/health")
            gh = "ok" if r.status_code == 200 else f"http {r.status_code}"
    except httpx.HTTPError:
        gh = "down"
    return {"status": "ok", "graphhopper": gh, "planner": "ok" if is_configured() else "no-auth"}


# ---------------------------------------------------------------- trips (sync, A11)

def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def store_trip(trip_id: str, trip: dict[str, Any], touch: bool = True) -> dict[str, Any]:
    """Writes a trip; `updatedAt` (schema v6) drives the iPhone ↔ PC sync (most recent wins)."""
    if touch or not trip.get("updatedAt"):
        trip["updatedAt"] = now_iso()
    trip_path(trip_id).write_text(json.dumps(trip, ensure_ascii=False, indent=2), encoding="utf-8")
    return trip


@app.get("/trips", dependencies=[Depends(require_token)])
def list_trips() -> list[dict[str, Any]]:
    """Summary of the trips stored on the PC, for the sync."""
    out = []
    for p in sorted(trips_dir().glob("*.json")):
        try:
            t = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        out.append({"id": t.get("id", p.stem), "name": t.get("name", ""), "updatedAt": t.get("updatedAt")})
    return out


def rides_dir() -> Path:
    d = DATA_DIR / "rides"
    d.mkdir(parents=True, exist_ok=True)
    return d


@app.put("/rides/{ride_id}", dependencies=[Depends(require_token)])
def put_ride(ride_id: str, ride: dict[str, Any]) -> dict[str, str]:
    """Backup of a ride summary + real track recorded by the iPhone."""
    if not TRIP_ID.match(ride_id):
        raise HTTPException(400, "id de sortie invalide")
    (rides_dir() / f"{ride_id}.json").write_text(json.dumps(ride, ensure_ascii=False), encoding="utf-8")
    return {"status": "ok"}


@app.get("/rides", dependencies=[Depends(require_token)])
def list_rides() -> list[str]:
    return sorted(p.stem for p in rides_dir().glob("*.json"))


# ---------------------------------------------------------------- offline alert pack (free ride)

def all_cameras() -> list[dict[str, Any]]:
    """Official lists (France, Spain) + OpenStreetMap + MapAtlas, merged by priority (see radar_sources)."""
    return merged_cameras(load_features(DATA_DIR / "osm" / "speed_cameras.geojsonseq"),
                          official_fr(DATA_DIR) + official_es(DATA_DIR), camera_alert, extra=mapatlas(DATA_DIR))


def alert_pack_version() -> str:
    osm = DATA_DIR / "osm"
    stamps = [int((osm / f).stat().st_mtime) for f in ("speed_cameras.geojsonseq", "hazards.geojsonseq", "radars_fr.json",
                                                        "radars_es.json", "radars_mapatlas.json")
              if (osm / f).exists()]
    return str(max(stamps)) if stamps else ""


@app.get("/alerts-pack/version", dependencies=[Depends(require_token)])
def get_alert_pack_version() -> dict[str, str]:
    return {"version": alert_pack_version()}


@app.get("/alerts-pack", dependencies=[Depends(require_token)])
def get_alert_pack() -> dict[str, Any]:
    """Every speed camera and hazard of the map, compact, for riding without an itinerary (stored on the iPhone)."""
    osm = DATA_DIR / "osm"
    cameras = []
    kind_code = {"speedCamera": 0, "redLightCamera": 1, "sectionCamera": 2}
    for f in all_cameras():
        a = f["alert"]
        # [lat, lon, maxspeed|null, 0 speed / 1 red light / 2 section, label]
        cameras.append([round(f["lat"], 5), round(f["lon"], 5), a.get("maxspeed"), kind_code.get(a["kind"], 0), a["label"]])
    hazards = [[round(f["lat"], 5), round(f["lon"], 5), hazard_alert(f["props"])["label"]]
               for f in load_features(osm / "hazards.geojsonseq")]
    return {"version": alert_pack_version(), "cameras": cameras, "hazards": hazards}


@app.get("/trips/{trip_id}", dependencies=[Depends(require_token)])
def get_trip(trip_id: str) -> dict[str, Any]:
    p = trip_path(trip_id)
    if not p.exists():
        raise HTTPException(404, "trip inconnu")
    return json.loads(p.read_text(encoding="utf-8"))


@app.put("/trips/{trip_id}", dependencies=[Depends(require_token)])
def put_trip(trip_id: str, trip: dict[str, Any]) -> dict[str, Any]:
    if trip.get("id") != trip_id:
        raise HTTPException(400, "id du corps ≠ id de l'URL")
    errors = validate_trip(trip)
    if errors:
        raise HTTPException(422, errors)
    return store_trip(trip_id, sanitize_trip(trip), touch=False)   # keeps the iPhone's updatedAt


# ---------------------------------------------------------------- planner chat (creation mode)

class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    trip: dict[str, Any]


class ChatReply(BaseModel):
    text: str
    trip: dict[str, Any] | None = None
    questions: list[str] = []


class ChatJob(BaseModel):
    """A planner turn runs for minutes (web research): the iPhone starts it, then polls it."""
    jobId: str
    tripId: str
    status: str = "running"            # running | done | error
    progress: list[str] = []
    startedAt: float = Field(default_factory=time.time)
    reply: ChatReply | None = None
    error: str | None = None


JOBS: dict[str, ChatJob] = {}
MAX_PROGRESS_LINES = 20


def geocoder() -> Geocoder:
    return Geocoder(DATA_DIR / "geocode_cache.json")


async def add_routes(trip: dict[str, Any], on_progress) -> str:
    """Finalisation after each planner turn: waypoints located, one road track per day."""
    if not trip.get("days"):
        return ""
    osm = DATA_DIR / "osm"
    cameras, hazards = all_cameras(), load_features(osm / "hazards.geojsonseq")
    fuel = load_features(osm / "fuel_stations.geojsonseq")
    pause_spots = load_features(osm / "pauses.geojsonseq")
    params = trip.get("params") or {}
    profile = route_profile(params)
    avoid_motorway = (params.get("roads") or {}).get("avoidMotorway", True)
    router = graphhopper_router(GRAPHHOPPER_URL, profile, avoid_motorway)
    warnings = await finalize_trip(trip, geocoder().locate, router, on_progress,
                                   alerts_for=lambda track: alerts_along(track, cameras, hazards),
                                   stations_for=(lambda track: stations_along(track, fuel)) if fuel else None,
                                   pauses_for=(lambda track: pauses_along(track, pause_spots)) if pause_spots else None)
    traced = sum(1 for d in trip["days"] if d.get("track"))
    radars = sum(1 for d in trip["days"] for a in d.get("alerts", []) if a["kind"] != "hazard")
    dangers = sum(1 for d in trip["days"] for a in d.get("alerts", []) if a["kind"] == "hazard")
    summary = f"Tracé {PROFILE_LABELS.get(profile, profile)} calculé pour {traced}/{len(trip['days'])} jour(s) : {radars} radar(s) et {dangers} zone(s) de danger sur le parcours."
    if not cameras:
        warnings.append("Base radars absente sur le PC : lance jobs/update_osm.ps1.")
    if not fuel:
        warnings.append("Base des stations absente sur le PC : lance jobs/update_osm.ps1.")
    return "\n\n".join([summary] + warnings)


def start_job(trip_id: str, background: BackgroundTasks, work) -> ChatJob:
    """Runs `work(job, on_progress)` in the background; one job per trip at a time."""
    running = next((j for j in JOBS.values() if j.tripId == trip_id and j.status == "running"), None)
    if running is not None:
        return running
    job = ChatJob(jobId=secrets.token_urlsafe(12), tripId=trip_id)
    JOBS[job.jobId] = job

    async def run() -> None:
        def on_progress(line: str) -> None:
            job.progress = (job.progress + [line])[-MAX_PROGRESS_LINES:]
        try:
            job.reply = await work(on_progress)
            if job.reply.trip is not None:
                store_trip(trip_id, job.reply.trip)
            job.status = "done"
        except Exception as exc:  # reported to the iPhone instead of being lost in a background task
            job.error = str(exc) or type(exc).__name__
            job.status = "error"

    background.add_task(run)
    return job


@app.post("/trips/{trip_id}/chat", dependencies=[Depends(require_token)], status_code=202, response_model=ChatJob)
async def start_chat(trip_id: str, body: ChatRequest, background: BackgroundTasks) -> ChatJob:
    trip_path(trip_id)  # validates the id
    if not is_configured():
        raise HTTPException(503, "CLAUDE_CODE_OAUTH_TOKEN absent : lance `claude setup-token` sur le PC et renseigne .env")
    body.trip["id"] = trip_id

    async def work(on_progress) -> ChatReply:
        reply = await planner.chat(body.message, body.trip, on_progress=on_progress)
        text = reply.text
        if reply.trip is not None:
            routes = await add_routes(reply.trip, on_progress)
            text = f"{text}\n\n{routes}".strip()
        return ChatReply(text=text, trip=reply.trip, questions=reply.questions)

    return start_job(trip_id, background, work)


class FinalizeRequest(BaseModel):
    trip: dict[str, Any]


@app.post("/trips/{trip_id}/finalize", dependencies=[Depends(require_token)], status_code=202, response_model=ChatJob)
async def start_finalize(trip_id: str, body: FinalizeRequest, background: BackgroundTasks) -> ChatJob:
    """Computes the road tracks of an existing trip (no Claude involved)."""
    trip_path(trip_id)
    trip = body.trip
    trip["id"] = trip_id
    errors = validate_trip(trip)
    if errors:
        raise HTTPException(422, errors)

    async def work(on_progress) -> ChatReply:
        summary = await add_routes(trip, on_progress)
        return ChatReply(text=summary or "Aucune étape à tracer.", trip=sanitize_trip(trip))

    return start_job(trip_id, background, work)


@app.get("/trips/{trip_id}/jobs/{job_id}", dependencies=[Depends(require_token)], response_model=ChatJob)
@app.get("/trips/{trip_id}/chat/{job_id}", dependencies=[Depends(require_token)], response_model=ChatJob)
async def get_chat_job(trip_id: str, job_id: str) -> ChatJob:
    job = JOBS.get(job_id)
    if job is None or job.tripId != trip_id:
        raise HTTPException(404, "tâche inconnue (le PC a peut-être redémarré) : renvoie ta demande")
    return job


# ---------------------------------------------------------------- routing (GraphHopper proxy)

class RouteRequest(BaseModel):
    points: list[tuple[float, float]] = Field(min_length=2, description="[[lat, lon], ...]")
    profile: str = Field(default="moto_curvy", pattern="^(moto_curvy|moto_fast|moto_adventure|moto_enduro)$")
    avoid_motorway: bool = True


@app.post("/route", dependencies=[Depends(require_token)])
async def route(req: RouteRequest) -> dict[str, Any]:
    for lat, lon in req.points:
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise HTTPException(422, "coordonnées invalides")
    payload = graphhopper_payload(list(req.points), req.profile, req.avoid_motorway)
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            r = await client.post(f"{GRAPHHOPPER_URL}/route", json=payload)
    except httpx.HTTPError as exc:
        raise HTTPException(503, f"GraphHopper injoignable : {exc}") from exc
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text[:500])
    return r.json()


@app.get("/live-events", dependencies=[Depends(require_token)])
def get_live_events(bbox: str) -> dict[str, Any]:
    """Official live events (France national roads, Spain) in a box "minLon,minLat,maxLon,maxLat", TomTom shape."""
    try:
        min_lon, min_lat, max_lon, max_lat = (float(x) for x in bbox.split(","))
    except ValueError as e:
        raise HTTPException(status_code=422, detail="bbox attendu : minLon,minLat,maxLon,maxLat") from e
    return live_events.in_box(min_lon, min_lat, max_lon, max_lat)


@app.get("/live-events/status", dependencies=[Depends(require_token)])
def get_live_events_status() -> dict[str, Any]:
    return live_events.status()
