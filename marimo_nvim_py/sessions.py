from __future__ import annotations

import hashlib
import json
import uuid
from pathlib import Path
from typing import Any

from marimo._ast.codegen import generate_filecontents_from_ir
from marimo._ast.parse import parse_notebook
from marimo._schemas.serialization import AppInstantiation, CellDef, Header, NotebookSerializationV1

from marimo_nvim_py.models import Session
from marimo_nvim_py.projected import (
    dedupe_empty_cells,
    parse_projected_cells,
    promote_first_marker_to_marimo,
    render_projected_lines,
)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class Worker:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}

    def _build_notebook(
        self, path: str, header: str | None, app_options: dict[str, Any], cells: list[dict[str, Any]]
    ) -> tuple[str, dict[str, Any], list[dict[str, Any]]]:
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
        return header, app_options, cells

    def _from_projection(self, lines: list[str], previous: list[dict[str, Any]] | None) -> list[dict[str, Any]]:
        parsed_cells = dedupe_empty_cells(parse_projected_cells(lines))
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
        )
        self.sessions[session_id] = session
        return self._session_payload(session)

    def sync_projection(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[params["session_id"]]
        lines = params["content"].splitlines()
        cells = self._from_projection(lines, session.cells)
        canonical_source, projection_map, cells = self._build_notebook(
            session.path, session.header, session.app_options, cells
        )
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
