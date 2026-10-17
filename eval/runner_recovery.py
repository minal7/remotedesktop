"""Crash-safe lifecycle and local-input recovery helpers for real-host evals.

This module deliberately does not know about the suite driver. The caller owns
task execution and marks a task complete only after its final attempt.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import math
import os
import signal
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Iterable


class RecoveryError(RuntimeError):
    """A fail-closed lifecycle or Mac-state check failed."""


class RunnerAlreadyActive(RecoveryError):
    pass


class ScreenLocked(RecoveryError):
    pass


class MacStateUnknown(RecoveryError):
    pass


def _mac_state_probe(timeout: float = 8.0) -> dict[str, Any]:
    """Read lock state and physical HID idle time through Quartz/CoreGraphics."""
    source = r'''import ApplicationServices
import Foundation
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
guard let session = session,
      let onConsole = session["kCGSSessionOnConsoleKey"] as? NSNumber,
      let loginDone = session["kCGSessionLoginDoneKey"] as? NSNumber,
      onConsole.intValue == 1 && loginDone.intValue == 1 else { exit(21) }
let locked: Bool
if let lockValue = session["CGSSessionScreenIsLocked"] {
    guard let number = lockValue as? NSNumber else { exit(23) }
    locked = number.boolValue
} else {
    locked = false
}
let idle = CGEventSource.secondsSinceLastEventType(
    .hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
guard idle.isFinite && idle >= 0 else { exit(22) }
print("{\"locked\":\(locked ? "true" : "false"),\"idle_seconds\":\(idle)}")
'''
    try:
        result = subprocess.run(["/usr/bin/swift", "-e", source], capture_output=True,
                                text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MacStateUnknown(f"Mac state probe failed: {type(error).__name__}") from error
    if result.returncode != 0:
        raise MacStateUnknown("Mac state probe could not verify screen lock and HID idle state")
    try:
        payload = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError) as error:
        raise MacStateUnknown("Mac state probe returned invalid data") from error
    if (not isinstance(payload, dict) or type(payload.get("locked")) is not bool
            or isinstance(payload.get("idle_seconds"), bool)
            or not isinstance(payload.get("idle_seconds"), (int, float))
            or not math.isfinite(payload["idle_seconds"]) or payload["idle_seconds"] < 0):
        raise MacStateUnknown("Mac state probe returned incomplete data")
    return payload


def screen_unlocked() -> bool:
    state = _mac_state_probe()
    if state["locked"]:
        raise ScreenLocked("OWNER ACTION NEEDED: unlock the Mac")
    return True


def local_idle_seconds() -> float:
    state = _mac_state_probe()
    if state["locked"]:
        raise ScreenLocked("OWNER ACTION NEEDED: unlock the Mac")
    return float(state["idle_seconds"])


class RunnerLifecycle:
    """Single-runner lock and child caffeinate assertion for a suite lifetime."""

    def __init__(self, output: Path, *, popen: Callable[..., Any] = subprocess.Popen,
                 screen_probe: Callable[[], bool] = screen_unlocked,
                 idle_probe: Callable[[], float] = local_idle_seconds,
                 sleep: Callable[[float], None] = time.sleep,
                 idle_seconds: float = 60.0, poll_seconds: float = 60.0,
                 caffeinate: str = "/usr/bin/caffeinate", global_lock: bool = True) -> None:
        if idle_seconds <= 0 or poll_seconds <= 0:
            raise ValueError("idle and poll intervals must be positive")
        self.output = Path(output)
        self.popen = popen
        self.screen_probe = screen_probe
        self.idle_probe = idle_probe
        self.sleep = sleep
        self.idle_seconds = idle_seconds
        self.poll_seconds = poll_seconds
        self.caffeinate = caffeinate
        self.global_lock = global_lock
        self._lock_streams: list[Any] = []
        self._assertion: Any = None

    def __enter__(self) -> "RunnerLifecycle":
        self.output.mkdir(parents=True, exist_ok=True)
        lock_paths = []
        if self.global_lock:
            lock_root = Path(tempfile.gettempdir())
            lock_paths.append(lock_root / f"remote-desktop-eval-{os.getuid()}.lock")
        lock_paths.append(self.output / ".runner.lock")
        try:
            for lock_path in lock_paths:
                flags = os.O_CREAT | os.O_RDWR
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                try:
                    fd = os.open(lock_path, flags, 0o600)
                except OSError as error:
                    raise RecoveryError(f"could not open safe runner lock file: {lock_path}") from error
                info = os.fstat(fd)
                if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
                    os.close(fd)
                    raise RecoveryError(f"unsafe runner lock file: {lock_path}")
                os.fchmod(fd, 0o600)
                stream = os.fdopen(fd, "a+")
                try:
                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    stream.close()
                    raise RunnerAlreadyActive("another suite runner holds a real-host or output lock") from error
                self._lock_streams.append(stream)
        except BaseException:
            self._release()
            raise
        try:
            self._assertion = self.popen([self.caffeinate, "-dimsu", "-w", str(os.getpid())],
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
            if getattr(self._assertion, "poll", lambda: None)() is not None:
                raise RecoveryError("caffeinate exited before the suite started")
        except BaseException:
            self._release()
            raise
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self._release()

    def _release(self) -> None:
        process, self._assertion = self._assertion, None
        if process is not None:
            try:
                process.terminate()
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            except ProcessLookupError:
                pass
        while self._lock_streams:
            stream = self._lock_streams.pop()
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
            stream.close()

    def check_screen_unlocked(self) -> None:
        try:
            unlocked = self.screen_probe()
        except (ScreenLocked, MacStateUnknown):
            raise
        except Exception as error:
            raise MacStateUnknown("screen lock state could not be verified") from error
        if unlocked is not True:
            raise ScreenLocked("OWNER ACTION NEEDED: unlock the Mac")

    def wait_for_local_idle(self) -> None:
        """Wait for a fresh, continuous 60-second physical-HID idle interval."""
        while True:
            self.check_screen_unlocked()
            try:
                idle = self.idle_probe()
            except (ScreenLocked, MacStateUnknown):
                raise
            except Exception as error:
                raise MacStateUnknown("local idle state could not be verified") from error
            if isinstance(idle, bool) or not isinstance(idle, (int, float)) or idle < 0:
                raise MacStateUnknown("local idle probe returned an invalid value")
            if idle >= self.idle_seconds:
                return
            self.sleep(min(self.poll_seconds, max(0.05, self.idle_seconds - idle)))


class Checkpoint:
    """Atomic, restartable task results plus a separate interruption history."""

    def __init__(self, output: Path, task_keys: Iterable[str]) -> None:
        self.output = Path(output)
        self.path = self.output / "checkpoint.json"
        self.interruptions_path = self.output / "interrupted_attempts.json"
        self.task_keys = list(task_keys)
        if len(self.task_keys) != len(set(self.task_keys)):
            raise ValueError("checkpoint task keys must be unique")
        self.completed: dict[str, dict[str, Any]] = {}
        self.interrupted_attempts: list[dict[str, Any]] = []
        self.inflight: dict[str, dict[str, Any]] = {}
        self._cleanup: dict[str, dict[str, Any]] = {}
        self._load()

    def _load(self) -> None:
        if self.path.exists():
            try:
                value = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise RecoveryError("checkpoint is unreadable; refusing to rerun completed tasks") from error
            if (not isinstance(value, dict) or value.get("version") != 1
                    or value.get("task_keys") != self.task_keys
                    or not isinstance(value.get("completed"), dict)):
                raise RecoveryError("checkpoint does not match the requested task sequence")
            completed = value["completed"]
            if any(key not in self.task_keys or not isinstance(row, dict) for key, row in completed.items()):
                raise RecoveryError("checkpoint contains invalid completed task rows")
            self.completed = completed
            inflight = value.get("inflight", {})
            if not isinstance(inflight, dict) or any(key not in self.task_keys or not isinstance(row, dict)
                                                     for key, row in inflight.items()):
                raise RecoveryError("checkpoint contains invalid in-flight task state")
            self.inflight = inflight
            cleanup = value.get("cleanup_pending", {})
            if not isinstance(cleanup, dict) or any(key not in self.task_keys or not isinstance(row, dict)
                                                    for key, row in cleanup.items()):
                raise RecoveryError("checkpoint contains invalid pending cleanup state")
            self._cleanup = cleanup
        if self.interruptions_path.exists():
            try:
                records = json.loads(self.interruptions_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise RecoveryError("interruption history is unreadable") from error
            if not isinstance(records, list) or any(not isinstance(row, dict) for row in records):
                raise RecoveryError("interruption history has invalid data")
            self.interrupted_attempts = records

    def is_completed(self, task_key: str) -> bool:
        return task_key in self.completed

    def rows(self) -> list[dict[str, Any]]:
        return [self.completed[key] for key in self.task_keys if key in self.completed]

    def pending_local_input_decision(self, task_key: str) -> str | None:
        """Return the durable recovery action after a crash around an input pause."""
        if task_key in self.completed:
            return None
        attempts = [row for row in self.interrupted_attempts
                    if row.get("task_key") == task_key and row.get("kind", "local-input") == "local-input"]
        if not attempts:
            return None
        return "wait-and-retry" if attempts[-1].get("retry_allowed") is True else "terminal-interrupted"

    def record_interruption(self, attempt: dict[str, Any]) -> bool:
        record = dict(attempt)
        task_key = record.get("task_key")
        if task_key not in self.task_keys:
            raise RecoveryError("interrupted attempt has an unknown task key")
        record.setdefault("kind", "local-input")
        number = 1 + sum(item.get("task_key") == task_key and item.get("kind", "local-input") == "local-input"
                         for item in self.interrupted_attempts)
        record["attempt_number"] = number
        record["retry_allowed"] = record["kind"] != "local-input" or number == 1
        self.interrupted_attempts.append(record)
        self._atomic_json(self.interruptions_path, self.interrupted_attempts)
        self.inflight.pop(task_key, None)
        self._save()
        return record["retry_allowed"]

    def record_abandoned_inflight(self) -> list[dict[str, Any]]:
        """Persist attempts left in-flight by a process crash or reboot."""
        abandoned = []
        for task_key, state in list(self.inflight.items()):
            record = {**state, "task_key": task_key, "kind": "abandoned-after-runner-stop"}
            self.record_interruption(record)
            abandoned.append(record)
        return abandoned

    def mark_inflight(self, task_key: str, attempt_id: str) -> None:
        if task_key not in self.task_keys:
            raise RecoveryError(f"unknown task key {task_key!r}")
        self.inflight[task_key] = {"attempt_id": attempt_id, "started_at": time.time()}
        self._save()

    def mark_completed(self, task_key: str, row: dict[str, Any]) -> None:
        if task_key not in self.task_keys:
            raise RecoveryError(f"unknown task key {task_key!r}")
        self.completed[task_key] = dict(row)
        self.inflight.pop(task_key, None)
        self._save()

    def mark_cleanup_pending(self, task_key: str, cleanup: dict[str, Any]) -> None:
        """Persist fixture cleanup independently, so resume can retry it without task replay."""
        if task_key not in self.task_keys or not isinstance(cleanup, dict):
            raise RecoveryError("cleanup must belong to a known task")
        self._cleanup[task_key] = dict(cleanup)
        self._save()

    def cleanup_pending(self) -> dict[str, dict[str, Any]]:
        return {key: dict(value) for key, value in self._cleanup.items()}

    def clear_cleanup_pending(self, task_key: str) -> None:
        self._cleanup.pop(task_key, None)
        self._save()

    def _save(self) -> None:
        self._atomic_json(self.path, {"version": 1, "task_keys": self.task_keys,
                                      "completed": self.completed, "inflight": self.inflight,
                                      "cleanup_pending": self._cleanup})

    @staticmethod
    def _atomic_json(path: Path, value: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(value, stream, indent=2, ensure_ascii=False)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def pin_run_identity(output: Path, driver_command: list[str], tasks: Iterable[Any], policy: str) -> dict[str, str]:
    """Bind a resumable output directory to the same driver, tasks, and policy."""
    if not driver_command or not policy:
        raise RecoveryError("driver command and policy are required to pin a run")
    binary = Path(driver_command[0]).expanduser()
    resolved = shutil.which(str(binary)) if not binary.is_absolute() else str(binary)
    if not resolved or not Path(resolved).is_file():
        raise RecoveryError("could not resolve driver binary for resume identity")
    driver_sha = hashlib.sha256(Path(resolved).read_bytes()).hexdigest()
    argv_sha = hashlib.sha256(json.dumps(driver_command, ensure_ascii=False,
                                         separators=(",", ":")).encode()).hexdigest()
    task_values = [item.value if hasattr(item, "value") else item for item in tasks]
    task_sha = hashlib.sha256(json.dumps(task_values, sort_keys=True, ensure_ascii=False,
                                         separators=(",", ":")).encode()).hexdigest()
    identity = {"driver_sha256": driver_sha, "driver_argv_sha256": argv_sha,
                "tasks_sha256": task_sha, "policy": policy}
    path = Path(output) / "run_identity.json"
    if path.exists():
        try:
            prior = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RecoveryError("run identity is unreadable; refusing to resume") from error
        if prior != identity:
            raise RecoveryError("driver, task list, or policy changed; refusing to mix results on resume")
    else:
        Checkpoint._atomic_json(path, identity)
    return identity


def is_local_input_interruption(response: dict[str, Any] | None, row: dict[str, Any] | None = None) -> bool:
    """Match the host's explicit local-input pause message without classifying model failures."""
    fragments = ["control of the mac changed", "control of the mac has changed"]
    for value in (response or {}, row or {}):
        for field in ("outcome", "answer", "reason", "error", "failure_class", "status", "checker"):
            text = value.get(field)
            if isinstance(text, (dict, list)):
                text = json.dumps(text, ensure_ascii=False)
            if isinstance(text, str) and any(fragment in text.casefold() for fragment in fragments):
                return True
    return False


