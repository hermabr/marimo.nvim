from __future__ import annotations

import queue
import signal
import subprocess
import threading
import time
from contextlib import contextmanager
from typing import Any
from uuid import uuid4

from marimo._ast.app import App, InternalApp
from marimo._ast.cell import CellConfig
from marimo._config.manager import get_default_config_manager
from marimo._ipc.queue_manager import QueueManager
from marimo._ipc.types import KernelArgs
from marimo._messaging.msgspec_encoder import asdict
from marimo._messaging.serde import deserialize_kernel_message
from marimo._runtime.commands import (
    AppMetadata,
    ExecuteCellsCommand,
    InvokeFunctionCommand,
    ModelCommand,
    SyncGraphCommand,
    UpdateUIElementCommand,
)
from marimo._session.notebook.file_manager import AppFileManager
from marimo._types.ids import CellId_t, RequestId, UIElementId, WidgetModelId

from marimo_nvim_py.models import RuntimeSession


def _cell_config(cell: dict[str, Any]) -> CellConfig:
    options = cell.get("options", {})
    if not isinstance(options, dict):
        options = {}
    return CellConfig.from_dict(options, warn=False)


def _build_file_manager(snapshot: dict[str, Any]) -> AppFileManager:
    app_options = snapshot.get("app_options")
    if not isinstance(app_options, dict):
        app_options = {}
    app = App(**app_options, _filename=snapshot["path"])
    internal_app = InternalApp(app)
    if snapshot.get("header"):
        internal_app._app._header = snapshot["header"]
    cells = snapshot.get("cells", [])
    internal_app.with_data(
        cell_ids=[cell["id"] for cell in cells],
        codes=[cell["code"] for cell in cells],
        names=[cell.get("name", "_") for cell in cells],
        configs=[_cell_config(cell) for cell in cells],
    )
    file_manager = AppFileManager.from_app(internal_app)
    file_manager.filename = snapshot["path"]
    return file_manager


def _route_control_request(runtime: RuntimeSession, command: Any) -> None:
    if isinstance(command, UpdateUIElementCommand):
        runtime.queue_manager.control_queue.put(command)
        runtime.queue_manager.set_ui_element_queue.put(command)
        return
    if isinstance(command, ModelCommand):
        runtime.queue_manager.control_queue.put(command)
        runtime.queue_manager.set_ui_element_queue.put(command)
        return
    runtime.queue_manager.control_queue.put(command)


def _uv_kernel_cmd(project_root: str, plugin_root: str) -> list[str]:
    cmd = ["uv", "run"]
    if project_root:
        cmd.extend(["--project", project_root])
    cmd.extend(["--directory", plugin_root, "--with", "marimo", "--with", "pyzmq", "python", "-m", "marimo._ipc.launch_kernel"])
    return cmd


class KernelLaunchError(Exception):
    pass


