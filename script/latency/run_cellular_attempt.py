#!/usr/bin/env python3
"""One guarded cellular-lab attempt. Host and mapping preference are external prerequisites."""
import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

import run_device_pairs as guard
from cellular_evidence import clean_client, measurement
from device_trace_tools import recent_client
from select_device_trace import select


def private_config(path):
    data = json.loads(Path(path).read_text())
    if not isinstance(data, dict) or data.get('device_id') != guard.IPAD_ID:
        raise ValueError('Invalid private configuration')
    host = str(uuid.UUID(data['host_id']))
    return data['device_id'], host


def read_rows(path):
    raw = path.read_text()
    if not raw or not raw.endswith('\n'):
        raise ValueError('Incomplete trace')
    rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
    if any(not isinstance(r, dict) or r.get('type') in {'truncated', 'trace_truncated'} for r in rows):
        raise ValueError('Incomplete trace')
    return rows


def current_connectivity(folder, previous):
    paths = [p for p in Path(folder).rglob('connectivity-*.jsonl') if p.name not in previous]
    if not paths:
        return None
    if len(paths) != 1:
        raise ValueError('Ambiguous current attempt')
    try:
        return clean_client(read_rows(paths[0]))
    except (OSError, json.JSONDecodeError, ValueError):
        return None


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def sanitized_connectivity(rows):
    clean_client(rows)  # Reject mixed or ambiguous attempts before retaining anything.
    events = {'attempt_start', 'path', 'stage', 'selected_pair', 'failure', 'first_presented'}
    allowed = {'interface': {'wifi', 'cellular', 'wired', 'unknown'},
               'localType': {'host', 'srflx', 'prflx'}, 'remoteType': {'host', 'srflx', 'prflx'},
               'localFamily': {'v4', 'v6', 'unknown'}, 'remoteFamily': {'v4', 'v6', 'unknown'},
               'protocol': {'udp', 'tcp', 'unknown'}, 'stage': {'signaling', 'ice_checking', 'dtls', 'hello', 'video'}}
    out = []
    for r in rows:
        if r.get('type') != 'connectivity' or r.get('event') not in events or not finite(r.get('time')): continue
        item = {'type': 'connectivity', 'event': r['event'], 'time': r['time']}
        # The ephemeral attempt token allows the existing parser to recheck attribution.
        if isinstance(r.get('attempt'), str):
            try: item['attempt'] = str(uuid.UUID(r['attempt']))
            except ValueError: raise ValueError('Invalid local attempt token')
        for key, values in allowed.items():
            if r.get(key) in values: item[key] = r[key]
        for key in ('hasIPv4', 'hasIPv6'):
            if type(r.get(key)) is bool: item[key] = r[key]
        out.append(item)
    return out


def sanitized_timing(rows):
    fields = {'clock': ('time', 'offset', 'uncertainty', 'rtt', 'samples'),
              'marker': ('marker_id', 'decodeTime', 'presentedTime'),
              'render': ('decodeTime', 'submittedTime', 'presentedTime')}
    out = []
    for r in rows:
        if r.get('type') not in fields: continue
        item = {'type': r['type']}
        for key in fields[r['type']]:
            if finite(r.get(key)): item[key] = r[key]
        out.append(item)
    return out


def save_json(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, sort_keys=True) + '\n')
    os.replace(temp, path)


def save_rows(path, rows):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(''.join(json.dumps(r, sort_keys=True) + '\n' for r in rows))
    os.replace(temp, path)


def preserve_snapshot(snapshot, old_connectivity, old_clients, output, selected=None):
    connectivity = [p for p in snapshot.rglob('connectivity-*.jsonl') if p.name not in old_connectivity]
    if len(connectivity) == 1:
        try: save_rows(output / 'connectivity.jsonl', sanitized_connectivity(read_rows(connectivity[0])))
        except (OSError, ValueError, TypeError, json.JSONDecodeError): pass
    candidates = [p for p in snapshot.rglob('client-*.jsonl') if p.name not in old_clients]
    if selected is not None and selected.exists():
        candidates = [p for p in candidates if p.read_bytes() == selected.read_bytes()]
    if len(candidates) == 1:
        try: save_rows(output / 'client-timing.jsonl', sanitized_timing(read_rows(candidates[0])))
        except (OSError, ValueError, TypeError, json.JSONDecodeError): pass


def preserve_marker(source, output):
    try:
        data = json.loads(source.read_text())
        if not finite(data.get('duration_s')) or type(data.get('initial_marker_observed_before_timing')) is not bool:
            return
        rows = []
        for r in data['markers']:
            item = {k: r[k] for k in ('marker_id', 'previous_marker_id', 'host_display_s', 'previous_host_display_s')
                    if k in r and finite(r[k])}
            if 'marker_id' not in item or 'host_display_s' not in item: return
            rows.append(item)
        save_json(output / 'marker.json', {'duration_s': data['duration_s'],
                  'initial_marker_observed_before_timing': data['initial_marker_observed_before_timing'], 'markers': rows})
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError): pass


