"""Narrow eval-only setup for one newly-created, untitled TextEdit document."""

from __future__ import annotations

import json
import os
import subprocess
import time
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class NativeDocumentLease:
    pid: int
    window_id: int

    def as_dict(self) -> dict[str, int]:
        return {"pid": self.pid, "window_id": self.window_id}

    @classmethod
    def from_dict(cls, value: Any) -> "NativeDocumentLease":
        if (not isinstance(value, dict) or set(value) != {"pid", "window_id"}
                or type(value["pid"]) is not int or value["pid"] <= 0
                or type(value["window_id"]) is not int or value["window_id"] < 0):
            raise ValueError("invalid TextEdit document lease")
        return cls(value["pid"], value["window_id"])


def _osascript(source: str, runner: Any = subprocess.run, timeout: float = 15) -> str:
    result = runner(["/usr/bin/osascript", "-"], input=source, capture_output=True,
                    text=True, timeout=timeout, check=False)
    if result.returncode != 0:
        detail = (result.stderr or "").strip().replace("\n", " ")[:500]
        raise RuntimeError("TextEdit eval setup failed" + (f": {detail}" if detail else ""))
    return result.stdout.strip()


def prepare_textedit_untitled(runner: Any = subprocess.run) -> NativeDocumentLease:
    source = '''tell application id "com.apple.TextEdit"
    launch
    if (count of documents) is not 0 then error "TextEdit has documents after clean-start"
    set newDocument to make new document
    try
    if (count of documents) is not 1 then error "TextEdit did not create exactly one document"
    set documentName to name of newDocument
    set matchingWindows to every window whose name is documentName
    if (count of matchingWindows) is not 1 then error "TextEdit did not create exactly one matching document window"
    set newWindow to first item of matchingWindows
    set windowID to id of newWindow
    activate
    on error errorMessage number errorNumber
        try
            close newDocument saving no
        end try
        error errorMessage number errorNumber
    end try
end tell
tell application "System Events"
    set appPID to unix id of first process whose bundle identifier is "com.apple.TextEdit"
end tell
return (appPID as text) & ":" & (windowID as text)
'''
    output = _osascript(source, runner=runner)
    try:
        pid_text, document_text = output.split(":", 1)
        lease = NativeDocumentLease(int(pid_text), int(document_text))
    except (ValueError, TypeError) as error:
        raise RuntimeError("TextEdit eval setup returned an invalid document identity") from error
    if lease.pid <= 0 or lease.window_id < 0:
        raise RuntimeError("TextEdit eval setup returned an invalid document identity")
    return lease


def close_textedit_untitled(lease: NativeDocumentLease | dict[str, Any],
                            runner: Any = subprocess.run) -> None:
    if isinstance(lease, dict):
        lease = NativeDocumentLease.from_dict(lease)
    elif not isinstance(lease, NativeDocumentLease):
        raise ValueError("invalid TextEdit document lease")
    # The PID and window ID are integers validated above, so they cannot inject AppleScript.
    source = f'''tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is 0 then return "closed"
    set appPID to unix id of first item of matchingProcesses
end tell
if appPID is not {lease.pid} then error "TextEdit process changed; refusing to close a document"
tell application id "com.apple.TextEdit"
    set matchingWindows to every window whose id is {lease.window_id}
    if (count of matchingWindows) is 0 then return "closed"
    if (count of matchingWindows) is not 1 then error "Window identity is ambiguous"
    close (document of first item of matchingWindows) saving no
end tell
return "closed"
'''
    _osascript(source, runner=runner)


def prepare_notes_no_selection(runner: Any = subprocess.run) -> None:
    source = '''tell application id "com.apple.Notes"
    launch
    activate
    set selection to {}
end tell
'''
    _osascript(source, runner=runner)


def reset_empty_textedit(runner: Any = subprocess.run) -> None:
    source = '''tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is 0 then return "not_running"
    return (unix id of first item of matchingProcesses) as text
end tell
'''
    output = _osascript(source, runner=runner)
    if output == "not_running":
        return
    try:
        pid = int(output)
    except ValueError as error:
        raise RuntimeError("TextEdit reset returned an invalid process identity") from error
    if pid <= 0:
        raise RuntimeError("TextEdit reset returned an invalid process identity")
    quit_source = '''tell application id "com.apple.TextEdit"
    if (count of documents) is 0 then
        quit
        return "quit"
    end if
    return "has_documents"
end tell
'''
    result = _osascript(quit_source, runner=runner)
    if result != "quit":
        return
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            return
        time.sleep(0.05)
    raise RuntimeError("TextEdit did not exit after closing its zero-document panel")


def lease_json(lease: NativeDocumentLease) -> str:
    """Stable JSON representation for runner checkpoint state."""
    return json.dumps(lease.as_dict(), separators=(",", ":"))
