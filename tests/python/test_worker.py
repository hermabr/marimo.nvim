from __future__ import annotations

import html
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any, cast

from marimo_nvim_py.projected import dedupe_empty_cells, drop_empty_cells, parse_projected_cells, promote_first_marker_to_marimo
from marimo_nvim_py.sessions import Worker, _extract_marimo_table_metadata


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


def assert_text_output(runtime: dict[str, object], expected: str) -> None:
    output = cast(dict[str, object], runtime["output"])
    text = output_text(output)
    assert expected in text


def output_text(output: dict[str, object]) -> str:
    mimetype = cast(str, output["mimetype"])
    if mimetype == "text/plain":
        return str(output["data"])
    if mimetype == "text/html":
        return html.unescape(re.sub(r"<[^>]+>", "", str(output["data"])))
    if mimetype == "text/markdown":
        return str(output["data"])
    raise AssertionError(f"expected text output, got {mimetype!r}")


def assert_no_output(runtime: dict[str, object]) -> None:
    assert runtime["output"] is None


def console_text(runtime: dict[str, object]) -> list[str]:
    console = cast(list[dict[str, object]], runtime["console"])
    lines: list[str] = []
    for entry in console:
        if entry["channel"] == "media":
            lines.append(f'[{entry["mimetype"]} output]')
        else:
            lines.extend(str(entry["data"]).splitlines())
    return lines


MARIMO_TABLE_HTML = (
    "<marimo-ui-element object-id='table-1' random-id='table-2'>"
    "<marimo-table data-initial-value='[]' data-label='null' "
    "data-data='&quot;[{&#92;&quot;number&#92;&quot;:1},{&#92;&quot;number&#92;&quot;:2},{&#92;&quot;number&#92;&quot;:3},"
    "{&#92;&quot;number&#92;&quot;:4},{&#92;&quot;number&#92;&quot;:5},{&#92;&quot;number&#92;&quot;:6},"
    "{&#92;&quot;number&#92;&quot;:7},{&#92;&quot;number&#92;&quot;:8},{&#92;&quot;number&#92;&quot;:9},"
    "{&#92;&quot;number&#92;&quot;:10}]&quot;' "
    "data-total-rows='100' data-total-columns='1' data-max-columns='50' "
    "data-banner-text='&quot;&quot;' data-pagination='true' data-page-size='10' "
    "data-field-types='[[&quot;number&quot;,[&quot;integer&quot;,&quot;i64&quot;]]]' "
    "data-show-filters='true' data-show-download='true' data-show-column-summaries='false' "
    "data-show-data-types='true' data-show-page-size-selector='true' "
    "data-show-column-explorer='true' data-show-chart-builder='false' data-row-headers='[]' "
    "data-has-stable-row-id='false' data-lazy='false' data-preload='false' "
    "data-download-file-name='&quot;df&quot;'></marimo-table></marimo-ui-element>"
)


def test_extract_marimo_table_metadata() -> None:
    metadata = _extract_marimo_table_metadata(MARIMO_TABLE_HTML)
    assert metadata is not None
    assert metadata["object_id"] == "table-1"
    assert metadata["row_count"] == 10
    assert metadata["total_rows"] == 100
    assert metadata["rows"][0] == {"number": 1}
    assert metadata["rows"][-1] == {"number": 10}


def test_expand_marimo_table_output_fetches_more_rows(monkeypatch: object) -> None:
    worker = Worker()
    expanded_rows = [{"number": idx} for idx in range(1, 101)]

    def fake_invoke_ui_function(*args: object, **kwargs: object) -> dict[str, object]:
        del args, kwargs
        return {
            "data": json.dumps(expanded_rows),
            "total_rows": 100,
            "cell_styles": None,
            "cell_hover_texts": None,
        }

    cast(Any, monkeypatch).setattr(worker, "_invoke_ui_function", fake_invoke_ui_function)
    output = {"mimetype": "text/html", "data": MARIMO_TABLE_HTML}
    expanded = worker._maybe_expand_marimo_table_output(cast(Any, SimpleNamespace()), output)
    assert expanded is not None
    metadata = _extract_marimo_table_metadata(expanded["data"])
    assert metadata is not None
    assert metadata["row_count"] == 100
    assert metadata["rows"][-1] == {"number": 100}


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


def test_reload_from_disk_closes_previous_runtime_session(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "reload_me.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    old_session = worker.sessions[initial["session_id"]]
    closed = {"value": False}

    def close() -> None:
        closed["value"] = True

    old_runtime_session = cast(object, SimpleNamespace(close=close))
    old_session.runtime_session = old_runtime_session

    path.write_text(RAW_NOTEBOOK, encoding="utf-8")
    reloaded = worker.reload_from_disk({"session_id": initial["session_id"]})

    new_session = worker.sessions[initial["session_id"]]
    assert reloaded["session_id"] == initial["session_id"]
    assert new_session is not old_session
    assert new_session.runtime_session is not None
    assert new_session.runtime_session is not old_runtime_session
    assert closed["value"] is True
    worker.shutdown({})


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
    assert_text_output(runtime, "1")
    worker.shutdown({})


def test_run_cells_only_runs_selected_cell_and_its_ancestors(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "runtime_ancestors.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\na = 1\na\n\n# +\n\nb = a + 1\nb\n\n# +\n\nc = 9\nc",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [initial["cells"][1]["id"]]})
    first_runtime = result["cells"][0]["runtime"]
    second_runtime = result["cells"][1]["runtime"]
    third_runtime = result["cells"][2]["runtime"]
    assert_text_output(first_runtime, "1")
    assert_text_output(second_runtime, "2")
    assert_no_output(third_runtime)
    worker.shutdown({})


