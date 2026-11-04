#!/usr/bin/env python3
"""Extract only categorical cellular diagnostics; never print raw trace or logs."""
import json
import math
import re

STAGES = {'signaling', 'ice_checking', 'dtls', 'hello', 'video'}
TYPES = {'host', 'srflx', 'prflx'}
FAMILIES = {'v4', 'v6', 'ipv4', 'ipv6'}
PROTOCOLS = {'udp', 'tcp'}
MAPPINGS = {'requested', 'mapped', 'double_nat', 'unavailable', 'released'}
SIGNALING_STAGES = {'offer_sent', 'answer_received', 'answer_applied', 'ice_connected'}
CANDIDATE_EVENTS = {'remote_candidate_received', 'remote_candidate_added', 'remote_candidate_add_failed'}
CANDIDATE_TYPES = {'host', 'srflx', 'prflx', 'unknown'}
CANDIDATE_FAMILIES = {'v4', 'v6', 'unknown'}


def clean_candidate_event(row):
    kind = row.get('event')
    candidate_type, family = row.get('candidateType'), row.get('family')
    count, elapsed = row.get('count'), row.get('elapsedMs')
    if (isinstance(kind, str) and kind in CANDIDATE_EVENTS
            and isinstance(candidate_type, str) and candidate_type in CANDIDATE_TYPES
            and isinstance(family, str) and family in CANDIDATE_FAMILIES
            and type(count) is int and 0 <= count <= 10_000
            and type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 0):
        return {'event': kind, 'candidateType': candidate_type, 'family': family,
                'count': count, 'elapsedMs': elapsed}
    return None


def clean_client(rows):
    """Accept one unambiguous attempt; return allowlisted facts only."""
    events = [r for r in rows if isinstance(r, dict) and r.get('type') == 'connectivity']
    starts = [r for r in events if r.get('event') == 'attempt_start']
    if len(starts) != 1 or not isinstance(starts[0].get('attempt'), str):
        raise ValueError('Missing or ambiguous attempt evidence')
    attempt = starts[0]['attempt']
    if any(r.get('attempt') != attempt for r in events):
        raise ValueError('Mixed attempt evidence')
    def timestamp(row):
        value = row.get('time')
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError('Invalid event timestamp')
        return value
    start = timestamp(starts[0]); out = {}
    for row in events:
        kind = row.get('event')
        if isinstance(kind, str) and kind in CANDIDATE_EVENTS:
            candidate = clean_candidate_event(row)
            if candidate is not None:
                out.setdefault('candidate_events', []).append(candidate)
        elif kind == 'stage' and row.get('stage') in SIGNALING_STAGES:
            out.setdefault('signaling_stages', []).append(row['stage'])
        elif kind == 'failure' and row.get('stage') in STAGES:
            out['failure_stage'] = row['stage']
        elif kind == 'first_presented':
            elapsed = timestamp(row) - start
            if elapsed < 0: raise ValueError('Invalid presentation timing')
            out['time_to_video_ms'] = round(elapsed * 1000, 1)
        elif kind == 'path':
            if row.get('interface') in {'wifi', 'cellular', 'wired', 'unknown'} and all(type(row.get(k)) is bool for k in ('hasIPv4', 'hasIPv6')):
                out['path'] = {k: row[k] for k in ('interface', 'hasIPv4', 'hasIPv6')}
        elif kind == 'selected_pair':
            keys = ('localType', 'localFamily', 'remoteType', 'remoteFamily', 'protocol')
            values = [row.get(k) for k in keys]
            if values[0] in TYPES and values[2] in TYPES and values[1] in FAMILIES and values[3] in FAMILIES and values[4] in PROTOCOLS:
                out['selected_pair'] = dict(zip(keys, values))
    return out


def clean_host(lines):
    """Recognize only exact status words in bounded host-log lines."""
    statuses = []
    for line in lines:
        match = re.search(r'(?<!\w)port_mapping=(requested|mapped|double_nat|unavailable|released)(?=\s|$)', line)
        if match: statuses.append(match.group(1))
    return {'mapping_statuses': statuses}


def measurement(marker_path, client_path, rows):
    """Return metrics only with a complete source and presentation window."""
    from summarize_latency import device_summary, summary
    from pathlib import Path
    marker = json.loads(Path(marker_path).read_text())
    report = device_summary(marker_path, client_path)
    samples = report['samples']
    source = sorted(marker['markers'], key=lambda r: r['host_display_s'])
    if (marker.get('duration_s', 0) < 60 or not marker.get('initial_marker_observed_before_timing')
            or report['source_marker_span_s'] < 59 or report['source_observer_missing_id_count']
            or report['source_marker_count'] != report['matched_marker_count']
            or report['rejected_marker_count'] or len(source) < 530):
        raise ValueError('Incomplete marker or clock coverage')
    frames = sorted(r['presentedTime'] for r in rows if r.get('type') == 'render'
                    and isinstance(r.get('presentedTime'), (int, float))
                    and not isinstance(r.get('presentedTime'), bool)
                    and math.isfinite(r['presentedTime']))
    first = min(r['client_presented_s'] for r in samples)
    last = max(r['client_presented_s'] for r in samples)
    frames = [x for x in frames if first <= x <= last]
    if len(frames) < 2 or frames[0] - first > .2 or last - frames[-1] > .2 or last - first < 59:
        raise ValueError('Incomplete presentation coverage')
    window = [r['screen_to_screen_ms'] for r in samples
              if source[0]['host_display_s'] <= r['host_display_s'] < source[0]['host_display_s'] + 30]
    if len(window) < 270:
        raise ValueError('Incomplete 30-second latency window')
    return {'screen_to_screen_30s': summary(window),
            'freeze_over_2s': any(b - a > 2 for a, b in zip(frames, frames[1:])),
            'observation_duration_s': marker['duration_s']}

def main():
    import argparse
    from pathlib import Path
    p = argparse.ArgumentParser(description='Parse one isolated client/host diagnostic window')
    p.add_argument('--connectivity', type=Path, required=True)
    p.add_argument('--client', type=Path, help='Matching complete client latency trace')
    p.add_argument('--host-log', type=Path, required=True)
    p.add_argument('--marker', type=Path, help='Complete 60-second marker data')
    args = p.parse_args()
    try:
        raw = args.connectivity.read_text()
        if raw and not raw.endswith('\n'): raise ValueError('Incomplete client trace')
        rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
        if any(isinstance(r, dict) and r.get('type') in {'truncated', 'trace_truncated'} for r in rows):
            raise ValueError('Truncated client trace')
        result = clean_client(rows)
        result.update(clean_host(args.host_log.read_text().splitlines()))
        result['measurement'] = None
        if args.marker and args.client:
            try:
                trace = args.client.read_text()
                if trace and not trace.endswith('\n'): raise ValueError('Incomplete latency trace')
                trace_rows = [json.loads(line) for line in trace.splitlines() if line.strip()]
                if any(isinstance(r, dict) and r.get('type') in {'truncated', 'trace_truncated'} for r in trace_rows):
                    raise ValueError('Truncated latency trace')
                result['measurement'] = measurement(args.marker, args.client, trace_rows)
            except (ValueError, KeyError, TypeError, OSError, ArithmeticError):
                pass  # Missing or incomplete evidence is unverified.
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        raise SystemExit('Evidence unavailable or incomplete')

if __name__ == '__main__':
    main()
