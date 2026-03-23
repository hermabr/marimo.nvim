#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from marimo._ast.codegen import generate_filecontents_from_ir
from marimo._ast.parse import parse_notebook
from marimo._schemas.serialization import AppInstantiation, CellDef, Header, NotebookSerializationV1


def _error(code: str, message: str) -> dict[str, Any]:
    return {"code": code, "message": message}


def _normalize_scalar(value: str) -> Any:
    trimmed = value.strip()
    if trimmed in {"True", "true"}:
        return True
    if trimmed in {"False", "false"}:
        return False
    if trimmed in {"None", "null"}:
        return None
    if (trimmed.startswith("'") and trimmed.endswith("'")) or (
        trimmed.startswith('"') and trimmed.endswith('"')
    ):
        return trimmed[1:-1]
    try:
        return int(trimmed)
    except ValueError:
        pass
    try:
        return float(trimmed)
    except ValueError:
        pass
    return trimmed


def _split_csv_like(text: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    quote: str | None = None
    prev = ""
    for char in text:
        if quote is not None:
            current.append(char)
            if char == quote and prev != "\\":
                quote = None
        elif char in {"'", '"'}:
            quote = char
            current.append(char)
        elif char == ",":
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
        prev = char
    if current:
        parts.append("".join(current))
    return parts


def parse_options_text(text: str | None) -> dict[str, Any]:
    if not text:
        return {}
    inner = text.strip()
    if inner.startswith("{") and inner.endswith("}"):
        inner = inner[1:-1]
    if not inner.strip():
        return {}
    opts: dict[str, Any] = {}
    for chunk in _split_csv_like(inner):
        item = chunk.strip()
        if not item:
            continue
        if item == "marimo":
            opts["marimo"] = True
            continue
        if "=" not in item:
            raise ValueError(f"invalid option: {item}")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"invalid option: {item}")
        opts[key] = _normalize_scalar(value)
    return opts


def render_scalar(value: Any) -> str:
    if value is None:
        return "None"
    if isinstance(value, bool):
        return "True" if value else "False"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(str(value))


def render_options(opts: dict[str, Any]) -> str:
    if not opts:
        return ""
    keys = sorted(opts.keys())
    parts: list[str] = []
    if opts.get("marimo"):
        parts.append("marimo")
    for key in keys:
        if key == "marimo":
            continue
        parts.append(f"{key}={render_scalar(opts[key])}")
    return " {" + ",".join(parts) + "}"


def parse_marker_line(line: str) -> tuple[bool, str | None]:
    if line == "# +":
        return True, None
    stripped = line.strip()
    if not stripped.startswith("# +"):
        return False, None
    opts = stripped[3:].strip()
    if opts.startswith("{") and opts.endswith("}"):
        return True, opts
    return False, None


def looks_like_marimo(lines: list[str]) -> bool:
    has_import = False
    has_app = False
    for line in lines:
        stripped = line.strip()
        if (
            stripped == "import marimo"
            or stripped.startswith("import marimo as ")
            or stripped.startswith("import marimo,")
        ):
            has_import = True
        if stripped.startswith("app") and ".App(" in stripped:
            has_app = True
    return has_import and has_app


def looks_like_projected(lines: list[str]) -> bool:
    if not lines:
        return False
    ok, marker = parse_marker_line(lines[0])
    return bool(ok and marker and "marimo" in marker)


def has_any_projected_markers(lines: list[str]) -> bool:
    return any(parse_marker_line(line)[0] or line == "# +" for line in lines)


def promote_first_marker_to_marimo(lines: list[str]) -> tuple[list[str], bool]:
    promoted = list(lines)
    first_marker_idx: int | None = None
    for idx, line in enumerate(promoted):
        if line == "# +" or parse_marker_line(line)[0]:
            first_marker_idx = idx
            break
    if first_marker_idx is None:
        return promoted, False
    if first_marker_idx > 0:
        promoted.insert(0, "")
        promoted.insert(0, "# + {marimo}")
        return promoted, True
    for idx, line in enumerate(promoted):
        if line == "# +":
            promoted[idx] = "# + {marimo}"
            return promoted, True
        ok, marker = parse_marker_line(line)
        if ok and marker is not None:
            opts = parse_options_text(marker)
            opts["marimo"] = True
            promoted[idx] = "# +" + render_options(opts)
            return promoted, True
    return promoted, False


