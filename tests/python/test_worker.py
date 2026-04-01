from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, cast

from marimo_nvim_py.codec import load_raw_notebook, serialize_notebook
from marimo_nvim_py.session import _uv_kernel_cmd


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


def projected_snapshot(path: Path, code: str) -> dict[str, Any]:
    return {
        "session_id": str(path),
        "path": str(path),
        "project_root": str(path.parent),
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


def test_load_raw_notebook_uses_serializer_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "notebook.py"
    snapshot = load_raw_notebook(path=str(path), content=RAW_NOTEBOOK, project_root=str(tmp_path))
    assert snapshot["session_id"] == str(path)
    assert snapshot["project_root"] == str(tmp_path)
    assert snapshot["cells"][0]["code"] == "x = 1\nx"
    assert snapshot["cells"][0]["name"] == "_"


def test_serialize_notebook_returns_canonical_source_and_ranges(tmp_path: Path) -> None:
    path = tmp_path / "projected.py"
    serialized = serialize_notebook(projected_snapshot(path, "x = 1\nx"))
    assert "import marimo" in serialized["canonical_source"]
    assert "@app.cell" in serialized["canonical_source"]
    assert serialized["canonical_ranges"][0]["start_line"] > 0
    assert serialized["last_saved_source_hash"]


def test_uv_kernel_command_keeps_with_marimo() -> None:
    cmd = _uv_kernel_cmd("/tmp/project", "/tmp/plugin")
    assert cmd[:2] == ["uv", "run"]
    assert "--with" in cmd
    assert "marimo" in cmd
    assert cmd[-3:] == ["python", "-m", "marimo._ipc.launch_kernel"]


def test_worker_runtime_forwards_raw_operations(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[2]
    path = tmp_path / "runtime.py"
    snapshot = projected_snapshot(path, "x = 1\nx")
    worker_cmd = [
        "uv",
        "run",
        "--directory",
        str(root),
        "--with",
        "marimo",
        "--with",
        "pyzmq",
        "python",
        "-m",
        "marimo_nvim_py.worker",
    ]
    process = subprocess.Popen(
        worker_cmd,
        cwd=str(root),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    stdin = process.stdin
    stdout = process.stdout

    def send(request_id: int, method: str, params: dict[str, Any]) -> None:
        stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
        stdin.flush()

    def read_until_response(expected_id: int) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        events: list[dict[str, Any]] = []
        while True:
            line = stdout.readline()
            payload = json.loads(line)
            if payload.get("id") == expected_id:
                return payload, events
            events.append(payload)

    try:
        send(
            1,
            "ensure_session",
            {
                "session_id": str(path),
                "path": str(path),
                "project_root": str(tmp_path),
                "plugin_root": str(root),
                "snapshot": snapshot,
            },
        )
        response, _ = read_until_response(1)
        assert response["ok"] is True

        send(
            2,
            "sync_notebook",
            {
                "session_id": str(path),
                "path": str(path),
                "project_root": str(tmp_path),
                "plugin_root": str(root),
                "snapshot": snapshot,
                "run_ids": [],
                "delete_ids": [],
            },
        )
        response, _ = read_until_response(2)
        assert response["ok"] is True

        send(
            3,
            "run_cells",
            {
                "session_id": str(path),
                "cell_ids": ["cell-1"],
                "codes": ["x = 1\nx"],
            },
        )
        response, events = read_until_response(3)
        assert response["ok"] is True
        operation_events = [event for event in events if event.get("event") == "operation"]
        assert operation_events
        assert any(event["request_id"] == 3 and cast(dict[str, Any], event["operation"]).get("op") == "cell-op" for event in operation_events)
        assert any(event["request_id"] == 3 and cast(dict[str, Any], event["operation"]).get("op") == "completed-run" for event in operation_events)
    finally:
        send(4, "shutdown", {})
        process.terminate()
        process.wait(timeout=10)


def test_worker_subprocess_uses_new_api_surface(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[2]
    path = tmp_path / "worker_api.py"
    snapshot = projected_snapshot(path, "x = 1\nx")
    worker_cmd = [
        "uv",
        "run",
        "--directory",
        str(root),
        "--with",
        "marimo",
        "--with",
        "pyzmq",
        "python",
        "-m",
        "marimo_nvim_py.worker",
    ]
    process = subprocess.Popen(
        worker_cmd,
        cwd=str(root),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    try:
        process.stdin.write(
            json.dumps(
                {
                    "id": 1,
                    "method": "serialize_notebook",
                    "params": {
                        "snapshot": snapshot,
                    },
                }
            )
            + "\n"
        )
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        assert response["id"] == 1
        assert response["ok"] is True
        assert "import marimo" in response["result"]["canonical_source"]
    finally:
        process.stdin.write(json.dumps({"id": 2, "method": "shutdown", "params": {}}) + "\n")
        process.stdin.flush()
        process.terminate()
        process.wait(timeout=10)
