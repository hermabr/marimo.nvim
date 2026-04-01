from __future__ import annotations

import html
import io
import re
import subprocess
from pathlib import Path
from typing import Any

from marimo_nvim_py.codec import load_raw_notebook, serialize_notebook
from marimo_nvim_py.kernel import KernelBridge
from marimo_nvim_py.models import NotebookSnapshot
from marimo_nvim_py.session_manager import Worker


RAW_NOTEBOOK = """\
import marimo

app = marimo.App()


@app.cell
def _():
    x = 1
    x
    return


if __name__ == "__main__":
    app.run()
"""


def build_snapshot(path: Path, code: str = "x = 1\nx") -> dict[str, Any]:
    return {
        "session_id": str(path),
        "path": str(path),
        "project_root": str(path.parent),
        "runtime_kind": "uv_project",
        "header": None,
        "app_options": {},
        "cells": [
            {
                "id": "cell-1",
                "name": "_",
                "code": code,
                "options": {},
            }
        ],
    }


def output_text(operation: dict[str, Any]) -> str | None:
    output = operation.get("output")
    if not isinstance(output, dict):
        return None
    if output.get("mimetype") == "text/plain":
        return str(output.get("data"))
    if output.get("mimetype") == "text/html":
        return html.unescape(re.sub(r"<[^>]+>", "", str(output.get("data"))))
    return None


def test_load_raw_notebook_returns_normalized_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "notebook.py"
    snapshot = load_raw_notebook(
        path=str(path),
        content=RAW_NOTEBOOK,
        project_root=str(tmp_path),
        runtime_kind="uv_project",
    )
    assert snapshot.session_id == str(path)
    assert snapshot.path == str(path)
    assert snapshot.project_root == str(tmp_path)
    assert snapshot.runtime_kind == "uv_project"
    assert len(snapshot.cells) == 1
    assert snapshot.cells[0].code == "x = 1\nx"


def test_serialize_notebook_returns_canonical_source_and_ranges(tmp_path: Path) -> None:
    snapshot = NotebookSnapshot.from_dict(build_snapshot(tmp_path / "projected.py"))
    serialized = serialize_notebook(snapshot)
    assert "import marimo" in serialized["canonical_source"]
    assert "@app.cell" in serialized["canonical_source"]
    assert serialized["canonical_ranges"][0]["start_line"] > 0


def test_kernel_bridge_uses_uv_with_marimo(monkeypatch: Any, tmp_path: Path) -> None:
    snapshot = NotebookSnapshot.from_dict(build_snapshot(tmp_path / "worker.py"))
    captured: dict[str, Any] = {}

    class FakePopen:
        def __init__(self, cmd: list[str], **kwargs: Any) -> None:
            captured["cmd"] = cmd
            captured["kwargs"] = kwargs
            self.stdin = io.BytesIO()
            self.stdout = io.BytesIO(b"KERNEL_READY\n")
            self.stderr = io.BytesIO()
            self.pid = 123

        def poll(self) -> None:
            return None

        def wait(self, timeout: float | None = None) -> int:
            del timeout
            return 0

        def terminate(self) -> None:
            return None

        def kill(self) -> None:
            return None

    monkeypatch.setattr(subprocess, "Popen", FakePopen)

    class FakeApp:
        config = {}

        class cell_manager:  # noqa: N801
            @staticmethod
            def config_map() -> dict[str, Any]:
                return {}

    bridge = KernelBridge(snapshot, FakeApp())  # type: ignore[arg-type]
    bridge.launch()

    assert captured["cmd"][:4] == ["uv", "run", "--project", str(tmp_path)]
    assert captured["cmd"].count("--with") == 2
    assert "marimo" in captured["cmd"]
    assert "pyzmq" in captured["cmd"]
    assert captured["cmd"][-2:] == ["-m", "marimo._ipc.launch_kernel"]


def test_worker_run_cells_forwards_raw_operation_events(tmp_path: Path) -> None:
    events: list[dict[str, Any]] = []
    worker = Worker(event_sink=events.append)
    snapshot = build_snapshot(tmp_path / "runtime.py")

    worker.ensure_session({"snapshot": snapshot})
    result = worker.run_cells(
        {
            "session_id": snapshot["session_id"],
            "cell_ids": ["cell-1"],
            "codes": ["x = 1\nx"],
            "_request_id": 7,
        }
    )

    assert result == {"session_id": snapshot["session_id"], "submitted": True}
    assert any(event.get("event") == "operation" for event in events)
    assert any(event.get("request_id") == 7 for event in events)
    assert any(event.get("operation", {}).get("op") == "completed-run" for event in events)

    cell_events = [
        event["operation"]
        for event in events
        if event.get("operation", {}).get("op") == "cell-op"
        and event.get("operation", {}).get("cell_id") == "cell-1"
    ]
    assert any(output_text(operation) == "1" for operation in cell_events)
    worker.shutdown({})


def test_worker_sync_notebook_accepts_runtime_session_creation(tmp_path: Path) -> None:
    events: list[dict[str, Any]] = []
    worker = Worker(event_sink=events.append)
    snapshot = build_snapshot(tmp_path / "sync.py", "x = 2\nx")

    result = worker.sync_notebook(
        {
            "snapshot": snapshot,
            "run_ids": ["cell-1"],
            "delete_ids": [],
            "_request_id": 11,
        }
    )

    assert result == {"session_id": snapshot["session_id"], "synced": True}
    assert any(event.get("request_id") == 11 for event in events)
    assert any(output_text(event["operation"]) == "2" for event in events if event.get("operation", {}).get("op") == "cell-op")
    worker.shutdown({})
