from __future__ import annotations

from pathlib import Path

from marimo_nvim_py.worker import Worker, dedupe_empty_cells, parse_projected_cells, promote_first_marker_to_marimo


RAW_NOTEBOOK = """\
import marimo

__generated_with = "0.21.1"
app = marimo.App()


@app.cell
def _():
    x = 1
    x
    return


if __name__ == "__main__":
    app.run()
"""


def test_parse_projected_cells_supports_setup_cell() -> None:
    cells = parse_projected_cells(
        [
            "# + {marimo, setup=True, hide_code=True}",
            "import marimo as mo",
            "",
            "# +",
            "x = mo.ui.slider(1, 10)",
            "x",
        ]
    )
    assert len(cells) == 2
    assert cells[0]["name"] == "setup"
    assert cells[0]["options"] == {"hide_code": True}
    assert cells[1]["name"] == "_"


def test_dedupe_empty_cells() -> None:
    cells = dedupe_empty_cells(
        [
            {"name": "_", "options": {}, "code": ""},
            {"name": "_", "options": {}, "code": ""},
            {"name": "_", "options": {}, "code": "x = 1"},
        ]
    )
    assert len(cells) == 2
    assert cells[0]["code"] == ""
    assert cells[1]["code"] == "x = 1"


def test_promote_first_marker_to_marimo() -> None:
    promoted, changed = promote_first_marker_to_marimo(
        [
            "# +",
            "",
            "x = 1",
        ]
    )
    assert changed is True
    assert promoted[0] == "# + {marimo}"


def test_open_session_from_raw_notebook(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "notebook.py"
    path.write_text(RAW_NOTEBOOK, encoding="utf-8")
    result = worker.open_session(
        {
            "path": str(path),
            "content": RAW_NOTEBOOK,
            "input_kind": "raw_marimo",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    assert result["session_id"] == str(path)
    assert result["runtime_kind"] == "uv_project"
    assert result["projected_lines"][0] == "# + {marimo}"
    assert "@app.cell" in result["canonical_source"]
    assert result["projection_map"]["cells"][0]["canonical_range"]["start_line"] > 0


def test_sync_projection_preserves_stable_ids(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "notebook.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    updated = worker.sync_projection(
        {
            "session_id": initial["session_id"],
            "content": "# + {marimo}\n\nx = 2\nx",
        }
    )
    assert initial["cells"][0]["id"] == updated["cells"][0]["id"]
    assert updated["cells"][0]["editor_status"] == "edited"


def test_write_session_writes_canonical_marimo_source(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "projected.py"
    result = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    worker.write_session(
        {
            "session_id": result["session_id"],
            "content": "# + {marimo}\n\nx = 1\nx",
        }
    )
    written = path.read_text(encoding="utf-8")
    assert "import marimo" in written
    assert "@app.cell" in written
