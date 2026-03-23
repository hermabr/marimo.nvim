from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass
class Session:
    session_id: str
    path: str
    project_root: str
    runtime_kind: str
    header: str | None
    app_options: dict[str, Any]
    cells: list[dict[str, Any]]
    canonical_source: str
    projected_lines: list[str]
    projection_map: dict[str, Any]
    last_saved_source_hash: str
    last_projection_hash: str
