from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, cast

from marimo_nvim_py.sessions import Worker
from marimo_nvim_py.session import RuntimeSession


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


def make_snapshot(path: Path, code_by_id: list[tuple[str, str]]) -> dict[str, Any]:
    return {
        "session_id": str(path),
        "path": str(path),
        "header": None,
        "app_options": {},
        "cells": [
            {
                "id": cell_id,
                "name": "_",
                "code": code,
                "options": {},
                "editor_status": "clean",
            }
            for cell_id, code in code_by_id
        ],
    }


def latest_cell_operation(events: list[dict[str, Any]], cell_id: str) -> dict[str, Any] | None:
    latest = None
    for event in events:
        operation = event.get("operation")
        if (
            event.get("event") == "operation"
            and isinstance(operation, dict)
            and operation.get("op") == "cell-op"
            and operation.get("cell_id") == cell_id
        ):
            latest = operation
    return latest


def has_cell_output(events: list[dict[str, Any]], cell_id: str, expected: str) -> bool:
    for event in events:
        operation = event.get("operation")
        if (
            event.get("event") == "operation"
            and isinstance(operation, dict)
            and operation.get("op") == "cell-op"
            and operation.get("cell_id") == cell_id
            and expected in output_text(operation)
        ):
            return True
    return False


def output_text(operation: dict[str, Any] | None) -> str:
    if not isinstance(operation, dict):
        return ""
    output = operation.get("output")
    if not isinstance(output, dict):
        return ""
    return str(output.get("data") or "")


def test_load_raw_notebook_returns_snapshot_and_canonical_source(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "notebook.py"
    result = worker.load_raw_notebook({"path": str(path), "content": RAW_NOTEBOOK})

    assert result["session_id"] == str(path)
    assert result["cells"][0]["code"] == "x = 1\nx"
    assert result["cells"][0]["canonical_range"]["start_line"] > 0
    assert "import marimo" in result["canonical_source"]
    assert "@app.cell" in result["canonical_source"]


def test_serialize_notebook_returns_canonical_source_for_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "projected.py"
    snapshot = make_snapshot(path, [("cell-1", "x = 1\nx")])

    result = Worker().serialize_notebook({"path": str(path), "snapshot": snapshot})

    assert result["last_saved_source_hash"]
    assert result["cells"][0]["id"] == "cell-1"
    assert result["cells"][0]["canonical_range"]["start_line"] > 0
    assert "import marimo" in result["canonical_source"]
    assert "@app.cell" in result["canonical_source"]


def test_runtime_session_kernel_command_uses_uv_and_with_marimo(tmp_path: Path) -> None:
    path = tmp_path / "runtime.py"
    session = RuntimeSession(
        session_id=str(path),
        path=str(path),
        project_root=str(tmp_path),
        runtime_kind="uv_project",
        snapshot=make_snapshot(path, [("cell-1", "x = 1\nx")]),
        event_sink=None,
    )

    command = session._kernel_command()

    assert command[:2] == ["uv", "run"]
    assert "--project" in command
    assert "--with" in command
    assert "marimo" in command
    assert command[-3:] == ["python", "-m", "marimo._ipc.launch_kernel"]


def test_run_cells_forwards_raw_operations(tmp_path: Path) -> None:
    events: list[dict[str, Any]] = []
    worker = Worker(event_sink=events.append)
    path = tmp_path / "runtime.py"
    snapshot = make_snapshot(path, [("cell-1", "x = 1\nx")])

    worker.ensure_session(
        {
            "session_id": str(path),
            "path": str(path),
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
            "snapshot": snapshot,
        }
    )
    worker.run_cells(
        {
            "session_id": str(path),
            "cell_ids": ["cell-1"],
            "codes": ["x = 1\nx"],
            "_request_id": 42,
        }
    )
    worker.shutdown({})

    assert events
    assert all(event.get("event") == "operation" for event in events)
    assert not any(event.get("event") in {"runtime_update", "session_update"} for event in events)
    operation = latest_cell_operation(events, "cell-1")
    assert operation is not None
    assert has_cell_output(events, "cell-1", "1")
    assert any(
        event.get("request_id") == 42
        and isinstance(event.get("operation"), dict)
        and event["operation"].get("op") == "completed-run"
        for event in events
    )


def test_sync_notebook_runs_changed_cells_and_forwards_operations(tmp_path: Path) -> None:
    events: list[dict[str, Any]] = []
    worker = Worker(event_sink=events.append)
    path = tmp_path / "sync.py"
    initial = make_snapshot(path, [("cell-1", "x = 1\nx"), ("cell-2", "y = x + 1\ny")])

    worker.ensure_session(
        {
            "session_id": str(path),
            "path": str(path),
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
            "snapshot": initial,
        }
    )
    updated = make_snapshot(path, [("cell-1", "x = 7\nx"), ("cell-2", "y = x + 1\ny")])
    worker.sync_notebook(
        {
            "session_id": str(path),
            "path": str(path),
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
            "snapshot": updated,
            "run_ids": ["cell-1"],
            "delete_ids": [],
            "_request_id": 7,
        }
    )
    worker.shutdown({})

    first_operation = latest_cell_operation(events, "cell-1")
    assert first_operation is not None
    assert has_cell_output(events, "cell-1", "7")
    assert any(
        event.get("request_id") == 7
        and isinstance(event.get("operation"), dict)
        and event["operation"].get("op") == "completed-run"
        for event in events
    )


def test_worker_process_interrupt_remains_immediate(tmp_path: Path) -> None:
    path = tmp_path / "interrupt.py"
    worker_cmd = [sys.executable, "-m", "marimo_nvim_py.worker"]
    process = subprocess.Popen(
        worker_cmd,
        cwd=str(Path(__file__).resolve().parents[2]),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    stdin = process.stdin
    stdout = process.stdout
    assert stdin is not None
    assert stdout is not None

    snapshot = make_snapshot(path, [("cell-1", "import time\ntime.sleep(2)\n1")])

    def send_request(request_id: int, method: str, params: dict[str, Any]) -> None:
        stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
        stdin.flush()

    try:
        send_request(
            1,
            "ensure_session",
            {
                "session_id": str(path),
                "path": str(path),
                "project_root": str(tmp_path),
                "runtime_kind": "uv_project",
                "snapshot": snapshot,
            },
        )
        while True:
            initial = json.loads(stdout.readline())
            if initial.get("event") is None:
                break
        assert initial["id"] == 1

        send_request(
            2,
            "run_cells",
            {
                "session_id": str(path),
                "cell_ids": ["cell-1"],
                "codes": ["import time\ntime.sleep(2)\n1"],
            },
        )
        time.sleep(0.2)
        interrupt_sent_at = time.monotonic()
        send_request(3, "interrupt", {"session_id": str(path)})

        response_order: list[int] = []
        interrupt_elapsed: float | None = None
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and len(response_order) < 2:
            line = stdout.readline()
            if not line:
                break
            payload = json.loads(line)
            if payload.get("event") is not None:
                continue
            response_order.append(cast(int, payload["id"]))
            if payload["id"] == 3:
                interrupt_elapsed = time.monotonic() - interrupt_sent_at
        assert response_order[:2] == [3, 2]
        assert interrupt_elapsed is not None and interrupt_elapsed < 1.0
    finally:
        if process.stdin is not None:
            process.stdin.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
