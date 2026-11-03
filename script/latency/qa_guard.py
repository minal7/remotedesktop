#!/usr/bin/env python3
"""Yield an owned latency process group whenever release QA claims memory."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def group_exists(process):
    process.poll()  # Reap the group leader if it has already exited.
    try:
        os.killpg(process.pid, 0)
        return True
    except ProcessLookupError:
        return False


def stop(process):
    # The child has a new session: never signal the invoking shell, another
    # build, or the installed release host.
    for requested_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        if not group_exists(process):
            break
        try:
            os.killpg(process.pid, requested_signal)
        except ProcessLookupError:
            break
        deadline = time.monotonic() + 3
        while group_exists(process) and time.monotonic() < deadline:
            time.sleep(.05)
    process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--flag', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=2700)
    parser.add_argument('--wait-seconds', type=float, default=0)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('A command is required after --.')
    cancelled = 0

    def cancel(signum, _frame):
        nonlocal cancelled
        # Do not raise during Popen: first retain the owned process handle so
        # cleanup cannot miss a child created at that exact moment.
        cancelled = signum

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, cancel)
    if args.flag.exists():
        print('Release QA is active; latency command not started.', flush=True)
        wait_started = time.monotonic()
        while args.flag.exists():
            if cancelled:
                return 128 + cancelled
            if time.monotonic() - wait_started >= args.wait_seconds:
                return 75
            time.sleep(.5)
    if cancelled:
        return 128 + cancelled
    started = time.monotonic()
    process = subprocess.Popen(command, start_new_session=True)
    try:
        while process.poll() is None:
            if cancelled:
                return 128 + cancelled
            if args.flag.exists():
                print('Release QA claimed memory; stopping this latency command.', flush=True)
                stop(process)
                return 75
            if time.monotonic() - started >= args.timeout:
                print('Latency command reached its time box.', flush=True)
                stop(process)
                return 124
            time.sleep(.2)
        if cancelled:
            return 128 + cancelled
        if args.flag.exists():
            print('Release QA became active as this latency command ended.', flush=True)
            return 75
        return process.returncode
    finally:
        if group_exists(process):
            stop(process)


if __name__ == '__main__':
    sys.exit(main())
