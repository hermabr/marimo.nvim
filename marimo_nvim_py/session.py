from __future__ import annotations

import queue
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, cast

from marimo._ast.app import App, InternalApp
from marimo._ast.cell import CellConfig
from marimo._messaging.msgspec_encoder import asdict
from marimo._messaging.notification import CompletedRunNotification, FunctionCallResultNotification
from marimo._messaging.serde import deserialize_kernel_message
from marimo._runtime.commands import (
    CreateNotebookCommand,
    ExecuteCellCommand,
    ExecuteCellsCommand,
    InvokeFunctionCommand,
    ModelCommand,
    ModelCustomMessage,
    ModelUpdateMessage,
    SyncGraphCommand,
    UpdateUIElementCommand,
)
from marimo._session.notebook.file_manager import AppFileManager
from marimo._session.state.session_view import SessionView
from marimo._types.ids import CellId_t, RequestId, UIElementId, WidgetModelId

from marimo_nvim_py.kernel import KernelBridge
from marimo_nvim_py.models import NotebookSnapshot, SnapshotCell


EventSink = Callable[[dict[str, Any]], None]


def _route_control_request(kernel: KernelBridge, command: Any) -> None:
    from marimo._runtime import commands

    if isinstance(command, commands.CodeCompletionCommand):
        kernel.queue_manager.completion_queue.put(command)
        return
    kernel.queue_manager.control_queue.put(command)
    if isinstance(command, (commands.UpdateUIElementCommand, commands.ModelCommand)):
        kernel.queue_manager.set_ui_element_queue.put(command)


def _cell_config(cell: SnapshotCell) -> CellConfig:
    return CellConfig.from_dict(cell.options, warn=False)


def _model_message_from_dict(message: dict[str, Any]) -> ModelUpdateMessage | ModelCustomMessage:
    method = str(message.get("method") or "")
    if method == "update":
        return ModelUpdateMessage(
            state=dict(message.get("state") or {}),
            buffer_paths=list(message.get("buffer_paths") or []),
        )
    if method == "custom":
        return ModelCustomMessage(content=message.get("content"))
    raise ValueError(f"unsupported model message method: {method}")


def _buffer_bytes(buffers: list[Any]) -> list[bytes]:
    out: list[bytes] = []
    for buffer in buffers:
        if isinstance(buffer, bytes):
            out.append(buffer)
        elif isinstance(buffer, str):
            out.append(buffer.encode("utf-8"))
        else:
            raise ValueError("model buffers must be bytes or strings")
    return out


