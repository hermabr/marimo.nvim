from __future__ import annotations

import threading
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
    runtime_session: Any = None
    runtime_consumer: Any = None
    runtime_cells: dict[str, Any] | None = None
    runtime_bootstrapped: bool = False
    autorun_generation: int = 0
    pending_changed_cell_ids: list[str] | None = None
    last_runtime_sync_hash: str | None = None
    runtime_lock: Any = None

    def __post_init__(self) -> None:
        if self.runtime_lock is None:
            self.runtime_lock = threading.RLock()