def test_run_cells_does_not_rerun_non_stale_ancestors_after_bootstrap(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "runtime_ancestor_rerun.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": (
                "# + {marimo}\n\nimport time\n"
                "counts = {'base': 0, 'mid': 0, 'leaf': 0}\n\n"
                "def f(x, key):\n"
                "    for i in range(x):\n"
                "        print(i)\n"
                "        time.sleep(0.01)\n"
                "    counts[key] += 1\n"
                "    return counts[key]\n\n"
                "# +\n\nmid = f(2, 'mid')\nmid\n\n"
                "# +\n\nleaf = mid + f(2, 'leaf')\nleaf"
            ),
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    leaf_id = initial["cells"][2]["id"]

    first = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [leaf_id]})
    assert_text_output(first["cells"][1]["runtime"], "1")
    assert_text_output(first["cells"][2]["runtime"], "2")

    second = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [leaf_id]})
    assert_text_output(second["cells"][1]["runtime"], "1")
    assert_text_output(second["cells"][2]["runtime"], "3")
    worker.shutdown({})


def test_run_cells_reruns_stale_ancestors_after_sync_projection(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "runtime_stale_ancestors.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny\n\n# +\n\nz = y + 1\nz",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    leaf_id = initial["cells"][2]["id"]

    bootstrapped = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [leaf_id]})
    assert_text_output(bootstrapped["cells"][0]["runtime"], "1")
    assert_text_output(bootstrapped["cells"][1]["runtime"], "2")
    assert_text_output(bootstrapped["cells"][2]["runtime"], "3")

    worker.sync_projection(
        {
            "session_id": initial["session_id"],
            "content": "# + {marimo}\n\nx = 7\nx\n\n# +\n\ny = x + 1\ny\n\n# +\n\nz = y + 1\nz",
        }
    )
    rerun = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [leaf_id]})
    assert_text_output(rerun["cells"][0]["runtime"], "7")
    assert_text_output(rerun["cells"][1]["runtime"], "8")
    assert_text_output(rerun["cells"][2]["runtime"], "9")
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
    assert_text_output(updated["cells"][0]["runtime"], "3")
    assert_text_output(updated["cells"][1]["runtime"], "4")
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
    output = cast(dict[str, object], runtime["output"])
    assert output["mimetype"] in {"text/plain", "text/html", "text/markdown", "application/vnd.marimo+mimebundle"}
    assert output["data"] is not None
    worker.shutdown({})


def test_run_cells_captures_stdout_as_console_entries(tmp_path: Path) -> None:
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
    assert_text_output(runtime, "1")
    assert console_text(runtime) == ["hello"]
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

    assert_text_output(result["cells"][0]["runtime"], "1")
    assert_text_output(result["cells"][1]["runtime"], "2")
    first_cell_id = initial["cells"][0]["id"]
    second_cell_id = initial["cells"][1]["id"]
    runtime_events = [event for event in events if event.get("event") == "runtime_update"]
    assert runtime_events
    assert any(
        event.get("request_id") == 42
        and isinstance(event.get("payload"), dict)
        and isinstance(cast(dict[str, dict[str, object]], cast(dict[str, object], event["payload"])["runtime_cells"]).get(first_cell_id, {}).get("output"), dict)
        and "1" in output_text(cast(dict[str, object], cast(dict[str, dict[str, object]], cast(dict[str, object], event["payload"])["runtime_cells"]).get(first_cell_id, {})["output"]))
        and cast(dict[str, dict[str, object]], cast(dict[str, object], event["payload"])["runtime_cells"]).get(second_cell_id, {}).get("status")
        in {"queued", "running"}
        for event in runtime_events
    )
    worker.shutdown({})


def test_sync_and_run_emits_session_update_for_new_cells(tmp_path: Path) -> None:
    events: list[dict[str, object]] = []
    worker = Worker(event_sink=events.append)
    path = tmp_path / "runtime_new_cell_stream.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\nx",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )

    updated = worker.sync_and_run(
        {
            "session_id": initial["session_id"],
            "content": "# + {marimo}\n\nx = 1\nx\n\n# +\n\nimport time\ntime.sleep(2.0)\ny = x + 1\ny",
            "_request_id": 99,
        }
    )

    assert len(updated["cells"]) == 2
    session_events = [event for event in events if event.get("event") == "session_update"]
    assert session_events
    assert any(
        event.get("request_id") == 99
        and isinstance(event.get("payload"), dict)
        and len(cast(list[dict[str, object]], cast(dict[str, object], event["payload"])["cells"])) == 2
        for event in session_events
    )
    worker.shutdown({})


