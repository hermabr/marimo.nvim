from __future__ import annotations

import asyncio
import ast
import contextlib
import html
import hashlib
import json
import os
import re
import time
import uuid
from pathlib import Path
from typing import Any, Callable, cast

from marimo._ast.app import App, InternalApp
from marimo._ast.cell import CellConfig
from marimo._ast.codegen import generate_filecontents_from_ir
from marimo._ast.compiler import compile_cell
from marimo._ast.parse import parse_notebook
from marimo._config.config import PartialMarimoConfig
from marimo._config.manager import get_default_config_manager
from marimo._messaging.msgspec_encoder import asdict
from marimo._messaging.notification import CompletedRunNotification, FunctionCallResultNotification
from marimo._messaging.serde import deserialize_kernel_message
from marimo._runtime.commands import AppMetadata, ExecuteCellsCommand, InvokeFunctionCommand, SyncGraphCommand
from marimo._runtime.dataflow import DirectedGraph
from marimo._schemas.serialization import AppInstantiation, CellDef, Header, NotebookSerializationV1
from marimo._server.models.models import InstantiateNotebookRequest
from marimo._session.consumer import SessionConsumer
from marimo._session.model import ConnectionState, SessionMode
from marimo._session.notebook.file_manager import AppFileManager
from marimo._session.session import SessionImpl
from marimo._types.ids import CellId_t
from marimo._types.ids import ConsumerId
from marimo._types.ids import RequestId

from marimo_nvim_py.models import Session
from marimo_nvim_py.projected import (
    dedupe_empty_cells,
    drop_empty_cells,
    parse_projected_cells,
    promote_first_marker_to_marimo,
    render_projected_lines,
)

MARIMO_TABLE_MAX_RENDER_ROWS = 1000
MARIMO_TABLE_FUNCTION_TIMEOUT_SECONDS = 5.0
_MARIMO_UI_ELEMENT_TAG_PATTERN = re.compile(r"<marimo-ui-element\b[^>]*object-id=(['\"])(.*?)\1", re.IGNORECASE)
_MARIMO_TABLE_TAG_PATTERN = re.compile(r"<marimo-table\b[^>]*>", re.IGNORECASE)

def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class RuntimeSessionConsumer(SessionConsumer):
    def __init__(self) -> None:
        self.completed_runs = 0
        self.function_results: dict[str, FunctionCallResultNotification] = {}

    @property
    def consumer_id(self) -> ConsumerId:
        return ConsumerId("marimo-nvim")

    def notify(self, notification: bytes) -> None:
        decoded = deserialize_kernel_message(cast(Any, notification))
        if isinstance(decoded, CompletedRunNotification):
            self.completed_runs += 1
        elif isinstance(decoded, FunctionCallResultNotification):
            self.function_results[str(decoded.function_call_id)] = decoded

    def connection_state(self) -> ConnectionState:
        return ConnectionState.OPEN

    def on_attach(self, session: Any, event_bus: Any) -> None:
        del session
        del event_bus

    def on_detach(self) -> None:
        return None

    def pop_function_result(self, function_call_id: str) -> FunctionCallResultNotification | None:
        return self.function_results.pop(function_call_id, None)

    def clear_function_result(self, function_call_id: str) -> None:
        self.function_results.pop(function_call_id, None)


def _extract_html_attribute(tag_html: str, attribute: str) -> str | None:
    single_quoted = re.search(rf"{attribute}='([^']*)'", tag_html)
    if single_quoted is not None:
        return single_quoted.group(1)
    double_quoted = re.search(rf'{attribute}="([^"]*)"', tag_html)
    if double_quoted is not None:
        return double_quoted.group(1)
    return None


def _decode_json_attribute(value: str | None) -> Any:
    if not value:
        return None
    decoded = html.unescape(value)
    try:
        parsed = json.loads(decoded)
    except json.JSONDecodeError:
        return None
    if isinstance(parsed, str):
        trimmed = parsed.strip()
        if trimmed.startswith(("[", "{")):
            try:
                return json.loads(trimmed)
            except json.JSONDecodeError:
                return parsed
    return parsed


