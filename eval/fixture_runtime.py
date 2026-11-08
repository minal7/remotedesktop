"""Local fixture HTTP server lifecycle helpers."""

from __future__ import annotations

import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def available(origin: str) -> bool:
    try:
        with urllib.request.urlopen(f"{origin}/__eval/health", timeout=0.5) as response:
            return response.status == 200
    except (OSError, urllib.error.URLError):
        return False


def start(origin: str, server_path: Path) -> subprocess.Popen[str] | None:
    if available(origin) or not server_path.is_file():
        return None
    process = subprocess.Popen(
        [sys.executable, str(server_path)], stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, text=True,
    )
    for _ in range(30):
        if available(origin):
            return process
        time.sleep(0.1)
    process.terminate()
    process.wait(timeout=2)
    return None