class MarimoRuntimeSession:
    def __init__(self, *, session_id: str, path: str, project_root: str, plugin_root: str, snapshot: dict[str, Any], event_sink: Any) -> None:
        self._event_sink = event_sink
        self._session = self._start(
            session_id=session_id,
            path=path,
            project_root=project_root,
            plugin_root=plugin_root,
            snapshot=snapshot,
        )

    @property
    def state(self) -> RuntimeSession:
        return self._session

    def _start(
        self,
        *,
        session_id: str,
        path: str,
        project_root: str,
        plugin_root: str,
        snapshot: dict[str, Any],
    ) -> RuntimeSession:
        file_manager = _build_file_manager(snapshot)
        config_manager = get_default_config_manager(current_path=path)
        queue_manager, connection_info = QueueManager.create()
        kernel_args = KernelArgs(
            configs=file_manager.app.cell_manager.config_map(),
            app_metadata=AppMetadata(
                query_params={},
                cli_args={},
                app_config=file_manager.app.config,
                argv=[],
                filename=path,
            ),
            user_config=config_manager.get_config(hide_secrets=False),
            log_level=20,
            profile_path=None,
            connection_info=connection_info,
            is_run_mode=False,
            virtual_files_supported=False,
            redirect_console_to_browser=True,
        )
        process = subprocess.Popen(
            _uv_kernel_cmd(project_root, plugin_root),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=plugin_root,
        )
        assert process.stdin is not None
        process.stdin.write(kernel_args.encode_json())
        process.stdin.flush()
        process.stdin.close()
        assert process.stdout is not None
        ready = process.stdout.readline().decode().strip()
        if ready != "KERNEL_READY":
            stderr = process.stderr.read().decode() if process.stderr is not None else ""
            raise KernelLaunchError(f"kernel failed to start via `{' '.join(_uv_kernel_cmd(project_root, plugin_root))}`\n{stderr}")
        runtime = RuntimeSession(
            session_id=session_id,
            path=path,
            project_root=project_root,
            plugin_root=plugin_root,
            snapshot=snapshot,
            queue_manager=queue_manager,
            process=process,
            consumer_thread=threading.Thread(target=lambda: None),
        )
        runtime.consumer_thread = threading.Thread(target=self._consume_notifications, args=(runtime,), daemon=True)
        runtime.consumer_thread.start()
        return runtime

    def _emit_operation(self, runtime: RuntimeSession, operation: dict[str, Any]) -> None:
        request_id = runtime.active_request_id
        if request_id is not None and runtime.current_operations is not None:
            runtime.current_operations.append(operation)
        if self._event_sink is None or request_id is None:
            return
        self._event_sink(
            {
                "event": "operation",
                "request_id": request_id,
                "session_id": runtime.session_id,
                "operation": operation,
            }
        )

    def _consume_notifications(self, runtime: RuntimeSession) -> None:
        while not runtime.stop_event.is_set():
            try:
                message = runtime.queue_manager.stream_queue.get(timeout=0.1)
            except queue.Empty:
                if runtime.process.poll() is not None:
                    return
                continue
            if message is None:
                continue
            decoded = deserialize_kernel_message(message)
            operation = asdict(decoded)
            if operation.get("op") == "completed-run":
                with runtime.lock:
                    runtime.completed_runs += 1
            elif operation.get("op") == "function-call-result":
                function_call_id = operation.get("function_call_id")
                if isinstance(function_call_id, str):
                    with runtime.lock:
                        runtime.function_results[function_call_id] = operation
            self._emit_operation(runtime, operation)

    @contextmanager
    def _request_scope(self, request_id: int | None) -> Any:
        with self._session.request_lock:
            previous = self._session.active_request_id
            previous_operations = self._session.current_operations
            self._session.active_request_id = request_id
            self._session.current_operations = []
            try:
                yield
            finally:
                self._session.active_request_id = previous
                self._session.current_operations = previous_operations

    def replace_snapshot(self, snapshot: dict[str, Any]) -> None:
        self._session.snapshot = snapshot

    def _route(self, command: Any) -> None:
        _route_control_request(self._session, command)

    def sync_notebook(self, *, run_ids: list[str], delete_ids: list[str], request_id: int | None) -> dict[str, Any]:
        cells = self._session.snapshot.get("cells", [])
        command = SyncGraphCommand(
            cells={cell["id"]: cell["code"] for cell in cells},
            run_ids=[CellId_t(cell_id) for cell_id in run_ids],
            delete_ids=[CellId_t(cell_id) for cell_id in delete_ids],
        )
        previous = self._session.completed_runs
        with self._request_scope(request_id):
            self._route(command)
            if run_ids:
                self._wait_for_runs(previous)
            return {"operations": list(self._session.current_operations or [])}

    def run_cells(self, *, cell_ids: list[str], codes: list[str], request_id: int | None) -> dict[str, Any]:
        if not cell_ids:
            return {"operations": []}
        previous = self._session.completed_runs
        command = ExecuteCellsCommand(
            cell_ids=[CellId_t(cell_id) for cell_id in cell_ids],
            codes=codes,
        )
        with self._request_scope(request_id):
            self._route(command)
            self._wait_for_runs(previous)
            return {"operations": list(self._session.current_operations or [])}

    def set_ui_element_value(self, *, object_ids: list[str], values: list[Any], request_id: int | None) -> dict[str, Any]:
        with self._request_scope(request_id):
            self._route(UpdateUIElementCommand(object_ids=[UIElementId(object_id) for object_id in object_ids], values=values))
            return {"operations": list(self._session.current_operations or [])}

    def set_model_value(self, *, model_id: str, message: dict[str, Any], buffers: list[bytes], request_id: int | None) -> dict[str, Any]:
        with self._request_scope(request_id):
            self._route(ModelCommand(model_id=WidgetModelId(model_id), message=message, buffers=buffers))  # type: ignore[arg-type]
            return {"operations": list(self._session.current_operations or [])}

    def invoke_function(self, *, namespace: str, function_name: str, args: dict[str, Any], request_id: int | None) -> dict[str, Any] | None:
        function_call_id = str(uuid4())
        with self._session.lock:
            self._session.function_results.pop(function_call_id, None)
        with self._request_scope(request_id):
            self._route(
                InvokeFunctionCommand(
                    function_call_id=RequestId(function_call_id),
                    namespace=namespace,
                    function_name=function_name,
                    args=args,
                )
            )
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                with self._session.lock:
                    result = self._session.function_results.pop(function_call_id, None)
                if result is not None:
                    return result
                time.sleep(0.01)
        return None

    def send_stdin(self, text: str) -> None:
        self._session.queue_manager.input_queue.put(text)

    def interrupt(self) -> None:
        if self._session.process.poll() is None and self._session.process.pid is not None:
            self._session.process.send_signal(signal.SIGINT)

    def _wait_for_runs(self, previous_completed_runs: int, timeout: float = 30.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._session.lock:
                if self._session.completed_runs > previous_completed_runs:
                    return
            if self._session.process.poll() is not None:
                break
            time.sleep(0.01)
        raise TimeoutError("timed out waiting for marimo runtime to finish")

    def close(self) -> None:
        self._session.stop_event.set()
        try:
            self._session.queue_manager.close_queues()
        except Exception:
            pass
        if self._session.process.poll() is None:
            self._session.process.terminate()
            try:
                self._session.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._session.process.kill()
