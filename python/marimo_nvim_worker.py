#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    src = root / "src"
    if str(src) not in sys.path:
        sys.path.insert(0, str(src))
    from marimo_nvim_py.worker import main as worker_main

    return worker_main()


if __name__ == "__main__":
    raise SystemExit(main())
