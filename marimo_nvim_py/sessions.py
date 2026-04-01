from __future__ import annotations

from typing import Any, Callable

from marimo_nvim_py.codec import load_raw_notebook, serialize_notebook
from marimo_nvim_py.session_manager import SessionManager


class Worker:
    def __init__(self, event_sink: Callable[[dict[str, Any]], None] | None = None) -> None:
        self.session_manager = SessionManager(event_sink=event_sink)

    def load_raw_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        return load_raw_notebook(
            path=params["path"],
            content=params["content"],
            project_root=params.get("project_root"),
        )

    def serialize_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        return serialize_notebook(params["snapshot"])

    def ensure_session(self, params: dict[str, Any]) -> dict[str, Any]:
        runtime = self.session_manager.ensure_session(
            session_id=params["session_id"],
            path=params["path"],
            project_root=params["project_root"],
            plugin_root=params["plugin_root"],
            snapshot=params["snapshot"],
        )
        return {
            "session_id": runtime.state.session_id,
            "path": runtime.state.path,
            "project_root": runtime.state.project_root,
        }

    def sync_notebook(self, params: dict[str, Any]) -> dict[str, Any]:
        runtime = self.session_manager.ensure_session(
            session_id=params["session_id"],
            path=params["path"],
            project_root=params["project_root"],
            plugin_root=params["plugin_root"],
            snapshot=params["snapshot"],
        )
        result = runtime.sync_notebook(
            run_ids=list(params.get("run_ids") or []),
            delete_ids=list(params.get("delete_ids") or []),
            request_id=params.get("_request_id"),
        )
        return {"session_id": runtime.state.session_id, **result}

    def run_cells(self, params: dict[str, Any]) -> dict[str, Any]:
        runtime = self.session_manager.get(params["session_id"])
        result = runtime.run_cells(
            cell_ids=list(params.get("cell_ids") or []),
            codes=list(params.get("codes") or []),
            request_id=params.get("_request_id"),
        )
        return {"session_id": runtime.state.session_id, **result}

    def set_ui_element_value(self, params: dict[str, Any]) -> dict[str, Any]:
        runtime = self.session_manager.get(params["session_id"])
        result = runtime.set_ui_element_value(
            object_ids=list(params.get("object_ids") or []),
            values=list(params.get("values") or []),
            request_id=params.get("_request_id"),
        )
        return {"session_id": runtime.state.session_id, **result}

    def set_model_value(self, params: dict[str, Any]) -> dict[str, Any]:
        runtime = self.session_manager.get(params["session_id"])
        result = runtime.set_model_value(
            model_id=params["model_id"],
            message=params["message"],
            buffers=list(params.get("buffers") or []),
            request_id=params.get("_request_id"),
        )
        return {"session_id": runtime.state.session_id, **result}

    def invoke_function(self, params: dict[str, Any]) -> dict[str, Any]:
        runtime = self.session_manager.get(params["session_id"])
        result = runtime.invoke_function(
            namespace=params["namespace"],
            function_name=params["function_name"],
            args=dict(params.get("args") or {}),
            request_id=params.get("_request_id"),
        )
        return {"session_id": runtime.state.session_id, "result": result}

    def send_stdin(self, params: dict[str, Any]) -> dict[str, Any]:
        runtime = self.session_manager.get(params["session_id"])
        runtime.send_stdin(params["text"])
        return {"session_id": runtime.state.session_id}

    def interrupt(self, params: dict[str, Any]) -> dict[str, Any]:
        runtime = self.session_manager.get(params["session_id"])
        runtime.interrupt()
        return {"session_id": runtime.state.session_id}

    def interrupt_now(self, params: dict[str, Any]) -> dict[str, Any]:
        return self.interrupt(params)

    def close_session(self, params: dict[str, Any]) -> dict[str, Any]:
        self.session_manager.close_session(params["session_id"])
        return {"closed": True}

    def shutdown(self, params: dict[str, Any]) -> dict[str, Any]:
        del params
        self.session_manager.shutdown()
        return {"shutdown": True}
