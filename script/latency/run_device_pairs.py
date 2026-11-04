#!/usr/bin/env python3
"""Run one guarded, same-session iPad A/B sweep after the device handoff."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import time
import uuid

from summarize_device_pairs import read_trace, summarize

ROOT = Path(__file__).resolve().parents[2]


def run(args):
    handoff = datetime.fromisoformat(args.not_before.replace('Z', '+00:00'))
    if handoff.tzinfo is None:
        raise ValueError('The device handoff time must include its timezone.')
    if datetime.now(timezone.utc) < handoff:
        raise ValueError('The physical-device handoff has not happened yet.')
    if args.qa_flag.exists():
        raise ValueError('Release QA is active; no device command started.')
    info = plistlib.loads((args.host_app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.threadmark.remotedesktop.host.debug':
        raise ValueError('Only the separately signed Debug host is allowed.')
    if not args.guarded:
        command = [sys.executable, str(ROOT / 'script/latency/qa_guard.py'), '--flag', str(args.qa_flag),
                   '--timeout', '720', '--', sys.executable, str(Path(__file__).resolve()),
                   *sys.argv[1:], '--guarded']
        return subprocess.call(command)
    args.output.mkdir(parents=True, exist_ok=False)
    marker_binary = args.marker_binary.resolve()
    if not marker_binary.is_file():
        raise ValueError('Build DeviceMarkerProbe before starting the device sweep.')
    marker_path = args.output / 'markers.json'
    marker_log = (args.output / 'marker.log').open('w')
    marker = None
    launch_process = None
    launch_log = None
    device_pid = None
    launch_json = None
    launch_attempted = False
    launch_token = str(uuid.uuid4())
    spawning = False
    stop_pending = False

    def launched_pid():
        if launch_json is None or not launch_json.is_file():
            return None
        try:
            pid = json.loads(launch_json.read_text())['result']['process']['processIdentifier']
            return pid if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0 else None
        except (OSError, ValueError, KeyError):
            return None

    def stop_requested(_signum, _frame):
        nonlocal stop_pending
        if spawning:
            stop_pending = True
            return
        raise KeyboardInterrupt

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, stop_requested)

    def command(arguments, name, required=True):
        with (args.output / f'{name}.log').open('w') as log:
            result = subprocess.run(arguments, stdout=log, stderr=subprocess.STDOUT, check=required, timeout=40)
            return result.returncode == 0

    try:
        # The changing marker is also the warmup content. It stays visible for
        # the whole session, including peer handoffs; IDs never restart.
        spawning = True
        try:
            marker = subprocess.Popen([str(marker_binary)], env={**os.environ,
                'LATENCY_SECONDS': '600', 'LATENCY_HOST_TRACE': str(marker_path)},
                stdout=marker_log, stderr=subprocess.STDOUT)
        finally:
            spawning = False
        if stop_pending:
            raise KeyboardInterrupt
        deadline = time.monotonic() + 12
        while 'MARKER_READY ' not in (args.output / 'marker.log').read_text():
            if marker.poll() is not None or time.monotonic() >= deadline:
                raise ValueError('The synthetic marker did not start.')
            time.sleep(.1)
        launch_json = args.output / 'launch.json'
        launch_attempted = True
        launch_log = (args.output / 'launch.log').open('w')
        # Keep devicectl attached: its documented --console contract forwards
        # catchable signals to the app even before a PID result is available.
        spawning = True
        try:
            launch_process = subprocess.Popen(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                 '--console',
                 '--terminate-existing', '--json-output', str(launch_json),
                 '--environment-variables', json.dumps({'LATENCY_LAB_F1_MAX_MS': str(args.f1_max_ms)}), args.bundle_id,
                 'LatencyProbe', 'LatencyProbeHostID', args.host_id,
                 'LatencyLabPairFix', args.fix, 'LatencyLabPairToken', launch_token],
                 stdout=launch_log, stderr=subprocess.STDOUT)
        finally:
            spawning = False
        if stop_pending:
            raise KeyboardInterrupt
        selected = None
        deadline = time.monotonic() + 570
        while time.monotonic() < deadline:
            if args.qa_flag.exists():
                raise ValueError('Release QA reclaimed the device window.')
            if marker.poll() is not None:
                raise ValueError('Marker ended before the paired session completed.')
            if launch_process.poll() is not None:
                raise ValueError('The attached iPad app ended before the paired session completed.')
            status_directory = args.output / 'status-copy'
            if status_directory.exists():
                shutil.rmtree(status_directory)
            status_directory.mkdir()
            copied = command(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                     '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle_id,
                     '--source', 'Library/Application Support/RemoteDesktopHost/Latency/pair-status.json',
                     '--destination', str(status_directory / 'pair-status.json')], 'status-copy', required=False)
            status = None
            if copied:
                try:
                    status = json.loads((status_directory / 'pair-status.json').read_text())
                    if status.get('launchToken') != launch_token:
                        status = None
                    elif (isinstance(status.get('processIdentifier'), int)
                          and not isinstance(status['processIdentifier'], bool)
                          and status['processIdentifier'] > 0):
                        device_pid = status['processIdentifier']
                    else:
                        status = None
                except (OSError, ValueError, KeyError):
                    status = None
            if status and status.get('stage') in ('complete', 'aborted'):
                snapshot = args.output / 'client-files'
                command(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                         '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle_id,
                         '--source', 'Library/Application Support/RemoteDesktopHost/Latency',
                         '--destination', str(snapshot)], 'copy')
                if status['stage'] == 'aborted':
                    raise RuntimeError('The lab could not finish the requested arms; the client trace was retained.')
                candidates = []
                for path in snapshot.rglob('client-*.jsonl'):
                    try:
                        rows = read_trace(path)
                        if any(r.get('type') == 'lab_pair' and r.get('stage') == 'complete'
                               and r.get('run') == status.get('run') for r in rows):
                            candidates.append(path)
                    except (ValueError, KeyError):
                        continue
                if len(candidates) != 1:
                    raise ValueError('Expected one complete trace matching the current paired run.')
                selected = args.output / 'client.jsonl'
                selected.write_bytes(candidates[0].read_bytes())
                break
            # Only the small atomic status record crosses USB during timing.
            # Copy the bounded full trace after the last measured window.
            time.sleep(10)
        if selected is None:
            raise ValueError('No complete four-pair session before the sweep deadline.')
        # Ask the marker to write its complete timestamp file and exit, outside
        # all eight measured windows. SIGTERM remains an abort path.
        marker.send_signal(signal.SIGUSR1)
        marker.wait(timeout=10)
        result = summarize(marker_path, selected, args.host_traces, args.output / 'segments')
        (args.output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result['median_paired_B_minus_A'], indent=2))
        return 0
    finally:
        # devicectl launches outside this process group. Terminate only the
        # exact PID returned by this sweep; never an installed host process.
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, signal.SIG_IGN)
        console_stopped = False
        if launch_process is not None:
            if launch_process.poll() is None:
                launch_process.send_signal(signal.SIGINT)
            try:
                launch_process.wait(timeout=2)
                console_stopped = True
            except subprocess.TimeoutExpired:
                pass
        # Launch may have completed just before an interrupt reached this
        # controller. Recover only its returned PID, never guess by app name.
        device_pid = device_pid or launched_pid()
        cleanup_error = False
        if not console_stopped and device_pid is not None:
            try:
                stopped = subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'terminate',
                                '--device', args.device, '--pid', str(device_pid)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                if stopped.returncode:
                    cleanup_error = True
            except subprocess.SubprocessError:
                cleanup_error = True
        elif launch_attempted and not console_stopped:
            cleanup_error = True
        if launch_process is not None and launch_process.poll() is None:
            launch_process.kill(); launch_process.wait()
        if launch_log is not None:
            launch_log.close()
        if marker is not None and marker.poll() is None:
            marker.terminate()
            try:
                marker.wait(timeout=3)
            except subprocess.TimeoutExpired:
                marker.kill(); marker.wait()
        marker_log.close()
        if cleanup_error:
            raise RuntimeError('Could not confirm the launched iPad app stopped; device cleanup is required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--host-id', required=True)
    parser.add_argument('--host-app', required=True, type=Path)
    parser.add_argument('--qa-flag', required=True, type=Path)
    parser.add_argument('--not-before', required=True, help='ISO 8601 device handoff time, with timezone')
    parser.add_argument('--fix', required=True, choices=['F1', 'F2', 'F3', 'F4'])
    parser.add_argument('--f1-max-ms', type=int, choices=[0, 10, 20], default=0)
    parser.add_argument('--marker-binary', required=True, type=Path)
    parser.add_argument('--host-traces', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--bundle-id', default='com.threadmark.remotedesktop.client')
    parser.add_argument('--guarded', action='store_true', help=argparse.SUPPRESS)
    try:
        sys.exit(run(parser.parse_args()))
    except (ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(str(error) or 'Sweep interrupted.', file=sys.stderr)
        sys.exit(1)
