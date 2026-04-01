from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, cast
from uuid import uuid4

import msgspec
from marimo._ast.app import App, InternalApp
from marimo._config.config import PartialMarimoConfig
from marimo._config.manager import get_default_config_manager
from marimo._config.settings import GLOBAL_SETTINGS
from marimo._ipc.queue_manager import QueueManager
from marimo._ipc.types import KernelArgs
from marimo._runtime.commands import (
    AppMetadata,
    ExecuteCellCommand,
    ExecuteCellsCommand,
    InvokeFunctionCommand,
    ModelCommand,
    ModelCustomMessage,
    ModelUpdateMessage,
    SyncGraphCommand,
    StopKernelCommand,
    UpdateUIElementCommand,
)
from marimo._messaging.msgspec_encoder import asdict
from marimo._session import queue as session_queue
from marimo._session.notebook.file_manager import AppFileManager
from marimo._types.ids import CellId_t, RequestId, UIElementId, WidgetModelId

from marimo_nvim_py.consumer import OperationConsumer

if hasattr(session_queue, "route_control_request"):
    route_control_request = session_queue.route_control_request
else:

    def route_control_request(
        request: Any,
        control_queue: Any,
        completion_queue: Any,
        ui_element_queue: Any,
    ) -> None:
        from marimo._runtime import commands

        if isinstance(request, commands.CodeCompletionCommand):
            completion_queue.put(request)
            return

        control_queue.put(request)
        if isinstance(
            request,
            (commands.UpdateUIElementCommand, commands.ModelCommand),
        ):
            ui_element_queue.put(request)


RUN_WAIT_TIMEOUT_SECONDS = 30.0
FUNCTION_WAIT_TIMEOUT_SECONDS = 5.0


def _cell_ids(snapshot: dict[str, Any]) -> list[str]:
    return [str(cell["id"]) for cell in snapshot.get("cells") or []]


def _typed_cell_ids(snapshot: dict[str, Any]) -> list[CellId_t]:
    return [cast(CellId_t, cell_id) for cell_id in _cell_ids(snapshot)]


def _codes(snapshot: dict[str, Any]) -> list[str]:
    return [str(cell.get("code") or "") for cell in snapshot.get("cells") or []]


def _names(snapshot: dict[str, Any]) -> list[str]:
    return [str(cell.get("name") or "_") for cell in snapshot.get("cells") or []]


def _configs(snapshot: dict[str, Any]) -> list[Any]:
    from marimo._ast.cell import CellConfig

    return [
        CellConfig.from_dict(dict(cell.get("options") or {}), warn=False)
        for cell in snapshot.get("cells") or []
    ]


