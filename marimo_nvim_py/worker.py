from __future__ import annotations

import json
import queue
import sys
import threading
from typing import Any

from marimo_nvim_py.session_manager import Worker


def _error(code: str, message: str) -> dict[str, Any]:
    return {"code": code, "message": message}


def main() -> int:
    event_stdout = sys.__stdout__ or sys.stdout
    write_lock = threading.Lock()

    def emit_event(payload: dict[str, Any]) -> None:
        with write_lock:
            event_stdout.write(json.dumps(payload) + "\n")
            event_stdout.flush()

    def emit_response(payload: dict[str, Any]) -> None:
        with write_lock:
            sys.stdout.write(json.dumps(payload) + "\n")
            sys.stdout.flush()

    worker = Worker(event_sink=emit_event)
    methods = {
        "load_raw_notebook": worker.load_raw_notebook,
        "serialize_notebook": worker.serialize_notebook,
        "resolve_changed_dependents": worker.resolve_changed_dependents,
        "ensure_session": worker.ensure_session,
        "sync_notebook": worker.sync_notebook,
        "run_cells": worker.run_cells,
        "set_ui_element_value": worker.set_ui_element_value,
        "set_model_value": worker.set_model_value,
        "invoke_function": worker.invoke_function,
        "send_stdin": worker.send_stdin,
        "interrupt": worker.interrupt,
        "close_session": worker.close_session,
        "shutdown": worker.shutdown,
    }

    request_queue: queue.Queue[dict[str, Any] | None] = queue.Queue()

    def handle_payload(payload: dict[str, Any], *, allow_immediate_interrupt: bool = False) -> None:
        request_id = payload.get("id")
        try:
            method = payload["method"]
            params = payload.get("params", {})
            params["_request_id"] = request_id
            if allow_immediate_interrupt and method == "interrupt":
                handler = worker.interrupt_now
            else:
                handler = methods.get(method)
            if handler is None:
                raise KeyError(f"unknown method: {method}")
            result = handler(params)
            response = {"id": request_id, "ok": True, "result": result}
        except Exception as exc:  # noqa: BLE001
            response = {"id": request_id, "ok": False, "error": _error("protocol_error", str(exc))}
        emit_response(response)

    def request_loop() -> None:
        while True:
            payload = request_queue.get()
            if payload is None:
                return
            handle_payload(payload)

    request_thread = threading.Thread(target=request_loop, daemon=True)
    request_thread.start()

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            payload = json.loads(raw)
        except Exception as exc:  # noqa: BLE001
            emit_response({"id": None, "ok": False, "error": _error("protocol_error", str(exc))})
            continue
        if payload.get("method") == "interrupt":
            handle_payload(payload, allow_immediate_interrupt=True)
            continue
        request_queue.put(payload)
    request_queue.put(None)
    request_thread.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