def _trim_blank_lines(body: list[str]) -> list[str]:
    trimmed = list(body)
    while trimmed and not trimmed[0].strip():
        trimmed.pop(0)
    while trimmed and not trimmed[-1].strip():
        trimmed.pop()
    return trimmed


def parse_projected_cells(lines: list[str]) -> list[dict[str, Any]]:
    cells: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None

    def flush() -> None:
        nonlocal current
        if current is None:
            return
        body = _trim_blank_lines(current["body"])
        cells.append(
            {
                "name": "setup" if current["setup"] else "_",
                "options": dict(current["options"]),
                "code": "\n".join(body),
            }
        )
        current = None

    for line in lines:
        is_marker, marker = parse_marker_line(line)
        if is_marker or line == "# +":
            flush()
            opts = parse_options_text(marker)
            setup = opts.get("setup") is True
            opts.pop("setup", None)
            current = {"options": opts, "setup": setup, "body": []}
        elif current is not None:
            current["body"].append(line)
    flush()

    if not cells:
        raise ValueError("projected marimo buffer has no `# +` cells")
    for idx, cell in enumerate(cells):
        if cell["name"] == "setup" and idx != 0:
            raise ValueError("setup cell must be the first cell")
    if cells[0]["options"].get("marimo") is not True:
        raise ValueError("first cell must be marked with `{marimo}`")
    cells[0]["options"].pop("marimo", None)
    return cells


def dedupe_empty_cells(cells: list[dict[str, Any]]) -> list[dict[str, Any]]:
    deduped: list[dict[str, Any]] = []
    previous_empty = False
    for cell in cells:
        is_empty = cell["code"] == ""
        if not (is_empty and previous_empty):
            deduped.append(cell)
        previous_empty = is_empty
    return deduped


def render_projected_lines(cells: list[dict[str, Any]]) -> tuple[list[str], list[dict[str, int]]]:
    lines: list[str] = []
    spans: list[dict[str, int]] = []
    for idx, cell in enumerate(cells):
        start_line = len(lines) + 1
        opts = dict(cell.get("options") or {})
        if idx == 0:
            opts["marimo"] = True
        if cell["name"] == "setup":
            opts["setup"] = True
        lines.append("# +" + render_options(opts))
        lines.append("")
        if cell["code"]:
            code_lines = _trim_blank_lines(cell["code"].split("\n"))
            lines.extend(code_lines)
        lines.append("")
        end_line = len(lines)
        spans.append(
            {
                "start_line": start_line,
                "start_col": 1,
                "end_line": end_line,
                "end_col": 1,
            }
        )
    while lines and lines[-1] == "":
        lines.pop()
    if spans:
        spans[-1]["end_line"] = len(lines)
    return lines, spans


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


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


