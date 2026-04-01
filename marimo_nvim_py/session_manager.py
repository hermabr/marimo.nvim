from __future__ import annotations

from typing import Any, Callable

from marimo_nvim_py.codec import load_raw_notebook, serialize_notebook
from marimo_nvim_py.models import NotebookSnapshot
from marimo_nvim_py.session import BridgeSession


class Worker:
    def __init__(self, event_sink: Callable[[dict[str, Any]], None] | None = None) -> None:
        self.sessions: dict[str, BridgeSession] = {}
        self.event_sink = event_sink

    def load_raw_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        snapshot = load_raw_notebook(
            path=str(params["path"]),
            content=str(params["content"]),
            project_root=str(params.get("project_root") or ""),
            runtime_kind=str(params.get("runtime_kind") or "uv"),
        )
        return snapshot.to_dict()

    def serialize_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        snapshot = NotebookSnapshot.from_dict(dict(params["snapshot"]))
        return serialize_notebook(snapshot)

    def ensure_session(self, params: dict[str, Any]) -> dict[str, Any]:
        snapshot = NotebookSnapshot.from_dict(dict(params["snapshot"]))
        session = self.sessions.get(snapshot.session_id)
        if session is None:
            session = BridgeSession(snapshot=snapshot, event_sink=self.event_sink)
            self.sessions[snapshot.session_id] = session
        else:
            session.update_snapshot(snapshot)
        session.ensure_started()
        return {"session_id": snapshot.session_id, "started": True}

    def sync_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        snapshot = NotebookSnapshot.from_dict(dict(params["snapshot"]))
        session = self.sessions.get(snapshot.session_id)
        if session is None:
            session = BridgeSession(snapshot=snapshot, event_sink=self.event_sink)
            self.sessions[snapshot.session_id] = session
        else:
            session.update_snapshot(snapshot)
        session.sync_notebook(
            run_ids=[str(cell_id) for cell_id in list(params.get("run_ids") or [])],
            delete_ids=[str(cell_id) for cell_id in list(params.get("delete_ids") or [])],
            request_id=params.get("_request_id"),
        )
        return {"session_id": snapshot.session_id, "synced": True}

    def run_cells(self, params: dict[str, Any]) -> dict[str, Any]:
        session_id = str(params["session_id"])
        session = self.sessions[session_id]
        session.run_cells(
            cell_ids=[str(cell_id) for cell_id in list(params.get("cell_ids") or [])],
            codes=[str(code) for code in list(params.get("codes") or [])],
            request_id=params.get("_request_id"),
        )
        return {"session_id": session_id, "submitted": True}

    def set_ui_element_value(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[str(params["session_id"])]
        session.set_ui_element_value(
            object_ids=[str(object_id) for object_id in list(params.get("object_ids") or [])],
            values=list(params.get("values") or []),
            request_id=params.get("_request_id"),
        )
        return {"session_id": session.snapshot.session_id, "submitted": True}

    def set_model_value(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[str(params["session_id"])]
        session.set_model_value(
            model_id=str(params["model_id"]),
            message=dict(params.get("message") or {}),
            buffers=list(params.get("buffers") or []),
            request_id=params.get("_request_id"),
        )
        return {"session_id": session.snapshot.session_id, "submitted": True}

    def invoke_function(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[str(params["session_id"])]
        return session.invoke_function(
            namespace=str(params["namespace"]),
            function_name=str(params["function_name"]),
            args=dict(params.get("args") or {}),
            request_id=params.get("_request_id"),
        )

    def send_stdin(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[str(params["session_id"])]
        session.send_stdin(str(params["text"]))
        return {"session_id": session.snapshot.session_id, "sent": True}

    def interrupt(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions[str(params["session_id"])]
        session.interrupt(params.get("_request_id"))
        return {"session_id": session.snapshot.session_id, "interrupted": True}

    def interrupt_now(self, params: dict[str, Any]) -> dict[str, Any]:
        return self.interrupt(params)

    def close_session(self, params: dict[str, Any]) -> dict[str, Any]:
        session = self.sessions.pop(str(params["session_id"]), None)
        if session is not None:
            session.close()
        return {"closed": True}

    def shutdown(self, params: dict[str, Any]) -> dict[str, Any]:
        del params
        for session in list(self.sessions.values()):
            session.close()
        self.sessions.clear()
        return {"shutdown": True}
