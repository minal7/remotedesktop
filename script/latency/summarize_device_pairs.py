#!/usr/bin/env python3
"""Split one opt-in iPad session into its eight recorded measurement windows."""
import argparse
import json
import math
from pathlib import Path
from statistics import median

from summarize_latency import device_summary, strict_loads
from summarize_pairs import quantile


def read_trace(path):
    data = Path(path).read_bytes()
    if not data.endswith(b'\n'):
        raise ValueError(f'Incomplete trace snapshot: {path}')
    rows = [strict_loads(line) for line in data.decode().splitlines() if line.strip()]
    if any(r.get('type') in ('truncated', 'trace_truncated') for r in rows):
        raise ValueError(f'Trace reached its bound: {path}')
    return rows


def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def host_time(rows, client_time):
    clocks = [r for r in rows if r.get('type') == 'clock' and finite_number(r.get('samples'))
              and r['samples'] >= 50 and all(finite_number(r.get(k)) for k in ('time', 'offset', 'rtt', 'uncertainty'))
              and r['rtt'] >= 0 and r['uncertainty'] >= 0 and 0 <= client_time - r['time'] <= 15]
    if not clocks:
        raise ValueError('Segment boundary lacks a recent clock estimate.')
    return client_time + max(clocks, key=lambda r: r['time'])['offset']


