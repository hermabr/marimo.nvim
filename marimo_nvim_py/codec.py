from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any, cast

from marimo._ast.cell import CellConfig
from marimo._ast.compiler import compile_cell
from marimo._runtime.dataflow import DirectedGraph
from marimo._ast.parse import parse_notebook
from marimo._schemas.serialization import AppInstantiation, CellDef, Header, NotebookSerializationV1
from marimo._session.notebook.serializer import get_notebook_serializer


def _drop_empty_cells(cells: list[dict[str, Any]]) -> list[dict[str, Any]]:
    kept = [cell for cell in cells if cell["code"].strip() != ""]
    if kept:
        return kept
    if not cells:
        return []
    first = dict(cells[0])
    first["code"] = ""
    return [first]


def _coerce_options(value: Any) -> dict[str, Any]:
    return dict(value) if isinstance(value, dict) else {}


def _cell_disabled_states(cells: list[dict[str, Any]]) -> dict[str, bool]:
    graph = DirectedGraph()
    try:
        for cell in cells:
            compiled = compile_cell(cell["code"], cell_id=cell["id"])
            compiled.configure(CellConfig.from_dict(_coerce_options(cell.get("options")), warn=False))
            graph.register_cell(cell["id"], compiled)
    except Exception:  # noqa: BLE001
        return {cell["id"]: False for cell in cells}

    disabled_by_ancestor: dict[str, bool] = {}
    for cell in cells:
        disabled = graph.is_disabled(cell["id"])
        disabled_by_ancestor[cell["id"]] = bool(disabled and not _coerce_options(cell.get("options")).get("disabled"))
    return disabled_by_ancestor


def _build_ir(path: str, snapshot: dict[str, Any]) -> NotebookSerializationV1:
    header = snapshot.get("header")
    app_options_raw = snapshot.get("app_options") or {}
    app_options = dict(app_options_raw) if isinstance(app_options_raw, dict) else {}
    cells = snapshot.get("cells") or []
    return NotebookSerializationV1(
        app=AppInstantiation(options=app_options),
        header=Header(value=header) if header else None,
        cells=[
            CellDef(
                code=cell["code"],
                name=cell.get("name", "_"),
                options=_coerce_options(cell.get("options")),
            )
            for cell in cells
        ],
        filename=path,
    )


def load_raw_notebook(path: str, content: str) -> dict[str, Any]:
    serializer = get_notebook_serializer(Path(path))
    notebook = serializer.deserialize(content, filepath=path)
    if not notebook.valid:
        description = notebook.violations[0].description if notebook.violations else "invalid marimo notebook"
        raise ValueError(description)
    cells = _drop_empty_cells(
        [
            {
                "id": uuid.uuid4().hex,
                "name": cell.name,
                "code": cell.code,
                "options": dict(cell.options or {}),
                "editor_status": "clean",
            }
            for cell in notebook.cells
        ]
    )
    return {
        "session_id": path,
        "path": path,
        "header": notebook.header.value if notebook.header and notebook.header.value != "" else None,
        "app_options": dict(notebook.app.options or {}),
        "cells": cells,
    }


def serialize_notebook(path: str, snapshot: dict[str, Any]) -> dict[str, Any]:
    cells = snapshot.get("cells") or []
    serializer = get_notebook_serializer(Path(path))
    canonical_source = serializer.serialize(_build_ir(path, snapshot))
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
    return {
        "canonical_source": canonical_source,
        "canonical_ranges": canonical_ranges,
        "disabled_transitively": _cell_disabled_states(cast(list[dict[str, Any]], cells)),
    }
