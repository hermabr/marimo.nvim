from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class SnapshotCell:
    id: str
    name: str
    code: str
    options: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SnapshotCell:
        return cls(
            id=str(data["id"]),
            name=str(data.get("name", "_")),
            code=str(data.get("code", "")),
            options=dict(data.get("options") or {}),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "code": self.code,
            "options": dict(self.options),
        }


@dataclass
class NotebookSnapshot:
    session_id: str
    path: str
    cwd: str
    project_root: str
    runtime_kind: str
    header: str | None
    app_options: dict[str, Any]
    cells: list[SnapshotCell]

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> NotebookSnapshot:
        return cls(
            session_id=str(data["session_id"]),
            path=str(data["path"]),
            cwd=str(data.get("cwd") or ""),
            project_root=str(data.get("project_root") or ""),
            runtime_kind=str(data.get("runtime_kind") or "uv"),
            header=data.get("header"),
            app_options=dict(data.get("app_options") or {}),
            cells=[SnapshotCell.from_dict(cell) for cell in list(data.get("cells") or [])],
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "path": self.path,
            "cwd": self.cwd,
            "project_root": self.project_root,
            "runtime_kind": self.runtime_kind,
            "header": self.header,
            "app_options": dict(self.app_options),
            "cells": [cell.to_dict() for cell in self.cells],
        }