def _encode_json_attribute(value: Any) -> str:
    encoded = json.dumps(json.dumps(value, separators=(",", ":")), separators=(",", ":"))
    return html.escape(encoded, quote=True).replace("\\", "&#92;")


def _replace_html_attribute(tag_html: str, attribute: str, value: str) -> str:
    escaped_value = value.replace("\\", "\\\\").replace("'", "&#39;")
    updated, count = re.subn(rf"({attribute}=')([^']*)(')", rf"\1{escaped_value}\3", tag_html, count=1)
    if count > 0:
        return updated
    escaped_value = value.replace("\\", "\\\\").replace('"', "&quot;")
    updated, count = re.subn(rf'({attribute}=")([^"]*)(")', rf"\1{escaped_value}\3", tag_html, count=1)
    if count > 0:
        return updated
    return tag_html


def _extract_marimo_table_metadata(output_data: Any) -> dict[str, Any] | None:
    if not isinstance(output_data, str) or output_data == "":
        return None
    ui_match = _MARIMO_UI_ELEMENT_TAG_PATTERN.search(output_data)
    table_match = _MARIMO_TABLE_TAG_PATTERN.search(output_data)
    if ui_match is None or table_match is None:
        return None
    object_id = ui_match.group(2)
    tag_html = table_match.group(0)
    rows = _decode_json_attribute(_extract_html_attribute(tag_html, "data-data"))
    if not isinstance(rows, list):
        return None
    total_rows = _extract_html_attribute(tag_html, "data-total-rows")
    try:
        parsed_total_rows = int(html.unescape(total_rows or ""))
    except ValueError:
        parsed_total_rows = len(rows)
    return {
        "object_id": object_id,
        "table_tag": tag_html,
        "rows": rows,
        "row_count": len(rows),
        "total_rows": parsed_total_rows,
    }


def _replace_marimo_table_rows(output_data: str, table_tag: str, rows: list[Any], page_size: int) -> str:
    updated_tag = _replace_html_attribute(table_tag, "data-data", _encode_json_attribute(rows))
    updated_tag = _replace_html_attribute(updated_tag, "data-page-size", str(page_size))
    return output_data.replace(table_tag, updated_tag, 1)


def _cell_config(cell: dict[str, Any]) -> CellConfig:
    return CellConfig.from_dict(cell.get("options", {}), warn=False)


