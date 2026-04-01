from __future__ import annotations

import hashlib
import uuid
from pathlib import Path
from typing import Any

from marimo._ast.cell import CellConfig
from marimo._ast.compiler import compile_cell
from marimo._ast.parse import parse_notebook
from marimo._runtime.dataflow import DirectedGraph
from marimo._schemas.serialization import (
    AppInstantiation,
    CellDef,
    Header,
    NotebookSerializationV1,
)
from marimo._session.notebook.serializer import get_notebook_serializer


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _cell_config(cell: dict[str, Any]) -> CellConfig:
    return CellConfig.from_dict(dict(cell.get("options") or {}), warn=False)


def _cell_disabled_states(cells: list[dict[str, Any]]) -> dict[str, bool]:
    graph = DirectedGraph()
    try:
        for cell in cells:
            compiled = compile_cell(cell["code"], cell_id=cell["id"])
            compiled.configure(_cell_config(cell))
            graph.register_cell(cell["id"], compiled)
    except Exception:  # noqa: BLE001
        return {cell["id"]: False for cell in cells}

    disabled_by_ancestor: dict[str, bool] = {}
    for cell in cells:
        disabled = graph.is_disabled(cell["id"])
        disabled_by_ancestor[cell["id"]] = bool(
            disabled and not cell.get("options", {}).get("disabled")
        )
    return disabled_by_ancestor


def _build_notebook_ir(
    path: str,
    header: str | None,
    app_options: dict[str, Any],
    cells: list[dict[str, Any]],
) -> NotebookSerializationV1:
    return NotebookSerializationV1(
        app=AppInstantiation(options=app_options or {}),
        header=Header(value=header) if header else None,
        cells=[
            CellDef(
                code=str(cell["code"]),
                name=str(cell.get("name") or "_"),
                options=dict(cell.get("options") or {}),
            )
            for cell in cells
        ],
        filename=path,
    )


def _canonical_ranges(path: str, canonical_source: str) -> list[dict[str, int]]:
    parsed = parse_notebook(canonical_source, filepath=path)
    if parsed is None:
        return []
    ranges: list[dict[str, int]] = []
    for cell in parsed.cells:
        ranges.append(
            {
                "start_line": int(cell.lineno),
                "start_col": int(cell.col_offset) + 1,
                "end_line": int(cell.end_lineno),
                "end_col": int(cell.end_col_offset) + 1,
            }
        )
    return ranges


def _serialize_cells(
    cells: list[dict[str, Any]],
    canonical_ranges: list[dict[str, int]],
) -> list[dict[str, Any]]:
    disabled_by_ancestor = _cell_disabled_states(cells)
    out: list[dict[str, Any]] = []
    for index, cell in enumerate(cells):
        out.append(
            {
                "id": str(cell["id"]),
                "name": str(cell.get("name") or "_"),
                "code": str(cell.get("code") or ""),
                "options": dict(cell.get("options") or {}),
                "index": index,
                "editor_status": str(cell.get("editor_status") or "clean"),
                "disabled_transitively": disabled_by_ancestor.get(
                    str(cell["id"]), False
                ),
                "canonical_range": canonical_ranges[index]
                if index < len(canonical_ranges)
                else {
                    "start_line": 1,
                    "start_col": 1,
                    "end_line": 1,
                    "end_col": 1,
                },
            }
        )
    return out


def serialize_notebook(path: str, snapshot: dict[str, Any]) -> dict[str, Any]:
    header = snapshot.get("header")
    app_options = dict(snapshot.get("app_options") or {})
    cells = [dict(cell) for cell in snapshot.get("cells") or []]
    notebook = _build_notebook_ir(path, header, app_options, cells)
    serializer = get_notebook_serializer(Path(path))
    canonical_source = serializer.serialize(notebook)
    serialized_cells = _serialize_cells(cells, _canonical_ranges(path, canonical_source))
    return {
        "canonical_source": canonical_source,
        "last_saved_source_hash": sha256_text(canonical_source),
        "cells": serialized_cells,
    }


def load_raw_notebook(path: str, content: str) -> dict[str, Any]:
    parsed = parse_notebook(content, filepath=path)
    if parsed is None:
        raise ValueError("empty notebook")
    if not parsed.valid:
        description = (
            parsed.violations[0].description
            if parsed.violations
            else "invalid marimo notebook"
        )
        raise ValueError(description)

    header = parsed.header.value if parsed.header and parsed.header.value else None
    app_options = dict(parsed.app.options or {})
    cells = [
        {
            "id": uuid.uuid4().hex,
            "name": cell.name,
            "code": cell.code,
            "options": dict(cell.options or {}),
            "editor_status": "clean",
        }
        for cell in parsed.cells
        if cell.code.strip() != ""
    ]
    if not cells:
        cells = [
            {
                "id": uuid.uuid4().hex,
                "name": "_",
                "code": "",
                "options": {},
                "editor_status": "clean",
            }
        ]
    snapshot = {
        "session_id": path,
        "path": path,
        "header": header,
        "app_options": app_options,
        "cells": cells,
    }
    return {
        **snapshot,
        **serialize_notebook(path, snapshot),
    }