def segments(rows):
    events = [r for r in rows if r.get('type') == 'lab_pair']
    if any(r.get('stage') == 'aborted' for r in events):
        raise ValueError('The paired session aborted; partial pairs are not acceptance data.')
    expected = [stage for _ in range(8) for stage in ('requested', 'begin', 'end')] + ['complete']
    if [r.get('stage') for r in events] != expected:
        raise ValueError('Pair events are missing, duplicated, or out of order.')
    completed = [r for r in events if r.get('stage') == 'complete']
    begins = [r for r in events if r.get('stage') == 'begin']
    ends = [r for r in events if r.get('stage') == 'end']
    if len(completed) != 1 or len(begins) != 8 or len(ends) != 8:
        raise ValueError('Eight complete windows in one session are required.')
    run = completed[0]['run']
    fix = completed[0]['fix']
    key = {'F1': 'f1Playout', 'F2': 'f2Encoder', 'F3': 'f3Sender', 'F4': 'f4Renderer'}[fix]
    result, fixed = [], None
    for index, (begin, end) in enumerate(zip(begins, ends), 1):
        requested = events[(index - 1) * 3]
        for event in (requested, begin, end):
            if (event['run'] != run or event['fix'] != fix or event['trial'] != index
                    or event['pair'] != (index + 1) // 2 or event['arm'] != ('A' if index % 2 else 'B')):
                raise ValueError('Pair order or session identity changed.')
        if (not all(finite_number(event.get('time')) for event in (requested, begin, end))
                or requested['time'] > begin['time'] or requested['settings'] != begin['settings']):
            raise ValueError('Requested configuration or timestamp does not match the window.')
        if ('peerNonce' not in begin or 'peerNonce' not in end
                or begin['settings'] != end['settings'] or begin['peerNonce'] != end['peerNonce']):
            raise ValueError('Configuration or peer changed during a measured window.')
        if abs(end['time'] - begin['time'] - 30) > .001:
            raise ValueError('Each measured window must be exactly 30 seconds.')
        if result and requested['time'] < result[-1][1]['time']:
            raise ValueError('A new trial was requested before the previous window ended.')
        settings = dict(begin['settings'])
        if settings.pop(key) is not (index % 2 == 0):
            raise ValueError('The selected toggle must alternate A off, B on.')
        if fixed is not None and settings != fixed:
            raise ValueError('A nonselected setting changed during the pairs.')
        fixed = settings
        result.append((begin, end))
    if (not finite_number(completed[0].get('time')) or completed[0]['time'] != result[-1][1]['time']
            or completed[0].get('trial') != 8 or completed[0].get('pair') != 4 or completed[0].get('arm') != 'B'):
        raise ValueError('Completion does not follow the final measured window.')
    return result


def write_trace(path, rows):
    path.write_text(''.join(json.dumps(row, sort_keys=True) + '\n' for row in rows))


def summarize(host_marker, client_trace, host_directory, output_directory):
    client = read_trace(client_trace)
    windows = segments(client)
    source = strict_loads(Path(host_marker).read_text())
    output_directory.mkdir(parents=True, exist_ok=True)
    host_traces = []
    for path in Path(host_directory).glob('host-*.jsonl'):
        # Ignore unrelated historical sessions; require complete snapshots only
        # for the peer selected by nonce and the measured time interval below.
        try:
            raw = path.read_text()
            rows = [strict_loads(line) for line in raw.splitlines() if line.strip()]
        except (OSError, ValueError, UnicodeError):
            continue
        host_traces.append((path, rows))
    results = []
    for begin, end in windows:
        start, stop = begin['time'], end['time']
        hstart, hstop = host_time(client, start), host_time(client, stop)
        matches = []
        for path, rows in host_traces:
            peers = [r for r in rows if r.get('type') == 'lab_peer']
            if (len(peers) == 1 and 'peerNonce' in peers[0] and peers[0]['peerNonce'] == begin['peerNonce']
                    and any(r.get('type') == 'stats' and hstart <= r.get('time', -1) <= hstop for r in rows)):
                matches.append((path, read_trace(path)))
        if len(matches) != 1:
            raise ValueError(f'Trial {begin["trial"]}: expected one matching host peer, got {len(matches)}.')
        host_path, host = matches[0]
        selected_markers = [r for r in source['markers'] if hstart <= r['host_display_s'] < hstop]
        if len(selected_markers) < 10:
            raise ValueError('Too few source markers in a measured window.')
        selected_client = [r for r in client if r.get('type') == 'clock'
                           or start <= r.get('time', r.get('presentedTime', -1)) < stop]
        stem = output_directory / f'{begin["pair"]}-{begin["arm"]}'
        marker_path = stem.with_suffix('.markers.json')
        selected_path = stem.with_suffix('.client.jsonl')
        telemetry_path = stem.with_suffix('.host.jsonl')
        marker_path.write_text(json.dumps({**source, 'duration_s': 30, 'markers': selected_markers}))
        write_trace(selected_path, selected_client)
        write_trace(telemetry_path, host)
        detail = device_summary(marker_path, selected_path, telemetry_path)
        client_stats = [r for r in selected_client if r.get('type') == 'stats' and r.get('side') == 'client']
        host_stats = [r for r in host if r.get('type') == 'stats' and hstart <= r.get('time', -1) < hstop]
        reports = [v for r in client_stats for v in r.get('reports', {}).values()]
        freeze_values = [v['freezeCountDelta'] for v in reports if 'freezeCountDelta' in v]
        metrics = {}
        for name, field in [('screen_to_screen', 'screen_to_screen'), ('render', 'all_frame_decode_to_present')]:
            for q in ('p50', 'p95'):
                metrics[f'{name}_{q}_ms'] = detail[field].get(f'{q}_ms')
        for field, data in [('host_stages', host_stats), ('client_stages', client_stats)]:
            for name in detail[field]:
                for q, fraction in [('p50', .5), ('p95', .95)]:
                    metrics[f'{name}_{q}'] = quantile([r.get('values', {}).get(name) for r in data], fraction)
        rtt = [r.get('values', {}).get('currentRoundTripTime') for r in client_stats]
        metrics['rtt_p95_ms'] = quantile([v * 1000 for v in rtt if isinstance(v, (int, float))], .95)
        metrics['freezes_per_minute'] = sum(freeze_values) * 2 if freeze_values else None
        entry = {'pair': begin['pair'], 'arm': begin['arm'], 'settings': begin['settings'],
                 'host_trace': str(host_path), 'peerNonce': begin.get('peerNonce'), 'metrics': metrics,
                 'wifi_spike': metrics['rtt_p95_ms'] is not None and metrics['rtt_p95_ms'] > 150,
                 'marker_coverage': [detail['matched_marker_count'], detail['source_marker_count']],
                 'sharpness': 'unverified', 'encoder_implementations': sorted({v['encoderImplementation']
                     for r in host_stats for v in r.get('reports', {}).values() if 'encoderImplementation' in v})}
        stem.with_suffix('.summary.json').write_text(json.dumps({**entry, 'detail': detail}, indent=2))
        results.append(entry)
    differences = []
    for a, b in zip(results[::2], results[1::2]):
        differences.append({key: b['metrics'][key] - value if value is not None and b['metrics'][key] is not None else None
                            for key, value in a['metrics'].items()})
    paired = {key: median([d[key] for d in differences]) if all(d[key] is not None for d in differences) else None
              for key in differences[0]}
    return {'fix': windows[0][0]['fix'], 'pairs': 4, 'run': windows[0][0]['run'],
            'median_paired_B_minus_A': paired, 'paired_differences': differences, 'runs': results,
            'note': 'Same app/signaling session, replacement peers between arms; one-second stage interval averages. '
                    'Wi-Fi spikes count. Sharpness and resource acceptance remain separate.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('host_marker', type=Path)
    parser.add_argument('client_trace', type=Path)
    parser.add_argument('host_directory', type=Path)
    parser.add_argument('output_directory', type=Path)
    args = parser.parse_args()
    result = summarize(args.host_marker, args.client_trace, args.host_directory, args.output_directory)
    (args.output_directory / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['median_paired_B_minus_A'], indent=2))
