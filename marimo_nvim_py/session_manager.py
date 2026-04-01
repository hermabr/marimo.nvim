from __future__ import annotations

from typing import Any

from marimo_nvim_py.models import NotebookSnapshot
from marimo_nvim_py.session import MarimoRuntimeSession


class SessionManager:
    def __init__(self, *, event_sink: Any = None) -> None:
        self._sessions: dict[str, MarimoRuntimeSession] = {}
        self._event_sink = event_sink

    def ensure_session(
        self,
        *,
        session_id: str,
        path: str,
        project_root: str,
        plugin_root: str,
        snapshot: NotebookSnapshot,
    ) -> MarimoRuntimeSession:
        existing = self._sessions.get(session_id)
        if existing is not None:
            existing.replace_snapshot(snapshot)
            return existing
        runtime = MarimoRuntimeSession(
            session_id=session_id,
            path=path,
            project_root=project_root,
            plugin_root=plugin_root,
            snapshot=snapshot,
            event_sink=self._event_sink,
        )
        self._sessions[session_id] = runtime
        return runtime

    def get(self, session_id: str) -> MarimoRuntimeSession:
        return self._sessions[session_id]

    def close_session(self, session_id: str) -> None:
        session = self._sessions.pop(session_id, None)
        if session is not None:
            session.close()

    def shutdown(self) -> None:
        for session_id in list(self._sessions):
            self.close_session(session_id)
