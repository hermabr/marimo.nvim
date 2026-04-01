from __future__ import annotations

from typing import Any, Callable, cast

from marimo._ast.compiler import compile_cell
from marimo._runtime.dataflow.graph import DirectedGraph
from marimo._types.ids import CellId_t

from marimo_nvim_py.codec import load_raw_notebook, serialize_notebook
from marimo_nvim_py.models import NotebookSnapshot
from marimo_nvim_py.session import BridgeSession


class Worker:
    def __init__(self, event_sink: Callable[[dict[str, Any]], None] | None = None) -> None:
        self.sessions: dict[str, BridgeSession] = {}
        self.event_sink = event_sink
        self.pending_cancellations: dict[str, set[int]] = {}

    def _session_for_snapshot(self, snapshot: NotebookSnapshot) -> BridgeSession:
        session = self.sessions.get(snapshot.session_id)
        if session is None:
            session = BridgeSession(snapshot=snapshot, event_sink=self.event_sink)
            self.sessions[snapshot.session_id] = session
        else:
            session.update_snapshot(snapshot)
        for request_id in self.pending_cancellations.pop(snapshot.session_id, set()):
            session.cancel_request(request_id)
        return session

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

    def resolve_changed_dependents(self, params: dict[str, Any]) -> dict[str, Any]:
        snapshot = NotebookSnapshot.from_dict(dict(params["snapshot"]))
        changed_ids = {str(cell_id) for cell_id in list(params.get("cell_ids") or [])}
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
            return {"cell_ids": []}

        dependent_ids: set[str] = set()
        for cell_id in changed_ids:
            if cast(CellId_t, cell_id) not in graph.cells:
                continue
            dependent_ids.update(
                str(descendant_id)
                for descendant_id in graph.descendants(cast(CellId_t, cell_id))
            )

        ordered_ids = [cell.id for cell in snapshot.cells if cell.id in dependent_ids]
        return {"cell_ids": ordered_ids}

    def ensure_session(self, params: dict[str, Any]) -> dict[str, Any]:
        snapshot = NotebookSnapshot.from_dict(dict(params["snapshot"]))
        session = self._session_for_snapshot(snapshot)
        session.ensure_started()
        return {"session_id": snapshot.session_id, "started": True}

    def sync_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        snapshot = NotebookSnapshot.from_dict(dict(params["snapshot"]))
        session = self._session_for_snapshot(snapshot)
        session.sync_notebook(
            run_ids=[str(cell_id) for cell_id in list(params.get("run_ids") or [])],
            delete_ids=[str(cell_id) for cell_id in list(params.get("delete_ids") or [])],
            request_id=params.get("_request_id"),
        )
        return {"session_id": snapshot.session_id, "synced": True}

    def run_cells(self, params: dict[str, Any]) -> dict[str, Any]:
        snapshot_dict = params.get("snapshot")
        session: BridgeSession
        session_id: str
        if snapshot_dict is not None:
            snapshot = NotebookSnapshot.from_dict(dict(snapshot_dict))
            session = self._session_for_snapshot(snapshot)
            session_id = snapshot.session_id
        else:
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
        session_id = str(params["session_id"])
        cancel_request_id = params.get("cancel_request_id")
        session = self.sessions.get(session_id)
        if session is None:
            if cancel_request_id is not None:
                self.pending_cancellations.setdefault(session_id, set()).add(int(cancel_request_id))
            return {"session_id": session_id, "interrupted": True}
        session.cancel_request(cancel_request_id)
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