def test_interrupt_is_not_queued_behind_run_request(tmp_path: Path) -> None:
    path = tmp_path / "runtime_interrupt.py"
    worker_cmd = [sys.executable, "-m", "marimo_nvim_py.worker"]
    process = subprocess.Popen(
        worker_cmd,
        cwd=str(Path(__file__).resolve().parents[2]),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    stdin = process.stdin
    stdout = process.stdout
    assert stdin is not None
    assert stdout is not None

    def send_request(request_id: int, method: str, params: dict[str, object]) -> None:
        stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
        stdin.flush()

    try:
        send_request(
            1,
            "open_session",
            {
                "path": str(path),
                "content": "# + {marimo}\n\nimport time\ntime.sleep(2)\n1",
                "input_kind": "projected",
                "project_root": str(tmp_path),
                "runtime_kind": "uv_project",
            },
        )
        open_response = json.loads(stdout.readline())
        assert open_response["id"] == 1
        open_result = cast(dict[str, object], open_response["result"])
        session_id = cast(str, open_result["session_id"])
        open_cells = cast(list[dict[str, object]], open_result["cells"])

        send_request(2, "run_cells", {"session_id": session_id, "cell_ids": [open_cells[0]["id"]]})
        time.sleep(0.2)
        interrupt_sent_at = time.monotonic()
        send_request(3, "interrupt", {"session_id": session_id})

        response_order: list[int] = []
        interrupt_elapsed: float | None = None
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and len(response_order) < 2:
            line = stdout.readline()
            if not line:
                break
            payload = json.loads(line)
            if payload.get("event") is not None:
                continue
            response_order.append(cast(int, payload["id"]))
            if payload["id"] == 3:
                interrupt_elapsed = time.monotonic() - interrupt_sent_at
        assert response_order[:2] == [3, 2]
        assert interrupt_elapsed is not None and interrupt_elapsed < 1.0
    finally:
        if process.stdin is not None:
            process.stdin.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


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
    assert_text_output(result["cells"][0]["runtime"], "'hello'")
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
    assert_text_output(first_runtime, "'hello'")
    assert console_text(first_runtime) == []
    assert console_text(second_runtime) == ["HEY"]
    worker.shutdown({})


def test_run_cells_attributes_stdout_after_html_output_to_the_emitting_cell(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "stdout_after_html.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": '# + {marimo}\n\nimport marimo as mo\nmo.md("# hello")\n\n# +\n\nprint("HEY")',
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [cell["id"] for cell in initial["cells"]]})
    first_runtime = result["cells"][0]["runtime"]
    second_runtime = result["cells"][1]["runtime"]
    output = cast(dict[str, object], first_runtime["output"])
    assert output["mimetype"] in {"text/plain", "text/html", "text/markdown", "application/vnd.marimo+mimebundle"}
    assert console_text(first_runtime) == []
    assert console_text(second_runtime) == ["HEY"]
    refreshed = worker.get_runtime_state({"session_id": initial["session_id"]})
    assert console_text(refreshed["runtime_cells"][initial["cells"][1]["id"]]) == ["HEY"]
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
    output = cast(dict[str, object], runtime["output"])
    assert output["mimetype"] == "application/vnd.marimo+error"
    errors = cast(list[dict[str, object]], output["data"])
    assert errors
    assert any("Traceback (most recent call last):" in line for line in console_text(runtime))
    worker.shutdown({})


def test_run_cells_preserves_multiple_definition_errors(tmp_path: Path) -> None:
    worker = Worker()
    path = tmp_path / "multiple_defs.py"
    initial = worker.open_session(
        {
            "path": str(path),
            "content": "# + {marimo}\n\nx = 1\n\n# +\n\nx = 2",
            "input_kind": "projected",
            "project_root": str(tmp_path),
            "runtime_kind": "uv_project",
        }
    )
    result = worker.run_cells({"session_id": initial["session_id"], "cell_ids": [cell["id"] for cell in initial["cells"]]})
    first_runtime = result["cells"][0]["runtime"]
    second_runtime = result["cells"][1]["runtime"]
    for runtime in {1: first_runtime, 2: second_runtime}.values():
        output = cast(dict[str, object], runtime["output"])
        assert output["mimetype"] == "application/vnd.marimo+error"
        errors = cast(list[dict[str, object]], output["data"])
        assert len(errors) == 1
        assert errors[0]["type"] == "multiple-defs"
        assert "defined by another cell" in str(errors[0]["msg"])
        assert console_text(runtime) == []
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
    assert_text_output(bootstrapped["cells"][1]["runtime"], "1")
    assert_text_output(bootstrapped["cells"][2]["runtime"], "1")
    assert_text_output(bootstrapped["cells"][3]["runtime"], "1")
    assert_text_output(bootstrapped["cells"][4]["runtime"], "104")

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

    assert_text_output(updated["cells"][1]["runtime"], "1")
    assert_text_output(updated["cells"][2]["runtime"], "1")
    assert_text_output(updated["cells"][3]["runtime"], "2")
    assert_text_output(updated["cells"][4]["runtime"], "206")
    worker.shutdown({})
