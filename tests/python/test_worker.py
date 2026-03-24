from __future__ import annotations

from pathlib import Path
from typing import cast

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


def test_write_projection_writes_canonical_marimo_source(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "projected_async.py"
    result = worker.write_projection(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx",
            "header": None,
            "app_options": {},
        }
    )
    written = path.read_text(encoding="utf-8")
    assert "import marimo" in written
    assert "@app.cell" in written
    assert result["last_saved_source_hash"]


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


def test_run_cells_populates_runtime_output(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "runtime_output.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [initial["cells"][0]["id"]]})
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
    initial = worker.open_session(
        {
            "path": str(path),
            "content": '# + {marimo}\n\nimport marimo as mo\nmo.md(\"# hello\")',
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [initial["cells"][0]["id"]]})
    runtime = result["cells"][0]["runtime"]
    assert runtime["output_kind"] in {"text", "html", "widget"}
    assert runtime["output_summary"] is not None or runtime["output_lines"]
    worker.shutdown({})


def test_run_cells_captures_stdout_as_console_lines(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "stdout_output.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": '# + {marimo}\n\nprint("hello")\n1',
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [initial["cells"][0]["id"]]})
    runtime = result["cells"][0]["runtime"]
    assert runtime["output_lines"] == ["1"]
    assert runtime["console_lines"] == ["hello"]
    assert runtime["has_console"] is True
    worker.shutdown({})


def test_run_cells_emits_incremental_runtime_updates(tmp_path: Path) -> None:
    events: list[dict[str, object]] = []
    worker = Worker(event_sink=events.append)
    path = tmp_path / "runtime_stream.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx\n\n# +\n\nimport time\ntime.sleep(2.0)\ny = x + 1\ny",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )

    result = worker.run_cells(
        {
            "session_id": initial["session_id"],
            "cell_ids": [cell["id"] for cell in initial["cells"]],
            "_request_id": 42,
        }
    )

    assert result["cells"][0]["runtime"]["output_lines"] == ["1"]
    assert result["cells"][1]["runtime"]["output_lines"] == ["2"]
    first_cell_id = initial["cells"][0]["id"]
    second_cell_id = initial["cells"][1]["id"]
    runtime_events = [event for event in events if event.get("event") == "runtime_update"]
    assert runtime_events
    assert any(
        event.get("request_id") == 42
        and isinstance(event.get("payload"), dict)
        and cast(dict[str, dict[str, object]], cast(dict[str, object], event["payload"])["runtime_cells"]).get(first_cell_id, {}).get("output_lines")
        == ["1"]
        and cast(dict[str, dict[str, object]], cast(dict[str, object], event["payload"])["runtime_cells"]).get(second_cell_id, {}).get("status")
        in {"queued", "running"}
        for event in runtime_events
    )
    worker.shutdown({})


def test_run_cells_resolves_relative_paths_from_notebook_directory(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "relative_path.py"
    data_path = tmp_path / "value.txt"
    data_path.write_text("hello", encoding="utf-8")
    initial = worker.open_session(
        {
            "path": str(path),
            "content": '# + {marimo}\n\nfrom pathlib import Path\nPath("./value.txt").read_text()',
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [initial["cells"][0]["id"]]})
    assert result["cells"][0]["runtime"]["output_lines"] == ["'hello'"]
    worker.shutdown({})


def test_run_cells_attributes_stdout_to_the_emitting_cell(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "stdout_attribution.py"
    (tmp_path / "value.txt").write_text("hello", encoding="utf-8")
    initial = worker.open_session(
        {
            "path": str(path),
            "content": (
                '# + {marimo}\n\nfrom pathlib import Path\nPath("./value.txt").read_text()\n\n'
                '# +\n\nprint("HEY")'
            ),
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [cell["id"] for cell in initial["cells"]]})
    first_runtime = result["cells"][0]["runtime"]
    second_runtime = result["cells"][1]["runtime"]
    assert first_runtime["output_lines"] == ["'hello'"]
    assert first_runtime["console_lines"] == []
    assert second_runtime["console_lines"] == ["HEY"]
    worker.shutdown({})


def test_run_cells_formats_runtime_tracebacks_as_error_output(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "runtime_nameerror.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\ndf",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [initial["cells"][0]["id"]]})
    runtime = result["cells"][0]["runtime"]
    assert runtime["output_kind"] == "error"
    assert not any("An internal error occurred:" in line for line in runtime["output_lines"])
    assert runtime["output_lines"] == ["name 'df' is not defined"]
    assert any("Traceback (most recent call last):" in line for line in runtime["console_lines"])
    assert any("NameError: name 'df' is not defined" in line for line in runtime["console_lines"])
    worker.shutdown({})


def test_sync_and_run_only_reruns_changed_branch(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "branch_selective.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": (
                "# + {marimo, setup=True}\n\ncounts = {'a': 0, 'left': 0, 'b': 0, 'final': 0}\n\n"
                "# +\n\ncounts['a'] += 1\na = 2\ncounts['a']\n\n"
                "# +\n\ncounts['left'] += 1\ncounts['left']\n\n"
                "# +\n\ncounts['b'] += 1\nb = 2\ncounts['b']\n\n"
                "# +\n\ncounts['final'] += 1\ncounts['final'] * 100 + a * b\n"
            ),
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )

    bootstrapped = worker.sync_and_run(
        {
            "session_id": initial["session_id"],
            "content": (
                "# + {marimo, setup=True}\n\ncounts = {'a': 0, 'left': 0, 'b': 0, 'final': 0}\n\n"
                "# +\n\ncounts['a'] += 1\na = 2\ncounts['a']\n\n"
                "# +\n\ncounts['left'] += 1\ncounts['left']\n\n"
                "# +\n\ncounts['b'] += 1\nb = 2\ncounts['b']\n\n"
                "# +\n\ncounts['final'] += 1\ncounts['final'] * 100 + a * b\n"
            ),
        }
    )
    assert bootstrapped["cells"][1]["runtime"]["output_lines"] == ["1"]
    assert bootstrapped["cells"][2]["runtime"]["output_lines"] == ["1"]
    assert bootstrapped["cells"][3]["runtime"]["output_lines"] == ["1"]
    assert bootstrapped["cells"][4]["runtime"]["output_lines"] == ["104"]

    updated = worker.sync_and_run(
        {
            "session_id": initial["session_id"],
            "content": (
                "# + {marimo, setup=True}\n\ncounts = {'a': 0, 'left': 0, 'b': 0, 'final': 0}\n\n"
                "# +\n\ncounts['a'] += 1\na = 2\ncounts['a']\n\n"
                "# +\n\ncounts['left'] += 1\ncounts['left']\n\n"
                "# +\n\ncounts['b'] += 1\nb = 3\ncounts['b']\n\n"
                "# +\n\ncounts['final'] += 1\ncounts['final'] * 100 + a * b\n"
            ),
        }
    )

    assert updated["cells"][1]["runtime"]["output_lines"] == ["1"]
    assert updated["cells"][2]["runtime"]["output_lines"] == ["1"]
    assert updated["cells"][3]["runtime"]["output_lines"] == ["2"]
    assert updated["cells"][4]["runtime"]["output_lines"] == ["206"]
    worker.shutdown({})
