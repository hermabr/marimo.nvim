from __future__ import annotations

import asyncio
import contextlib
import hashlib
import html
import io
import json
import logging
import os
import threading
import re
import time
import uuid
from pathlib import Path
from typing import Any, Callable, cast

from marimo._ast.app import App, InternalApp
from marimo._ast.cell import CellConfig
from marimo._ast.codegen import generate_filecontents_from_ir
from marimo._ast.parse import parse_notebook
from marimo._config.config import PartialMarimoConfig
from marimo._config.manager import get_default_config_manager
from marimo._messaging.cell_output import CellChannel, CellOutput
from marimo._messaging.errors import Error
from marimo._messaging.notification import CompletedRunNotification
from marimo._messaging.serde import deserialize_kernel_message
from marimo._runtime.commands import AppMetadata, ExecuteCellsCommand, SyncGraphCommand
from marimo._schemas.serialization import AppInstantiation, CellDef, Header, NotebookSerializationV1
from marimo._server.models.models import InstantiateNotebookRequest
from marimo._session.consumer import SessionConsumer
from marimo._session.model import ConnectionState, SessionMode
from marimo._session.notebook.file_manager import AppFileManager
from marimo._session.session import SessionImpl
from marimo._types.ids import ConsumerId
from marimo._utils.lists import as_list

from marimo_nvim_py.models import Session
from marimo_nvim_py.projected import (
    dedupe_empty_cells,
    drop_empty_cells,
    parse_projected_cells,
    promote_first_marker_to_marimo,
    render_projected_lines,
)

MAX_OUTPUT_LINES = 12
MAX_OUTPUT_LINE_CHARS = 160
MIMEBUNDLE_TYPE = "application/vnd.marimo+mimebundle"


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class RuntimeSessionConsumer(SessionConsumer):
    def __init__(self) -> None:
        self.completed_runs = 0

    @property
    def consumer_id(self) -> ConsumerId:
        return ConsumerId("marimo-nvim")

    def notify(self, notification: bytes) -> None:
        decoded = deserialize_kernel_message(cast(Any, notification))
        if isinstance(decoded, CompletedRunNotification):
            self.completed_runs += 1

    def connection_state(self) -> ConnectionState:
        return ConnectionState.OPEN

    def on_attach(self, session: Any, event_bus: Any) -> None:
        del session
        del event_bus

    def on_detach(self) -> None:
        return None


def _cell_config(cell: dict[str, Any]) -> CellConfig:
    return CellConfig.from_dict(cell.get("options", {}), warn=False)


def _build_notebook_ir(
    path: str, header: str | None, app_options: dict[str, Any], cells: list[dict[str, Any]]
) -> NotebookSerializationV1:
    return NotebookSerializationV1(
        app=AppInstantiation(options=app_options or {}),
        header=Header(value=header) if header else None,
        cells=[CellDef(code=cell["code"], name=cell["name"], options=cell.get("options", {})) for cell in cells],
        filename=path,
    )


def _truncate_lines(lines: list[str]) -> list[str]:
    trimmed: list[str] = []
    truncated = False
    for line in lines:
        current = line
        if len(current) > MAX_OUTPUT_LINE_CHARS:
            current = current[: MAX_OUTPUT_LINE_CHARS - 3] + "..."
            truncated = True
        trimmed.append(current)
    while trimmed and trimmed[-1] == "":
        trimmed.pop()
    if len(trimmed) > MAX_OUTPUT_LINES:
        trimmed = trimmed[:MAX_OUTPUT_LINES]
        truncated = True
    if truncated:
        trimmed.append("[output truncated]")
    return trimmed


def _split_text_output(data: str) -> list[str]:
    return _truncate_lines(data.splitlines())


def _error_lines(errors: list[Error]) -> list[str]:
    return _truncate_lines([error.describe() for error in errors])


def _internal_error_id(line: str) -> str | None:
    match = re.search(r"An internal error occurred:\s*([0-9a-f-]+)", line)
    if match is None:
        return None
    return match.group(1)


def _merge_unique_lines(existing: list[str], extra: list[str]) -> list[str]:
    merged = list(existing)
    seen = set(existing)
    for line in extra:
        if line not in seen:
            merged.append(line)
            seen.add(line)
    return merged


def _format_error_runtime(runtime: dict[str, Any]) -> dict[str, Any]:
    if runtime.get("output_kind") != "error":
        return runtime
    formatted = dict(runtime)
    output_lines = list(cast(list[str], formatted.get("output_lines") or []))
    console_lines = [str(line).removeprefix("stderr: ") for line in cast(list[str], formatted.get("console_lines") or [])]
    visible_output = [line for line in output_lines if _internal_error_id(line) is None]
    if console_lines:
        visible_output = _merge_unique_lines(visible_output, console_lines)
    formatted["output_lines"] = _truncate_lines(visible_output)
    formatted["console_lines"] = []
    formatted["has_console"] = False
    return formatted