class Worker:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}

    def _build_notebook(self, path: str, header: str | None, app_options: dict[str, Any], cells: list[dict[str, Any]]) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
        notebook = NotebookSerializationV1(
            app=AppInstantiation(options=app_options or {}),
            header=Header(value=header) if header else None,
            cells=[CellDef(code=cell["code"], name=cell["name"], options=cell.get("options", {})) for cell in cells],
            filename=path,
        )
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
            projection_range = spans[idx] if idx < len(spans) else {"start_line": 1, "start_col": 1, "end_line": 1, "end_col": 1}
            canonical_range = canonical_ranges[idx] if idx < len(canonical_ranges) else {"start_line": 1, "start_col": 1, "end_line": 1, "end_col": 1}
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
            return [
                {
                    **cell,
                    "id": uuid.uuid4().hex,
                    "editor_status": "clean",
                }
                for cell in parsed_cells
            ]
        previous_by_key: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
        for old in previous:
            key = (old["name"], json.dumps(old.get("options", {}), sort_keys=True), old["code"])
            previous_by_key.setdefault(key, []).append(old)
        matched_previous_ids: set[str] = set()
        result: list[dict[str, Any]] = []
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
                candidate_idx = min(idx, len(previous) - 1)
                candidate = previous[candidate_idx] if previous else None
                if candidate and candidate["id"] not in matched_previous_ids:
                    matched = candidate
            if matched is None:
                result.append({**cell, "id": uuid.uuid4().hex, "editor_status": "edited"})
            else:
                matched_previous_ids.add(matched["id"])
                status = "clean" if matched["code"] == cell["code"] and matched.get("options", {}) == cell.get("options", {}) and matched["name"] == cell["name"] else "edited"
                result.append({**cell, "id": matched["id"], "editor_status": status})
        return result

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
        return header, app_options, cells

    def _from_projection(self, lines: list[str], previous: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
        parsed_cells = dedupe_empty_cells(parse_projected_cells(lines))
        return self._reconcile_ids(previous, parsed_cells)

    def _session_payload(self, session: Session) -> dict[str, Any]:
        return {
            "session_id": session.session_id,
            "path": session.path,
            "project_root": session.project_root,
            "runtime_kind": session.runtime_kind,
            "header": session.header,
            "app_options": session.app_options,
            "projected_lines": session.projected_lines,
            "canonical_source": session.canonical_source,
            "cells": session.cells,
            "projection_map": session.projection_map,
            "last_saved_source_hash": session.last_saved_source_hash,
            "last_projection_hash": session.last_projection_hash,
        }

    def open_session(self, params: dict[str, Any]) -> dict[str, Any]:
        path = params["path"]
        content = params["content"]
        input_kind = params["input_kind"]
        session_id = path
        project_root = params.get("project_root") or str(Path(path).parent)
        runtime_kind = params.get("runtime_kind") or "python"
        if input_kind == "raw_marimo":
            header, app_options, cells = self._from_raw_notebook(path, content)
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
        )
        self.sessions[session_id] = session
        return self._session_payload(session)

    def sync_projection(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        lines = params["content"].splitlines()
        cells = self._from_projection(lines, session.cells)
        canonical_source, projection_map, cells = self._build_notebook(session.path, session.header, session.app_options, cells)
        projected_lines = render_projected_lines(cells)[0]
        session.cells = cells
        session.canonical_source = canonical_source
        session.projected_lines = projected_lines
        session.projection_map = projection_map
        session.last_projection_hash = sha256_text("\n".join(projected_lines))
        return self._session_payload(session)

    def write_session(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        result = self.sync_projection(params)
        Path(session.path).write_text(session.canonical_source, encoding="utf-8")
        session.last_saved_source_hash = sha256_text(session.canonical_source)
        result["last_saved_source_hash"] = session.last_saved_source_hash
        return result

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

    def close_session(self, params: dict[str, Any]) -> dict[str, Any]:
        self.sessions.pop(params["session_id"], None)
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
        self.sessions.clear()
        return {"shutdown": True}


def main() -> int:
    worker = Worker()
    methods = {
        "open_session": worker.open_session,
        "sync_projection": worker.sync_projection,
        "write_session": worker.write_session,
        "reload_from_disk": worker.reload_from_disk,
        "close_session": worker.close_session,
        "get_session_state": worker.get_session_state,
        "get_canonical_source": worker.get_canonical_source,
        "get_projection_map": worker.get_projection_map,
        "shutdown": worker.shutdown,
    }
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        request_id = None
        try:
            payload = json.loads(raw)
            request_id = payload.get("id")
            method = payload["method"]
            params = payload.get("params", {})
            handler = methods.get(method)
            if handler is None:
                raise KeyError(f"unknown method: {method}")
            result = handler(params)
            response = {"id": request_id, "ok": True, "result": result}
        except Exception as exc:  # noqa: BLE001
            response = {"id": request_id, "ok": False, "error": _error("protocol_error", str(exc))}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
