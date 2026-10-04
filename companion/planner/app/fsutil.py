"""File helpers shared by the API and the planner."""
from __future__ import annotations

import os
from pathlib import Path


def write_atomic(path: Path, text: str) -> None:
    """Writes `text` to `path` so that a crash leaves either the old file or the new one, never a truncated one."""
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)
