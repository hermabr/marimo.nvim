from __future__ import annotations

import ast
from typing import cast

from marimo._ast.compiler import compile_cell
from marimo._runtime.dataflow.graph import DirectedGraph
from marimo._types.ids import CellId_t

from marimo_nvim_py.models import NotebookSnapshot, SnapshotCell


def _cell_ast_dump(cell: SnapshotCell) -> str | None:
    try:
        compiled = compile_cell(
            code=cell.code,
            cell_id=cast(CellId_t, cell.id),
            filename=None,
        )
    except Exception:
        return None
    return ast.dump(
        compiled.mod,
        annotate_fields=False,
        include_attributes=False,
    )


def cell_requires_rerun(previous: SnapshotCell | None, current: SnapshotCell) -> bool:
    if previous is None:
        return True
    if previous.name != current.name:
        return True
    if previous.options != current.options:
        return True
    if previous.code == current.code:
        return False

    previous_ast = _cell_ast_dump(previous)
    current_ast = _cell_ast_dump(current)
    if previous_ast is None or current_ast is None:
        return True
    return previous_ast != current_ast


def resolve_runtime_updates(
    snapshot: NotebookSnapshot,
    previous_cells: list[SnapshotCell],
    raw_changed_ids: set[str],
) -> tuple[list[str], list[str]]:
    previous_by_id = {cell.id: cell for cell in previous_cells}
    changed_ids = [
        cell.id
        for cell in snapshot.cells
        if cell.id in raw_changed_ids
        and cell_requires_rerun(previous_by_id.get(cell.id), cell)
    ]
    if not changed_ids:
        return [], []

    try:
        graph = DirectedGraph()
        for cell in snapshot.cells:
            graph.register_cell(
                cast(CellId_t, cell.id),
                compile_cell(
                    code=cell.code,
                    cell_id=cast(CellId_t, cell.id),
                    filename=None,
                ),
            )
    except Exception:
        return changed_ids, []

    changed_lookup = set(changed_ids)
    dependent_lookup: set[str] = set()
    for cell_id in changed_ids:
        if cast(CellId_t, cell_id) not in graph.cells:
            continue
        dependent_lookup.update(
            str(descendant_id)
            for descendant_id in graph.descendants(cast(CellId_t, cell_id))
        )

    dependent_ids = [
        cell.id
        for cell in snapshot.cells
        if cell.id in dependent_lookup
        and cell.id not in changed_lookup
        and not cell.options.get("disabled", False)
    ]
    return changed_ids, dependent_ids