@dataclass
class RuntimeSession:
    session_id: str
    path: str
    project_root: str
    runtime_kind: str
    snapshot: dict[str, Any]
    event_sink: Callable[[dict[str, Any]], None] | None

    def __post_init__(self) -> None:
        self._plugin_root = str(Path(__file__).resolve().parent.parent)
        self._queue_manager: Any | None = None
        self._connection_info: Any | None = None
        self._process: subprocess.Popen[bytes] | None = None
        self._consumer: OperationConsumer | None = None
        self._active_request_id: int | None = None
        self._lock = threading.RLock()
        self._stderr_thread: threading.Thread | None = None
        self._stderr_tail: list[str] = []
        self._internal_app: InternalApp | None = None
        self._file_manager: AppFileManager | None = None

    def set_snapshot(self, snapshot: dict[str, Any]) -> None:
        self.snapshot = snapshot
        if self._internal_app is None or self._file_manager is None:
            return
        self._internal_app.with_data(
            cell_ids=_typed_cell_ids(snapshot),
            codes=_codes(snapshot),
            names=_names(snapshot),
            configs=_configs(snapshot),
        )
        self._file_manager.filename = self.path

    def runtime_cells(self) -> dict[str, dict[str, Any]]:
        if self._consumer is None:
            return {}
        runtime_cells: dict[str, dict[str, Any]] = {}
        for cell in self.snapshot.get("cells") or []:
            cell_id = str(cell["id"])
            typed_cell_id = cast(CellId_t, cell_id)
            notification = self._consumer.session_view.cell_notifications.get(
                typed_cell_id
            )
            if notification is None:
                runtime_cells[cell_id] = {
                    "status": None,
                    "stale_inputs": False,
                    "output": None,
                    "console": [],
                    "last_run_timestamp": None,
                    "last_execution_time_ms": None,
                }
                continue
            console = notification.console
            if console is None:
                console_items: list[dict[str, Any]] = []
            elif isinstance(console, list):
                console_items = [asdict(cast(msgspec.Struct, item)) for item in console]
            else:
                console_items = [asdict(cast(msgspec.Struct, console))]
            runtime_cells[cell_id] = {
                "status": notification.status,
                "stale_inputs": bool(notification.stale_inputs),
                "output": asdict(notification.output)
                if notification.output is not None
                else None,
                "console": console_items,
                "last_run_timestamp": None,
                "last_execution_time_ms": None,
            }
        return runtime_cells

    def close(self) -> None:
        with self._lock:
            consumer = self._consumer
            self._consumer = None
            queue_manager = self._queue_manager
            self._queue_manager = None
            process = self._process
            self._process = None
            if queue_manager is not None:
                with contextlib.suppress(Exception):
                    route_control_request(
                        request=StopKernelCommand(),
                        control_queue=queue_manager.control_queue,
                        completion_queue=queue_manager.completion_queue,
                        ui_element_queue=queue_manager.set_ui_element_queue,
                    )
                with contextlib.suppress(Exception):
                    queue_manager.close_queues()
            if process is not None and process.poll() is None:
                process.terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    process.wait(timeout=5.0)
                if process.poll() is None:
                    process.kill()
            if consumer is not None:
                consumer.close()

    def ensure_started(self, request_id: int | None = None) -> None:
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                return
            self._build_file_manager()
            queue_manager, connection_info = QueueManager.create()
            self._queue_manager = queue_manager
            self._connection_info = connection_info
            process = self._launch_kernel()
            self._process = process
            consumer = OperationConsumer(
                session_id=self.session_id,
                stream_queue=queue_manager.stream_queue,
                event_sink=self.event_sink,
                current_request_id=lambda: self._active_request_id,
            )
            self._consumer = consumer
            consumer.start()
            baseline = consumer.completed_runs
            self._set_active_request_id(request_id)
            try:
                create_request = self._create_notebook_request()
                self._send_control_request(create_request)
                if not consumer.wait_for_completed_runs(
                    baseline + 1, RUN_WAIT_TIMEOUT_SECONDS
                ):
                    raise TimeoutError("timed out waiting for marimo kernel startup")
            finally:
                self._set_active_request_id(None)

    def sync_notebook(
        self,
        snapshot: dict[str, Any],
        *,
        run_ids: list[str],
        delete_ids: list[str],
        request_id: int | None,
    ) -> None:
        with self._lock:
            self.set_snapshot(snapshot)
            if self._process is None or self._process.poll() is not None:
                if run_ids or delete_ids:
                    self.ensure_started(request_id=request_id)
                else:
                    return
            if self._queue_manager is None or self._consumer is None:
                return
            self._set_active_request_id(request_id)
            try:
                baseline = self._consumer.completed_runs
                command = SyncGraphCommand(
                    cells={
                        cast(CellId_t, cell_id): code
                        for cell_id, code in zip(_cell_ids(snapshot), _codes(snapshot))
                    },
                    run_ids=[cast(CellId_t, cell_id) for cell_id in run_ids],
                    delete_ids=[cast(CellId_t, cell_id) for cell_id in delete_ids],
                )
                self._send_control_request(command)
                if not self._consumer.wait_for_completed_runs(
                    baseline + 1, RUN_WAIT_TIMEOUT_SECONDS
                ):
                    raise TimeoutError("timed out waiting for marimo runtime sync")
            finally:
                self._set_active_request_id(None)

    def run_cells(
        self, *, cell_ids: list[str], codes: list[str], request_id: int | None
    ) -> None:
        if not cell_ids:
            return
        with self._lock:
            self.ensure_started(request_id=None)
            if self._queue_manager is None or self._consumer is None:
                return
            self._set_active_request_id(request_id)
            try:
                baseline = self._consumer.completed_runs
                command = ExecuteCellsCommand(
                    cell_ids=[cast(CellId_t, cell_id) for cell_id in cell_ids],
                    codes=codes,
                )
                self._send_control_request(command)
                if not self._consumer.wait_for_completed_runs(
                    baseline + 1, RUN_WAIT_TIMEOUT_SECONDS
                ):
                    raise TimeoutError("timed out waiting for marimo runtime run")
            finally:
                self._set_active_request_id(None)

    def set_ui_element_value(
        self, *, object_ids: list[str], values: list[Any], request_id: int | None
    ) -> None:
        with self._lock:
            self.ensure_started(request_id=None)
            command = UpdateUIElementCommand(
                object_ids=[cast(UIElementId, object_id) for object_id in object_ids],
                values=values,
                token=str(uuid4()),
            )
            self._run_control_command(command, request_id=request_id)

    def set_model_value(
        self,
        *,
        model_id: str,
        message: dict[str, Any],
        buffers: list[bytes],
        request_id: int | None,
    ) -> None:
        with self._lock:
            self.ensure_started(request_id=None)
            method = message.get("method")
            if method == "update":
                model_message = ModelUpdateMessage(
                    state=dict(message.get("state") or {}),
                    buffer_paths=list(message.get("buffer_paths") or []),
                )
            else:
                model_message = ModelCustomMessage(content=message.get("content"))
            command = ModelCommand(
                model_id=cast(WidgetModelId, model_id),
                message=model_message,
                buffers=buffers,
            )
            self._run_control_command(command, request_id=request_id)

    def invoke_function(
        self,
        *,
        namespace: str,
        function_name: str,
        args: dict[str, Any],
        request_id: int | None,
    ) -> Any | None:
        with self._lock:
            self.ensure_started(request_id=None)
            if self._consumer is None:
                return None
            function_call_id = str(uuid4())
            self._consumer.clear_function_result(function_call_id)
            command = InvokeFunctionCommand(
                function_call_id=cast(RequestId, function_call_id),
                namespace=namespace,
                function_name=function_name,
                args=args,
            )
            self._set_active_request_id(request_id)
            try:
                self._send_control_request(command)
                deadline = time.monotonic() + FUNCTION_WAIT_TIMEOUT_SECONDS
                while time.monotonic() < deadline:
                    result = self._consumer.pop_function_result(function_call_id)
                    if result is not None:
                        if result.status.code == "ok":
                            return result.return_value
                        return None
                    time.sleep(0.01)
            finally:
                self._set_active_request_id(None)
        return None

    def send_stdin(self, text: str) -> None:
        with self._lock:
            if self._queue_manager is None or self._consumer is None:
                return
            self._queue_manager.input_queue.put(text)
            self._consumer.session_view.add_stdin(text)

    def interrupt(self) -> None:
        process = self._process
        if process is None or process.poll() is not None:
            return
        if process.pid is not None:
            os.kill(process.pid, signal.SIGINT)

    def _run_control_command(self, command: Any, *, request_id: int | None) -> None:
        if self._consumer is None:
            return
        self._set_active_request_id(request_id)
        try:
            baseline = self._consumer.completed_runs
            self._send_control_request(command)
            if not self._consumer.wait_for_completed_runs(
                baseline + 1, RUN_WAIT_TIMEOUT_SECONDS
            ):
                raise TimeoutError("timed out waiting for marimo runtime command")
        finally:
            self._set_active_request_id(None)

    def _set_active_request_id(self, request_id: int | None) -> None:
        self._active_request_id = request_id

    def _build_file_manager(self) -> None:
        app = App(**(self.snapshot.get("app_options") or {}), _filename=self.path)
        internal_app = InternalApp(app)
        header = self.snapshot.get("header")
        if header:
            internal_app._app._header = header
        internal_app.with_data(
            cell_ids=_typed_cell_ids(self.snapshot),
            codes=_codes(self.snapshot),
            names=_names(self.snapshot),
            configs=_configs(self.snapshot),
        )
        file_manager = AppFileManager.from_app(internal_app)
        file_manager.filename = self.path
        self._internal_app = internal_app
        self._file_manager = file_manager

    def _kernel_command(self) -> list[str]:
        cmd = ["uv", "run"]
        if self.runtime_kind == "uv_project" and self.project_root:
            cmd.extend(["--project", self.project_root])
        cmd.extend(
            [
                "--directory",
                self._plugin_root,
                "--with",
                "marimo",
                "--with",
                "pyzmq",
                "python",
                "-m",
                "marimo._ipc.launch_kernel",
            ]
        )
        return cmd

    def _launch_kernel(self) -> subprocess.Popen[bytes]:
        if self._file_manager is None or self._connection_info is None:
            raise RuntimeError("runtime file manager is not initialized")
        config_manager = get_default_config_manager(
            current_path=self.path
        ).with_overrides(
            cast(
                PartialMarimoConfig,
                {
                    "runtime": {
                        "on_cell_change": "autorun",
                        "auto_instantiate": True,
                        "auto_reload": "off",
                        "watcher_on_save": "lazy",
                    }
                },
            )
        )
        kernel_args = KernelArgs(
            configs={
                cast(CellId_t, cell["id"]): config
                for cell, config in zip(
                    self.snapshot.get("cells") or [], _configs(self.snapshot)
                )
            },
            app_metadata=AppMetadata(
                query_params={},
                filename=self.path,
                cli_args={},
                argv=[],
                app_config=self._file_manager.app.config,
            ),
            user_config=config_manager.get_config(hide_secrets=False),
            log_level=GLOBAL_SETTINGS.LOG_LEVEL,
            profile_path=None,
            connection_info=self._connection_info,
            is_run_mode=True,
            virtual_files_supported=False,
            redirect_console_to_browser=True,
        )
        process = subprocess.Popen(
            self._kernel_command(),
            cwd=self._plugin_root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if process.stdin is None or process.stdout is None:
            raise RuntimeError("failed to create marimo kernel subprocess pipes")
        process.stdin.write(kernel_args.encode_json())
        process.stdin.flush()
        process.stdin.close()
        ready = process.stdout.readline().decode("utf-8", errors="replace").strip()
        if ready != "KERNEL_READY":
            stderr = ""
            if process.stderr is not None:
                stderr = process.stderr.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                "failed to start marimo kernel\n"
                f"command: {' '.join(self._kernel_command())}\n"
                f"stderr: {stderr.strip()}"
            )
        if process.stderr is not None:
            self._stderr_thread = threading.Thread(
                target=self._drain_stderr,
                args=(process.stderr,),
                daemon=True,
            )
            self._stderr_thread.start()
        return process

    def _drain_stderr(self, stream: Any) -> None:
        for raw_line in stream:
            line = raw_line.decode("utf-8", errors="replace").rstrip()
            if line == "":
                continue
            self._stderr_tail.append(line)
            if len(self._stderr_tail) > 50:
                self._stderr_tail.pop(0)

    def _create_notebook_request(self) -> Any:
        execution_requests = tuple(
            ExecuteCellCommand(
                cell_id=cell_id,
                code=code,
            )
            for cell_id, code in zip(
                _typed_cell_ids(self.snapshot), _codes(self.snapshot)
            )
        )
        from marimo._runtime.commands import CreateNotebookCommand

        return CreateNotebookCommand(
            execution_requests=execution_requests,
            cell_ids=tuple(_typed_cell_ids(self.snapshot)),
            set_ui_element_value_request=UpdateUIElementCommand(
                object_ids=[],
                values=[],
                token=str(uuid4()),
            ),
            auto_run=False,
            request=None,
        )

    def _send_control_request(self, command: Any) -> None:
        if self._queue_manager is None or self._consumer is None:
            raise RuntimeError("runtime session is not started")
        route_control_request(
            command,
            self._queue_manager.control_queue,
            self._queue_manager.completion_queue,
            self._queue_manager.set_ui_element_queue,
        )
        self._consumer.session_view.add_control_request(command)