@dataclass
class BridgeSession:
    snapshot: NotebookSnapshot
    event_sink: EventSink | None = None
    kernel_idle_timeout_seconds: float | None = None
    file_manager: AppFileManager | None = None
    kernel: KernelBridge | None = None
    session_view: SessionView = field(default_factory=SessionView)
    completed_runs: int = 0
    function_results: dict[str, FunctionCallResultNotification] = field(default_factory=dict)
    lock: threading.RLock = field(default_factory=threading.RLock)
    command_lock: threading.RLock = field(default_factory=threading.RLock)
    stop_event: threading.Event = field(default_factory=threading.Event)
    idle_stop_event: threading.Event = field(default_factory=threading.Event)
    stream_thread: threading.Thread | None = None
    idle_thread: threading.Thread | None = None
    active_request_id: int | None = None
    cancelled_request_ids: set[int] = field(default_factory=set)
    last_activity_monotonic: float = field(default_factory=time.monotonic)
    started_once: bool = False
    closed: bool = False

    def update_snapshot(self, snapshot: NotebookSnapshot) -> None:
        self.snapshot = snapshot

    def _build_file_manager(self) -> AppFileManager:
        app = App(**(self.snapshot.app_options or {}), _filename=self.snapshot.path)
        internal_app = InternalApp(app)
        if self.snapshot.header:
            internal_app._app._header = self.snapshot.header
        internal_app.with_data(
            cell_ids=[cast(CellId_t, cell.id) for cell in self.snapshot.cells],
            codes=[cell.code for cell in self.snapshot.cells],
            names=[cell.name for cell in self.snapshot.cells],
            configs=[_cell_config(cell) for cell in self.snapshot.cells],
        )
        file_manager = AppFileManager.from_app(internal_app)
        file_manager.filename = self.snapshot.path
        return file_manager

    def _kernel_is_running(self) -> bool:
        return (
            self.kernel is not None
            and self.kernel.process is not None
            and self.kernel.process.poll() is None
        )

    def _touch_activity(self) -> None:
        with self.lock:
            self.last_activity_monotonic = time.monotonic()

    def _has_pending_work_locked(self) -> bool:
        return any(
            notification.status in {"running", "queued"}
            for notification in self.session_view.cell_notifications.values()
        )

    def _emit_kernel_restarted(self, request_id: int | None) -> None:
        if self.event_sink is None:
            return
        self.event_sink(
            {
                "event": "operation",
                "request_id": request_id,
                "session_id": self.snapshot.session_id,
                "operation": {"op": "kernel-restarted"},
            }
        )

    def _start_idle_monitor(self) -> None:
        if self.kernel_idle_timeout_seconds is None:
            return
        if self.kernel_idle_timeout_seconds <= 0:
            return
        if self.idle_thread is not None and self.idle_thread.is_alive():
            return
        self.idle_stop_event.clear()
        self.idle_thread = threading.Thread(target=self._idle_loop, daemon=True)
        self.idle_thread.start()

    def ensure_started(self, request_id: int | None = None) -> None:
        with self.command_lock:
            if self._kernel_is_running():
                self._touch_activity()
                return
            restarted = self.started_once
            self._stop_kernel()
            self.closed = False
            self.file_manager = self._build_file_manager()
            self.kernel = KernelBridge(self.snapshot, self.file_manager.app)
            self.kernel.launch()
            self.stop_event.clear()
            self.stream_thread = threading.Thread(target=self._stream_loop, daemon=True)
            self.stream_thread.start()
            self.started_once = True
            self._touch_activity()
            self._instantiate()
            self._start_idle_monitor()
            if restarted:
                self._emit_kernel_restarted(request_id)

    def _instantiate(self) -> None:
        assert self.file_manager is not None
        execution_requests = tuple(
            ExecuteCellCommand(cell_id=cast(CellId_t, cell.id), code=cell.code)
            for cell in self.snapshot.cells
        )
        command = CreateNotebookCommand(
            execution_requests=execution_requests,
            cell_ids=tuple(cast(CellId_t, cell.id) for cell in self.snapshot.cells),
            set_ui_element_value_request=UpdateUIElementCommand(object_ids=[], values=[]),
            auto_run=False,
        )
        self._send_command(command)
        self._drain_notifications(timeout=0.2)

    def _stream_loop(self) -> None:
        kernel = self.kernel
        assert kernel is not None
        while not self.stop_event.is_set():
            try:
                raw = kernel.queue_manager.stream_queue.get(timeout=0.1)
            except queue.Empty:
                continue
            except Exception:
                continue
            if raw is None:
                continue
            decoded = deserialize_kernel_message(raw)
            with self.lock:
                self.session_view.add_raw_notification(raw)
                if isinstance(decoded, CompletedRunNotification):
                    self.completed_runs += 1
                elif isinstance(decoded, FunctionCallResultNotification):
                    self.function_results[str(decoded.function_call_id)] = decoded
                self.last_activity_monotonic = time.monotonic()
                request_id = self.active_request_id
            if self.event_sink is not None:
                self.event_sink(
                    {
                        "event": "operation",
                        "request_id": request_id,
                        "session_id": self.snapshot.session_id,
                        "operation": asdict(decoded),
                    }
                )

    def _send_command(self, command: Any) -> None:
        assert self.kernel is not None
        self._touch_activity()
        self.session_view.add_control_request(command)
        _route_control_request(self.kernel, command)

    def _idle_loop(self) -> None:
        assert self.kernel_idle_timeout_seconds is not None
        while not self.idle_stop_event.is_set():
            now = time.monotonic()
            with self.lock:
                idle_for = now - self.last_activity_monotonic
                has_pending_work = self._has_pending_work_locked()
            if has_pending_work:
                wait_seconds = min(max(self.kernel_idle_timeout_seconds, 0.05), 5.0)
            else:
                remaining = self.kernel_idle_timeout_seconds - idle_for
                if remaining <= 0:
                    with self.command_lock:
                        now = time.monotonic()
                        with self.lock:
                            idle_for = now - self.last_activity_monotonic
                            has_pending_work = self._has_pending_work_locked()
                        if (
                            not self.closed
                            and self._kernel_is_running()
                            and not has_pending_work
                            and idle_for >= self.kernel_idle_timeout_seconds
                        ):
                            self._stop_kernel()
                            return
                    wait_seconds = 0.05
                else:
                    wait_seconds = min(max(remaining, 0.05), 5.0)
            self.idle_stop_event.wait(wait_seconds)

    def cancel_request(self, request_id: int | None) -> None:
        if request_id is None:
            return
        with self.lock:
            self.cancelled_request_ids.add(request_id)

    def _consume_cancelled_request(self, request_id: int | None) -> bool:
        if request_id is None:
            return False
        with self.lock:
            if request_id not in self.cancelled_request_ids:
                return False
            self.cancelled_request_ids.discard(request_id)
            return True

    def _drain_notifications(self, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            time.sleep(0.01)

    def _wait_for_completion(self, previous_completed_runs: int, timeout: float = 15.0) -> None:
        deadline = time.monotonic() + timeout
        settled_since: float | None = None
        while time.monotonic() < deadline:
            with self.lock:
                completed_runs = self.completed_runs
                notifications = list(self.session_view.cell_notifications.values())
            if completed_runs > previous_completed_runs:
                all_settled = True
                for notification in notifications:
                    if notification.status in {"running", "queued"}:
                        all_settled = False
                        break
                if all_settled:
                    if settled_since is None:
                        settled_since = time.monotonic()
                    elif time.monotonic() - settled_since >= 0.05:
                        return
                else:
                    settled_since = None
            time.sleep(0.01)
        raise TimeoutError("timed out waiting for marimo runtime to finish")

    def sync_notebook(self, *, run_ids: list[str], delete_ids: list[str], request_id: int | None) -> None:
        with self.command_lock:
            self.ensure_started(request_id)
            if self._consume_cancelled_request(request_id):
                return
            assert self.file_manager is not None
            assert self.file_manager.app is not None
            self.file_manager.app.with_data(
                cell_ids=[cast(CellId_t, cell.id) for cell in self.snapshot.cells],
                codes=[cell.code for cell in self.snapshot.cells],
                names=[cell.name for cell in self.snapshot.cells],
                configs=[_cell_config(cell) for cell in self.snapshot.cells],
            )
            command = SyncGraphCommand(
                cells={cast(CellId_t, cell.id): cell.code for cell in self.snapshot.cells},
                run_ids=[cast(CellId_t, cell_id) for cell_id in run_ids],
                delete_ids=[cast(CellId_t, cell_id) for cell_id in delete_ids],
            )
            with self.lock:
                self.active_request_id = request_id
            self._send_command(command)
        if run_ids:
            self._drain_notifications(timeout=0.05)
        else:
            self._drain_notifications(timeout=0.1)

    def run_cells(self, *, cell_ids: list[str], codes: list[str], request_id: int | None) -> None:
        with self.command_lock:
            self.ensure_started(request_id)
            if self._consume_cancelled_request(request_id):
                return
            command = ExecuteCellsCommand(
                cell_ids=[cast(CellId_t, cell_id) for cell_id in cell_ids],
                codes=codes,
            )
            with self.lock:
                self.active_request_id = request_id
            self._send_command(command)
        self._drain_notifications(timeout=0.05)

    def set_ui_element_value(self, *, object_ids: list[str], values: list[Any], request_id: int | None) -> None:
        with self.command_lock:
            self.ensure_started(request_id)
            command = UpdateUIElementCommand(
                object_ids=[cast(UIElementId, object_id) for object_id in object_ids],
                values=values,
            )
            with self.lock:
                self.active_request_id = request_id
            self._send_command(command)
        self._drain_notifications(timeout=0.05)

    def set_model_value(
        self,
        *,
        model_id: str,
        message: dict[str, Any],
        buffers: list[Any],
        request_id: int | None,
    ) -> None:
        with self.command_lock:
            self.ensure_started(request_id)
            command = ModelCommand(
                model_id=cast(WidgetModelId, model_id),
                message=_model_message_from_dict(message),
                buffers=_buffer_bytes(buffers),
            )
            with self.lock:
                self.active_request_id = request_id
            self._send_command(command)
        self._drain_notifications(timeout=0.05)

    def invoke_function(
        self,
        *,
        namespace: str,
        function_name: str,
        args: dict[str, Any],
        request_id: int | None,
        timeout: float = 5.0,
    ) -> dict[str, Any]:
        with self.command_lock:
            self.ensure_started(request_id)
            function_call_id = uuid.uuid4().hex
            command = InvokeFunctionCommand(
                function_call_id=RequestId(function_call_id),
                namespace=namespace,
                function_name=function_name,
                args=args,
            )
            with self.lock:
                self.active_request_id = request_id
                self.function_results.pop(function_call_id, None)
            self._send_command(command)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                result = self.function_results.pop(function_call_id, None)
            if result is not None:
                with self.lock:
                    self.active_request_id = None
                return {
                    "return_value": result.return_value,
                    "status": asdict(result.status),
                }
            time.sleep(0.01)
        with self.lock:
            self.active_request_id = None
        raise TimeoutError("timed out waiting for function result")

    def send_stdin(self, text: str) -> None:
        with self.command_lock:
            self.ensure_started()
            assert self.kernel is not None
            self._touch_activity()
            self.kernel.queue_manager.input_queue.put(text)
            with self.lock:
                self.session_view.add_stdin(text)

    def interrupt(self, request_id: int | None) -> None:
        with self.command_lock:
            self.ensure_started(request_id)
            assert self.kernel is not None
            with self.lock:
                self.active_request_id = request_id
                previous_completed_runs = self.completed_runs
                had_pending_work = any(
                    notification.status in {"running", "queued"}
                    for notification in self.session_view.cell_notifications.values()
                )
            self.kernel.interrupt()
        if had_pending_work:
            try:
                self._wait_for_completion(previous_completed_runs, timeout=2.0)
            except TimeoutError:
                self._drain_notifications(timeout=0.1)
        else:
            self._drain_notifications(timeout=0.1)
        with self.lock:
            self.active_request_id = None

    def _stop_kernel(self) -> None:
        self.stop_event.set()
        kernel = self.kernel
        stream_thread = self.stream_thread
        self.kernel = None
        self.stream_thread = None
        self.file_manager = None
        if kernel is not None:
            kernel.close()
        if stream_thread is not None and stream_thread is not threading.current_thread():
            stream_thread.join(timeout=1)

    def close(self) -> None:
        self.closed = True
        self.idle_stop_event.set()
        with self.command_lock:
            self._stop_kernel()
        if self.idle_thread is not None and self.idle_thread is not threading.current_thread():
            self.idle_thread.join(timeout=1)
        self.idle_thread = None