def launch_detached(command: list[str], *, log_path: Path, cwd: Path,
                    popen: Callable[..., Any] = subprocess.Popen) -> int:
    """Start a detached supervisor process with its own append-only log."""
    if not command:
        raise ValueError("detached command must not be empty")
    Path(log_path).parent.mkdir(parents=True, exist_ok=True)
    with Path(log_path).open("ab", buffering=0) as log:
        process = popen(command, cwd=str(cwd), stdin=subprocess.DEVNULL,
                        stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                        close_fds=True)
    return int(process.pid)


def _checkpoint_is_complete(output: Path | None) -> bool:
    if output is None:
        return False
    path = output / "checkpoint.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    keys, completed = value.get("task_keys"), value.get("completed")
    cleanup = value.get("cleanup_pending", {})
    return (isinstance(keys, list) and bool(keys) and isinstance(completed, dict)
            and isinstance(cleanup, dict) and not cleanup and set(keys) <= completed.keys())


def _command_output(command: list[str]) -> Path | None:
    found = []
    index = 0
    while index < len(command):
        value = command[index]
        if value == "--output":
            if index + 1 >= len(command):
                raise RecoveryError("child --output is missing its path")
            found.append(Path(command[index + 1]).expanduser().resolve(strict=False))
            index += 2
            continue
        if value.startswith("--output="):
            found.append(Path(value.split("=", 1)[1]).expanduser().resolve(strict=False))
        index += 1
    if len(set(found)) > 1:
        raise RecoveryError("child command contains conflicting --output paths")
    return found[0] if found else None


