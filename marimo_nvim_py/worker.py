from __future__ import annotations

import json
import sys
from typing import Any

from marimo_nvim_py.sessions import Worker


def _error(code: str, message: str) -> dict[str, Any]:
    return {"code": code, "message": message}


def main() -> int:
    worker = Worker()
    methods = {
        "open_session": worker.open_session,
        "sync_projection": worker.sync_projection,
        "write_session": worker.write_session,
        "reload_from_disk": worker.reload_from_disk,
        "close_session": worker.close_session,
        "get_session_state": worker.get_session_state,
        "get_canonical_source": worker.get_canonical_source,
        "get_projection_map": worker.get_projection_map,
        "shutdown": worker.shutdown,
    }
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        request_id = None
        try:
            payload = json.loads(raw)
            request_id = payload.get("id")
            method = payload["method"]
            params = payload.get("params", {})
            handler = methods.get(method)
            if handler is None:
                raise KeyError(f"unknown method: {method}")
            result = handler(params)
            response = {"id": request_id, "ok": True, "result": result}
        except Exception as exc:  # noqa: BLE001
            response = {"id": request_id, "ok": False, "error": _error("protocol_error", str(exc))}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
