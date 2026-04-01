from __future__ import annotations

from typing import Any, Callable

from marimo_nvim_py.codec import load_raw_notebook, serialize_notebook
from marimo_nvim_py.session_manager import SessionManager


class BridgeWorker:
    def __init__(self, event_sink: Callable[[dict[str, Any]], None] | None = None) -> None:
        self._sessions = SessionManager(event_sink=event_sink)

    def load_raw_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        return load_raw_notebook(params["path"], params["content"])

    def serialize_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        return serialize_notebook(params["path"], params["snapshot"])

    def ensure_session(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._sessions.ensure(
            session_id=params["session_id"],
            path=params["path"],
            project_root=params["project_root"],
            runtime_kind=params.get("runtime_kind") or "uv",
            snapshot=params["snapshot"],
        )
        session.ensure_started(request_id=params.get("_request_id"))
        return {
            "session_id": session.session_id,
            "runtime_cells": session.runtime_cells(),
        }

    def sync_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._sessions.ensure(
            session_id=params["session_id"],
            path=params["path"],
            project_root=params["project_root"],
            runtime_kind=params.get("runtime_kind") or "uv",
            snapshot=params["snapshot"],
        )
        session.sync_notebook(
            params["snapshot"],
            run_ids=list(params.get("run_ids") or []),
            delete_ids=list(params.get("delete_ids") or []),
            request_id=params.get("_request_id"),
        )
        return {
            "session_id": session.session_id,
            "runtime_cells": session.runtime_cells(),
        }

    def run_cells(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._sessions.get(params["session_id"])
        session.run_cells(
            cell_ids=list(params.get("cell_ids") or []),
            codes=list(params.get("codes") or []),
            request_id=params.get("_request_id"),
        )
        return {
            "session_id": session.session_id,
            "runtime_cells": session.runtime_cells(),
        }

    def set_ui_element_value(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._sessions.get(params["session_id"])
        session.set_ui_element_value(
            object_ids=list(params.get("object_ids") or []),
            values=list(params.get("values") or []),
            request_id=params.get("_request_id"),
        )
        return {
            "session_id": session.session_id,
            "runtime_cells": session.runtime_cells(),
        }

    def set_model_value(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._sessions.get(params["session_id"])
        session.set_model_value(
            model_id=params["model_id"],
            message=dict(params.get("message") or {}),
            buffers=list(params.get("buffers") or []),
            request_id=params.get("_request_id"),
        )
        return {
            "session_id": session.session_id,
            "runtime_cells": session.runtime_cells(),
        }

    def invoke_function(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._sessions.get(params["session_id"])
        return {
            "value": session.invoke_function(
                namespace=params["namespace"],
                function_name=params["function_name"],
                args=dict(params.get("args") or {}),
                request_id=params.get("_request_id"),
            )
        }

    def send_stdin(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._sessions.get(params["session_id"])
        session.send_stdin(str(params.get("text") or ""))
        return {"session_id": session.session_id}

    def interrupt(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self._sessions.get(params["session_id"])
        session.interrupt()
        return {
            "session_id": session.session_id,
            "runtime_cells": session.runtime_cells(),
        }

    def interrupt_now(self, params: dict[str, Any]) -> dict[str, Any]:
        return self.interrupt(params)

    def close_session(self, params: dict[str, Any]) -> dict[str, Any]:
        self._sessions.close(params["session_id"])
        return {"closed": True}

    def shutdown(self, params: dict[str, Any]) -> dict[str, Any]:
        del params
        self._sessions.shutdown()
        return {"shutdown": True}
