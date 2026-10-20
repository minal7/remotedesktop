"""Narrow eval-only setup for one newly-created, untitled TextEdit document."""

from __future__ import annotations

import json
import os
import subprocess
import time
import uuid
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


@dataclass(frozen=True)
class NotesSelectionReceipt:
    status: str
    folder_name: str | None
    folder_id: str | None
    folder_note_count: int | None
    selected_note_count: int

    def as_dict(self) -> dict[str, int | str | None]:
        return {"status": self.status, "folder_name": self.folder_name, "folder_id": self.folder_id,
                "folder_note_count": self.folder_note_count, "selected_note_count": self.selected_note_count}


def _osascript(source: str, runner: Any = subprocess.run, timeout: float = 15,
               application: str = "TextEdit", include_error_detail: bool = True) -> str:
    try:
        result = runner(["/usr/bin/osascript", "-"], input=source, capture_output=True,
                        text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{application} eval setup failed: AppleScript evaluation timed out after {timeout:g}s") from exc
    if result.returncode != 0:
        detail = (result.stderr or "").strip().replace("\n", " ")[:500] if include_error_detail else ""
        raise RuntimeError(f"{application} eval setup failed" + (f": {detail}" if detail else ""))
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


def prepare_notes_no_selection(runner: Any = subprocess.run) -> NotesSelectionReceipt:
    folder_name = f"RemoteDesktop Eval {uuid.uuid4().hex}"
    source = f'''set folderName to "{folder_name}"
set folderID to ""
set operationStage to "launch"
try
    tell application id "com.apple.Notes"
        launch
        reopen
        activate
        set operationStage to "verify-standard-window"
        tell application "System Events"
            set matchingProcesses to every process whose bundle identifier is "com.apple.Notes"
            if (count of matchingProcesses) is not 1 then error "process identity is ambiguous"
            set notesProcess to first item of matchingProcesses
            set windowReady to false
            repeat with attempt from 1 to 10
                set notesWindows to windows of notesProcess whose subrole is "AXStandardWindow"
                if (count of notesWindows) > 1 then error "standard window identity is ambiguous"
                if (count of notesWindows) is 1 then
                    set windowReady to true
                    exit repeat
                end if
                delay 0.2
            end repeat
            if not windowReady then error "standard window did not reopen"
        end tell
        set operationStage to "check-existing-selection"
        set initialSelectionCount to count of selection
        if initialSelectionCount is 0 then
            set verifiedSelectionCount to count of selection
            if verifiedSelectionCount is not 0 then error "selection changed"
            return "already_clear|||0|0"
        end if
        set operationStage to "resolve-default-account"
        set defaultAccount to default account
        if defaultAccount is missing value then error "no default account"
        if (count of (every folder of defaultAccount whose name is folderName)) is not 0 then error "folder name collision"
        set operationStage to "create-owned-folder"
        set fixtureFolder to make new folder at defaultAccount with properties {{name:folderName}}
        set folderID to id of fixtureFolder
        set operationStage to "show-owned-folder"
        show fixtureFolder
        set operationStage to "verify-owned-folder-empty"
        set verifiedFolderNoteCount to count of notes of fixtureFolder
        if verifiedFolderNoteCount is not 0 then error "folder is not empty"
        if (count of selection) is not 0 then
            set operationStage to "locate-notes-process"
            tell application "System Events"
                set matchingProcesses to every process whose bundle identifier is "com.apple.Notes"
                if (count of matchingProcesses) is not 1 then error "process identity is ambiguous"
                set notesProcess to first item of matchingProcesses
                set operationStage to "locate-standard-window"
                set notesWindows to windows of notesProcess whose subrole is "AXStandardWindow"
                if (count of notesWindows) is not 1 then error "window identity is ambiguous"
                set operationStage to "locate-splitter"
                set splitterGroups to splitter groups of first item of notesWindows
                if (count of splitterGroups) is not 1 then error "splitter identity is ambiguous"
                set operationStage to "locate-scroll-areas"
                set scrollAreas to scroll areas of first item of splitterGroups
                set operationStage to "locate-folders-outline"
                set folderOutlines to {{}}
                repeat with sidebarArea in scrollAreas
                    set availableOutlines to outlines of sidebarArea
                    repeat with candidateOutline in availableOutlines
                        set end of folderOutlines to contents of candidateOutline
                    end repeat
                end repeat
                if (count of folderOutlines) is not 1 then error "Notes folder outline is not unique"
                set operationStage to "enumerate-owned-folder-rows"
                set matchingRows to {{}}
                repeat with folderRowReference in rows of first item of folderOutlines
                    set folderRowObject to contents of folderRowReference
                    set operationStage to "enumerate-owned-folder-row-elements"
                    set rowElements to UI elements of folderRowObject
                    repeat with folderCellReference in rowElements
                        set folderCellObject to contents of folderCellReference
                        if value of attribute "AXRole" of folderCellObject is "AXCell" then
                            set operationStage to "enumerate-owned-folder-cell-elements"
                            set cellElements to UI elements of folderCellObject
                            repeat with folderNodeReference in cellElements
                                set folderNodeObject to contents of folderNodeReference
                                set operationStage to "read-owned-folder-title"
                                set folderTitles to text fields of folderNodeObject
                                if (count of folderTitles) is 1 then
                                    set folderTitle to value of first item of folderTitles
                                    if folderTitle is folderName then set end of matchingRows to folderRowObject
                                end if
                            end repeat
                        end if
                    end repeat
                end repeat
                set operationStage to "match-owned-folder-row"
                if (count of matchingRows) is not 1 then error "owned folder row is not unique"
                set operationStage to "select-owned-folder-row"
                set ownedFolderRow to first item of matchingRows
                set selected of ownedFolderRow to true
                delay 0.2
            end tell
        end if
        set operationStage to "verify-empty-selection"
        set verifiedFolderNoteCount to count of notes of fixtureFolder
        set verifiedSelectionCount to count of selection
        if verifiedFolderNoteCount is not 0 then error "folder is not empty"
        if verifiedSelectionCount is not 0 then error "selection remains nonempty"
    end tell
    return "fixture_created|" & folderName & "|" & folderID & "|" & ¬
        (verifiedFolderNoteCount as text) & "|" & (verifiedSelectionCount as text)
on error errorMessage number errorNumber
    return "setup_error|" & operationStage & "|" & folderName & "|" & folderID & "|" & (errorNumber as text)
end try
'''
    try:
        output = _osascript(source, runner=runner, application="Notes", include_error_detail=False)
    except RuntimeError as error:
        raise RuntimeError(f"Notes setup failed; fixture candidate {folder_name}, identity unknown: {error}") from error
    try:
        fields = output.split("|", 4)
        if output.startswith("setup_error|"):
            error_fields = output.split("|", 4)
            if len(error_fields) != 5:
                raise ValueError("wrong error field count")
            _, stage, owned_name, owned_id, error_code = error_fields
            allowed_stages = {"launch", "check-existing-selection", "resolve-default-account",
                              "create-owned-folder", "show-owned-folder", "verify-owned-folder-empty",
                              "verify-standard-window", "locate-notes-process", "locate-standard-window", "locate-splitter", "locate-scroll-areas",
                              "locate-folders-outline", "enumerate-owned-folder-rows",
                              "enumerate-owned-folder-row-elements", "enumerate-owned-folder-cell-elements",
                              "read-owned-folder-title", "match-owned-folder-row", "select-owned-folder-row",
                              "verify-empty-selection"}
            if stage not in allowed_stages or owned_name != folder_name:
                raise ValueError("invalid error identity")
            if not error_code.lstrip("-").isdigit():
                raise ValueError("invalid error code")
            raise RuntimeError(f"Notes setup failed at {stage}; owned folder {owned_name}; "
                               f"identity {owned_id or 'not returned'}; AppleScript error {error_code}")
        if len(fields) != 5:
            raise ValueError("wrong field count")
        status, returned_name, returned_id, folder_count, selection_count = fields
        folder_note_count, selected_note_count = int(folder_count), int(selection_count)
        if status == "already_clear":
            if returned_name or returned_id or folder_note_count != 0 or selected_note_count != 0:
                raise ValueError("invalid already-clear receipt")
            return NotesSelectionReceipt(status, None, None, None, 0)
        if (status != "fixture_created" or returned_name != folder_name or not returned_id
                or folder_note_count != 0 or selected_note_count != 0):
            raise ValueError("invalid fixture receipt")
        return NotesSelectionReceipt(status, returned_name, returned_id, folder_note_count, selected_note_count)
    except (ValueError, TypeError) as error:
        raise RuntimeError("Notes eval setup returned an invalid selection receipt") from error


def reset_empty_textedit(runner: Any = subprocess.run, *, monotonic: Any = time.monotonic,
                         sleep: Any = time.sleep, pid_probe: Any = os.kill,
                         quit_if_empty: bool = True) -> TextEditReset:
    process_probe = '''tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is 0 then return "not_running"
    if (count of matchingProcesses) is not 1 then error "TextEdit process identity is ambiguous"
    return (unix id of first item of matchingProcesses) as text
end tell
'''
    output = _osascript(process_probe, runner=runner)
    if output == "not_running":
        return TextEditReset("not_running", None, 0)
    try:
        pid = int(output)
    except ValueError as error:
        raise RuntimeError("TextEdit reset returned an invalid process identity") from error
    if pid <= 0:
        raise RuntimeError("TextEdit reset returned an invalid process identity")

    document_probe = '''tell application id "com.apple.TextEdit"
    set documentCount to count of documents
end tell
'''
    try:
        documents = int(_osascript(document_probe, runner=runner))
    except ValueError as error:
        raise RuntimeError("TextEdit reset returned an invalid document count") from error
    if documents < 0:
        raise RuntimeError("TextEdit reset returned an invalid document count")

    # The app-targeted query can race with termination/relaunch. Require the same
    # unique process before acting on the document count it returned.
    verify_probe = '''tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is not 1 then error "TextEdit process changed during document probe"
    return (unix id of first item of matchingProcesses) as text
end tell
'''
    try:
        verified_pid = int(_osascript(verify_probe, runner=runner))
    except ValueError as error:
        raise RuntimeError("TextEdit reset returned an invalid verified process identity") from error
    if verified_pid != pid:
        raise RuntimeError("TextEdit process changed during document probe")
    if documents:
        return TextEditReset("has_documents", pid, documents)
    if not quit_if_empty:
        return TextEditReset("empty", pid, 0)
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


def dismiss_empty_textedit_open_panel(expected_pid: int, runner: Any = subprocess.run) -> str:
    """Dismiss only TextEdit's standard Open panel when its process has no documents."""
    if type(expected_pid) is not int or expected_pid <= 0:
        raise ValueError("invalid expected TextEdit process identity")
    source = f'''tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is not 1 then error "TextEdit process is not uniquely running"
    set appPID to unix id of first item of matchingProcesses
end tell
if appPID is not {expected_pid} then error "TextEdit process changed before Open panel check"
tell application id "com.apple.TextEdit"
    set documentCount to count of documents
end tell
if documentCount is not 0 then return "has_documents"
tell application "System Events"
    set matchingProcesses to every process whose bundle identifier is "com.apple.TextEdit"
    if (count of matchingProcesses) is not 1 then error "TextEdit process changed before Open panel dismissal"
    set targetProcess to first item of matchingProcesses
    if (unix id of targetProcess) is not {expected_pid} then error "TextEdit process changed before Open panel dismissal"
    set panels to windows of targetProcess whose value of attribute "AXIdentifier" is "open-panel"
    if (count of panels) is 0 then return "no_panel"
    if (count of panels) is not 1 then error "TextEdit Open panel identity is ambiguous"
    set panel to first item of panels
    set panelRole to role of panel
    if panelRole is not "AXWindow" and panelRole is not "AXSheet" then error "TextEdit Open panel has an unexpected role"
    set panelLayouts to splitter groups of panel
    if (count of panelLayouts) is not 1 then error "TextEdit Open panel layout is not unique"
    set panelLayout to first item of panelLayouts
    set cancelButtons to buttons of panelLayout whose value of attribute "AXIdentifier" is "CancelButton"
    if (count of cancelButtons) is not 1 then error "TextEdit Open panel Cancel control count=" & (count of cancelButtons as text)
    if (unix id of targetProcess) is not {expected_pid} then error "TextEdit process changed before Open panel dismissal"
    click first button of panelLayout whose value of attribute "AXIdentifier" is "CancelButton"
end tell
return "dismissed"
'''
    result = _osascript(source, runner=runner)
    if result not in {"has_documents", "no_panel", "dismissed"}:
        raise RuntimeError("TextEdit Open panel check returned an invalid status")
    return result


def lease_json(lease: NativeDocumentLease) -> str:
    """Stable JSON representation for runner checkpoint state."""
    return json.dumps(lease.as_dict(), separators=(",", ":"))
