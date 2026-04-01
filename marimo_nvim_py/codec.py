from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from marimo._ast.parse import parse_notebook
from marimo._schemas.serialization import AppInstantiation, CellDef, Header, NotebookSerializationV1
from marimo._session.notebook.serializer import PythonNotebookSerializer


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _normalize_options(options: dict[str, Any] | None) -> dict[str, Any]:
    return dict(options or {})


def _normalize_app_options(options: Any) -> dict[str, Any]:
    if isinstance(options, dict):
        return dict(options)
    return {}


def _snapshot(
    *,
    path: str,
    project_root: str,
    header: str | None,
    app_options: dict[str, Any],
    cells: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "session_id": path,
        "path": path,
        "project_root": project_root,
        "header": header,
        "app_options": _normalize_app_options(app_options),
        "cells": [
            {
                "name": cell["name"],
                "code": cell["code"],
                "options": _normalize_options(cell.get("options")),
            }
            for cell in cells
        ],
    }


def load_raw_notebook(*, path: str, content: str, project_root: str | None = None) -> dict[str, Any]:
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
            "name": cell.name,
            "code": cell.code,
            "options": dict(cell.options or {}),
        }
        for cell in notebook.cells
        if cell.code.strip() != ""
    ]
    if not cells:
        cells = [{"name": "_", "code": "", "options": {}}]
    return _snapshot(
        path=path,
        project_root=project_root or str(Path(path).resolve().parent),
        header=header,
        app_options=app_options,
        cells=cells,
    )


def _to_ir(snapshot: dict[str, Any]) -> NotebookSerializationV1:
    return NotebookSerializationV1(
        app=AppInstantiation(options=_normalize_app_options(snapshot.get("app_options"))),
        header=Header(value=snapshot["header"]) if snapshot.get("header") else None,
        cells=[
            CellDef(
                code=cell["code"],
                name=cell.get("name", "_"),
                options=_normalize_options(cell.get("options")),
            )
            for cell in snapshot.get("cells", [])
        ],
        filename=snapshot["path"],
    )


def serialize_notebook(snapshot: dict[str, Any]) -> dict[str, Any]:
    serializer = PythonNotebookSerializer()
    notebook_ir = _to_ir(snapshot)
    canonical_source = serializer.serialize(notebook_ir)
    parsed = parse_notebook(canonical_source, filepath=snapshot["path"])
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
        "last_saved_source_hash": sha256_text(canonical_source),
    }
