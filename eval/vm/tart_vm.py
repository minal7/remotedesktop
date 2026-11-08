#!/usr/bin/env python3
"""Fail-closed Tart reset and real-app driver for the private eval VM."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
TART_ROOT = ROOT / "build" / "tart"
RUN_ROOT = ROOT / "build" / "eval" / "vm"
FIXTURE_FILES = ROOT / "eval" / "fixtures" / "files"
GOLDEN_NAME = "general-agent-golden"
APP_COMMAND = "/Applications/RemoteDesktopHost.app/Contents/MacOS/RemoteDesktopHost --debug-agent-eval"
TOKEN_RE = re.compile(r"^[a-f0-9]{32}$")
TASK_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
Run = Callable[..., subprocess.CompletedProcess[str]]


class Blocked(RuntimeError):
    pass


@dataclass(frozen=True)
class Config:
    task_id: str
    token: str
    tart_home: Path
    identity: Path
    known_hosts: Path
    local_eval_root: Path
    guest_user: str
    project_root: str
    remote_eval_root: str

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Config":
        values = os.environ if env is None else env
        task_id, token = values.get("EVAL_TASK_ID", ""), values.get("EVAL_RUN_TOKEN", "")
        if not TASK_RE.fullmatch(task_id) or not TOKEN_RE.fullmatch(token):
            raise Blocked("EVAL_TASK_ID and a 32-character EVAL_RUN_TOKEN are required")
        if values.get("EVAL_TART_GOLDEN") != GOLDEN_NAME:
            raise Blocked(f"EVAL_TART_GOLDEN must be the approved {GOLDEN_NAME!r} image")
        tart_home = _absolute_path(values.get("TART_HOME", ""), "TART_HOME")
        if tart_home != TART_ROOT:
            raise Blocked("TART_HOME must be this checkout's build/tart directory")
        identity = _private_file(values.get("EVAL_VM_SSH_IDENTITY", ""), "EVAL_VM_SSH_IDENTITY")
        known_hosts = _private_file(values.get("EVAL_VM_KNOWN_HOSTS", ""), "EVAL_VM_KNOWN_HOSTS", private=False)
        local_eval_root = _absolute_path(values.get("REMOTE_DESKTOP_EVAL_ROOT", ""), "REMOTE_DESKTOP_EVAL_ROOT")
        allowed_output = (ROOT / "build" / "eval").resolve(strict=False)
        if local_eval_root != allowed_output and not local_eval_root.is_relative_to(allowed_output):
            raise Blocked("REMOTE_DESKTOP_EVAL_ROOT must stay inside this checkout's build/eval")
        secure_dir(local_eval_root)
        guest_user = values.get("EVAL_VM_SSH_USER", "")
        if not USER_RE.fullmatch(guest_user):
            raise Blocked("EVAL_VM_SSH_USER must name the owner-configured guest account")
        project_root = _guest_path(values.get("EVAL_VM_PROJECT_ROOT", ""), "EVAL_VM_PROJECT_ROOT")
        remote_eval_root = _guest_path(values.get("EVAL_VM_REMOTE_EVAL_ROOT", ""), "EVAL_VM_REMOTE_EVAL_ROOT")
        fixture_source = _absolute_path(values.get("EVAL_FIXTURE_FILES", ""), "EVAL_FIXTURE_FILES")
        if fixture_source != FIXTURE_FILES:
            raise Blocked("EVAL_FIXTURE_FILES must point to this checkout's eval/fixtures/files")
        return cls(task_id, token, tart_home, identity, known_hosts, local_eval_root,
                   guest_user, project_root, remote_eval_root)

    @property
    def vm_name(self) -> str:
        return f"general-agent-eval-{self.token}"

    @property
    def state_path(self) -> Path:
        return RUN_ROOT / "state" / f"{self.token}.json"


def _absolute_path(value: str, label: str) -> Path:
    path = Path(value)
    if not value or not path.is_absolute() or "\x00" in value or ".." in path.parts:
        raise Blocked(f"{label} must be a safe absolute path")
    if path.is_symlink():
        raise Blocked(f"{label} may not be a symlink")
    return path.resolve(strict=False)


def _guest_path(value: str, label: str) -> str:
    path = Path(value)
    if not value or not path.is_absolute() or "\x00" in value or ".." in path.parts:
        raise Blocked(f"{label} must be an explicit absolute guest path")
    return str(path)


def _private_file(value: str, label: str, private: bool = True) -> Path:
    path = Path(value)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise Blocked(f"{label} must be an existing regular file, not a symlink")
    info = path.stat()
    if info.st_uid != os.getuid() or (private and info.st_mode & 0o077):
        raise Blocked(f"{label} must be owned by this user and private")
    if not private and info.st_mode & 0o002:
        raise Blocked(f"{label} may not be world-writable")
    return path.resolve(strict=True)


def secure_dir(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Blocked(f"private directory is unsafe: {path}")


def tart_env(config: Config) -> dict[str, str]:
    env = dict(os.environ)
    env["TART_HOME"] = str(config.tart_home)
    env["TART_NO_AUTO_PRUNE"] = "1"
    return env


def ssh_base(config: Config, address: str) -> list[str]:
    host = _ssh_host(address)
    return ["ssh", "-i", str(config.identity), "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-o", "StrictHostKeyChecking=yes",
            "-o", f"HostKeyAlias={GOLDEN_NAME}",
            "-o", f"UserKnownHostsFile={config.known_hosts}", "-o", "ConnectTimeout=5",
            f"{config.guest_user}@{host}"]


def _ssh_host(address: str) -> str:
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError as error:
        raise Blocked("Tart returned an invalid guest IP address") from error
    return f"[{parsed}]" if parsed.version == 6 else str(parsed)


def remote(config: Config, address: str, command: str) -> list[str]:
    return [*ssh_base(config, address), command]


def invoke(argv: list[str], *, env: dict[str, str] | None = None,
           input_text: str | None = None, timeout: float = 30,
           capture_output: bool = True, text: bool = True,
           check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, env=env, input=input_text, capture_output=capture_output,
                          text=text, timeout=timeout, check=check)


def checked(run: Run, argv: list[str], label: str, **kwargs: Any) -> subprocess.CompletedProcess[str]:
    try:
        result = run(argv, **kwargs)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Blocked(f"{label} unavailable: {type(error).__name__}") from error
    if result.returncode:
        raise Blocked(f"{label} failed ({result.returncode})")
    return result


def reset_commands(config: Config) -> list[list[str]]:
    name = config.vm_name
    return [["tart", "clone", GOLDEN_NAME, name],
            ["tart", "set", name, "--cpu", "4", "--memory", "16384",
             "--display", "1440x900px", "--no-display-refit"],
            ["tart", "run", "--no-graphics", "--no-audio", "--no-usb-accessories", "--no-clipboard", name]]


def _write_state(config: Config, pid: int, *, replace: bool = False) -> None:
    secure_dir(RUN_ROOT)
    secure_dir(config.state_path.parent)
    if not replace and (config.state_path.exists() or config.state_path.is_symlink()):
        raise Blocked("a state record already exists for this run token")
    temp = config.state_path.with_name(f".{config.token}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump({"task_id": config.task_id, "token": config.token,
                   "vm_name": config.vm_name, "pid": pid}, stream, separators=(",", ":"))
        stream.write("\n")
    if not replace and config.state_path.exists():
        temp.unlink(missing_ok=True)
        raise Blocked("a state record already exists for this run token")
    temp.replace(config.state_path)


def _read_state(config: Config) -> dict[str, Any]:
    path = config.state_path
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise Blocked("matching private reset state is missing or unsafe")
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise Blocked("reset state is unreadable") from error
    expected = {"task_id": config.task_id, "token": config.token, "vm_name": config.vm_name}
    if not isinstance(state, dict) or any(state.get(key) != value for key, value in expected.items()):
        raise Blocked("reset state does not match this task and run token")
    return state


def _guest_setup_command(config: Config) -> str:
    project = shlex.quote(config.project_root)
    eval_root = shlex.quote(config.remote_eval_root)
    server = shlex.quote(f"{config.project_root}/eval/fixtures/web/server.py")
    return (f"test -f {server} && test -d {project}/eval/fixtures/files && "
            f"test ! -L {eval_root} && mkdir -p {eval_root} && test ! -L {eval_root} && "
            f"chmod 700 {eval_root} && "
            f"(nohup python3 {server} >/dev/null 2>&1 </dev/null &)")


def reset(config: Config, run: Run = invoke, *, dry_run: bool = False,
          launch_process: Callable[..., Any] = subprocess.Popen) -> dict[str, Any]:
    if shutil.which("tart") is None and run is invoke:
        raise Blocked("Tart is not installed")
    if dry_run:
        return {"commands": reset_commands(config), "guest_setup": _guest_setup_command(config),
                "ssh_options": ssh_base(config, "192.0.2.1")[1:-1]}
    list_result = checked(run, ["tart", "list", "--quiet"], "Tart inventory", env=tart_env(config))
    if config.vm_name in list_result.stdout.splitlines():
        raise Blocked("owned VM name already exists; refusing to overwrite it")
    if GOLDEN_NAME not in list_result.stdout.splitlines():
        raise Blocked("approved golden VM is not present in the configured Tart home")
    clone, configure, launch = reset_commands(config)
    if config.state_path.exists() or config.state_path.is_symlink():
        raise Blocked("reset state already exists for this token")
    checked(run, clone, "golden clone", env=tart_env(config))
    try:
        _write_state(config, 0)
        checked(run, configure, "VM resource configuration", env=tart_env(config))
        process = launch_process(launch, env=tart_env(config), stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
        _write_state(config, process.pid, replace=True)
        ip_result = checked(run, ["tart", "ip", config.vm_name, "--wait", "300"],
                            "VM address", env=tart_env(config), timeout=310)
        address = ip_result.stdout.strip()
        _ssh_host(address)
        config_cmd = remote(config, address, "true")
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            probe = run(config_cmd, capture_output=True, text=True, timeout=8, check=False)
            if probe.returncode == 0:
                break
            time.sleep(2)
        else:
            raise Blocked("owner-configured SSH key could not reach the guest")
        checked(run, remote(config, address, _guest_setup_command(config)), "guest fixture setup", timeout=30)
        health = remote(config, address, "curl --fail --silent http://127.0.0.1:8765/__eval/health")
        for _ in range(30):
            probe = run(health, capture_output=True, text=True, timeout=8, check=False)
            if probe.returncode == 0 and '"ok":true' in probe.stdout:
                return {"vm": config.vm_name, "address": address}
            time.sleep(1)
        raise Blocked("guest fixture server did not become healthy")
    except Exception:
        cleanup_vm(config, run, ownership_confirmed=True)
        raise


def cleanup_vm(config: Config, run: Run = invoke, *, ownership_confirmed: bool = False) -> None:
    name = config.vm_name
    if config.state_path.is_file() and not config.state_path.is_symlink():
        try:
            state = json.loads(config.state_path.read_text(encoding="utf-8"))
            if state.get("vm_name") != name or state.get("token") != config.token:
                return
        except (OSError, json.JSONDecodeError):
            if not ownership_confirmed:
                return
        run(["tart", "stop", name], env=tart_env(config), capture_output=True, text=True, timeout=60, check=False)
        run(["tart", "delete", name], env=tart_env(config), capture_output=True, text=True, timeout=60, check=False)
        config.state_path.unlink(missing_ok=True)
    elif ownership_confirmed:
        run(["tart", "stop", name], env=tart_env(config), capture_output=True, text=True, timeout=60, check=False)
        run(["tart", "delete", name], env=tart_env(config), capture_output=True, text=True, timeout=60, check=False)


def _guest_state(config: Config, address: str, run: Run) -> dict[str, Any] | None:
    url = f"http://127.0.0.1:8765/__eval/state?token={config.token}"
    result = run(remote(config, address, f"curl --fail --silent {shlex.quote(url)}"),
                 capture_output=True, text=True, timeout=15, check=False)
    if result.returncode:
        return None
    try:
        state = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(state, dict) or not isinstance(state.get("elements"), dict):
        return None
    return {**state, "run_token": config.token}


def _safe_task_response(response: Any, request: dict[str, Any]) -> dict[str, Any]:
    required = {"task_id", "outcome", "answer", "episode_path", "wall_seconds", "real_host_app", "environment", "policy"}
    if not isinstance(response, dict) or not required <= response.keys():
        raise Blocked("guest app returned an invalid response object")
    if response["task_id"] != request.get("task_id") or response["real_host_app"] is not True:
        raise Blocked("guest response did not match the real host app request")
    if response["environment"] != "pixel" or response["policy"] != request.get("policy"):
        raise Blocked("guest response environment or policy did not match the request")
    if not all(isinstance(response[key], str) for key in ("outcome", "answer", "episode_path")):
        raise Blocked("guest app response fields have invalid types")
    return response


def _safe_preflight_response(response: Any) -> dict[str, Any]:
    required = {"operation", "real_host_app", "outcome", "checks", "active_environment", "policy"}
    if not isinstance(response, dict) or not required <= response.keys():
        raise Blocked("guest app returned an invalid preflight response")
    if response["operation"] != "preflight" or response["real_host_app"] is not True:
        raise Blocked("guest response did not prove the real host preflight")
    if response["outcome"] not in {"ready", "infra_blocked"} or not isinstance(response["checks"], list):
        raise Blocked("guest preflight fields have invalid types")
    if response["active_environment"] != "pixel" or response["policy"] not in {"fara15-4b", "ui-tars15-7b", "none"}:
        raise Blocked("guest preflight model or environment is invalid")
    if response["outcome"] == "infra_blocked":
        if not all(isinstance(response.get(key), str) and response[key]
                   for key in ("blocked_reason", "owner_action")):
            raise Blocked("blocked guest preflight omitted its reason or owner action")
    else:
        if response.get("model_status") != "loaded":
            raise Blocked("ready guest preflight omitted model readiness")
    return response


def _episode_guest_path(config: Config, request: dict[str, Any], response: dict[str, Any]) -> str:
    path = Path(response["episode_path"])
    task_id = request.get("task_id")
    if not isinstance(task_id, str) or not TASK_RE.fullmatch(task_id):
        raise Blocked("request task_id is invalid")
    expected = Path(config.remote_eval_root) / "<run-id>" / "episodes" / task_id / "episode.jsonl"
    if not path.is_absolute() or path.name != "episode.jsonl" or path.parent.name != task_id:
        raise Blocked("guest episode path is outside the expected run layout")
    if path.parent.parent.parent.parent != Path(config.remote_eval_root):
        raise Blocked("guest episode path escapes the private eval root")
    try:
        uuid.UUID(path.parent.parent.parent.name)
    except ValueError as error:
        raise Blocked("guest episode run directory is not a UUID") from error
    if str(path) != str(expected).replace("<run-id>", path.parent.parent.parent.name):
        raise Blocked("guest episode path is malformed")
    return str(path)


def _export_episode(config: Config, address: str, guest_path: str, run: Run) -> Path:
    guest_directory = str(Path(guest_path).parent)
    check = remote(config, address, f"test -f {shlex.quote(guest_path)} && "
                   f"test ! -L {shlex.quote(guest_path)} && "
                   f"test ! -L {shlex.quote(guest_directory)}")
    checked(run, check, "guest episode verification", timeout=15)
    run_id = Path(guest_path).parent.parent.parent.name
    destination = config.local_eval_root / run_id / "episodes" / Path(guest_path).parent.name
    secure_dir(config.local_eval_root)
    secure_dir(config.local_eval_root / run_id)
    secure_dir(destination.parent)
    if destination.exists() or destination.is_symlink():
        raise Blocked("local episode destination already exists")
    source = f"{config.guest_user}@{_ssh_host(address)}:{guest_directory}"
    scp = ["scp", "-r", "-i", str(config.identity), "-o", "IdentitiesOnly=yes",
           "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
           "-o", f"HostKeyAlias={GOLDEN_NAME}",
           "-o", f"UserKnownHostsFile={config.known_hosts}", source, str(destination)]
    checked(run, scp, "private episode transfer", timeout=120)
    if destination.is_symlink() or not destination.is_dir() or destination.stat().st_uid != os.getuid():
        raise Blocked("exported episode directory is missing or unsafe")
    destination.chmod(0o700)
    secure_dir(destination)
    episode = destination / "episode.jsonl"
    if episode.is_symlink() or not episode.is_file():
        raise Blocked("exported episode is missing or unsafe")
    for path in destination.iterdir():
        if path.is_symlink() or (path.name != "episode.jsonl" and not re.fullmatch(r"step-\d{3}\.png", path.name)):
            raise Blocked("exported episode directory contains an unexpected entry")
        if path.is_file() and path.stat().st_mode & 0o077:
            path.chmod(0o600)
    return episode


def drive(config: Config, run: Run = invoke, *, request_text: str | None = None) -> dict[str, Any]:
    _read_state(config)
    try:
        if request_text is None:
            request_text = sys.stdin.read()
        try:
            request = json.loads(request_text)
        except json.JSONDecodeError as error:
            raise Blocked("driver input must be one JSON request") from error
        if not isinstance(request, dict):
            raise Blocked("driver input request is invalid")
        if request.get("operation") == "preflight":
            if (set(request) - {"operation", "probe_url", "policy"}
                    or not isinstance(request.get("probe_url"), str)
                    or request.get("policy", "fara15-4b") not in {"fara15-4b", "ui-tars15-7b"}):
                raise Blocked("preflight input request is invalid")
            return _drive_preflight(config, request_text, request, run)
        if not isinstance(request.get("task_id"), str):
            raise Blocked("driver input request is invalid")
        address_result = checked(run, ["tart", "ip", config.vm_name], "VM address", env=tart_env(config))
        address = address_result.stdout.strip()
        _ssh_host(address)
        command = (f"REMOTE_DESKTOP_EVAL_ROOT={shlex.quote(config.remote_eval_root)} "
                   f"{APP_COMMAND}")
        app_result = checked(run, remote(config, address, command), "real host app", input_text=request_text,
                             timeout=1800)
        try:
            response = _safe_task_response(json.loads(app_result.stdout), request)
        except json.JSONDecodeError as error:
            raise Blocked("guest app stdout was not one JSON object") from error
        guest_path = _episode_guest_path(config, request, response)
        episode = _export_episode(config, address, guest_path, run)
        response["episode_path"] = str(episode)
        response["fixture_state"] = _guest_state(config, address, run)
        _read_state(config)
        response["vm_execution"] = {"engine": "tart", "golden": GOLDEN_NAME,
                                     "vm_name": config.vm_name, "run_token": config.token,
                                     "reset_state": "verified"}
        return response
    finally:
        cleanup_vm(config, run)


def _drive_preflight(config: Config, request_text: str, request: dict[str, Any], run: Run) -> dict[str, Any]:
    address_result = checked(run, ["tart", "ip", config.vm_name], "VM address", env=tart_env(config))
    address = address_result.stdout.strip()
    _ssh_host(address)
    app_command = f"REMOTE_DESKTOP_EVAL_ROOT={shlex.quote(config.remote_eval_root)} {APP_COMMAND}"
    app_result = checked(run, remote(config, address, app_command), "real host preflight",
                         input_text=request_text, timeout=1800)
    try:
        response = _safe_preflight_response(json.loads(app_result.stdout))
    except json.JSONDecodeError as error:
        raise Blocked("guest app stdout was not one preflight JSON object") from error
    if response["policy"] != request.get("policy", "fara15-4b"):
        raise Blocked("guest preflight policy did not match the request")
    response["vm_execution"] = {"engine": "tart", "golden": GOLDEN_NAME,
                                "vm_name": config.vm_name, "run_token": config.token,
                                "reset_state": "verified"}
    return response


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("reset", "driver"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        config = Config.from_env()
        if args.mode == "reset":
            result = reset(config, dry_run=args.dry_run)
        else:
            if args.dry_run:
                raise Blocked("driver dry-run is not an execution result")
            result = drive(config)
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except Blocked as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
