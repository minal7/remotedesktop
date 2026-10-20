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


@dataclass(frozen=True)
class TextEditReset:
    status: str
    pid: int | None
    document_count: int | None

    def as_dict(self) -> dict[str, int | str | None]:
        return {"status": self.status, "pid": self.pid, "document_count": self.document_count}


def _osascript(source: str, runner: Any = subprocess.run, timeout: float = 15) -> str:
    result = runner(["/usr/bin/osascript", "-"], input=source, capture_output=True,
                    text=True, timeout=timeout, check=False)
    if result.returncode != 0:
        detail = (result.stderr or "").strip().replace("\n", " ")[:500]
        raise RuntimeError("TextEdit eval setup failed" + (f": {detail}" if detail else ""))
    return result.stdout.strip()


def prepare_textedit_untitled(expected_pid: int, runner: Any = subprocess.run) -> NativeDocumentLease:
    if type(expected_pid) is not int or expected_pid <= 0:
        raise ValueError("invalid expected TextEdit process identity")
    source = f'''tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is not 1 then error "TextEdit process is not uniquely running"
    set appPID to unix id of first item of matchingProcesses
end tell
if appPID is not {expected_pid} then error "TextEdit process changed after fresh launch"
tell application id "com.apple.TextEdit"
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
    if lease.pid != expected_pid:
        raise RuntimeError("TextEdit eval setup returned a different process identity")
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


def reset_empty_textedit(runner: Any = subprocess.run, *, monotonic: Any = time.monotonic,
                         sleep: Any = time.sleep, pid_probe: Any = os.kill) -> TextEditReset:
    source = '''tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is 0 then return "not_running"
    set appPID to unix id of first item of matchingProcesses
end tell
tell application id "com.apple.TextEdit"
    set documentCount to count of documents
end tell
return (appPID as text) & ":" & (documentCount as text)
'''
    output = _osascript(source, runner=runner)
    if output == "not_running":
        return TextEditReset("not_running", None, 0)
    try:
        pid_text, documents_text = output.split(":", 1)
        pid = int(pid_text)
        documents = int(documents_text)
    except ValueError as error:
        raise RuntimeError("TextEdit reset returned an invalid process identity") from error
    if pid <= 0:
        raise RuntimeError("TextEdit reset returned an invalid process identity")
    if documents < 0:
        raise RuntimeError("TextEdit reset returned an invalid document count")
    if documents:
        return TextEditReset("has_documents", pid, documents)
    quit_source = f'''tell application id "com.apple.TextEdit"
    if (count of documents) is 0 then
        tell application "System Events"
            set currentProcesses to every process whose bundle identifier is "com.apple.TextEdit"
            if (count of currentProcesses) is not 1 then error "TextEdit process is not uniquely running before quit"
            set currentPID to unix id of first item of currentProcesses
        end tell
        if currentPID is not {pid} then error "TextEdit process changed before zero-document quit"
        quit
        return "quit"
    end if
    return "has_documents"
end tell
'''
    result = _osascript(quit_source, runner=runner)
    if result == "has_documents":
        return TextEditReset("has_documents", pid, None)
    if result != "quit":
        raise RuntimeError("TextEdit reset returned an invalid quit status")
    deadline = monotonic() + 3.0
    while monotonic() < deadline:
        try:
            pid_probe(pid, 0)
        except ProcessLookupError:
            return TextEditReset("quit", pid, 0)
        except PermissionError:
            # The process is still present; lacking signal permission is not proof of exit.
            pass
        sleep(0.05)
    raise RuntimeError(f"TextEdit pid {pid} did not exit after closing its zero-document panel")


def launch_fresh_textedit(reset: TextEditReset, runner: Any = subprocess.run) -> int:
    valid_reset = isinstance(reset, TextEditReset) and (
        (reset.status == "not_running" and reset.pid is None and reset.document_count == 0)
        or (reset.status == "quit" and type(reset.pid) is int and reset.pid > 0
            and reset.document_count == 0)
    )
    if not valid_reset:
        detail = reset.as_dict() if isinstance(reset, TextEditReset) else "invalid reset result"
        raise RuntimeError(f"Refusing fresh TextEdit launch without a consistent zero-document reset: {detail}")
    argv = ["/usr/bin/open", "-F", "-b", "com.apple.TextEdit"]
    result = runner(argv, capture_output=True, text=True, timeout=10, check=False)
    if result.returncode != 0:
        detail = (result.stderr or "").strip().replace("\n", " ")[:500]
        raise RuntimeError("Fresh TextEdit launch failed" + (f": {detail}" if detail else ""))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        source = '''tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is 0 then return "not_running"
    return (unix id of first item of matchingProcesses) as text
end tell
'''
        try:
            output = _osascript(source, runner=runner, timeout=3)
            if output != "not_running":
                pid = int(output)
                if pid > 0:
                    return pid
        except (RuntimeError, ValueError):
            pass
        time.sleep(0.1)
    raise RuntimeError("Fresh TextEdit launch did not produce a running process")


def lease_json(lease: NativeDocumentLease) -> str:
    """Stable JSON representation for runner checkpoint state."""
    return json.dumps(lease.as_dict(), separators=(",", ":"))
