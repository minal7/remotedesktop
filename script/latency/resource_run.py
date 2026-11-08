#!/usr/bin/env python3
"""Select and summarize one bounded, resource-only physical-device run."""
import json
import math
import sys
from pathlib import Path
from summarize_latency import resource_summary, strict_loads

LIMIT = 1_000_000


def read_trace(path, side):
    data = path.read_bytes()
    if not data or len(data) > LIMIT or not data.endswith(b'\n'):
        raise ValueError('Trace missing, incomplete or over byte cap')
    records = [strict_loads(line) for line in data.decode('utf-8').splitlines() if line.strip()]
    if any(r.get('type') in ('truncated', 'trace_truncated') for r in records):
        raise ValueError('Trace truncated')
    if not any(r.get('type') == 'resource_mode' and r.get('side') == side and
               r.get('resourceCadenceSeconds') == 1 and r.get('statsCadenceSeconds') == 10 for r in records):
        raise ValueError(f'{side} was not launched in resource-only mode')
    return records


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def clocks_from(records):
    return sorted((r for r in records if r.get('type') == 'clock' and r.get('samples', 0) >= 50
                   and all(finite(r.get(k)) for k in ('time', 'offset', 'rtt', 'uncertainty'))
                   and r['rtt'] >= 0 and r['uncertainty'] >= 0), key=lambda r: r['time'])


def converted_client_times(records, clocks, start, end):
    times = []
    for r in records:
        t = r.get('time')
        if r.get('type') != 'resource' or not finite(t):
            continue
        recent = [c for c in clocks if c['time'] <= t and t - c['time'] <= 15]
        if recent:
            converted = t + recent[-1]['offset']
            if start <= converted <= end:
                times.append(converted)
    return sorted(times)


def coverage(times, start, end):
    if len(times) < 2:
        return {'samples': len(times), 'span_s': 0, 'complete': False}
    times = sorted(times)
    span = times[-1] - times[0]
    max_gap = max(b - a for a, b in zip(times, times[1:]))
    return {'samples': len(times), 'span_s': span, 'max_gap_s': max_gap,
            'complete': span >= 598 and times[0] <= start + 2 and times[-1] >= end - 2 and max_gap <= 5}


def report(host, client, start, end, requested):
    if not all(finite(v) for v in (start, end, requested)) or requested < 600 or end - start < 600:
        raise ValueError('Resource run requires at least 600 seconds requested and elapsed')
    clocks = clocks_from(client)
    host_times = [r['time'] for r in host if r.get('type') == 'resource' and finite(r.get('time'))
                  and finite(r.get('processCPUPercent')) and r['processCPUPercent'] >= 0 and start <= r['time'] <= end]
    client_times = converted_client_times(client, clocks, start, end)
    host_coverage, client_coverage = coverage(host_times, start, end), coverage(client_times, start, end)
    resources = resource_summary(host, client, clocks, start, end)
    battery = resources['client_battery']
    battery['continuous_unplugged_samples'] = (bool(client_times) and battery['state_counts'] == {'1': len(client_times)}
                                               and battery['valid_level_samples'] == len(client_times))
    return {'kind': 'resource_only', 'requested_duration_s': requested, 'elapsed_s': end - start,
            'host_coverage': host_coverage, 'client_coverage': client_coverage,
            'coverage_complete': host_coverage['complete'] and client_coverage['complete'],
            'resources': resources, 'gpu_use': None, 'within_15_percent_verdict': None,
            'note': 'Battery levels are coarse; charging, unknown states, gaps, or insufficient resolution prevent a drain comparison. Thermal states alone do not prove absence of throttling.'}


def select(directory, side, start, end):
    matches = []
    for path in Path(directory).rglob(f'{side}-*.jsonl'):
        try:
            records = read_trace(path, side)
            if side == 'host':
                times = [r['time'] for r in records if r.get('type') == 'resource' and finite(r.get('time'))
                         and finite(r.get('processCPUPercent')) and start <= r['time'] <= end]
            else:
                times = converted_client_times(records, clocks_from(records), start, end)
            if coverage(times, start, end)['complete']:
                matches.append((path, records))
        except (ValueError, OSError, UnicodeError, TypeError):
            continue
    if len(matches) != 1:
        raise ValueError(f'Expected one complete {side} resource trace, found {len(matches)}')
    return matches[0]


if __name__ == '__main__':
    if len(sys.argv) != 7:
        raise SystemExit('Usage: resource_run.py HOST_DIR CLIENT_DIR START END REQUESTED OUTPUT_DIR')
    host_dir, client_dir, start, end, requested, output = sys.argv[1:]
    start, end, requested = float(start), float(end), float(requested)
    host_path, host = select(host_dir, 'host', start, end)
    client_path, client = select(client_dir, 'client', start, end)
    result = report(host, client, start, end, requested)
    if not result['coverage_complete']:
        raise SystemExit('Resource coverage incomplete')
    output = Path(output)
    # Write the already-validated snapshots, not a second read of live files.
    (output / 'host-resource.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in host))
    (output / 'client-resource.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in client))
    (output / 'resource-summary.json').write_text(json.dumps(result, indent=2) + '\n')