def _format_runtime_cells(runtime_cells: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {cell_id: _format_error_runtime(dict(runtime)) for cell_id, runtime in runtime_cells.items()}


def _placeholder(kind: str, mimetype: str) -> tuple[str, str]:
    if kind == "html":
        return "html", "[html output]"
    if kind == "media":
        return "media", f"[{mimetype} output]"
    if kind == "widget":
        return "widget", "[widget output]"
    return "empty", ""


def _html_to_text(data: str) -> list[str]:
    text = re.sub(r"<br\s*/?>", "\n", data, flags=re.IGNORECASE)
    text = re.sub(r"</(p|div|li|tr|h[1-6])>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    lines = [line.strip() for line in text.splitlines()]
    lines = [line for line in lines if line != ""]
    return _truncate_lines(lines)


def _normalize_output(output: CellOutput | None) -> dict[str, Any]:
    runtime: dict[str, Any] = {
        "output_kind": "empty",
        "output_lines": [],
        "output_summary": None,
        "run_result_status": None,
    }
    if output is None:
        return runtime

    if output.channel == CellChannel.MARIMO_ERROR and isinstance(output.data, list):
        runtime["output_kind"] = "error"
        runtime["run_result_status"] = "marimo-error"
        runtime["output_lines"] = _error_lines(output.data)
        return runtime

    if output.mimetype == "text/plain" and isinstance(output.data, str):
        lines = _split_text_output(output.data)
        runtime["output_kind"] = "text" if lines else "empty"
        runtime["output_lines"] = lines
        return runtime

    if output.mimetype == MIMEBUNDLE_TYPE and isinstance(output.data, dict):
        mimebundle = output.data
        if isinstance(mimebundle.get("text/plain"), str):
            lines = _split_text_output(mimebundle["text/plain"])
            runtime["output_kind"] = "text" if lines else "empty"
            runtime["output_lines"] = lines
            return runtime
        if "text/html" in mimebundle:
            lines = _html_to_text(cast(str, mimebundle["text/html"]))
            if lines:
                runtime["output_kind"] = "text"
                runtime["output_lines"] = lines
            else:
                kind, summary = _placeholder("html", "text/html")
                runtime["output_kind"] = kind
                runtime["output_summary"] = summary
            return runtime
        for mimetype in mimebundle:
            if mimetype.startswith("image/"):
                kind, summary = _placeholder("media", mimetype)
                runtime["output_kind"] = kind
                runtime["output_summary"] = summary
                return runtime
        kind, summary = _placeholder("widget", output.mimetype)
        runtime["output_kind"] = kind
        runtime["output_summary"] = summary
        return runtime

    if output.mimetype in {"text/html", "text/markdown"}:
        lines = _html_to_text(output.data) if isinstance(output.data, str) else []
        if lines:
            runtime["output_kind"] = "text"
            runtime["output_lines"] = lines
        else:
            kind, summary = _placeholder("html", output.mimetype)
            runtime["output_kind"] = kind
            runtime["output_summary"] = summary
        return runtime

    if output.channel == CellChannel.MEDIA or output.mimetype.startswith("image/"):
        kind, summary = _placeholder("media", output.mimetype)
        runtime["output_kind"] = kind
        runtime["output_summary"] = summary
        return runtime

    kind, summary = _placeholder("widget", output.mimetype)
    runtime["output_kind"] = kind
    runtime["output_summary"] = summary
    return runtime


def _normalize_console(console: Any) -> list[str]:
    lines: list[str] = []
    for output in as_list(console):
        if not isinstance(output, CellOutput):
            continue
        if not isinstance(output.data, str):
            continue
        prefix = "stderr: " if output.channel == CellChannel.STDERR else ""
        for line in output.data.splitlines():
            lines.append(prefix + line if prefix else line)
    return _truncate_lines(lines)


def _runtime_defaults() -> dict[str, Any]:
    return {
        "status": None,
        "stale_inputs": False,
        "run_result_status": None,
        "output_kind": "empty",
        "output_lines": [],
        "output_summary": None,
        "has_console": False,
        "console_lines": [],
        "last_run_timestamp": None,
        "last_execution_time_ms": None,
    }


class _ConsoleCapture:
    def __init__(self, current_cell_id: Callable[[], str | None], fallback_cell_ids: list[str] | None = None) -> None:
        self._current_cell_id = current_cell_id
        self._fallback_cell_ids = list(fallback_cell_ids or [])
        self._lines: dict[str, list[str]] = {}
        self._partials: dict[str, str] = {}
        self._pending_lines: list[str] = []
        self._pending_partial = ""
        self._lock = threading.Lock()

    def _target_cell_id(self) -> str | None:
        return self._current_cell_id()

    def _append(self, target: str | None, text: str) -> None:
        if text == "":
            return
        if target is None:
            partial = self._pending_partial
        else:
            partial = self._partials.get(target, "")
        chunks = text.split("\n")
        chunks[0] = partial + chunks[0]
        complete = chunks[:-1]
        if target is None:
            self._pending_partial = chunks[-1]
        else:
            self._partials[target] = chunks[-1]
        if complete:
            if target is None:
                self._pending_lines.extend(complete)
            else:
                self._lines.setdefault(target, []).extend(complete)

    def bind(self, cell_id: str | None) -> None:
        if cell_id is None:
            return
        with self._lock:
            if self._pending_lines:
                self._lines.setdefault(cell_id, []).extend(self._pending_lines)
                self._pending_lines = []
            if self._pending_partial != "":
                self._partials[cell_id] = self._partials.get(cell_id, "") + self._pending_partial
                self._pending_partial = ""

    def stdout_writer(self) -> Any:
        capture = self

        class _Writer:
            def write(self, text: str) -> int:
                with capture._lock:
                    capture._append(capture._target_cell_id(), text)
                return len(text)

            def flush(self) -> None:
                return None

        return _Writer()

    def stderr_writer(self) -> Any:
        capture = self

        class _Writer:
            def write(self, text: str) -> int:
                with capture._lock:
                    lines = text.split("\n")
                    prefixed = "\n".join(("stderr: " + line) if line else "stderr: " for line in lines)
                    capture._append(capture._target_cell_id(), prefixed)
                return len(text)

            def flush(self) -> None:
                return None

        return _Writer()

    def snapshot(self) -> dict[str, list[str]]:
        with self._lock:
            if (self._pending_lines or self._pending_partial != "") and self._fallback_cell_ids:
                fallback = self._fallback_cell_ids[-1]
                if self._pending_lines:
                    self._lines.setdefault(fallback, []).extend(self._pending_lines)
                    self._pending_lines = []
                if self._pending_partial != "":
                    self._partials[fallback] = self._partials.get(fallback, "") + self._pending_partial
                    self._pending_partial = ""
            snapshot = {cell_id: list(lines) for cell_id, lines in self._lines.items()}
            for cell_id, partial in self._partials.items():
                if partial != "":
                    snapshot.setdefault(cell_id, []).append(partial)
        return snapshot


class _RuntimeLogCapture(logging.Handler):
    def __init__(self) -> None:
        super().__init__(level=logging.ERROR)
        self._error_details: dict[str, list[str]] = {}
        self._lock = threading.Lock()

    def emit(self, record: logging.LogRecord) -> None:
        message = record.getMessage()
        if "error_id=" not in message:
            return
        lines = message.splitlines()
        if not lines:
            return
        error_id, first_line = self._parse_header(lines[0])
        if error_id is None:
            return
        captured = [line for line in [first_line, *lines[1:]] if line != ""]
        if not captured:
            return
        with self._lock:
            self._error_details[error_id] = captured

    def snapshot(self) -> dict[str, list[str]]:
        with self._lock:
            return {error_id: list(lines) for error_id, lines in self._error_details.items()}

    def _parse_header(self, line: str) -> tuple[str | None, str]:
        match = re.search(r"error_id=([0-9a-f-]+)\)\s*(.*)$", line)
        if match is None:
            return None, line
        return match.group(1), match.group(2)


class Worker:
    def __init__(self, event_sink: Callable[[dict[str, Any]], None] | None = None) -> None:
        self.sessions: dict[str, Session] = {}
        self.event_sink = event_sink
        try:
            asyncio.get_event_loop()
        except RuntimeError:
            asyncio.set_event_loop(asyncio.new_event_loop())

    def _build_notebook(
        self, path: str, header: str | None, app_options: dict[str, Any], cells: list[dict[str, Any]]
    ) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
        notebook = _build_notebook_ir(path, header, app_options, cells)
        canonical_source = generate_filecontents_from_ir(notebook)
        parsed = parse_notebook(canonical_source, filepath=path)
        canonical_ranges: list[dict[str, int]] = []
        if parsed is not None:
            for cell in parsed.cells:
                canonical_ranges.append(
                    {
                        "start_line": int(cell.lineno),
                        "start_col": int(cell.col_offset) + 1,
                        "end_line": int(cell.end_lineno),
                        "end_col": int(cell.end_col_offset) + 1,
                    }
                )
        projected_lines, spans = render_projected_lines(cells)
        out_cells: list[dict[str, Any]] = []
        for idx, cell in enumerate(cells):
            projection_range = (
                spans[idx]
                if idx < len(spans)
                else {"start_line": 1, "start_col": 1, "end_line": 1, "end_col": 1}
            )
            canonical_range = (
                canonical_ranges[idx]
                if idx < len(canonical_ranges)
                else {"start_line": 1, "start_col": 1, "end_line": 1, "end_col": 1}
            )
            out_cells.append(
                {
                    "id": cell["id"],
                    "name": cell["name"],
                    "code": cell["code"],
                    "options": cell.get("options", {}),
                    "index": idx,
                    "editor_status": cell.get("editor_status", "clean"),
                    "projection_range": projection_range,
                    "canonical_range": canonical_range,
                }
            )
        projection_map = {
            "cells": [
                {
                    "id": cell["id"],
                    "name": cell["name"],
                    "projection_range": cell["projection_range"],
                    "canonical_range": cell["canonical_range"],
                }
                for cell in out_cells
            ]
        }
        return canonical_source, projection_map, out_cells

    def _reconcile_ids(self, previous: list[dict[str, Any]] | None, parsed_cells: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not previous:
            return [{**cell, "id": uuid.uuid4().hex, "editor_status": "clean"} for cell in parsed_cells]
        previous_by_key: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
        for old in previous:
            key = (old["name"], json.dumps(old.get("options", {}), sort_keys=True), old["code"])
            previous_by_key.setdefault(key, []).append(old)
        matched_previous_ids: set[str] = set()
        provisional: list[dict[str, Any]] = []
        unmatched_new_indices: list[int] = []
        for idx, cell in enumerate(parsed_cells):
            key = (cell["name"], json.dumps(cell.get("options", {}), sort_keys=True), cell["code"])
            matched = None
            queue = previous_by_key.get(key, [])
            while queue:
                candidate = queue.pop(0)
                if candidate["id"] not in matched_previous_ids:
                    matched = candidate
                    break
            if matched is None:
                provisional.append({**cell})
                unmatched_new_indices.append(idx)
            else:
                matched_previous_ids.add(matched["id"])
                status = (
                    "clean"
                    if matched["code"] == cell["code"]
                    and matched.get("options", {}) == cell.get("options", {})
                    and matched["name"] == cell["name"]
                    else "edited"
                )
                provisional.append({**cell, "id": matched["id"], "editor_status": status})

        remaining_previous = [cell for cell in previous if cell["id"] not in matched_previous_ids]
        prev_pos = 0
        for idx in unmatched_new_indices:
            cell = provisional[idx]
            matched = None
            for search_idx in range(prev_pos, len(remaining_previous)):
                candidate = remaining_previous[search_idx]
                if candidate["name"] == cell["name"] and candidate.get("options", {}) == cell.get("options", {}):
                    matched = candidate
                    prev_pos = search_idx + 1
                    break
            if matched is None:
                provisional[idx] = {**cell, "id": uuid.uuid4().hex, "editor_status": "edited"}
            else:
                provisional[idx] = {**cell, "id": matched["id"], "editor_status": "edited"}

        return provisional

    def _from_raw_notebook(self, path: str, content: str) -> tuple[str | None, dict[str, Any], list[dict[str, Any]]]:
        notebook = parse_notebook(content, filepath=path)
        if notebook is None:
            raise ValueError("empty notebook")
        if not notebook.valid:
            description = notebook.violations[0].description if notebook.violations else "invalid marimo notebook"
            raise ValueError(description)
        header = notebook.header.value if notebook.header and notebook.header.value != "" else None
        app_options = dict(notebook.app.options or {})
        cells = [
            {
                "id": uuid.uuid4().hex,
                "name": cell.name,
                "code": cell.code,
                "options": dict(cell.options or {}),
                "editor_status": "clean",
            }
            for cell in notebook.cells
        ]
        return header, app_options, drop_empty_cells(cells)

    def _from_projection(self, lines: list[str], previous: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
        parsed_cells = drop_empty_cells(dedupe_empty_cells(parse_projected_cells(lines)))
        return self._reconcile_ids(previous, parsed_cells)

    def _from_manual_python(self, content: str) -> list[dict[str, Any]]:
        lines = content.splitlines()
        top_level_markers = any(line.startswith("# +") for line in lines)
        if top_level_markers:
            promoted, changed = promote_first_marker_to_marimo(lines)
            if not changed:
                raise ValueError("failed to promote projected markers to marimo cells")
            return self._from_projection(promoted, None)
        return [
            {
                "id": uuid.uuid4().hex,
                "name": "_",
                "code": content,
                "options": {},
                "editor_status": "clean",
            }
        ]

    def _build_runtime_file_manager(self, session: Session) -> AppFileManager:
        app = App(**(session.app_options or {}), _filename=session.path)
        internal_app = InternalApp(app)
        if session.header:
            internal_app._app._header = session.header
        internal_app.with_data(
            cell_ids=[cell["id"] for cell in session.cells],
            codes=[cell["code"] for cell in session.cells],
            names=[cell["name"] for cell in session.cells],
            configs=[_cell_config(cell) for cell in session.cells],
        )
        file_manager = AppFileManager.from_app(internal_app)
        file_manager.filename = session.path
        return file_manager

    def _emit_event(self, event: str, request_id: int | None, payload: dict[str, Any]) -> None:
        if self.event_sink is None or request_id is None:
            return
        self.event_sink(
            {
                "event": event,
                "request_id": request_id,
                "payload": payload,
            }
        )

    def _emit_runtime_update(
        self,
        session: Session,
        request_id: int | None,
        runtime_cells: dict[str, dict[str, Any]],
    ) -> None:
        if not runtime_cells:
            return
        self._emit_event(
            "runtime_update",
            request_id,
            {
                "session_id": session.session_id,
                "runtime_cells": runtime_cells,
            },
        )

    def _changed_runtime_cells(
        self,
        previous: dict[str, dict[str, Any]],
        current: dict[str, dict[str, Any]],
    ) -> dict[str, dict[str, Any]]:
        changed: dict[str, dict[str, Any]] = {}
        for cell_id, runtime in current.items():
            if previous.get(cell_id) != runtime:
                changed[cell_id] = runtime
        return changed

    def _merge_captured_console(
        self,
        runtime_cells: dict[str, dict[str, Any]],
        captured_console: dict[str, list[str]] | None,
    ) -> dict[str, dict[str, Any]]:
        if not captured_console:
            return runtime_cells
        merged = {cell_id: dict(runtime) for cell_id, runtime in runtime_cells.items()}
        for cell_id, lines in captured_console.items():
            if not lines:
                continue
            runtime = dict(merged.get(cell_id, _runtime_defaults()))
            runtime["console_lines"] = _truncate_lines(lines)
            runtime["has_console"] = bool(runtime["console_lines"])
            merged[cell_id] = _format_error_runtime(runtime)
        return merged

    def _merge_runtime_error_details(
        self,
        runtime_cells: dict[str, dict[str, Any]],
        error_details: dict[str, list[str]] | None,
    ) -> dict[str, dict[str, Any]]:
        if not error_details:
            return runtime_cells
        merged = {cell_id: dict(runtime) for cell_id, runtime in runtime_cells.items()}
        for cell_id, runtime in merged.items():
            if runtime.get("output_kind") != "error":
                continue
            output_lines = list(cast(list[str], runtime.get("output_lines") or []))
            error_id = None
            for line in output_lines:
                error_id = _internal_error_id(line)
                if error_id is not None:
                    break
            if error_id is None:
                continue
            details = error_details.get(error_id) or []
            if not details:
                continue
            runtime["output_lines"] = _truncate_lines(_merge_unique_lines(output_lines, details))
            merged[cell_id] = _format_error_runtime(runtime)
        return merged

    def _current_running_cell_id(self, session: Session, preferred_ids: list[str] | None = None) -> str | None:
        runtime_cells = session.runtime_cells or {}
        search_ids = preferred_ids or [cell["id"] for cell in session.cells]
        for cell_id in search_ids:
            runtime = runtime_cells.get(cell_id) or {}
            if runtime.get("status") == "running":
                return cell_id
        for cell_id in search_ids:
            runtime = runtime_cells.get(cell_id) or {}
            if runtime.get("status") == "queued":
                return cell_id
        return None

    def _wait_for_completion(
        self,
        session: Session,
        previous_completed_runs: int,
        timeout: float = 15.0,
        request_id: int | None = None,
        console_capture: _ConsoleCapture | None = None,
        log_capture: _RuntimeLogCapture | None = None,
    ) -> None:
        if session.runtime_session is None or session.runtime_consumer is None:
            return
        deadline = time.monotonic() + timeout
        settled_since: float | None = None
        last_emitted = dict(session.runtime_cells or {})
        while time.monotonic() < deadline:
            session.runtime_session.flush_messages()
            current_runtime = self._refresh_runtime_cells(session)
            if console_capture is not None:
                console_capture.bind(self._current_running_cell_id(session))
                current_runtime = self._merge_captured_console(current_runtime, console_capture.snapshot())
            if log_capture is not None:
                current_runtime = self._merge_runtime_error_details(current_runtime, log_capture.snapshot())
            session.runtime_cells = current_runtime
            changed = self._changed_runtime_cells(last_emitted, current_runtime)
            if changed:
                self._emit_runtime_update(session, request_id, changed)
                last_emitted = dict(current_runtime)
            view = session.runtime_session.session_view
            notifications = list(view.cell_notifications.values())
            if session.runtime_consumer.completed_runs > previous_completed_runs and notifications:
                all_settled = True
                for notification in notifications:
                    if notification.status in {"running", "queued"}:
                        all_settled = False
                        break
                if all_settled:
                    if settled_since is None:
                        settled_since = time.monotonic()
                    elif time.monotonic() - settled_since >= 0.1:
                        return
                else:
                    settled_since = None
            time.sleep(0.01)
        raise TimeoutError("timed out waiting for marimo runtime to finish")

    def _refresh_runtime_cells(self, session: Session) -> dict[str, dict[str, Any]]:
        runtime_cells: dict[str, dict[str, Any]] = {}
        if session.runtime_session is None:
            session.runtime_cells = runtime_cells
            return runtime_cells
        view = session.runtime_session.session_view
        session.runtime_session.flush_messages()
        for cell in session.cells:
            runtime = _runtime_defaults()
            cell_id = cell["id"]
            notification = view.cell_notifications.get(cell_id)
            if notification is not None:
                normalized = _normalize_output(notification.output)
                runtime.update(normalized)
                runtime["status"] = notification.status
                runtime["stale_inputs"] = bool(notification.stale_inputs)
                runtime["console_lines"] = _normalize_console(notification.console)
                runtime["has_console"] = bool(runtime["console_lines"])
                runtime = _format_error_runtime(runtime)
            execution_time = view.last_execution_time.get(cell_id)
            if isinstance(execution_time, (int, float)) and runtime["status"] == "idle":
                runtime["last_execution_time_ms"] = int(execution_time)
            runtime_cells[cell_id] = runtime
        runtime_cells = _format_runtime_cells(runtime_cells)
        session.runtime_cells = runtime_cells
        return runtime_cells

    def _perform_runtime_operation(self, operation: Any) -> Any:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            return operation()

    @contextlib.contextmanager
    def _session_cwd(self, session: Session) -> Any:
        original = os.getcwd()
        target = str(Path(session.path).resolve().parent)
        try:
            os.chdir(target)
            yield
        finally:
            os.chdir(original)

    def _with_runtime_payload(self, session: Session) -> dict[str, Any]:
        runtime_cells = _format_runtime_cells(session.runtime_cells or {})
        session.runtime_cells = runtime_cells
        cells = [{**cell, "runtime": runtime_cells.get(cell["id"], _runtime_defaults())} for cell in session.cells]
        return {
            "session_id": session.session_id,
            "path": session.path,
            "project_root": session.project_root,
            "runtime_kind": session.runtime_kind,
            "header": session.header,
            "app_options": session.app_options,
            "projected_lines": session.projected_lines,
            "canonical_source": session.canonical_source,
            "cells": cells,
            "projection_map": session.projection_map,
            "last_saved_source_hash": session.last_saved_source_hash,
            "last_projection_hash": session.last_projection_hash,
        }

    def _session_payload(self, session: Session) -> dict[str, Any]:
        self._refresh_runtime_cells(session)
        return self._with_runtime_payload(session)

    def ensure_runtime_session(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        if session.runtime_session is not None:
            return self._session_payload(session)

        file_manager = self._build_runtime_file_manager(session)
        config_manager = get_default_config_manager(current_path=session.path).with_overrides(
            cast(
                PartialMarimoConfig,
                {
                    "runtime": {
                        "on_cell_change": "autorun",
                        "auto_instantiate": True,
                        "auto_reload": "off",
                        "watcher_on_save": "lazy",
                    }
                },
            )
        )
        consumer = RuntimeSessionConsumer()
        runtime_session = SessionImpl.create(
            initialization_id=session.session_id,
            session_consumer=consumer,
            mode=SessionMode.RUN,
            app_metadata=AppMetadata(
                query_params={},
                filename=session.path,
                cli_args={},
                argv=[],
                app_config=file_manager.app.config,
            ),
            app_file_manager=file_manager,
            config_manager=config_manager,
            virtual_files_supported=False,
            redirect_console_to_browser=False,
            ttl_seconds=None,
            auto_instantiate=True,
        )
        session.runtime_session = runtime_session
        session.runtime_consumer = consumer
        with self._session_cwd(session):
            self._perform_runtime_operation(
                lambda: runtime_session.instantiate(
                    InstantiateNotebookRequest(object_ids=[], values=[], auto_run=False),
                    http_request=None,
                )
            )
        self._refresh_runtime_cells(session)
        return self._session_payload(session)

    def _compute_changed_and_deleted_ids(
        self, previous_cells: list[dict[str, Any]] | None, current_cells: list[dict[str, Any]]
    ) -> tuple[list[str], list[str]]:
        if previous_cells is None:
            return [cell["id"] for cell in current_cells], []
        previous_by_id = {cell["id"]: cell for cell in previous_cells}
        current_ids = {cell["id"] for cell in current_cells}
        changed_ids: list[str] = []
        for cell in current_cells:
            previous = previous_by_id.get(cell["id"])
            if previous is None:
                changed_ids.append(cell["id"])
                continue
            if (
                previous["code"] != cell["code"]
                or previous.get("options", {}) != cell.get("options", {})
                or previous["name"] != cell["name"]
            ):
                changed_ids.append(cell["id"])
        deleted_ids = [cell["id"] for cell in previous_cells if cell["id"] not in current_ids]
        return changed_ids, deleted_ids

    def sync_runtime_graph(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        self.ensure_runtime_session({"session_id": session.session_id})
        run_ids = params.get("run_ids") or []
        delete_ids = params.get("delete_ids") or []
        if session.runtime_session is None:
            return self._session_payload(session)

        cell_ids = [cell["id"] for cell in session.cells]
        codes = [cell["code"] for cell in session.cells]
        names = [cell["name"] for cell in session.cells]
        configs = [_cell_config(cell) for cell in session.cells]
        session.runtime_session.app_file_manager.app.with_data(
            cell_ids=cell_ids,
            codes=codes,
            names=names,
            configs=configs,
        )
        previous_completed_runs = session.runtime_consumer.completed_runs if session.runtime_consumer else 0
        request_id = cast(int | None, params.get("_request_id"))
        with self._session_cwd(session):
            self._perform_runtime_operation(
                lambda: session.runtime_session.put_control_request(
                    SyncGraphCommand(cells=dict(zip(cell_ids, codes)), run_ids=run_ids, delete_ids=delete_ids),
                    from_consumer_id=None,
                )
            )
            if run_ids or delete_ids:
                captured_console = _ConsoleCapture(
                    current_cell_id=lambda: self._current_running_cell_id(session, run_ids),
                    fallback_cell_ids=run_ids,
                )
                captured_logs = _RuntimeLogCapture()
                root_logger = logging.getLogger()
                root_logger.addHandler(captured_logs)
                try:
                    with contextlib.redirect_stdout(captured_console.stdout_writer()), contextlib.redirect_stderr(
                        captured_console.stderr_writer()
                    ):
                        self._wait_for_completion(
                            session,
                            previous_completed_runs,
                            request_id=request_id,
                            console_capture=captured_console,
                            log_capture=captured_logs,
                        )
                finally:
                    root_logger.removeHandler(captured_logs)
                session.runtime_cells = self._merge_captured_console(
                    session.runtime_cells or {}, captured_console.snapshot()
                )
                session.runtime_cells = self._merge_runtime_error_details(
                    session.runtime_cells or {}, captured_logs.snapshot()
                )
            else:
                self._perform_runtime_operation(lambda: session.runtime_session.flush_messages())
        session.last_runtime_sync_hash = sha256_text(json.dumps({"cell_ids": cell_ids, "codes": codes}, sort_keys=True))
        self._refresh_runtime_cells(session)
        if run_ids or delete_ids:
            session.runtime_cells = self._merge_captured_console(session.runtime_cells or {}, captured_console.snapshot())
            session.runtime_cells = self._merge_runtime_error_details(session.runtime_cells or {}, captured_logs.snapshot())
        return self._with_runtime_payload(session)

    def run_cells(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        self.ensure_runtime_session({"session_id": session.session_id})
        if session.runtime_session is None:
            return self._session_payload(session)
        requested_ids = list(params.get("cell_ids") or [])
        if not requested_ids:
            return self._session_payload(session)
        code_by_id = {cell["id"]: cell["code"] for cell in session.cells}
        runnable_ids = [cell_id for cell_id in requested_ids if cell_id in code_by_id]
        if not session.runtime_bootstrapped:
            runnable_ids = [cell["id"] for cell in session.cells]
        if not runnable_ids:
            return self._session_payload(session)
        previous_completed_runs = session.runtime_consumer.completed_runs if session.runtime_consumer else 0
        request_id = cast(int | None, params.get("_request_id"))
        with self._session_cwd(session):
            self._perform_runtime_operation(
                lambda: session.runtime_session.put_control_request(
                    ExecuteCellsCommand(cell_ids=list(runnable_ids), codes=[code_by_id[cell_id] for cell_id in runnable_ids]),
                    from_consumer_id=None,
                )
            )
            captured_console = _ConsoleCapture(
                current_cell_id=lambda: self._current_running_cell_id(session, runnable_ids),
                fallback_cell_ids=runnable_ids,
            )
            captured_logs = _RuntimeLogCapture()
            root_logger = logging.getLogger()
            root_logger.addHandler(captured_logs)
            try:
                with contextlib.redirect_stdout(captured_console.stdout_writer()), contextlib.redirect_stderr(
                    captured_console.stderr_writer()
                ):
                    self._wait_for_completion(
                        session,
                        previous_completed_runs,
                        request_id=request_id,
                        console_capture=captured_console,
                        log_capture=captured_logs,
                    )
            finally:
                root_logger.removeHandler(captured_logs)
        session.runtime_bootstrapped = True
        self._refresh_runtime_cells(session)
        session.runtime_cells = self._merge_captured_console(session.runtime_cells or {}, captured_console.snapshot())
        session.runtime_cells = self._merge_runtime_error_details(session.runtime_cells or {}, captured_logs.snapshot())
        return self._with_runtime_payload(session)

    def get_runtime_state(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        self.ensure_runtime_session({"session_id": session.session_id})
        self._refresh_runtime_cells(session)
        return {"runtime_cells": session.runtime_cells or {}}

    def sync_and_run(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        previous_cells = session.cells
        lines = params["content"].splitlines()
        cells = self._from_projection(lines, session.cells)
        changed_ids, deleted_ids = self._compute_changed_and_deleted_ids(previous_cells, cells)
        if not session.runtime_bootstrapped:
            changed_ids = [cell["id"] for cell in cells]
        canonical_source, projection_map, cells = self._build_notebook(session.path, session.header, session.app_options, cells)
        projected_lines = render_projected_lines(cells)[0]
        session.cells = cells
        session.canonical_source = canonical_source
        session.projected_lines = projected_lines
        session.projection_map = projection_map
        session.last_projection_hash = sha256_text("\n".join(projected_lines))
        session.pending_changed_cell_ids = changed_ids
        session.autorun_generation += 1
        self.sync_runtime_graph(
            {
                "session_id": session.session_id,
                "run_ids": changed_ids,
                "delete_ids": deleted_ids,
                "_request_id": params.get("_request_id"),
            }
        )
        if changed_ids or session.runtime_session is not None:
            session.runtime_bootstrapped = True
        return self._session_payload(session)

    def open_session(self, params: dict[str, Any]) -> dict[str, Any]:
        path = params["path"]
        content = params["content"]
        input_kind = params["input_kind"]
        session_id = path
        project_root = params.get("project_root") or str(Path(path).parent)
        runtime_kind = params.get("runtime_kind") or "python"
        if input_kind == "raw_marimo":
            header, app_options, cells = self._from_raw_notebook(path, content)
        elif input_kind == "manual_python":
            header = None
            app_options = {}
            cells = self._from_manual_python(content)
        else:
            lines = content.splitlines()
            if input_kind == "generic_projected_promotable":
                lines, changed = promote_first_marker_to_marimo(lines)
                if not changed:
                    raise ValueError("buffer is neither a real marimo notebook nor a projected `# +` notebook")
            header = None
            app_options = {}
            cells = self._from_projection(lines, None)
        canonical_source, projection_map, cells = self._build_notebook(path, header, app_options, cells)
        projected_lines = render_projected_lines(cells)[0]
        session = Session(
            session_id=session_id,
            path=path,
            project_root=project_root,
            runtime_kind=runtime_kind,
            header=header,
            app_options=app_options,
            cells=cells,
            canonical_source=canonical_source,
            projected_lines=projected_lines,
            projection_map=projection_map,
            last_saved_source_hash=sha256_text(canonical_source),
            last_projection_hash=sha256_text("\n".join(projected_lines)),
            runtime_cells={},
            runtime_bootstrapped=False,
            pending_changed_cell_ids=[],
        )
        self.sessions[session_id] = session
        self.ensure_runtime_session({"session_id": session_id})
        return self._session_payload(session)

    def sync_projection(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        previous_cells = session.cells
        lines = params["content"].splitlines()
        cells = self._from_projection(lines, session.cells)
        canonical_source, projection_map, cells = self._build_notebook(session.path, session.header, session.app_options, cells)
        projected_lines = render_projected_lines(cells)[0]
        session.cells = cells
        session.canonical_source = canonical_source
        session.projected_lines = projected_lines
        session.projection_map = projection_map
        session.last_projection_hash = sha256_text("\n".join(projected_lines))
        changed_ids, deleted_ids = self._compute_changed_and_deleted_ids(previous_cells, cells)
        self.sync_runtime_graph({"session_id": session.session_id, "run_ids": [], "delete_ids": deleted_ids})
        session.pending_changed_cell_ids = changed_ids
        return self._session_payload(session)

    def write_session(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        result = self.sync_projection(params)
        Path(session.path).write_text(session.canonical_source, encoding="utf-8")
        session.last_saved_source_hash = sha256_text(session.canonical_source)
        result["last_saved_source_hash"] = session.last_saved_source_hash
        return result

    def write_projection(self, params: dict[str, Any]) -> dict[str, Any]:
        path = params["path"]
        lines = params["content"].splitlines()
        header = params.get("header")
        app_options = dict(params.get("app_options") or {})
        cells = self._from_projection(lines, None)
        canonical_source, _, _ = self._build_notebook(path, header, app_options, cells)
        Path(path).write_text(canonical_source, encoding="utf-8")
        return {
            "canonical_source": canonical_source,
            "last_saved_source_hash": sha256_text(canonical_source),
        }

    def reload_from_disk(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        content = Path(session.path).read_text(encoding="utf-8")
        return self.open_session(
            {
                "path": session.path,
                "content": content,
                "input_kind": "raw_marimo",
                "project_root": session.project_root,
                "runtime_kind": session.runtime_kind,
            }
        )

    def clear_outputs(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        if session.runtime_session is not None:
            session.runtime_session.close()
        session.runtime_session = None
        session.runtime_consumer = None
        session.runtime_cells = {}
        session.runtime_bootstrapped = False
        return self.ensure_runtime_session({"session_id": session.session_id})

    def interrupt(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        if session.runtime_session is not None:
            self._perform_runtime_operation(lambda: session.runtime_session.try_interrupt())
            time.sleep(0.05)
            session.runtime_session.flush_messages()
        self._refresh_runtime_cells(session)
        return self._session_payload(session)

    def close_session(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions.pop(params["session_id"], None)
        if session and session.runtime_session is not None:
            session.runtime_session.close()
        return {"closed": True}

    def get_session_state(self, params: dict[str, Any]) -> dict[str, Any]:
        return self._session_payload(self.sessions[params["session_id"]])

    def get_canonical_source(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        return {"canonical_source": session.canonical_source}

    def get_projection_map(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        return {"projection_map": session.projection_map}

    def shutdown(self, params: dict[str, Any]) -> dict[str, Any]:
        for session in self.sessions.values():
            if session.runtime_session is not None:
                session.runtime_session.close()
        self.sessions.clear()
        return {"shutdown": True}