def _collect_assigned_names(node: ast.AST) -> set[str]:
    names: set[str] = set()

    def visit_target(target: ast.AST) -> None:
        if isinstance(target, ast.Name):
            names.add(target.id)
            return
        if isinstance(target, (ast.Tuple, ast.List)):
            for elt in target.elts:
                visit_target(elt)

    for current in ast.walk(node):
        if isinstance(current, ast.Assign):
            for target in current.targets:
                visit_target(target)
        elif isinstance(current, ast.AnnAssign):
            visit_target(current.target)
        elif isinstance(current, ast.AugAssign):
            visit_target(current.target)
        elif isinstance(current, (ast.For, ast.AsyncFor)):
            visit_target(current.target)
        elif isinstance(current, ast.With):
            for item in current.items:
                if item.optional_vars is not None:
                    visit_target(item.optional_vars)
        elif isinstance(current, ast.AsyncWith):
            for item in current.items:
                if item.optional_vars is not None:
                    visit_target(item.optional_vars)
        elif isinstance(current, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(current.name)
        elif isinstance(current, ast.Import):
            for alias in current.names:
                names.add(alias.asname or alias.name.split(".")[0])
        elif isinstance(current, ast.ImportFrom):
            for alias in current.names:
                if alias.name != "*":
                    names.add(alias.asname or alias.name)
    return names


def _cell_defined_names(code: str) -> set[str]:
    try:
        tree = ast.parse(code)
    except SyntaxError:
        return set()
    return _collect_assigned_names(tree)


def _multiple_definition_errors(cells: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    definitions: dict[str, list[str]] = {}
    names_by_cell_id: dict[str, set[str]] = {}
    for cell in cells:
        names = _cell_defined_names(cell["code"])
        names_by_cell_id[cell["id"]] = names
        for name in names:
            definitions.setdefault(name, []).append(cell["id"])

    errors_by_cell_id: dict[str, list[dict[str, Any]]] = {}
    for cell in cells:
        cell_id = cell["id"]
        errors: list[dict[str, Any]] = []
        for name in sorted(names_by_cell_id[cell_id]):
            other_cells = [other for other in definitions.get(name, []) if other != cell_id]
            if not other_cells:
                continue
            errors.append(
                {
                    "type": "multiple-defs",
                    "msg": f"The variable '{name}' was defined by another cell",
                    "name": name,
                    "cells": other_cells,
                }
            )
        if errors:
            errors_by_cell_id[cell_id] = errors
    return errors_by_cell_id


def _build_notebook_ir(
    path: str, header: str | None, app_options: dict[str, Any], cells: list[dict[str, Any]]
) -> NotebookSerializationV1:
    return NotebookSerializationV1(
        app=AppInstantiation(options=app_options or {}),
        header=Header(value=header) if header else None,
        cells=[CellDef(code=cell["code"], name=cell["name"], options=cell.get("options", {})) for cell in cells],
        filename=path,
    )


def _runtime_defaults() -> dict[str, Any]:
    return {
        "status": None,
        "stale_inputs": False,
        "output": None,
        "console": [],
        "last_run_timestamp": None,
        "last_execution_time_ms": None,
    }


def _cell_output_message(output: Any) -> dict[str, Any] | None:
    if output is None:
        return None
    return asdict(output)


def _console_messages(console: Any) -> list[dict[str, Any]]:
    if console is None:
        return []
    if isinstance(console, list):
        return [asdict(output) for output in console]
    return [asdict(console)]


def _is_internal_error_output(output: dict[str, Any] | None) -> bool:
    if output is None or output.get("mimetype") != "application/vnd.marimo+error":
        return False
    data = output.get("data")
    if not isinstance(data, list) or not data:
        return False
    return all(isinstance(item, dict) and item.get("type") == "internal" for item in data)


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

    def _emit_session_update(self, session: Session, request_id: int | None) -> None:
        self._emit_event("session_update", request_id, self._with_runtime_payload(session))

    def _invoke_ui_function(
        self,
        session: Session,
        namespace: str,
        function_name: str,
        args: dict[str, Any],
        timeout: float = MARIMO_TABLE_FUNCTION_TIMEOUT_SECONDS,
    ) -> Any | None:
        if session.runtime_session is None or session.runtime_consumer is None:
            return None
        function_call_id = str(uuid.uuid4())
        session.runtime_consumer.clear_function_result(function_call_id)
        with self._session_cwd(session):
            with session.runtime_lock:
                self._perform_runtime_operation(
                    lambda: session.runtime_session.put_control_request(
                        InvokeFunctionCommand(
                            function_call_id=RequestId(function_call_id),
                            namespace=namespace,
                            function_name=function_name,
                            args=args,
                        ),
                        from_consumer_id=None,
                    )
                )
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                with session.runtime_lock:
                    session.runtime_session.flush_messages()
                result = session.runtime_consumer.pop_function_result(function_call_id)
                if result is not None:
                    if result.status.code == "ok":
                        return result.return_value
                    return None
                time.sleep(0.01)
        return None

    def _maybe_expand_marimo_table_output(
        self,
        session: Session,
        output: dict[str, Any] | None,
    ) -> dict[str, Any] | None:
        if output is None or output.get("mimetype") != "text/html":
            return output
        metadata = _extract_marimo_table_metadata(output.get("data"))
        if metadata is None:
            return output
        desired_rows = min(metadata["total_rows"], MARIMO_TABLE_MAX_RENDER_ROWS)
        if metadata["row_count"] >= desired_rows:
            return output
        result = self._invoke_ui_function(
            session,
            namespace=metadata["object_id"],
            function_name="search",
            args={
                "page_size": desired_rows,
                "page_number": 0,
                "query": None,
                "sort": None,
                "filters": None,
                "limit": desired_rows,
            },
        )
        if not isinstance(result, dict):
            return output
        expanded_rows = result.get("data")
        if not isinstance(expanded_rows, str):
            return output
        try:
            parsed_rows = json.loads(expanded_rows)
        except json.JSONDecodeError:
            return output
        if not isinstance(parsed_rows, list) or len(parsed_rows) <= metadata["row_count"]:
            return output
        expanded_output = dict(output)
        expanded_output["data"] = _replace_marimo_table_rows(
            cast(str, output["data"]),
            metadata["table_tag"],
            parsed_rows,
            len(parsed_rows),
        )
        return expanded_output

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

    def _serialized_runtime_cells(self, session: Session) -> dict[str, dict[str, Any]]:
        if session.runtime_session is None:
            return {}
        view = session.runtime_session.session_view
        runtime_cells: dict[str, dict[str, Any]] = {}
        multiple_definition_errors = _multiple_definition_errors(session.cells)
        for cell in session.cells:
            cell_id = cell["id"]
            runtime = _runtime_defaults()
            notification = view.cell_notifications.get(cell_id)
            if notification is not None:
                runtime["status"] = notification.status
                runtime["stale_inputs"] = bool(notification.stale_inputs)
                runtime["output"] = _cell_output_message(notification.output)
                runtime["output"] = self._maybe_expand_marimo_table_output(session, runtime["output"])
                runtime["console"] = _console_messages(notification.console)
                if _is_internal_error_output(runtime["output"]) and multiple_definition_errors.get(cell_id):
                    runtime["output"] = {
                        "channel": "marimo-error",
                        "mimetype": "application/vnd.marimo+error",
                        "data": multiple_definition_errors[cell_id],
                    }
            execution_time = view.last_execution_time.get(cell_id)
            if isinstance(execution_time, (int, float)) and runtime["status"] == "idle":
                runtime["last_execution_time_ms"] = int(execution_time)
            runtime_cells[cell_id] = runtime
        return runtime_cells

    def _wait_for_completion(
        self,
        session: Session,
        previous_completed_runs: int,
        timeout: float = 15.0,
        request_id: int | None = None,
    ) -> None:
        if session.runtime_session is None or session.runtime_consumer is None:
            return
        deadline = time.monotonic() + timeout
        settled_since: float | None = None
        last_emitted = dict(session.runtime_cells or {})
        while time.monotonic() < deadline:
            completed_runs, notifications, current_runtime = self._runtime_progress_snapshot(session)
            changed = self._changed_runtime_cells(last_emitted, current_runtime)
            if changed:
                self._emit_runtime_update(session, request_id, changed)
                last_emitted = dict(current_runtime)
            if completed_runs > previous_completed_runs and notifications:
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

    def _runtime_progress_snapshot(self, session: Session) -> tuple[int, list[Any], dict[str, dict[str, Any]]]:
        with session.runtime_lock:
            if session.runtime_session is None:
                session.runtime_cells = {}
                return 0, [], {}
            session.runtime_session.flush_messages()
            runtime_cells = self._serialized_runtime_cells(session)
            session.runtime_cells = runtime_cells
            notifications = list(session.runtime_session.session_view.cell_notifications.values())
            completed_runs = session.runtime_consumer.completed_runs if session.runtime_consumer else 0
            return completed_runs, notifications, runtime_cells

    def _refresh_runtime_cells(self, session: Session) -> dict[str, dict[str, Any]]:
        _, _, runtime_cells = self._runtime_progress_snapshot(session)
        return runtime_cells

    def _perform_runtime_operation(self, operation: Any) -> Any:
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
        runtime_cells = session.runtime_cells or {}
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
            redirect_console_to_browser=True,
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
            with session.runtime_lock:
                self._perform_runtime_operation(
                    lambda: session.runtime_session.put_control_request(
                        SyncGraphCommand(cells=dict(zip(cell_ids, codes)), run_ids=run_ids, delete_ids=delete_ids),
                        from_consumer_id=None,
                    )
                )
            if run_ids or delete_ids:
                self._refresh_runtime_cells(session)
                self._emit_session_update(session, request_id)
                self._wait_for_completion(session, previous_completed_runs, request_id=request_id)
            else:
                with session.runtime_lock:
                    session.runtime_session.flush_messages()
        session.last_runtime_sync_hash = sha256_text(json.dumps({"cell_ids": cell_ids, "codes": codes}, sort_keys=True))
        self._refresh_runtime_cells(session)
        return self._with_runtime_payload(session)

    def _runtime_needs_execution(self, runtime: dict[str, Any] | None) -> bool:
        if runtime is None:
            return True
        if runtime.get("stale_inputs"):
            return True
        if runtime.get("last_execution_time_ms") is None:
            return True
        return False

    def _execution_closure(self, session: Session, requested_ids: list[str]) -> list[str]:
        valid_ids = {cell["id"] for cell in session.cells}
        requested = {cell_id for cell_id in requested_ids if cell_id in valid_ids}
        if not requested:
            return []
        try:
            graph = DirectedGraph()
            for cell in session.cells:
                graph.register_cell(cell["id"], compile_cell(cell["code"], cell_id=cell["id"]))
        except Exception:  # noqa: BLE001
            return [cell["id"] for cell in session.cells if cell["id"] in requested]

        pending_changed = set(session.pending_changed_cell_ids or [])
        runtime_cells = session.runtime_cells or {}
        closure = set(requested)
        for cell_id in requested:
            if cell_id in graph.cells:
                ancestors = cast(set[str], graph.ancestors(cast(CellId_t, cell_id)))
                should_include_all = self._runtime_needs_execution(runtime_cells.get(cell_id)) or any(
                    ancestor_id in pending_changed for ancestor_id in ancestors
                )
                for ancestor_id in ancestors:
                    if should_include_all or self._runtime_needs_execution(runtime_cells.get(ancestor_id)):
                        closure.add(ancestor_id)
        return [cell["id"] for cell in session.cells if cell["id"] in closure]

    def run_cells(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        self.ensure_runtime_session({"session_id": session.session_id})
        if session.runtime_session is None:
            return self._session_payload(session)
        requested_ids = list(params.get("cell_ids") or [])
        if not requested_ids:
            return self._session_payload(session)
        code_by_id = {cell["id"]: cell["code"] for cell in session.cells}
        runnable_ids = [cell_id for cell_id in self._execution_closure(session, requested_ids) if cell_id in code_by_id]
        if not runnable_ids:
            return self._session_payload(session)
        previous_completed_runs = session.runtime_consumer.completed_runs if session.runtime_consumer else 0
        request_id = cast(int | None, params.get("_request_id"))
        with self._session_cwd(session):
            with session.runtime_lock:
                self._perform_runtime_operation(
                    lambda: session.runtime_session.put_control_request(
                        ExecuteCellsCommand(
                            cell_ids=[cast(CellId_t, cell_id) for cell_id in runnable_ids],
                            codes=[code_by_id[cell_id] for cell_id in runnable_ids],
                        ),
                        from_consumer_id=None,
                    )
                )
            self._wait_for_completion(session, previous_completed_runs, request_id=request_id)
        session.runtime_bootstrapped = True
        session.pending_changed_cell_ids = []
        self._refresh_runtime_cells(session)
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
        previous_session = self.sessions.get(session_id)
        if previous_session and previous_session.runtime_session is not None:
            previous_session.runtime_session.close()
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
        with session.runtime_lock:
            if session.runtime_session is not None:
                self._perform_runtime_operation(lambda: session.runtime_session.try_interrupt())
                time.sleep(0.05)
                session.runtime_session.flush_messages()
        self._refresh_runtime_cells(session)
        return self._session_payload(session)

    def interrupt_now(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        with session.runtime_lock:
            if session.runtime_session is not None:
                self._perform_runtime_operation(lambda: session.runtime_session.try_interrupt())
                time.sleep(0.05)
                session.runtime_session.flush_messages()
        self._refresh_runtime_cells(session)
        return self._with_runtime_payload(session)

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