class Attempt:
    def __init__(self, device, build):
        self.device = device
        self.build = build
        self.client = self.marker = None
        self.launch_json = None
        self.spawning = False
        self.stop_pending = False

    def check(self):
        guard.require_selected_ipad(self.device, self.build)

    def signal_handler(self, _signal, _frame):
        if self.spawning:
            self.stop_pending = True
        else:
            raise KeyboardInterrupt

    def spawn(self, args, **kwargs):
        self.check()
        self.spawning = True
        try:
            child = subprocess.Popen(args, **kwargs)
        finally:
            self.spawning = False
        return child

    def check_deferred(self):
        if self.stop_pending:
            raise KeyboardInterrupt

    def command(self, args, timeout=40):
        self.check()
        child = self.spawn(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.check_deferred()
            deadline = time.monotonic() + timeout
            while child.poll() is None:
                self.check()
                if time.monotonic() >= deadline:
                    raise TimeoutError('Device operation timed out')
                time.sleep(.2)
            if child.returncode:
                raise ValueError('Device operation failed')
        finally:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()

    def snapshot(self, path):
        if path.exists(): shutil.rmtree(path)
        self.command(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', self.device,
                      '--domain-type', 'appDataContainer', '--domain-identifier', guard.CLIENT_BUNDLE,
                      '--source', 'Library/Application Support/RemoteDesktopHost/Latency',
                      '--destination', str(path)])

    def install(self, app, scratch):
        self.check()
        app = app.resolve(strict=True)
        if not app.is_relative_to((guard.ROOT / 'build/latency').resolve()):
            raise ValueError('Invalid lab app path')
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        version, build = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')
        if info.get('CFBundleIdentifier') != guard.CLIENT_BUNDLE or not version or str(build) != str(self.build):
            raise ValueError('Invalid lab app identity')
        signed = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)],
                                capture_output=True, check=True, timeout=10)
        entitlements = plistlib.loads(signed.stdout)
        if (entitlements.get('get-task-allow') is not True or
                entitlements.get('com.apple.developer.icloud-container-environment') != 'Development'):
            raise ValueError('Invalid lab app signature')
        self.command(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', self.device, str(app)], 60)
        installed = scratch / 'installed.json'
        self.command(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', self.device,
                      '--bundle-id', guard.CLIENT_BUNDLE, '--json-output', str(installed)], 30)
        guard.verify_installed_lab(json.loads(installed.read_text()), version, build)
        self.check()

    def stop_child(self, child):
        if child is not None and child.poll() is None:
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()

    def cleanup(self):
        # Console signal reaches the exact launched app. If that fails, only
        # the exact PID from devicectl's launch result can be terminated.
        failure = False
        if self.client is not None:
            console_stopped = False
            if self.client.poll() is None:
                try:
                    guard.read_coordination_log()
                    self.client.send_signal(signal.SIGINT)
                    self.client.wait(timeout=3)
                    console_stopped = True
                except (subprocess.TimeoutExpired, ValueError, OSError):
                    pass
            if not console_stopped:
                try:
                    pid = json.loads(self.launch_json.read_text())['result']['process']['processIdentifier']
                    if type(pid) is not int or pid <= 0: raise ValueError('Invalid PID')
                    guard.read_coordination_log()
                    result = subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'terminate',
                        '--device', self.device, '--pid', str(pid)], stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, timeout=5)
                    if result.returncode: failure = True
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
                    failure = True
            if self.client.poll() is None:
                self.client.kill(); self.client.wait()
        self.stop_child(self.marker)
        if failure: raise RuntimeError('Could not confirm client cleanup')


def client_environment(mode):
    lan = mode == 'wifi'
    return {'LATENCY_LAB': '1', 'CONNECTIVITY_DIAGNOSTICS': '1',
            'LATENCY_LAB_F1': '1' if lan else '0',
            'LATENCY_LAB_F1_MAX_MS': '10' if lan else '0',
            'LATENCY_LAB_F2': '0', 'LATENCY_LAB_F3': '0', 'LATENCY_LAB_F4': '0'}


