#!/usr/bin/env python3
"""Run one isolated Debug latency host, yielding to release QA."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
BUILD_ROOT = ROOT / 'build/latency'
BUNDLE_ID = 'com.threadmark.remotedesktop.host.debug'


def validate_bundle(path):
    app = path.resolve(strict=True)
    if not app.is_dir() or not app.is_relative_to(BUILD_ROOT.resolve()):
        raise ValueError('Host must be an app inside this worktree build/latency.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != 'RemoteDesktopHost':
        raise ValueError('Host must be the expected Debug bundle and executable.')
    executable = (app / 'Contents/MacOS/RemoteDesktopHost').resolve(strict=True)
    if not executable.is_file() or not executable.is_relative_to(app):
        raise ValueError('Host executable must be inside the validated app bundle.')
    return app, executable


def validate_entitlements(app):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', '--xml', str(app)],
                            capture_output=True, check=True, timeout=15)
    entitlements = plistlib.loads(result.stdout)
    if entitlements.get('com.apple.developer.icloud-container-environment') != 'Development':
        raise ValueError('Host must have signed Development iCloud entitlements.')
    if 'iCloud.com.threadmark.remotedesktop' not in entitlements.get('com.apple.developer.icloud-container-identifiers', []):
        raise ValueError('Host lacks the expected signed iCloud container.')


def running_pids_with_executable(executable):
    # proc_pidpath is read-only and checks actual executable identity rather
    # than an ambiguous process name or a command-line substring.
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libproc.proc_listallpids.restype = ctypes.c_int
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    for _ in range(3):
        count = libproc.proc_listallpids(None, 0)
        if count <= 0:
            raise RuntimeError('Could not enumerate local process identities.')
        capacity = count + 1024
        pids = (ctypes.c_int * capacity)()
        found = libproc.proc_listallpids(pids, ctypes.sizeof(pids))
        if found < 0:
            raise RuntimeError('Could not enumerate local process identities.')
        if found >= capacity:
            continue
        matches = []
        for pid in pids[:found]:
            buffer = ctypes.create_string_buffer(4096)
            if pid > 0 and libproc.proc_pidpath(pid, buffer, len(buffer)) > 0:
                try:
                    if Path(os.fsdecode(buffer.value)).resolve() == executable:
                        matches.append(pid)
                except (OSError, ValueError):
                    continue
        return matches
    raise RuntimeError('Process list changed too quickly to check safely.')


def normalized_host_id(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        raise ValueError('Host ID must be a canonical UUID.') from None
    if len(value) != 36 or str(parsed) != value.lower():
        raise ValueError('Host ID must be a canonical UUID.')
    return str(parsed).upper()


def write_state(path, **state):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, sort_keys=True) + '\n')
    os.replace(temporary, path)


def ignore_sigint():
    signal.signal(signal.SIGINT, signal.SIG_IGN)


def guarded_run(args):
    host_id = normalized_host_id(args.host_id)
    if args.qa_flag.exists():
        raise ValueError('Release QA is active; host not started.')
    app, executable = validate_bundle(args.host_app)
    validate_entitlements(app)
    if running_pids_with_executable(executable):
        raise ValueError('The exact Debug host executable is already running.')
    if args.qa_flag.exists():
        raise ValueError('Release QA is active; host not started.')
    args.output.mkdir(parents=False, exist_ok=False)
    state = args.output / 'state.json'
    log_path = args.output / 'host.log'
    pending = 0
    child = None

    def cancel(signum, _frame):
        nonlocal pending
        # Do not raise inside Popen: first retain its returned process handle.
        pending = pending or signum

    old_handlers = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        env = os.environ.copy()
        # Host supports F2/F3, but only an authenticated replacement request
        # chooses them. Client selection remains the controller's responsibility.
        env.update({'REMOTE_DESKTOP_LATENCY_HOST_ID': host_id, 'LATENCY_LAB': '1',
                    'LATENCY_LAB_F1': '0', 'LATENCY_LAB_F2': '1',
                    'LATENCY_LAB_F3': '1', 'LATENCY_LAB_F4': '0'})
        env.pop('REMOTE_DESKTOP_R0_HOST_ID', None)
        with log_path.open('wb') as log:
            if pending or args.qa_flag.exists():
                raise RuntimeError('Cancelled before the Debug host started.')
            child = subprocess.Popen([str(executable), '--debug-latency-host'], env=env,
                                     stdout=log, stderr=subprocess.STDOUT, preexec_fn=ignore_sigint)
            write_state(state, status='running', pid=child.pid, host_id=host_id, executable=str(executable))
            deadline = time.monotonic() + args.timeout
            while child.poll() is None and not pending and not args.qa_flag.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            if child.poll() is not None:
                write_state(state, status='exited', pid=child.pid, returncode=child.returncode, host_id=host_id)
                return child.returncode if child.returncode else 1
            reason = 'qa' if args.qa_flag.exists() else ('signal' if pending else 'timeout')
            # Popen owns this exact child; never signal a discovered PID.
            child.terminate()
            try:
                # qa_guard allows three seconds after SIGINT, then another
                # three after SIGTERM. Its second signal is also handled by
                # this wrapper, leaving time for the host's async teardown.
                code = child.wait(timeout=5.5)
                write_state(state, status='stopped', pid=child.pid, returncode=code, reason=reason, host_id=host_id)
                return 75 if reason == 'qa' else (128 + pending if pending else 0)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
                write_state(state, status='forced_stop', pid=child.pid, reason=reason, host_id=host_id)
                raise RuntimeError('Debug host did not complete shutdown within the guard grace period.')
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5.5)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host-app', type=Path, required=True)
    parser.add_argument('--host-id', required=True)
    parser.add_argument('--qa-flag', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('--internal-guarded', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 3600:
        parser.error('timeout must be between 1 and 3600 seconds')
    if args.internal_guarded:
        return guarded_run(args)
    if args.qa_flag.exists():
        raise ValueError('Release QA is active; host not started.')
    command = [sys.executable, str(ROOT / 'script/latency/qa_guard.py'), '--flag', str(args.qa_flag),
               '--timeout', str(args.timeout + 30), '--', sys.executable, str(Path(__file__).resolve()),
               *sys.argv[1:], '--internal-guarded']
    return subprocess.call(command)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
