#!/usr/bin/env python3
"""Identify the unique session trace that overlaps a host marker run."""
import json
import shutil
import sys
from pathlib import Path
from summarize_latency import device_summary, strict_loads


def select(host_path, directory, destination):
    candidates = []
    for path in Path(directory).rglob('client-*.jsonl'):
        try:
            result = device_summary(host_path, path)
        except (ValueError, KeyError, OSError, TypeError, json.JSONDecodeError):
            continue
        rows = result['samples']
        markers = strict_loads(Path(host_path).read_text())['markers']
        # Measure observer coverage without treating skipped video markers as a
        # collection failure. Clock and render records must span the whole run.
        records = [strict_loads(line) for line in path.read_text().splitlines() if line.strip()]
        if any(r.get('type') in ('truncated', 'trace_truncated') for r in records):
            continue
        clocks = [r for r in records if r.get('type') == 'clock' and r.get('samples', 0) >= 50]
        complete_clock = any(abs((c['time'] + c['offset']) - markers[-1]['host_display_s']) <= 15 for c in clocks)
        if (len(rows) >= 10 and complete_clock and
                min(r['host_display_s'] for r in rows) <= markers[0]['host_display_s'] + 5 and
                max(r['host_display_s'] for r in rows) >= markers[-1]['host_display_s'] - 5):
            candidates.append(path)
    if len(candidates) != 1:
        raise ValueError(f'Expected one matching client session; found {len(candidates)}')
    shutil.copyfile(candidates[0], destination)


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit('Usage: select_device_trace.py HOST_JSON CLIENT_DIRECTORY OUTPUT_JSONL')
    select(*sys.argv[1:])
