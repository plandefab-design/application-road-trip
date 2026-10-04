"""Moto Road companion API — reachable only through Tailscale (`tailscale serve --bg 8080`) + bearer token."""
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

from .alerts import alerts_along, load_features, pauses_along, stations_along
from .data_pack import all_cameras
from .finalize import (PROFILE_LABELS, Geocoder, finalize_trip, graphhopper_router,
                       instructions_from_path, route_profile)
from .planner import Planner, is_configured
from .radar_sources import refresh_loop
from .seasonal import cached, load_closures, load_passes, seasonal_checks
from .trip_schema import sanitize_trip, validate_trip

DATA_DIR = Path(os.environ.get("DATA_DIR", "./data"))
GRAPHHOPPER_URL = os.environ.get("GRAPHHOPPER_URL", "http://localhost:8989")
TRIP_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Official camera lists refreshed in the background (never blocks the API): France, Spain daily, MapAtlas monthly.
    # They complete the alerts of the trips traced here; the iPhone's own pack comes from GitHub (app.data_pack).
    task = asyncio.create_task(refresh_loop(DATA_DIR))
    yield
    task.cancel()


app = FastAPI(title="Moto Road companion", version="0.1.0", lifespan=lifespan)
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
    trip_path(trip_id).write_text(json.dumps(trip, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
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


@app.delete("/trips/{trip_id}", dependencies=[Depends(require_token)], status_code=204)
def delete_trip(trip_id: str) -> None:
    """Trip deleted by the rider on the iPhone: set aside in trips/deleted (recoverable by hand), never synced back."""
    p = trip_path(trip_id)
    if not p.exists():
        raise HTTPException(404, "trip inconnu")
    bin_dir = p.parent / "deleted"
    bin_dir.mkdir(exist_ok=True)
    p.replace(bin_dir / p.name)


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
    cameras, hazards = all_cameras(DATA_DIR), load_features(osm / "hazards.geojsonseq")
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
    # Seasonal closures and weather of the season, checked from sourced data (no planner turn needed).
    on_progress("Fermetures saisonnières et météo de saison…")
    checks = await seasonal_checks(trip, cached(osm / "closures.geojsonseq", load_closures),
                                   cached(osm / "passes.geojsonseq", load_passes))
    return "\n\n".join([summary] + warnings + checks)


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


# ---------------------------------------------------------------- free ride with several stops

# Route choice of the free ride: curvy (no motorway, no straight trunk roads), fastest without motorway, fastest.
RIDE_MODES = {"curvy": ("moto_curvy", True), "nomotorway": ("moto_fast", True), "fast": ("moto_fast", False)}


class RideRouteRequest(BaseModel):
    points: list[tuple[float, float]] = Field(min_length=2, max_length=12, description="[[lat, lon], ...] start, stops, end")
    mode: str = Field(default="curvy", pattern="^(curvy|nomotorway|fast)$")


@app.post("/ride-route", dependencies=[Depends(require_token)])
async def ride_route(req: RideRouteRequest) -> dict[str, Any]:
    """Road route through the rider's stops in the trip format: track, turn-by-turn, distance, time and the position
    of each intermediate stop along it (the iPhone adds cameras and hazards from its pack)."""
    for lat, lon in req.points:
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise HTTPException(422, "coordonnées invalides")
    profile, avoid = RIDE_MODES[req.mode]
    route = graphhopper_router(GRAPHHOPPER_URL, profile, avoid)
    try:
        path = await route([{"lat": lat, "lon": lon} for lat, lon in req.points])
    except RuntimeError as exc:
        raise HTTPException(422, str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(503, f"GraphHopper injoignable : {exc}") from exc
    coords = (path.get("points") or {}).get("coordinates", [])
    instructions = instructions_from_path(path)
    return {
        "track": [{"lat": round(c[1], 6), "lon": round(c[0], 6)} for c in coords],
        "instructions": instructions,
        "distanceKm": round(path.get("distance", 0) / 1000, 1),
        "timeMin": round(path.get("time", 0) / 60_000),
        "via": [i["along"] for i in instructions if i["maneuver"] == "via"],
    }
