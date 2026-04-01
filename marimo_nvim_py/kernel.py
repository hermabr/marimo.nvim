from __future__ import annotations

import os
import signal
import subprocess
from collections import deque
from pathlib import Path
from typing import TYPE_CHECKING

from marimo._config.manager import get_default_config_manager
from marimo._config.settings import GLOBAL_SETTINGS
from marimo._ipc.queue_manager import QueueManager
from marimo._ipc.types import KernelArgs
from marimo._runtime.commands import AppMetadata

from marimo_nvim_py.models import NotebookSnapshot

if TYPE_CHECKING:
    from marimo._ast.app import InternalApp


class KernelLaunchError(RuntimeError):
    pass


class KernelBridge:
    def __init__(self, snapshot: NotebookSnapshot, app: InternalApp) -> None:
        self.snapshot = snapshot
        self.app = app
        self.queue_manager, connection_info = QueueManager.create()
        self.stderr_lines: deque[str] = deque(maxlen=200)
        self.process: subprocess.Popen[bytes] | None = None

        config_manager = get_default_config_manager(current_path=snapshot.path)
        self.kernel_args = KernelArgs(
            configs=app.cell_manager.config_map(),
            app_metadata=AppMetadata(
                query_params={},
                cli_args={},
                app_config=app.config,
                argv=[],
                filename=snapshot.path,
            ),
            user_config=config_manager.get_config(hide_secrets=False),
            log_level=GLOBAL_SETTINGS.LOG_LEVEL,
            profile_path=None,
            connection_info=connection_info,
            is_run_mode=False,
            virtual_files_supported=False,
            redirect_console_to_browser=True,
        )

    @staticmethod
    def _plugin_root() -> str:
        return str(Path(__file__).resolve().parent.parent)

    def launch(self) -> None:
        cmd = ["uv", "run"]
        if self.snapshot.runtime_kind == "uv_project" and self.snapshot.project_root:
            cmd.extend(["--project", self.snapshot.project_root])
        cmd.extend(
            [
                "--directory",
                self._plugin_root(),
                "--with",
                "marimo",
                "--with",
                "pyzmq",
                "python",
                "-m",
                "marimo._ipc.launch_kernel",
            ]
        )
        self.process = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=os.environ.copy(),
        )

        assert self.process.stdin is not None
        self.process.stdin.write(self.kernel_args.encode_json())
        self.process.stdin.flush()
        self.process.stdin.close()

        assert self.process.stdout is not None
        ready = self.process.stdout.readline().decode("utf-8", errors="replace").strip()
        if ready != "KERNEL_READY":
            stderr = self.read_stderr()
            raise KernelLaunchError(
                f"Kernel failed to start.\n\nCommand: {' '.join(cmd)}\n\nStderr:\n{stderr}"
            )

    def read_stderr(self) -> str:
        if self.process is None or self.process.stderr is None:
            return ""
        data = self.process.stderr.read().decode("utf-8", errors="replace")
        if data:
            for line in data.splitlines():
                self.stderr_lines.append(line)
        return data

    def poll_stderr(self) -> None:
        if self.process is None or self.process.stderr is None:
            return
        chunk = self.process.stderr.readline()
        if not chunk:
            return
        self.stderr_lines.append(chunk.decode("utf-8", errors="replace").rstrip())

    def interrupt(self) -> None:
        if self.process is None or self.process.pid is None:
            return
        if os.name == "nt" and self.queue_manager.win32_interrupt_queue is not None:
            self.queue_manager.win32_interrupt_queue.put_nowait(True)
            return
        os.kill(self.process.pid, signal.SIGINT)

    def close(self) -> None:
        if self.process is not None:
            from marimo._runtime import commands

            self.queue_manager.control_queue.put(commands.StopKernelCommand())
            self.queue_manager.close_queues()
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
