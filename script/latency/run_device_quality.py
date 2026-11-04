#!/usr/bin/env python3
"""Guarded, untimed synthetic text capture on an already-reserved iPad.

The controller owns the synthetic fixture, the one client launch, and the
uniquely named quality test runner. It never starts or stops the Mac host.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import signal
import subprocess
import sys
import time
from urllib.parse import unquote, urlparse
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
TEST_TARGET = 'RemoteDesktopLatencyQualityTests'
TEST_IDENTIFIER = TEST_TARGET + '/LatencyQualityLiveE2ETests/testCaptureF4AAndB'
CLIENT_BUNDLE = 'com.threadmark.remotedesktop.client'
RUNNER_BUNDLE = 'com.threadmark.remotedesktop.client.latency-quality-tests.xctrunner'


def handoff_time(value):
    date = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if date.tzinfo is None or datetime.now(timezone.utc) < date:
        raise ValueError('The device handoff time has not passed or lacks a timezone.')
    return date


def replace_testroot(value, root):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(root))
    if isinstance(value, list):
        return [replace_testroot(item, root) for item in value]
    if isinstance(value, dict):
        return {key: replace_testroot(item, root) for key, item in value.items()}
    return value


def inspect_xctestrun(path):
    original = path.resolve(strict=True)
    if not original.is_relative_to((ROOT / 'build/latency').resolve()):
        raise ValueError('xctestrun must be within this worktree latency build.')
    raw = plistlib.loads(original.read_bytes())
    # Only the established Xcode format-1 schema is allowed; fail closed if
    # Xcode changes its layout rather than accidentally running another suite.
    if raw.get('__xctestrun_metadata__', {}).get('FormatVersion') != 1:
        raise ValueError('Unsupported xctestrun format; inspect before using.')
    names = [key for key in raw if not key.startswith('__')]
    if names != [TEST_TARGET] or not isinstance(raw[TEST_TARGET], dict):
        raise ValueError('xctestrun must contain only the quality UI test target.')
    test = raw[TEST_TARGET]
    if (test.get('SystemAttachmentLifetime') != 'keepNever'
            or test.get('PreferredScreenCaptureFormat') != 'screenshots'):
        raise ValueError('xctestrun must disable retained automatic captures and video.')
    if (test.get('BlueprintName') != TEST_TARGET or test.get('TestHostBundleIdentifier') != RUNNER_BUNDLE
            or test.get('IsUITestBundle') is not True):
        raise ValueError('Unexpected test blueprint.')
    if test.get('TestBundlePath') != '__TESTHOST__/PlugIns/RemoteDesktopLatencyQualityTests.xctest':
        raise ValueError('Unexpected quality test bundle location.')
    scheme_path = ROOT / 'ios/RemoteDesktop.xcodeproj/xcshareddata/xcschemes/RemoteDesktopLatencyQuality.xcscheme'
    action = ET.parse(scheme_path).getroot().find('TestAction')
    if action is None or action.get('buildConfiguration') != 'Debug' or action.get('systemAttachmentLifetime') != 'keepNever' or action.get('preferredScreenCaptureFormat') != 'screenshots':
        raise ValueError('Generated quality scheme does not meet Debug screenshot policy.')
    rebased = replace_testroot(raw, original.parent)
    test = rebased[TEST_TARGET]
    runner_path = Path(test.get('TestHostPath', '')).resolve(strict=True)
    if not runner_path.is_relative_to(original.parent) or not runner_path.name.endswith('.app'):
        raise ValueError('Quality runner app must be in the test products directory.')
    info = plistlib.loads((runner_path / 'Info.plist').read_bytes())
    bundle = info.get('CFBundleIdentifier', '')
    executable = info.get('CFBundleExecutable', '')
    if (bundle != RUNNER_BUNDLE
            or not executable or '/' in executable
            or TEST_TARGET not in runner_path.name or TEST_TARGET not in executable
            or not (runner_path / executable).is_file()):
        raise ValueError('Runner bundle/executable is not uniquely identifiable as the quality runner.')
    if not (runner_path / 'PlugIns/RemoteDesktopLatencyQualityTests.xctest').is_dir():
        raise ValueError('Quality runner does not contain its expected test bundle.')
    client_path = Path(test.get('UITargetAppPath', '')).resolve(strict=True)
    if not client_path.is_relative_to(original.parent / 'Debug-iphoneos'):
        raise ValueError('Target app must be the built iOS Debug app.')
    client_info = plistlib.loads((client_path / 'Info.plist').read_bytes())
    if client_info.get('CFBundleIdentifier') != CLIENT_BUNDLE:
        raise ValueError('Unexpected quality target app bundle.')
    return rebased, runner_path, executable, client_path


def use_destination_artifacts(test):
    # Documented by `man xcodebuild.xctestrun`: all three path keys must
    # be excluded when destination artifacts are used.
    for key in ('TestBundlePath', 'TestHostPath', 'UITargetAppPath', 'DependentProductPaths'):
        test.pop(key, None)
    test['UseDestinationArtifacts'] = True
    test['TestHostBundleIdentifier'] = RUNNER_BUNDLE
    test['TestBundleDestinationRelativePath'] = '__TESTHOST__/PlugIns/RemoteDesktopLatencyQualityTests.xctest'
    test['UITargetAppBundleIdentifier'] = CLIENT_BUNDLE


def quality_processes(data, runner_name, executable):
    if data.get('info', {}).get('outcome') != 'success':
        raise ValueError('Device process listing did not succeed.')
    rows = data.get('result', {}).get('runningProcesses')
    if not isinstance(rows, list):
        raise ValueError('Unexpected device process listing schema.')
    result = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('executable'), str):
            continue  # An unrelated OS process need not expose an executable.
        parsed = urlparse(row['executable'])
        path = PurePosixPath(unquote(parsed.path))
        parts = path.parts
        # The saved physical-device schema uses this exact application root.
        if (parsed.scheme == 'file' and not parsed.netloc and len(parts) == 9
                and parts[:6] == ('/', 'private', 'var', 'containers', 'Bundle', 'Application')
                and parts[-2:] == (runner_name, executable)):
            try: uuid.UUID(parts[6])
            except ValueError: continue
            pid = row.get('processIdentifier')
            if type(pid) is not int or pid <= 1:
                raise ValueError('Quality process has an invalid PID.')
            result.append((pid, str(path)))
    return result


def signal_owned(test_process, console, fixture, errors):
    """Signal all owned handles before any wait or device-process query."""
    for label, process, signum in (('test', test_process, signal.SIGTERM),
                                   ('client console', console, signal.SIGINT),
                                   ('fixture', fixture, signal.SIGTERM)):
        if process is None:
            continue
        try:
            if process.poll() is None:
                process.send_signal(signum)
        except OSError:
            errors.append(f'Could not signal owned {label} process.')


def geometry(path):
    data = json.loads(path.read_text())
    size, crop = data.get('image_pixels'), data.get('crop_pixels')
    if (not isinstance(size, list) or len(size) != 2 or not isinstance(crop, list) or len(crop) != 4
            or any(type(n) is not int or n < 0 or n > 16384 for n in size + crop)
            or min(size) < 1 or min(crop[2:]) < 8
            or crop[0] + crop[2] > size[0] or crop[1] + crop[3] > size[1]
            or data.get('fixture') != 'synthetic_static_text' or data.get('origin') != 'top_left'):
        raise ValueError('Synthetic reference geometry is invalid.')
    return size, crop


def selected_fixes(value):
    fixes = value.split(',')
    if not fixes or len(fixes) != len(set(fixes)) or any(item not in ('F1', 'F3', 'F4') for item in fixes):
        raise ValueError('Fixes must be a nonempty comma-separated subset of F1,F3,F4.')
    return [name for name in ('F1', 'F3', 'F4') if name in fixes]


def run(args):
    fixes = selected_fixes(args.fixes)
    handoff_time(args.not_before)
    if args.qa_flag.exists(): raise ValueError('Release QA is active; no device command started.')
    host = args.host_app.resolve(strict=True)
    if not host.is_relative_to((ROOT / 'build/latency').resolve()):
        raise ValueError('Debug host must be in this worktree latency build.')
    if plistlib.loads((host / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != 'com.threadmark.remotedesktop.host.debug':
        raise ValueError('Only the separate Debug host is allowed.')
    try:
        if len(args.host_id) != 36 or str(uuid.UUID(args.host_id)) != args.host_id.lower(): raise ValueError()
    except ValueError: raise ValueError('Host ID must be a UUID.') from None
    fixture_binary = args.fixture_binary.resolve(strict=True)
    if not fixture_binary.is_file(): raise ValueError('StaticTextFixture binary is unavailable.')
    test_config, runner_path, runner_executable, client_path = inspect_xctestrun(args.xctestrun)
    runner_name = runner_path.name
    if not args.guarded:
        command = [sys.executable, str(ROOT / 'script/latency/qa_guard.py'), '--flag', str(args.qa_flag),
                   '--timeout', '660', '--', sys.executable, str(Path(__file__).resolve()),
                   *sys.argv[1:], '--guarded']
        return subprocess.call(command)
    args.output.mkdir(parents=True, exist_ok=False)
    pending = 0
    fixture = console = test_process = None
    launch_attempted = test_started = False
    launch_json = args.output / 'launch.json'
    logs = []

    def cancel(signum, _frame):
        nonlocal pending
        pending = pending or signum
    previous = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    def check():
        if pending or args.qa_flag.exists(): raise RuntimeError('Quality run interrupted by QA or cancellation.')
    def logfile(name):
        handle = (args.output / name).open('wb'); logs.append(handle); return handle
    def processes():
        path = args.output / 'process-list.tmp.json'
        try:
            subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'processes', '--device', args.device,
                            '--json-output', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           check=True, timeout=4)
            return quality_processes(json.loads(path.read_text()), runner_name, runner_executable)
        finally:
            path.unlink(missing_ok=True)
    def client_pid():
        try:
            pid = json.loads(launch_json.read_text())['result']['process']['processIdentifier']
            return pid if type(pid) is int and pid > 1 else None
        except (OSError, ValueError, KeyError, TypeError): return None
    def terminate_pid(pid):
        result = subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', args.device,
                                 '--pid', str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
        return result.returncode == 0
    cleanup_errors = []
    try:
        check()
        if processes(): raise ValueError('The exact quality test runner is already running.')
        # Install both exact build products before starting the client. The
        # subsequent xctestrun uses destination artifacts and must not install.
        for name, app in (('install-client.log', client_path), ('install-runner.log', runner_path)):
            check()
            subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device, str(app)],
                           stdout=logfile(name), stderr=subprocess.STDOUT, check=True, timeout=60)
        check()
        fixture_dir = args.output / 'fixture'
        fixture = subprocess.Popen([str(fixture_binary), str(fixture_dir), '600'], stdout=logfile('fixture.log'), stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while not (fixture_dir / 'geometry.json').is_file() or not (fixture_dir / 'reference.png').is_file():
            check()
            if fixture.poll() is not None or time.monotonic() >= deadline: raise ValueError('Synthetic fixture failed to start.')
            time.sleep(.1)
        size, crop = geometry(fixture_dir / 'geometry.json')
        env = {'RUN_LATENCY_QUALITY_E2E': '1', 'LATENCY_QUALITY_NOT_BEFORE': args.not_before,
               'LATENCY_QUALITY_FIXES': ','.join(fixes), 'LATENCY_QUALITY_F1_MAX_MS': str(args.f1_max_ms),
               'LATENCY_QUALITY_REFERENCE_PIXELS': ','.join(map(str, size)),
               'LATENCY_QUALITY_REFERENCE_CROP': ','.join(map(str, crop))}
        test = test_config[TEST_TARGET]
        test.setdefault('EnvironmentVariables', {}).update(env)
        use_destination_artifacts(test)
        local_run = args.output / 'quality.xctestrun'
        local_run.write_bytes(plistlib.dumps(test_config))
        check()
        launch_attempted = True
        launch_env = {'LATENCY_LAB_F1': '0', 'LATENCY_LAB_F2': '0', 'LATENCY_LAB_F3': '0', 'LATENCY_LAB_F4': '0'}
        console = subprocess.Popen(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
            '--console', '--terminate-existing', '--json-output', str(launch_json),
            '--environment-variables', json.dumps(launch_env), CLIENT_BUNDLE,
            'LatencyProbe', 'LatencyLab', 'LatencyQuality', 'LatencyProbeHostID', args.host_id],
            stdout=logfile('client-console.log'), stderr=subprocess.STDOUT)
        # XCTest waits for the already-running app and fixture; it never calls app.launch().
        check()
        test_started = True
        test_process = subprocess.Popen(['xcodebuild', 'test-without-building', '-xctestrun', str(local_run),
            '-destination', 'platform=iOS,id=' + args.device, '-parallel-testing-enabled', 'NO',
            '-collect-test-diagnostics', 'never',
            '-only-testing:' + TEST_IDENTIFIER, '-resultBundlePath', str(args.output / 'quality.xcresult')],
            stdout=logfile('xcodebuild.log'), stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 510
        while test_process.poll() is None:
            check()
            if fixture.poll() is not None or console.poll() is not None: raise RuntimeError('Owned fixture or client exited during capture.')
            if time.monotonic() >= deadline: raise RuntimeError('Quality test timed out.')
            time.sleep(.25)
        test_returncode = test_process.returncode
        check()
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
            '--domain-type', 'appDataContainer', '--domain-identifier', CLIENT_BUNDLE,
            '--source', 'Library/Application Support/RemoteDesktopHost/Latency',
            '--destination', str(args.output / 'client-traces')], stdout=logfile('trace-copy.log'),
            stderr=subprocess.STDOUT, check=True, timeout=30)
        if test_returncode != 0: raise RuntimeError('Quality test failed; xcresult and client traces were retained.')
        print('Captured xcresult and client traces; screenshot extraction and acceptance remain separate.')
        return 0
    finally:
        # Ignore repeated cancellation during bounded ownership cleanup.
        for sig in previous: signal.signal(sig, signal.SIG_IGN)
        signal_owned(test_process, console, fixture, cleanup_errors)
        # Give all three processes a chance to stop concurrently before any
        # potentially slow device query. Never skip another cleanup on error.
        for label, process in (('test', test_process), ('fixture', fixture)):
            if process is None:
                continue
            try:
                process.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                try:
                    process.kill(); process.wait(timeout=.5)
                except (OSError, subprocess.SubprocessError):
                    cleanup_errors.append(f'Could not stop owned {label} process.')
            except OSError:
                cleanup_errors.append(f'Could not wait for owned {label} process.')
        if console is not None:
            try:
                console.wait(timeout=.5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    pid = client_pid()
                    if pid is None or not terminate_pid(pid): cleanup_errors.append('Could not confirm client cleanup.')
                except (OSError, subprocess.SubprocessError):
                    cleanup_errors.append('Could not confirm client cleanup.')
                try:
                    if console.poll() is None: console.kill(); console.wait(timeout=.5)
                except (OSError, subprocess.SubprocessError):
                    cleanup_errors.append('Could not stop owned client console.')
        elif launch_attempted: cleanup_errors.append('Client launch ownership could not be confirmed.')
        if test_started:
            try:
                matches = processes()
                if len(matches) > 1:
                    cleanup_errors.append('Multiple quality runner processes; no PID was guessed.')
                elif matches:
                    pid, path = matches[0]
                    # Re-read immediately before signaling to reject PID reuse.
                    if (pid, path) not in processes() or not terminate_pid(pid):
                        cleanup_errors.append('Could not confirm the exact quality runner stopped.')
                    elif processes():
                        cleanup_errors.append('Quality runner remains after termination.')
            except (OSError, ValueError, subprocess.SubprocessError):
                cleanup_errors.append('Could not verify quality runner cleanup.')
        for handle in logs: handle.close()
        for sig, old in previous.items(): signal.signal(sig, old)
        if cleanup_errors: raise RuntimeError('; '.join(cleanup_errors))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--host-id', required=True)
    parser.add_argument('--host-app', type=Path, required=True)
    parser.add_argument('--qa-flag', type=Path, required=True)
    parser.add_argument('--not-before', required=True)
    parser.add_argument('--fixture-binary', type=Path, required=True)
    parser.add_argument('--fixes', default='F4', help='Comma-separated subset of F1,F3,F4')
    parser.add_argument('--f1-max-ms', type=int, choices=[0, 10, 20], default=0)
    parser.add_argument('--xctestrun', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--guarded', action='store_true', help=argparse.SUPPRESS)
    return run(parser.parse_args())


if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr); sys.exit(1)
