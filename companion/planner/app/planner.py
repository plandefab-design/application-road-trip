"""Trip planner powered by the Claude Agent SDK (runs on FAB's PC with his own subscription).

Creation mode only — the iPhone never needs this to navigate.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .trip_schema import extract_json_block, sanitize_trip, validate_trip

SYSTEM_PROMPT_FILE = Path(__file__).resolve().parent.parent / "system_prompt.md"
MAX_REPAIR_ATTEMPTS = 1


class PlannerUnavailable(RuntimeError):
    """Raised when the Agent SDK is missing or not authenticated."""


@dataclass
class PlannerReply:
    text: str
    trip: dict[str, Any] | None
    questions: list[str]


def is_configured() -> bool:
    return bool(os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") or os.environ.get("ANTHROPIC_API_KEY"))


def build_prompt(message: str, trip: dict[str, Any]) -> str:
    return (
        "Formulaire et état actuel du trip (trip.json v1) :\n"
        f"```json\n{json.dumps(trip, ensure_ascii=False)}\n```\n\n"
        f"Demande du pilote : {message}\n\n"
        "Réponds d'abord en texte pour le pilote, puis termine OBLIGATOIREMENT par UN bloc ```json contenant "
        "le trip.json v1 COMPLET mis à jour (même id). S'il manque une information indispensable, pose tes "
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

    async def chat(self, message: str, trip: dict[str, Any]) -> PlannerReply:
        if not is_configured():
            raise PlannerUnavailable("CLAUDE_CODE_OAUTH_TOKEN absent : lance `claude setup-token` sur le PC et renseigne .env")
        try:
            from claude_agent_sdk import AssistantMessage, ClaudeAgentOptions, ResultMessage, TextBlock, query
        except ImportError as exc:  # pragma: no cover - depends on install
            raise PlannerUnavailable("claude-agent-sdk non installé") from exc

        trip_id = trip.get("id", "unknown")
        options = ClaudeAgentOptions(
            system_prompt=SYSTEM_PROMPT_FILE.read_text(encoding="utf-8"),
            # Research only: web search/fetch. No shell, no file writes.
            allowed_tools=["WebSearch", "WebFetch"],
            disallowed_tools=["Bash", "Write", "Edit", "NotebookEdit"],
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
                    text_parts.extend(b.text for b in msg.content if isinstance(b, TextBlock))
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
            prompt = "Le JSON produit est invalide : " + "; ".join(errors) + ". Renvoie le trip.json v1 complet corrigé."
        return PlannerReply(text=prose, trip=None, questions=["Le planner n'a pas produit de trip valide : " + "; ".join(errors)])
