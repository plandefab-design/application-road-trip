"""MotoTrip companion API — reachable only through Tailscale (`tailscale serve --bg 8080`) + bearer token."""
from __future__ import annotations

import json
import os
import re
import secrets
import time
from pathlib import Path
from typing import Any

import httpx
from fastapi import BackgroundTasks, Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from .planner import Planner, is_configured
from .trip_schema import sanitize_trip, validate_trip

DATA_DIR = Path(os.environ.get("DATA_DIR", "./data"))
GRAPHHOPPER_URL = os.environ.get("GRAPHHOPPER_URL", "http://localhost:8989")
TRIP_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

app = FastAPI(title="MotoTrip companion", version="0.1.0")
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
    trip = sanitize_trip(trip)
    trip_path(trip_id).write_text(json.dumps(trip, ensure_ascii=False, indent=2), encoding="utf-8")
    return trip


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


async def run_chat_job(job: ChatJob, message: str, trip: dict[str, Any]) -> None:
    def on_progress(line: str) -> None:
        job.progress = (job.progress + [line])[-MAX_PROGRESS_LINES:]

    try:
        reply = await planner.chat(message, trip, on_progress=on_progress)
        if reply.trip is not None:
            trip_path(job.tripId).write_text(json.dumps(reply.trip, ensure_ascii=False, indent=2), encoding="utf-8")
        job.reply = ChatReply(text=reply.text, trip=reply.trip, questions=reply.questions)
        job.status = "done"
    except Exception as exc:  # reported to the iPhone instead of being lost in a background task
        job.error = str(exc) or type(exc).__name__
        job.status = "error"


@app.post("/trips/{trip_id}/chat", dependencies=[Depends(require_token)], status_code=202, response_model=ChatJob)
async def start_chat(trip_id: str, body: ChatRequest, background: BackgroundTasks) -> ChatJob:
    trip_path(trip_id)  # validates the id
    if not is_configured():
        raise HTTPException(503, "CLAUDE_CODE_OAUTH_TOKEN absent : lance `claude setup-token` sur le PC et renseigne .env")
    running = next((j for j in JOBS.values() if j.tripId == trip_id and j.status == "running"), None)
    if running is not None:
        return running                    # one planner turn per trip at a time
    body.trip["id"] = trip_id
    job = ChatJob(jobId=secrets.token_urlsafe(12), tripId=trip_id)
    JOBS[job.jobId] = job
    background.add_task(run_chat_job, job, body.message, body.trip)
    return job


@app.get("/trips/{trip_id}/chat/{job_id}", dependencies=[Depends(require_token)], response_model=ChatJob)
async def get_chat_job(trip_id: str, job_id: str) -> ChatJob:
    job = JOBS.get(job_id)
    if job is None or job.tripId != trip_id:
        raise HTTPException(404, "tâche inconnue (le PC a peut-être redémarré) : renvoie ta demande")
    return job


# ---------------------------------------------------------------- routing (GraphHopper proxy)

class RouteRequest(BaseModel):
    points: list[tuple[float, float]] = Field(min_length=2, description="[[lat, lon], ...]")
    profile: str = Field(default="moto_curvy", pattern="^(moto_curvy|moto_fast)$")
    avoid_motorway: bool = True


@app.post("/route", dependencies=[Depends(require_token)])
async def route(req: RouteRequest) -> dict[str, Any]:
    for lat, lon in req.points:
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise HTTPException(422, "coordonnées invalides")
    payload: dict[str, Any] = {
        "profile": req.profile,
        "points": [[lon, lat] for lat, lon in req.points],   # GraphHopper expects [lon, lat]
        "points_encoded": False,
        "instructions": True,
        "details": ["road_class", "max_speed", "average_speed"],
        "locale": "fr",
    }
    if req.avoid_motorway:
        payload["custom_model"] = {"priority": [{"if": "road_class == MOTORWAY", "multiply_by": "0"}]}
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            r = await client.post(f"{GRAPHHOPPER_URL}/route", json=payload)
    except httpx.HTTPError as exc:
        raise HTTPException(503, f"GraphHopper injoignable : {exc}") from exc
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text[:500])
    return r.json()
