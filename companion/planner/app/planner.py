"""Trip planner powered by the Claude Agent SDK (runs on FAB's PC with his own subscription).

Creation mode only — the iPhone never needs this to navigate.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .trip_schema import extract_json_block, sanitize_trip, validate_trip

SYSTEM_PROMPT_FILE = Path(__file__).resolve().parent.parent / "system_prompt.md"
MAX_REPAIR_ATTEMPTS = 1
RESEARCH_TOOLS = ("WebSearch", "WebFetch")


class PlannerUnavailable(RuntimeError):
    """Raised when the Agent SDK is missing or not authenticated."""


@dataclass
class PlannerReply:
    text: str
    trip: dict[str, Any] | None
    questions: list[str]


def is_configured() -> bool:
    return bool(os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") or os.environ.get("ANTHROPIC_API_KEY"))


def describe_tool_use(name: str, tool_input: dict[str, Any]) -> str:
    """Short French progress line shown on the iPhone while Claude works."""
    if name == "WebSearch":
        return f"Recherche : {tool_input.get('query', '')}"[:140]
    if name == "WebFetch":
        return f"Lecture : {tool_input.get('url', '')}"[:140]
    return f"Outil : {name}"


def without_geometry(trip: dict[str, Any]) -> dict[str, Any]:
    """Trip as shown to Claude: tracks, instructions and alerts (thousands of points) are recomputed by the PC anyway."""
    days = [{k: v for k, v in d.items() if k not in ("track", "instructions", "alerts", "stations", "speedLimits", "pauses")} for d in trip.get("days", []) or []]
    return {**trip, "days": days}


def build_prompt(message: str, trip: dict[str, Any]) -> str:
    return (
        "Formulaire et état actuel du trip (trip.json v8) :\n"
        f"```json\n{json.dumps(without_geometry(trip), ensure_ascii=False)}\n```\n\n"
        f"Demande du pilote : {message}\n\n"
        "Réponds d'abord en texte pour le pilote, puis termine OBLIGATOIREMENT par UN bloc ```json contenant "
        "le trip.json v8 COMPLET mis à jour (même id). S'il manque une information indispensable, pose tes "
        "questions dans le champ \"questions\" du JSON (liste de chaînes) au lieu de deviner."
    )


class Planner:
    def __init__(self, data_dir: Path):
        self.sessions_file = data_dir / "planner_sessions.json"
        self.sessions_file.parent.mkdir(parents=True, exist_ok=True)

    def _sessions(self) -> dict[str, str]:
        if self.sessions_file.exists():
            return json.loads(self.sessions_file.read_text(encoding="utf-8"))
        return {}

    def _save_session(self, trip_id: str, session_id: str) -> None:
        sessions = self._sessions()
        sessions[trip_id] = session_id
        self.sessions_file.write_text(json.dumps(sessions), encoding="utf-8")

    async def chat(
        self, message: str, trip: dict[str, Any], on_progress: Callable[[str], None] | None = None
    ) -> PlannerReply:
        if not is_configured():
            raise PlannerUnavailable("CLAUDE_CODE_OAUTH_TOKEN absent : lance `claude setup-token` sur le PC et renseigne .env")
        try:
            from claude_agent_sdk import (
                AssistantMessage,
                ClaudeAgentOptions,
                ResultMessage,
                TextBlock,
                ToolUseBlock,
                query,
            )
        except ImportError as exc:  # pragma: no cover - depends on install
            raise PlannerUnavailable("claude-agent-sdk non installé") from exc

        trip_id = trip.get("id", "unknown")
        options = ClaudeAgentOptions(
            system_prompt=SYSTEM_PROMPT_FILE.read_text(encoding="utf-8"),
            # Research only: web search/fetch are the ONLY tools available (no sub-agents, no shell, no files).
            tools=list(RESEARCH_TOOLS),
            allowed_tools=list(RESEARCH_TOOLS),
            disallowed_tools=["Agent", "Task", "Bash", "Write", "Edit", "NotebookEdit"],
            permission_mode="default",
            resume=self._sessions().get(trip_id),
            model=os.environ.get("PLANNER_MODEL") or None,
            max_turns=40,
        )

        prompt = build_prompt(message, trip)
        for attempt in range(MAX_REPAIR_ATTEMPTS + 1):
            text_parts: list[str] = []
            async for msg in query(prompt=prompt, options=options):
                if isinstance(msg, AssistantMessage):
                    for block in msg.content:
                        if isinstance(block, TextBlock):
                            text_parts.append(block.text)
                        elif isinstance(block, ToolUseBlock) and on_progress is not None:
                            on_progress(describe_tool_use(block.name, block.input))
                elif isinstance(msg, ResultMessage):
                    self._save_session(trip_id, msg.session_id)
                    options.resume = msg.session_id

            prose, proposed = extract_json_block("\n".join(text_parts))
            if proposed is None:
                return PlannerReply(text=prose, trip=None, questions=[])
            proposed["id"] = trip_id
            questions = [str(q) for q in proposed.pop("questions", []) or []]
            errors = validate_trip(proposed)
            if not errors:
                return PlannerReply(text=prose, trip=sanitize_trip(proposed), questions=questions)
            # One repair attempt with the validation errors (SPEC §7: schema-validated output).
            prompt = "Le JSON produit est invalide : " + "; ".join(errors) + ". Renvoie le trip.json v8 complet corrigé."
        return PlannerReply(text=prose, trip=None, questions=["Le planner n'a pas produit de trip valide : " + "; ".join(errors)])
