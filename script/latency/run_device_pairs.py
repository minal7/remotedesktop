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

from summarize_device_pairs import read_trace, selected_fixes, summarize

ROOT = Path(__file__).resolve().parents[2]
RELEASE_BUILD = Path('/Users/michael/.codex/worktrees/remote-desktop-release/remote desktop/build')
COORDINATION = Path('/Users/michael/.codex/worktrees/coordination')
LEASE = COORDINATION / 'ipad.lock' / 'lease.json'
IPAD_QUEUE = COORDINATION / 'ipad.queue'
COORDINATION_LOG = COORDINATION / 'log.md'
IPAD_ID = '00008103-001869493A53001E'
RELEASE_QA = RELEASE_BUILD / '.release-qa-active'
CLIENT_BUNDLE = 'com.threadmark.remotedesktop.client'


def read_coordination_log():
    # Read the current record before each device action, including cleanup.
    try:
        return COORDINATION_LOG.read_text().splitlines()[-20:]
    except (OSError, UnicodeError) as error:
        raise ValueError('Coordination log unavailable; device action refused.') from error


def require_device_window(now=None, minimum_remaining=0):
    read_coordination_log()
    if RELEASE_QA.exists():
        raise ValueError('Release QA is active; no device command started.')
    try:
        lease = json.loads(LEASE.read_text())
        now = now or datetime.now().astimezone()
        started = datetime.strptime(lease['started'], '%H:%M').time()
        expires = datetime.strptime(lease['expires'], '%H:%M').time()
        start = now.replace(hour=started.hour, minute=started.minute, second=0, microsecond=0)
        end = now.replace(hour=expires.hour, minute=expires.minute, second=0, microsecond=0)
        build = str(lease['app_build'])
        if (lease['holder'] != 'B' or not isinstance(lease['purpose'], str)
                or not lease['purpose'].strip() or not build.isascii() or not build.isdecimal()
                or int(build) < 9000 or not start <= now < end
                or (end - start).total_seconds() > 1800
                or (end - now).total_seconds() <= minimum_remaining):
            raise ValueError('Invalid or expired B device lease.')
        if IPAD_QUEUE.exists() and any(line.split()[:1] == ['A'] for line in IPAD_QUEUE.read_text().splitlines()):
            raise ValueError('Chat A is queued; release at this safe point.')
        return int(build)
    except (OSError, KeyError, TypeError, json.JSONDecodeError, UnicodeError) as error:
        raise ValueError('Valid B device lease required.') from error


def verify_installed_lab(data, version, build):
    if not isinstance(data, dict) or not isinstance(data.get('info'), dict) or not isinstance(data.get('result'), dict):
        raise ValueError('Installed lab client version could not be verified.')
    apps = data['result'].get('apps')
    if data['info'].get('outcome') != 'success' or not isinstance(apps, list):
        raise ValueError('Installed lab client version could not be verified.')
    matches = [row for row in apps if isinstance(row, dict) and row.get('bundleIdentifier') == CLIENT_BUNDLE]
    if (len(matches) != 1 or matches[0].get('bundleVersion') != str(build)
            or matches[0].get('version') != str(version)):
        raise ValueError('Installed lab client version could not be verified.')


def require_selected_ipad(device, expected_build=None):
    lease_build = require_device_window()
    if expected_build is not None and lease_build != expected_build:
        raise ValueError('Lease build changed; device action refused.')
    if device != IPAD_ID:
        raise ValueError('Only the designated iPad is allowed.')


def require_lab_bundle(bundle_id):
    if bundle_id != CLIENT_BUNDLE:
        raise ValueError('Only the verified lab client bundle may be launched.')


def install_verified_lab_app(device, client_app):
    """Install only the signed Debug lab product; verify the installed version."""
    require_selected_ipad(device)
    app = client_app.resolve(strict=True)
    if not app.is_relative_to((ROOT / 'build/latency').resolve()):
        raise ValueError('Lab client must be in this worktree latency build.')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    version = info.get('CFBundleShortVersionString')
    build = info.get('CFBundleVersion')
    if (info.get('CFBundleIdentifier') != CLIENT_BUNDLE or not version or not build
            or not str(build).isascii() or not str(build).isdecimal()
            or int(build) != require_device_window()):
        raise ValueError('Lab client identity and version are required.')
    signed = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                            capture_output=True, check=True, timeout=10)
    entitlements = plistlib.loads(signed.stdout)
    if (entitlements.get('get-task-allow') is not True or
            entitlements.get('com.apple.developer.icloud-container-environment') != 'Development'):
        raise ValueError('Only a signed Development Debug client may be installed.')
    require_device_window()
    require_selected_ipad(device)
    require_device_window(minimum_remaining=65)
    subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, str(app)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=60)
    require_device_window()
    import tempfile
    with tempfile.TemporaryDirectory(prefix='latency-app-check-') as tmp:
        result = Path(tmp) / 'apps.json'
        require_device_window(minimum_remaining=35)
        subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', device,
                        '--bundle-id', CLIENT_BUNDLE, '--json-output', str(result)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=30)
        data = json.loads(result.read_text())
    verify_installed_lab(data, version, build)
    require_device_window()


def fixture_environment(photo):
    env = dict(os.environ)
    if photo is None:
        return env
    photo = photo.resolve(strict=True)
    if not photo.is_file() or not os.access(photo, os.R_OK):
        raise ValueError('A readable licensed fixture photo is required.')
    env.update({'LATENCY_OPTICAL': '1', 'LATENCY_LARGE_CHANGE_PHOTO': str(photo)})
    return env


