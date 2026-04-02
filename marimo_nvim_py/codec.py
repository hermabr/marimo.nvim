from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any

from marimo._schemas.serialization import (
    AppInstantiation,
    CellDef,
    Header,
    NotebookSerializationV1,
)
from marimo._session.notebook.serializer import PythonNotebookSerializer

from marimo_nvim_py.models import NotebookSnapshot, SnapshotCell


def _drop_empty_cells(cells: list[SnapshotCell]) -> list[SnapshotCell]:
    kept = [cell for cell in cells if cell.code.strip() != ""]
    if kept:
        return kept
    if not cells:
        return []
    first = SnapshotCell(id=cells[0].id, name=cells[0].name, code="", options=dict(cells[0].options))
    return [first]


def _snapshot_to_ir(snapshot: NotebookSnapshot) -> NotebookSerializationV1:
    return NotebookSerializationV1(
        app=AppInstantiation(options=dict(snapshot.app_options or {})),
        header=Header(value=snapshot.header) if snapshot.header else None,
        cells=[
            CellDef(
                code=cell.code,
                name=cell.name,
                options=dict(cell.options or {}),
            )
            for cell in snapshot.cells
        ],
        filename=snapshot.path,
    )


def load_raw_notebook(
    *,
    path: str,
    content: str,
    cwd: str,
    project_root: str,
    runtime_kind: str,
) -> NotebookSnapshot:
    serializer = PythonNotebookSerializer()
    notebook = serializer.deserialize(content, filepath=path)
    if not notebook.valid:
        description = notebook.violations[0].description if notebook.violations else "invalid marimo notebook"
        raise ValueError(description)
    cells = _drop_empty_cells(
        [
            SnapshotCell(
                id=uuid.uuid4().hex,
                name=cell.name,
                code=cell.code,
                options=dict(cell.options or {}),
            )
            for cell in list(notebook.cells or [])
        ]
    )
    return NotebookSnapshot(
        session_id=path,
        path=path,
        cwd=cwd,
        project_root=project_root or str(Path(path).resolve().parent),
        runtime_kind=runtime_kind or "uv",
        header=notebook.header.value if notebook.header and notebook.header.value else None,
        app_options=dict(notebook.app.options or {}),
        cells=cells,
    )


def serialize_notebook(snapshot: NotebookSnapshot) -> dict[str, Any]:
    serializer = PythonNotebookSerializer()
    canonical_source = serializer.serialize(_snapshot_to_ir(snapshot))
    canonical_notebook = serializer.deserialize(canonical_source, filepath=snapshot.path)
    canonical_ranges: list[dict[str, int]] = []
    for cell in list(canonical_notebook.cells or []):
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
    }
