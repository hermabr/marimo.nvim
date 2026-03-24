from __future__ import annotations

from pathlib import Path

from marimo_nvim_py.projected import dedupe_empty_cells, drop_empty_cells, parse_projected_cells, promote_first_marker_to_marimo
from marimo_nvim_py.sessions import Worker


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


def test_drop_empty_cells() -> None:
    cells = drop_empty_cells(
        [
            {"name": "_", "options": {}, "code": ""},
            {"name": "_", "options": {}, "code": "x = 1"},
            {"name": "_", "options": {}, "code": "   "},
        ]
    )
    assert len(cells) == 1
    assert cells[0]["code"] == "x = 1"


def test_drop_empty_cells_preserves_one_when_all_empty() -> None:
    cells = drop_empty_cells(
        [
            {"name": "_", "options": {}, "code": ""},
            {"name": "_", "options": {}, "code": "   "},
        ]
    )
    assert len(cells) == 1
    assert cells[0]["code"] == ""


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


def test_open_session_from_raw_notebook_drops_empty_cells(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "raw_with_empty.py"
    raw = """\
import marimo

app = marimo.App()


@app.cell
def _():
    x = 1
    return (x,)


@app.cell
def _():
    return


if __name__ == "__main__":
    app.run()
"""
    result = worker.open_session(
        {
            "path": str(path),
            "content": raw,
            "input_kind": "raw_marimo",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    assert len(result["cells"]) == 1
    assert result["cells"][0]["code"] == "x = 1"
    assert result["canonical_source"].count("@app.cell") == 1


def test_sync_projection_preserves_existing_ids_when_inserting_first_cell(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "insert_before.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\na = 1\n\n# +\n\nb = 2",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    old_a_id = initial["cells"][0]["id"]
    old_b_id = initial["cells"][1]["id"]

    updated = worker.sync_projection(
        {
            "session_id": initial["session_id"],
            "content": "# + {marimo}\n\nx = 0\n\n# +\n\na = 1\n\n# +\n\nb = 2",
        }
    )

    assert len(updated["cells"]) == 3
    assert updated["cells"][0]["id"] not in {old_a_id, old_b_id}
    assert updated["cells"][1]["id"] == old_a_id
    assert updated["cells"][2]["id"] == old_b_id
    assert updated["cells"][1]["editor_status"] == "clean"
    assert updated["cells"][2]["editor_status"] == "clean"


def test_open_session_populates_runtime_output(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "runtime_output.py"
    result = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    runtime = result["cells"][0]["runtime"]
    assert runtime["status"] == "idle"
    assert runtime["output_kind"] == "text"
    assert runtime["output_lines"] == ["1"]
    worker.shutdown({})


def test_sync_and_run_updates_descendant_outputs(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "reactive.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    updated = worker.sync_and_run(
        {
            "session_id": initial["session_id"],
            "content": "# + {marimo}\n\nx = 3\nx\n\n# +\n\ny = x + 1\ny",
        }
    )
    assert updated["cells"][0]["runtime"]["output_lines"] == ["3"]
    assert updated["cells"][1]["runtime"]["output_lines"] == ["4"]
    worker.shutdown({})


def test_html_output_is_summarized(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "html_output.py"
    result = worker.open_session(
        {
            "path": str(path),
            "content": '# + {marimo}\n\nimport marimo as mo\nmo.md(\"# hello\")',
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    runtime = result["cells"][0]["runtime"]
    assert runtime["output_kind"] in {"text", "html", "widget"}
    assert runtime["output_summary"] is not None or runtime["output_lines"]
    worker.shutdown({})
