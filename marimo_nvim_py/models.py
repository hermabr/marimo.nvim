from __future__ import annotations

import subprocess
import threading
from dataclasses import dataclass, field
from typing import Any


SnapshotCell = dict[str, Any]
NotebookSnapshot = dict[str, Any]


@dataclass
class RuntimeSession:
    session_id: str
    path: str
    project_root: str
    plugin_root: str
    snapshot: NotebookSnapshot
    queue_manager: Any
    process: subprocess.Popen[bytes]
    consumer_thread: threading.Thread
    lock: threading.RLock = field(default_factory=threading.RLock)
    request_lock: threading.RLock = field(default_factory=threading.RLock)
    stop_event: threading.Event = field(default_factory=threading.Event)
    completed_runs: int = 0
    function_results: dict[str, dict[str, Any]] = field(default_factory=dict)
    active_request_id: int | None = None
    current_operations: list[dict[str, Any]] | None = None