def _command_for_checkpoint(command: list[str], output: Path) -> list[str]:
    """Pin the child to one output and enable resume only after its checkpoint exists."""
    target = Path(output).expanduser().resolve(strict=False)
    child_output = _command_output(command)
    if child_output is not None and child_output != target:
        raise RecoveryError("supervisor and child --output paths must match")
    cleaned: list[str] = []
    index = 0
    while index < len(command):
        value = command[index]
        if value == "--resume":
            index += 1
            continue
        if value == "--output":
            index += 2
            continue
        if value.startswith("--output="):
            index += 1
            continue
        cleaned.append(value)
        index += 1
    cleaned.extend(["--output", str(target)])
    if (target / "checkpoint.json").is_file():
        cleaned.append("--resume")
    return cleaned


def _run_child(command: list[str], timeout: float | None) -> Any:
    """Run as a process group so deadline expiry reaps workers as well as the CLI."""
    process = subprocess.Popen(command, start_new_session=True)
    try:
        code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return type("Completed", (), {"returncode": 124})()
    return type("Completed", (), {"returncode": code})()


def supervise(command: list[str], *, log_stream: Any, max_restarts: int = 12,
              base_delay: float = 5.0, max_delay: float = 300.0,
              output: Path | None = None, deadline_seconds: float | None = None,
              run: Callable[..., Any] | None = None,
              screen_probe: Callable[[], bool] = screen_unlocked,
              sleep: Callable[[float], None] = time.sleep) -> int:
    """Restart a checkpoint-aware suite after blockers/process crashes, boundedly."""
    if max_restarts < 0 or base_delay < 0 or max_delay < base_delay:
        raise ValueError("invalid supervisor retry bounds")
    restarts = 0
    deadline = time.monotonic() + deadline_seconds if deadline_seconds is not None else None

    def pause(delay: float) -> None:
        if deadline is not None:
            delay = min(delay, max(0.0, deadline - time.monotonic()))
        if delay > 0:
            sleep(delay)

    while True:
        if deadline is not None and time.monotonic() >= deadline:
            print("Supervisor deadline reached; checkpoint retained for resume.", file=log_stream, flush=True)
            return 124
        try:
            screen_probe()
        except ScreenLocked:
            print("OWNER ACTION NEEDED: unlock the Mac", file=log_stream, flush=True)
            pause(min(max_delay, base_delay * (2 ** min(restarts, 8))))
            continue
        except Exception as error:
            print(f"OWNER ACTION NEEDED: Mac lock state unavailable ({type(error).__name__})",
                  file=log_stream, flush=True)
            pause(min(max_delay, base_delay * (2 ** min(restarts, 8))))
            continue
        remaining = max(0.0, deadline - time.monotonic()) if deadline is not None else None
        child_command = _command_for_checkpoint(command, output) if output is not None else list(command)
        result = run(child_command, remaining) if run is not None else _run_child(child_command, remaining)
        code = int(result.returncode)
        if code == 0 or _checkpoint_is_complete(output):
            return code
        if restarts >= max_restarts:
            print(f"Supervisor stopped after {restarts} restarts (last exit {code}).",
                  file=log_stream, flush=True)
            return code
        restarts += 1
        delay = min(max_delay, base_delay * (2 ** min(restarts - 1, 8)))
        print(f"Suite exited {code}; resuming from checkpoint in {delay:g}s "
              f"(restart {restarts}/{max_restarts}).", file=log_stream, flush=True)
        pause(delay)


def main(argv: list[str] | None = None) -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="Detached checkpoint-aware eval suite supervisor")
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--output", type=Path, help="fixed suite output directory for all child restarts")
    parser.add_argument("--resume", action="store_true", help="resume the output checkpoint when one exists")
    parser.add_argument("--max-restarts", type=int, default=12)
    parser.add_argument("--deadline-seconds", type=float, default=3600)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provide a command after --")
    try:
        child_output = _command_output(command)
        if args.output is None:
            args.output = child_output
        elif child_output is not None and child_output != args.output.expanduser().resolve(strict=False):
            parser.error("--output must match the child command's --output path")
        if args.output is None:
            parser.error("provide --output or include --output PATH in the child command")
        args.output = args.output.expanduser().resolve(strict=False)
    except RecoveryError as error:
        parser.error(str(error))
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("a", encoding="utf-8") as log:
        return supervise(command, log_stream=log, max_restarts=args.max_restarts,
                         output=args.output, deadline_seconds=args.deadline_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
