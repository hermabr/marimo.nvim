from __future__ import annotations

from typing import Any, Callable

from marimo_nvim_py.session import RuntimeSession


class SessionManager:
    def __init__(self, event_sink: Callable[[dict[str, Any]], None] | None = None) -> None:
        self._sessions: dict[str, RuntimeSession] = {}
        self._event_sink = event_sink

    def get(self, session_id: str) -> RuntimeSession:
        return self._sessions[session_id]

    def ensure(
        self,
        *,
        session_id: str,
        path: str,
        project_root: str,
        runtime_kind: str,
        snapshot: dict[str, Any],
    ) -> RuntimeSession:
        session = self._sessions.get(session_id)
        if session is None:
            session = RuntimeSession(
                session_id=session_id,
                path=path,
                project_root=project_root,
                runtime_kind=runtime_kind,
                snapshot=snapshot,
                event_sink=self._event_sink,
            )
            self._sessions[session_id] = session
        else:
            session.set_snapshot(snapshot)
        return session

    def close(self, session_id: str) -> None:
        session = self._sessions.pop(session_id, None)
        if session is not None:
            session.close()

    def shutdown(self) -> None:
        for session in list(self._sessions.values()):
            session.close()
        self._sessions.clear()