def client_experiment_environment(args):
    env = {'LATENCY_LAB_F1_MAX_MS': str(args.f1_max_ms)}
    if args.lab60:
        env.update({'LATENCY_LAB': '1', 'LATENCY_QOS_FPS': '60',
                    'LATENCY_QOS_PREFERENCE': 'fluency'})
    return env


def run(args):
    selected_fixes(args.fix)
    marker_env = fixture_environment(args.fixture_photo)
    if args.lab60 and args.fixture_photo is None:
        raise ValueError('LAB60 comparable runs require a licensed fixture photo.')
    handoff = datetime.fromisoformat(args.not_before.replace('Z', '+00:00'))
    if handoff.tzinfo is None:
        raise ValueError('The device handoff time must include its timezone.')
    if datetime.now(timezone.utc) < handoff:
        raise ValueError('The physical-device handoff has not happened yet.')
    if args.qa_flag.exists():
        raise ValueError('Release QA is active; no device command started.')
    if args.qa_flag.resolve() != RELEASE_QA:
        raise ValueError('The QA guard must use the shared release QA flag.')
    require_device_window()
    require_selected_ipad(args.device)
    expected_build = require_device_window()
    require_lab_bundle(args.bundle_id)
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
        require_selected_ipad(args.device, expected_build)
        require_device_window(minimum_remaining=45)
        with (args.output / f'{name}.log').open('w') as log:
            result = subprocess.run(arguments, stdout=log, stderr=subprocess.STDOUT, check=required, timeout=40)
            return result.returncode == 0

    try:
        install_verified_lab_app(args.device, args.client_app)
        # The changing marker is also the warmup content. It stays visible for
        # the whole session, including peer handoffs; IDs never restart.
        spawning = True
        try:
            marker = subprocess.Popen([str(marker_binary)], env={**marker_env,
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
        # Keep devicectl attached: its documented --console contract forwards
        # catchable signals to the app even before a PID result is available.
        require_selected_ipad(args.device, expected_build)
        spawning = True
        try:
            launch_process = subprocess.Popen(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                 '--console',
                 '--terminate-existing', '--json-output', str(launch_json),
                 '--environment-variables', json.dumps(client_experiment_environment(args)), args.bundle_id,
                 'LatencyProbe', 'LatencyProbeHostID', args.host_id,
                 'LatencyLabPairFix', args.fix, 'LatencyLabPairToken', launch_token],
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        finally:
            spawning = False
        if stop_pending:
            raise KeyboardInterrupt
        selected = None
        deadline = time.monotonic() + 570
        while time.monotonic() < deadline:
            require_selected_ipad(args.device, expected_build)
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
            next_poll = time.monotonic() + 10
            while time.monotonic() < next_poll:
                require_selected_ipad(args.device, expected_build)
                if args.qa_flag.exists():
                    raise ValueError('Release QA reclaimed the device window.')
                time.sleep(min(.2, max(0, next_poll - time.monotonic())))
        if selected is None:
            raise ValueError('No complete four-pair session before the sweep deadline.')
        # Ask the marker to write its complete timestamp file and exit, outside
        # all eight measured windows. SIGTERM remains an abort path.
        marker.send_signal(signal.SIGUSR1)
        marker_deadline = time.monotonic() + 10
        while marker.poll() is None:
            require_selected_ipad(args.device, expected_build)
            if time.monotonic() >= marker_deadline:
                raise ValueError('Marker did not finish.')
            time.sleep(.2)
        if marker.returncode:
            raise ValueError('Marker did not finish successfully.')
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
        cleanup_error = False
        if launch_process is not None:
            if launch_process.poll() is None:
                try:
                    read_coordination_log()
                except ValueError:
                    cleanup_error = True
                launch_process.send_signal(signal.SIGINT)
            try:
                launch_process.wait(timeout=2)
                console_stopped = True
            except subprocess.TimeoutExpired:
                pass
        # Launch may have completed just before an interrupt reached this
        # controller. Recover only its returned PID, never guess by app name.
        device_pid = device_pid or launched_pid()
        if not console_stopped and device_pid is not None:
            try:
                read_coordination_log()
                stopped = subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'terminate',
                                '--device', args.device, '--pid', str(device_pid)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                if stopped.returncode:
                    cleanup_error = True
            except (subprocess.SubprocessError, ValueError):
                cleanup_error = True
        elif launch_attempted and not console_stopped:
            cleanup_error = True
        if launch_process is not None and launch_process.poll() is None:
            launch_process.kill(); launch_process.wait()
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
    parser.add_argument('--client-app', required=True, type=Path)
    parser.add_argument('--qa-flag', required=True, type=Path)
    parser.add_argument('--not-before', required=True, help='ISO 8601 device handoff time, with timezone')
    parser.add_argument('--fix', required=True, help='One fix, or sorted kept fixes joined by + for the combined check')
    parser.add_argument('--f1-max-ms', type=int, choices=[0, 10, 20], default=0)
    parser.add_argument('--marker-binary', required=True, type=Path)
    parser.add_argument('--fixture-photo', type=Path, help='Licensed photo for the alternating full-screen fixture')
    parser.add_argument('--lab60', action='store_true', help='Use the explicitly prepared 60 fps adaptive baseline')
    parser.add_argument('--host-traces', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--bundle-id', default='com.threadmark.remotedesktop.client')
    parser.add_argument('--guarded', action='store_true', help=argparse.SUPPRESS)
    try:
        sys.exit(run(parser.parse_args()))
    except (ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(str(error) or 'Sweep interrupted.', file=sys.stderr)
        sys.exit(1)
