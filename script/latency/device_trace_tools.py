#!/usr/bin/env python3
"""Pixel-free readiness, telemetry selection and network metadata helpers."""
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from summarize_latency import strict_loads


def read(path):
    try:
        return [strict_loads(line) for line in path.read_text().splitlines() if line.strip()]
    except (ValueError, OSError):
        return []


def recent_client(directory, since="0"):
    now = time.monotonic()
    found = []
    for p in Path(directory).rglob('client-*.jsonl'):
        for r in read(p):
            if (r.get('type') == 'clock' and r.get('samples', 0) >= 50 and
                    all(isinstance(r.get(k), (int, float)) and not isinstance(r.get(k), bool) for k in ('time', 'offset', 'rtt', 'uncertainty')) and
                    r['rtt'] >= 0 and r['uncertainty'] >= 0 and 0 <= now - (r['time'] + r['offset']) <= 15 and r['time'] + r['offset'] >= float(since)):
                found.append((r['time'] + r['offset'], p))
    return max(found, default=(None, None))[1]


def host_ready(directory, since):
    now = time.monotonic()
    return any(r.get('type') == 'stats' and r.get('side') == 'host' and
               float(since) <= r.get('time', -1) <= now and now - r['time'] <= 5
               for p in Path(directory).glob('host-*.jsonl') for r in read(p))


def resource_host_ready(directory, since):
    from resource_run import read_trace
    now = time.monotonic()
    for path in Path(directory).glob('host-*.jsonl'):
        try:
            records = read_trace(path, 'host')
        except (ValueError, OSError, UnicodeError, TypeError):
            continue
        if any(r.get('type') == 'resource' and isinstance(r.get('time'), (int, float)) and
               float(since) <= r['time'] <= now and now - r['time'] <= 5 and
               isinstance(r.get('processCPUPercent'), (int, float)) for r in records):
            return True
    return False


def host_telemetry(host_marker, directory, output):
    markers = strict_loads(Path(host_marker).read_text())['markers']
    if not markers:
        raise ValueError('No source markers')
    start, end = markers[0]['host_display_s'], markers[-1]['host_display_s']
    matches = []
    for p in Path(directory).glob('host-*.jsonl'):
        try:
            snapshot = p.read_bytes()
            if snapshot and not snapshot.endswith(b'\n'):
                continue
            records = [strict_loads(line) for line in snapshot.decode('utf-8').splitlines() if line.strip()]
        except (ValueError, OSError, UnicodeError):
            continue
        if any(r.get('type') in ('truncated', 'trace_truncated') for r in records):
            continue
        stats = [r for r in records if r.get('type') == 'stats' and r.get('side') == 'host'
                 and start - 2 <= r.get('time', -1) <= end]
        # Verify both ends so a trace cut off at the 1 MB limit fails closed.
        if stats and min(r['time'] for r in stats) <= start + 3 and max(r['time'] for r in stats) >= end - 3:
            matches.append(snapshot)
    if len(matches) != 1:
        raise ValueError(f'Expected one complete host session, found {len(matches)}')
    Path(output).write_bytes(matches[0])


def metadata(host_hz, client_hz, output):
    result = {'host_refresh_hz': float(host_hz), 'client_refresh_hz': float(client_hz),
              'refresh_rates': 'user-supplied assumptions, not measured presentation cadence',
              'wifi_channel': None, 'wifi_band': None, 'awdl': 'not independently identified'}
    try:
        raw = subprocess.run(['system_profiler', 'SPAirPortDataType', '-json'], capture_output=True, text=True, timeout=25, check=True)
        data = json.loads(raw.stdout)
        def visit(obj):
            if isinstance(obj, dict):
                for k, v in obj.items():
                    if 'current' in k.lower() and isinstance(v, dict):
                        for ck, cv in v.items():
                            if 'channel' in ck.lower() and isinstance(cv, (str, int)):
                                return str(cv)
                    value = visit(v)
                    if value: return value
            elif isinstance(obj, list):
                for v in obj:
                    value = visit(v)
                    if value: return value
            return None
        channel = visit(data)
        if channel:
            match = re.search(r'\b(\d+)\b', channel)
            result['wifi_channel'] = int(match.group(1)) if match else None
            band = re.search(r'\b(2\.4|5|6)\s*GHz\b', channel, re.I)
            result['wifi_band'] = band.group(1) + ' GHz' if band else None
    except (subprocess.SubprocessError, OSError, ValueError):
        pass
    Path(output).write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    if sys.argv[1] == 'ready':
        path = recent_client(*sys.argv[2:])
        if path is None: raise SystemExit(1)
        print(path)
    elif sys.argv[1] == 'host-ready':
        if not host_ready(*sys.argv[2:]): raise SystemExit(1)
    elif sys.argv[1] == 'resource-host-ready':
        if not resource_host_ready(*sys.argv[2:]): raise SystemExit(1)
    elif sys.argv[1] == 'host':
        host_telemetry(*sys.argv[2:])
    elif sys.argv[1] == 'metadata':
        metadata(*sys.argv[2:])
    else:
        raise SystemExit('Unknown command')