def run(args):
    device, host = private_config(args.config)
    build = guard.require_device_window()
    guard.require_selected_ipad(device, build)
    if not args.marker.is_file() or not os.access(args.marker, os.X_OK):
        raise ValueError('Required existing lab binary unavailable')
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    attempt = Attempt(device, build)
    prior_handlers = {sig: signal.signal(sig, attempt.signal_handler) for sig in (signal.SIGINT, signal.SIGTERM)}
    tmp = tempfile.TemporaryDirectory(prefix='cellular-lab-')
    marker_file = Path(tmp.name) / 'marker.json'
    try:
        root = Path(tmp.name)
        attempt.install(args.client_app, root)
        before = root / 'before'
        attempt.snapshot(before)
        previous_connectivity = {p.name for p in before.rglob('connectivity-*.jsonl')}
        previous_clients = {p.name for p in before.rglob('client-*.jsonl')}
        started = time.monotonic()
        attempt.launch_json = root / 'launch.json'
        attempt.client = attempt.spawn(['xcrun', 'devicectl', 'device', 'process', 'launch',
            '--device', device, '--console', '--terminate-existing', '--json-output', str(attempt.launch_json),
            '--environment-variables', json.dumps(client_environment(args.mode)),
            guard.CLIENT_BUNDLE, 'LatencyProbe', 'LatencyProbeHostID', host],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        attempt.check_deferred()
        deadline = time.monotonic() + args.timeout
        evidence = None
        first_video_seen = None
        snapshot = root / 'snapshot'
        while time.monotonic() < deadline:
            attempt.check()
            if attempt.client.poll() is not None:
                raise ValueError('Lab process ended before readiness')
            attempt.snapshot(snapshot)
            preserve_snapshot(snapshot, previous_connectivity, previous_clients, args.output)
            evidence = current_connectivity(snapshot, previous_connectivity)
            if evidence and evidence.get('failure_stage'):
                return {'status': 'partial', 'diagnostics': evidence, 'measurement': None}
            if evidence and 'time_to_video_ms' in evidence:
                if args.mode in ('baseline', 'wifi'):
                    if first_video_seen is None: first_video_seen = time.monotonic()
                    if 'selected_pair' in evidence or time.monotonic() - first_video_seen >= 5:
                        return {'status': 'partial', 'diagnostics': evidence, 'measurement': None}
                    # Allow the typed selected-pair report to arrive.
                else:
                    client = recent_client(snapshot, str(started))
                    if client is not None and client.name not in previous_clients:
                        break
            until = time.monotonic() + 2
            while time.monotonic() < until:
                attempt.check(); time.sleep(.2)
        else:
            return {'status': 'partial', 'diagnostics': evidence or {}, 'measurement': None}
        attempt.marker = attempt.spawn([str(args.marker)], env={**os.environ,
            'LATENCY_HOST_TRACE': str(marker_file), 'LATENCY_SECONDS': '60'},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        attempt.check_deferred()
        marker_deadline = time.monotonic() + 90
        while attempt.marker.poll() is None:
            attempt.check()
            if attempt.client.poll() is not None or time.monotonic() >= marker_deadline:
                raise ValueError('Measurement did not finish')
            time.sleep(.2)
        if attempt.marker.returncode: raise ValueError('Marker failed')
        for _ in range(15):
            attempt.check(); time.sleep(.2)
        attempt.snapshot(snapshot)
        preserve_snapshot(snapshot, previous_connectivity, previous_clients, args.output)
        preserve_marker(marker_file, args.output)
        evidence = current_connectivity(snapshot, previous_connectivity) or evidence
        selected = root / 'selected.jsonl'
        try:
            select(marker_file, snapshot, selected)
            if not any(p.name not in previous_clients and p.read_bytes() == selected.read_bytes()
                       for p in snapshot.rglob('client-*.jsonl')):
                raise ValueError('Stale client trace')
            preserve_snapshot(snapshot, previous_connectivity, previous_clients, args.output, selected)
            stats = measurement(marker_file, selected, read_rows(selected))
        except (OSError, KeyError, ValueError, TypeError, json.JSONDecodeError):
            stats = None
        return {'status': 'partial', 'diagnostics': evidence, 'measurement': stats}
    finally:
        for sig in prior_handlers: signal.signal(sig, signal.SIG_IGN)
        try: attempt.cleanup()
        finally:
            preserve_marker(marker_file, args.output)
            tmp.cleanup()
            for sig, old in prior_handlers.items(): signal.signal(sig, old)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--mode', choices=('baseline', 'mapped', 'wifi'), required=True)
    p.add_argument('--config', type=Path, required=True)
    p.add_argument('--client-app', type=Path, required=True)
    p.add_argument('--marker', type=Path, required=True)
    p.add_argument('--timeout', type=int, default=120, choices=range(1, 181))
    args = p.parse_args()
    try:
        print(json.dumps(run(args), sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError,
            subprocess.SubprocessError, KeyboardInterrupt):
        print(json.dumps({'status': 'infra-fail', 'measurement': None}))
        raise SystemExit(1)

if __name__ == '__main__': main()
