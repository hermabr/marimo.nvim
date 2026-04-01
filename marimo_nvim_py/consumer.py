from __future__ import annotations

import base64
import queue
import threading
from typing import Any, Callable

from marimo._messaging.msgspec_encoder import asdict
from marimo._messaging.notification import (
    CompletedRunNotification,
    FunctionCallResultNotification,
)
from marimo._messaging.serde import deserialize_kernel_message
from marimo._session.state.session_view import SessionView


def _jsonable(value: Any) -> Any:
    if isinstance(value, bytes):
        return {
            "encoding": "base64",
            "data": base64.b64encode(value).decode("ascii"),
        }
    if isinstance(value, list):
        return [_jsonable(item) for item in value]
    if isinstance(value, tuple):
        return [_jsonable(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    return value


class OperationConsumer:
    def __init__(
        self,
        *,
        session_id: str,
        stream_queue: Any,
        event_sink: Callable[[dict[str, Any]], None] | None,
        current_request_id: Callable[[], int | None],
    ) -> None:
        self._session_id = session_id
        self._stream_queue = stream_queue
        self._event_sink = event_sink
        self._current_request_id = current_request_id
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._completed_runs = 0
        self._function_results: dict[str, FunctionCallResultNotification] = {}
        self._view = SessionView()
        self._condition = threading.Condition()

    @property
    def completed_runs(self) -> int:
        with self._condition:
            return self._completed_runs

    @property
    def session_view(self) -> SessionView:
        return self._view

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._consume, daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)

    def wait_for_completed_runs(self, minimum_completed_runs: int, timeout: float) -> bool:
        with self._condition:
            return self._condition.wait_for(
                lambda: self._completed_runs >= minimum_completed_runs,
                timeout=timeout,
            )

    def pop_function_result(
        self, function_call_id: str
    ) -> FunctionCallResultNotification | None:
        with self._condition:
            return self._function_results.pop(function_call_id, None)

    def clear_function_result(self, function_call_id: str) -> None:
        with self._condition:
            self._function_results.pop(function_call_id, None)

    def _emit_operation(self, operation: dict[str, Any]) -> None:
        if self._event_sink is None:
            return
        self._event_sink(
            {
                "event": "operation",
                "request_id": self._current_request_id(),
                "session_id": self._session_id,
                "operation": operation,
            }
        )

    def _consume(self) -> None:
        while not self._stop.is_set():
            try:
                raw = self._stream_queue.get(timeout=0.1)
            except queue.Empty:
                continue
            except Exception:  # noqa: BLE001
                if self._stop.is_set():
                    return
                continue
            if raw is None:
                return
            notification = deserialize_kernel_message(raw)
            self._view.add_raw_notification(raw)
            self._emit_operation(_jsonable(asdict(notification)))
            with self._condition:
                if isinstance(notification, CompletedRunNotification):
                    self._completed_runs += 1
                elif isinstance(notification, FunctionCallResultNotification):
                    self._function_results[str(notification.function_call_id)] = (
                        notification
                    )
                self._condition.notify_all()
