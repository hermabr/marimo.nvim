from __future__ import annotations

import json
from typing import Any


def normalize_scalar(value: str) -> Any:
    trimmed = value.strip()
    if trimmed in {"True", "true"}:
        return True
    if trimmed in {"False", "false"}:
        return False
    if trimmed in {"None", "null"}:
        return None
    if (trimmed.startswith("'") and trimmed.endswith("'")) or (
        trimmed.startswith('"') and trimmed.endswith('"')
    ):
        return trimmed[1:-1]
    try:
        return int(trimmed)
    except ValueError:
        pass
    try:
        return float(trimmed)
    except ValueError:
        pass
    return trimmed


def split_csv_like(text: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    quote: str | None = None
    prev = ""
    for char in text:
        if quote is not None:
            current.append(char)
            if char == quote and prev != "\\":
                quote = None
        elif char in {"'", '"'}:
            quote = char
            current.append(char)
        elif char == ",":
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
        prev = char
    if current:
        parts.append("".join(current))
    return parts


def parse_options_text(text: str | None) -> dict[str, Any]:
    if not text:
        return {}
    inner = text.strip()
    if inner.startswith("{") and inner.endswith("}"):
        inner = inner[1:-1]
    if not inner.strip():
        return {}
    opts: dict[str, Any] = {}
    for chunk in split_csv_like(inner):
        item = chunk.strip()
        if not item:
            continue
        if item == "marimo":
            opts["marimo"] = True
            continue
        if item == "marimo_disabled":
            opts["disabled"] = True
            continue
        if "=" not in item:
            raise ValueError(f"invalid option: {item}")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"invalid option: {item}")
        opts[key] = normalize_scalar(value)
    return opts


def render_scalar(value: Any) -> str:
    if value is None:
        return "None"
    if isinstance(value, bool):
        return "True" if value else "False"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(str(value))


def render_options(opts: dict[str, Any]) -> str:
    keys = sorted(opts.keys())
    parts: list[str] = []
    if opts.get("marimo"):
        parts.append("marimo")
    if opts.get("disabled"):
        parts.append("marimo_disabled")
    for key in keys:
        if key in {"marimo", "disabled"}:
            continue
        parts.append(f"{key}={render_scalar(opts[key])}")
    if not parts:
        return ""
    return " {" + ",".join(parts) + "}"


def parse_marker_line(line: str) -> tuple[bool, str | None]:
    if line == "# +":
        return True, None
    stripped = line.strip()
    if not stripped.startswith("# +"):
        return False, None
    opts = stripped[3:].strip()
    if opts.startswith("{") and opts.endswith("}"):
        return True, opts
    return False, None


def looks_like_marimo(lines: list[str]) -> bool:
    has_import = False
    has_app = False
    for line in lines:
        stripped = line.strip()
        if (
            stripped == "import marimo"
            or stripped.startswith("import marimo as ")
            or stripped.startswith("import marimo,")
        ):
            has_import = True
        if stripped.startswith("app") and ".App(" in stripped:
            has_app = True
    return has_import and has_app


def looks_like_projected(lines: list[str]) -> bool:
    if not lines:
        return False
    ok, marker = parse_marker_line(lines[0])
    return bool(ok and marker and "marimo" in marker)


def has_any_projected_markers(lines: list[str]) -> bool:
    return any(parse_marker_line(line)[0] or line == "# +" for line in lines)


def promote_first_marker_to_marimo(lines: list[str]) -> tuple[list[str], bool]:
    promoted = list(lines)
    first_marker_idx: int | None = None
    for idx, line in enumerate(promoted):
        if line == "# +" or parse_marker_line(line)[0]:
            first_marker_idx = idx
            break
    if first_marker_idx is None:
        return promoted, False
    if first_marker_idx > 0:
        promoted.insert(0, "")
        promoted.insert(0, "# + {marimo}")
        return promoted, True
    for idx, line in enumerate(promoted):
        if line == "# +":
            promoted[idx] = "# + {marimo}"
            return promoted, True
        ok, marker = parse_marker_line(line)
        if ok and marker is not None:
            opts = parse_options_text(marker)
            opts["marimo"] = True
            promoted[idx] = "# +" + render_options(opts)
            return promoted, True
    return promoted, False


def trim_blank_lines(body: list[str]) -> list[str]:
    trimmed = list(body)
    while trimmed and not trimmed[0].strip():
        trimmed.pop(0)
    while trimmed and not trimmed[-1].strip():
        trimmed.pop()
    return trimmed


def parse_projected_cells(lines: list[str]) -> list[dict[str, Any]]:
    cells: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None

    def flush() -> None:
        nonlocal current
        if current is None:
            return
        body = trim_blank_lines(current["body"])
        cells.append(
            {
                "name": "setup" if current["setup"] else "_",
                "options": dict(current["options"]),
                "code": "\n".join(body),
            }
        )
        current = None

    for line in lines:
        is_marker, marker = parse_marker_line(line)
        if is_marker or line == "# +":
            flush()
            opts = parse_options_text(marker)
            setup = opts.get("setup") is True
            opts.pop("setup", None)
            current = {"options": opts, "setup": setup, "body": []}
        elif current is not None:
            current["body"].append(line)
    flush()

    if not cells:
        raise ValueError("projected marimo buffer has no `# +` cells")
    for idx, cell in enumerate(cells):
        if cell["name"] == "setup" and idx != 0:
            raise ValueError("setup cell must be the first cell")
    if cells[0]["options"].get("marimo") is not True:
        raise ValueError("first cell must be marked with `{marimo}`")
    cells[0]["options"].pop("marimo", None)
    return cells


def dedupe_empty_cells(cells: list[dict[str, Any]]) -> list[dict[str, Any]]:
    deduped: list[dict[str, Any]] = []
    previous_empty = False
    for cell in cells:
        is_empty = cell["code"] == ""
        if not (is_empty and previous_empty):
            deduped.append(cell)
        previous_empty = is_empty
    return deduped


def drop_empty_cells(cells: list[dict[str, Any]]) -> list[dict[str, Any]]:
    kept = [cell for cell in cells if cell["code"].strip() != ""]
    if kept:
        return kept
    if not cells:
        return []
    first = dict(cells[0])
    first["code"] = ""
    return [first]


def render_projected_lines(cells: list[dict[str, Any]]) -> tuple[list[str], list[dict[str, int]]]:
    lines: list[str] = []
    spans: list[dict[str, int]] = []
    for idx, cell in enumerate(cells):
        start_line = len(lines) + 1
        opts = dict(cell.get("options") or {})
        if idx == 0:
            opts["marimo"] = True
        if cell["name"] == "setup":
            opts["setup"] = True
        lines.append("# +" + render_options(opts))
        lines.append("")
        if cell["code"]:
            code_lines = trim_blank_lines(cell["code"].split("\n"))
            lines.extend(code_lines)
        lines.append("")
        end_line = len(lines)
        spans.append(
            {
                "start_line": start_line,
                "start_col": 1,
                "end_line": end_line,
                "end_col": 1,
            }
        )
    while lines and lines[-1] == "":
        lines.pop()
    if spans:
        spans[-1]["end_line"] = len(lines)
    return lines, spans
