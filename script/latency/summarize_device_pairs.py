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


def present_interval_p95_ms(rows):
    times = sorted(r['presentedTime'] for r in rows
                   if r.get('type') == 'render' and finite_number(r.get('presentedTime')))
    return quantile([(b - a) * 1000 for a, b in zip(times, times[1:])], .95)


def locked_25ms_runs(rows, tolerance_ms=1.0, minimum_gaps=20):
    """Count consecutive ~25 ms presentation gaps, not a broad 25–50ms bucket."""
    times = sorted(r['presentedTime'] for r in rows
                   if r.get('type') == 'render' and finite_number(r.get('presentedTime')))
    runs, count = [], 0
    for a, b in zip(times, times[1:]):
        gap = (b - a) * 1000
        if abs(gap - 25) <= tolerance_ms:
            count += 1
        else:
            if count >= minimum_gaps: runs.append(count)
            count = 0
    if count >= minimum_gaps: runs.append(count)
    return {'observed_runs': len(runs), 'longest_consecutive_gaps': max(runs, default=0),
            'tolerance_ms': tolerance_ms, 'minimum_consecutive_gaps': minimum_gaps,
            'presentation_records': len(times),
            'interpretation': 'observed timestamp cadence; not a freeze or complete-coverage claim'}


PAIR_ENUMS = {'localCandidateType': {'host', 'srflx', 'prflx', 'unknown'},
              'remoteCandidateType': {'host', 'srflx', 'prflx', 'unknown'},
              'localCandidateFamily': {'v4', 'v6', 'unknown'},
              'remoteCandidateFamily': {'v4', 'v6', 'unknown'},
              'candidateProtocol': {'udp', 'tcp', 'unknown'}}
STATS_NUMERIC = {'rttFloorMs', 'currentRoundTripTime', 'captureWidth', 'captureHeight',
                 'frameWidth', 'frameHeight', 'framesDecodedDelta', 'framesEncodedDelta',
                 'framesDroppedDelta', 'freezeCountDelta', 'packetsLostDelta',
                 'availableOutgoingBitrate', 'targetBitrate', 'packetSendMs', 'encodeMs',
                 'jitterBufferMs', 'jitterBufferTargetMs', 'decodeMs', 'framesPerSecond',
                 'bytesSentDelta', 'bytesReceivedDelta', 'packetsSentDelta', 'packetsReceivedDelta',
                 'jitter'}
FLAG_KEYS = {'f1Playout', 'f1MaximumDelayMs', 'f2Encoder', 'f3Sender', 'f4Renderer', 'renderHint60'}


def safe_implementation(value):
    # Fixed vocabularies ensure arbitrary SDP/identifiers cannot leak into output.
    return value if value in ('VideoToolbox', 'OpenH264', 'libvpx', 'software', 'unknown') else None


def sanitize_stage0(rows):
    """Keep only typed lab metrics; strip report/peer/attempt IDs and arbitrary strings."""
    out = []
    for row in rows:
        kind = row.get('type')
        if kind == 'stats' and finite_number(row.get('time')):
            vals = row.get('values', {})
            if not isinstance(vals, dict): continue
            safe = {k: v for k, v in vals.items() if k in STATS_NUMERIC and finite_number(v)}
            for key, allowed in PAIR_ENUMS.items():
                if isinstance(vals.get(key), str) and vals[key] in allowed: safe[key] = vals[key]
            impl = safe_implementation(vals.get('encoderImplementation'))
            if impl: safe['encoderImplementation'] = impl
            if vals.get('codec_mimeType') in ('video/H264', 'video/VP8', 'video/VP9', 'video/AV1'):
                safe['codec_mimeType'] = vals['codec_mimeType']
            streams = []
            reports = row.get('reports', {})
            if isinstance(reports, dict):
                for report in reports.values():
                    if not isinstance(report, dict): continue
                    item = {k: v for k, v in report.items() if k in STATS_NUMERIC and finite_number(v)}
                    impl = safe_implementation(report.get('encoderImplementation'))
                    if impl: item['encoderImplementation'] = impl
                    if report.get('codec_mimeType') in ('video/H264', 'video/VP8', 'video/VP9', 'video/AV1'):
                        item['codec_mimeType'] = report['codec_mimeType']
                    if item: streams.append(item)
            item = {'type': kind, 'time': row['time'], 'values': safe, 'streams': streams}
            if row.get('side') in ('host', 'client'): item['side'] = row['side']
            out.append(item)
        elif kind == 'encoded_frame_sizes' and finite_number(row.get('time')):
            keys = ('count', 'p50Bytes', 'p95Bytes', 'maxBytes')
            if (all(type(row.get(k)) is int and row[k] >= 0 for k in keys)
                    and row['p50Bytes'] <= row['p95Bytes'] <= row['maxBytes']
                    and type(row.get('complete')) is bool):
                item = {'type': kind, 'time': row['time'], **{k: row[k] for k in keys}, 'complete': row['complete']}
                for key in ('intervalStart', 'intervalSeconds'):
                    if finite_number(row.get(key)) and row[key] >= 0: item[key] = row[key]
                out.append(item)
        elif kind == 'render':
            keys = ('decodeTime', 'submittedTime', 'presentedTime', 'acquisitionRequestedTime', 'acquisitionReturnedTime', 'receiptDeliveryTime')
            safe = {k: row[k] for k in keys if finite_number(row.get(k))}
            if 'presentedTime' in safe: out.append({'type': kind, **safe})
        elif kind == 'marker' and type(row.get('marker_id')) is int and finite_number(row.get('presentedTime')):
            out.append({'type': kind, 'marker_id': row['marker_id'], 'presentedTime': row['presentedTime'],
                        **({'decodeTime': row['decodeTime']} if finite_number(row.get('decodeTime')) else {})})
        elif kind == 'clock' and all(finite_number(row.get(k)) for k in ('time', 'offset', 'rtt', 'uncertainty', 'samples')):
            out.append({'type': kind, **{k: row[k] for k in ('time', 'offset', 'rtt', 'uncertainty', 'samples')}})
        elif kind == 'lab_pair' and row.get('fix') == 'R60' and row.get('stage') in ('requested', 'begin', 'end', 'complete') and isinstance(row.get('settings'), dict):
            settings = {k: v for k, v in row['settings'].items() if k in FLAG_KEYS and
                        ((k != 'f1MaximumDelayMs' and type(v) is bool) or
                         (k == 'f1MaximumDelayMs' and type(v) is int and v in (10, 20)))}
            if (finite_number(row.get('time')) and row.get('arm') in ('A', 'B') and
                    type(row.get('trial')) is int and 1 <= row['trial'] <= 8 and
                    type(row.get('pair')) is int and 1 <= row['pair'] <= 4):
                out.append({'type': kind, 'fix': 'R60', 'stage': row['stage'], 'time': row['time'],
                            'arm': row['arm'], 'trial': row['trial'], 'pair': row['pair'], 'settings': settings})
        elif kind == 'lab_configuration' and isinstance(row.get('settings'), dict):
            settings = {k: v for k, v in row['settings'].items() if k in FLAG_KEYS and
                        ((k != 'f1MaximumDelayMs' and type(v) is bool) or
                         (k == 'f1MaximumDelayMs' and type(v) is int and v in (0, 10, 20)))}
            if finite_number(row.get('time')): out.append({'type': kind, 'time': row['time'], 'settings': settings})
        elif kind == 'stream_event' and row.get('event') == 'bandwidth_estimate_drop':
            before, after = row.get('beforeBps'), row.get('afterBps')
            if (finite_number(row.get('time')) and finite_number(before) and finite_number(after)
                    and before > 0 and 0 <= after < before * .5 and row.get('metric') in ('targetBitrate', 'availableOutgoingBitrate')):
                out.append({'type': kind, 'time': row['time'], 'event': row['event'],
                            'metric': row['metric'], 'beforeBps': before, 'afterBps': after})
    return out


def sanitize_fixture_markers(markers):
    """Retain observed transition timing without fixture paths, pixels, or arbitrary strings."""
    out = []
    for row in markers:
        if type(row.get('marker_id')) is not int or not finite_number(row.get('host_display_s')):
            continue
        item = {'marker_id': row['marker_id'], 'host_display_s': row['host_display_s']}
        if type(row.get('previous_marker_id')) is int: item['previous_marker_id'] = row['previous_marker_id']
        if finite_number(row.get('previous_host_display_s')): item['previous_host_display_s'] = row['previous_host_display_s']
        if row.get('scene') in ('text', 'photo'): item['scene'] = row['scene']
        if type(row.get('scene_transition')) is bool: item['scene_transition'] = row['scene_transition']
        out.append(item)
    return out


def network_intervals(rows, start=None, stop=None):
    """Observed video RTP deltas per poll; estimates are not link capacity."""
    stats = sorted((r for r in rows if r.get('type') == 'stats' and finite_number(r.get('time'))),
                   key=lambda r: r['time'])
    result = []
    def nonnegative(value):
        return value if finite_number(value) and value >= 0 else None
    for old, current in zip(stats, stats[1:]):
        dt = current['time'] - old['time']
        if not 0 < dt <= 5 or (start is not None and old['time'] < start) or (stop is not None and current['time'] >= stop):
            continue
        values = current.get('values') if isinstance(current.get('values'), dict) else {}
        reports = current.get('reports') if isinstance(current.get('reports'), dict) else {}
        streams = []
        for report in reports.values():
            if not isinstance(report, dict): continue
            sent = nonnegative(report.get('bytesSentDelta'))
            received = nonnegative(report.get('bytesReceivedDelta'))
            packets_sent = nonnegative(report.get('packetsSentDelta'))
            packets_received = nonnegative(report.get('packetsReceivedDelta'))
            packets_lost = nonnegative(report.get('packetsLostDelta'))
            jitter = nonnegative(report.get('jitter'))
            if all(v is None for v in (sent, received, packets_sent, packets_received, packets_lost, jitter)):
                continue
            streams.append({'sent_bps': sent * 8 / dt if sent is not None else None,
                            'received_bps': received * 8 / dt if received is not None else None,
                            'packets_sent_delta': packets_sent, 'packets_received_delta': packets_received,
                            'packets_lost_delta': packets_lost,
                            'rtp_jitter_ms': jitter * 1000 if jitter is not None else None,
                            'sender_packet_send_ms': nonnegative(report.get('packetSendMs')),
                            'target_bitrate_estimate_bps': nonnegative(report.get('targetBitrate'))})
        rtt = nonnegative(values.get('currentRoundTripTime'))
        result.append({'time': current['time'], 'interval_s': dt, 'streams': streams,
                       'streams_missing': not streams,
                       'rtt_ms': rtt * 1000 if rtt is not None else None,
                       'sender_packet_send_ms': nonnegative(values.get('packetSendMs')),
                       'target_bitrate_estimate_bps': nonnegative(values.get('targetBitrate')),
                       'available_outgoing_estimate_bps': nonnegative(values.get('availableOutgoingBitrate'))})
    return {'intervals': result, 'note': 'Video RTP byte deltas per poll; estimates are not measured capacity. Missing values are null.'}


def stage0_window(client, host, begin, end, detail, source_markers):
    """Comparable per-window evidence, with missing facts explicit and no guessed paths."""
    start, stop = begin['time'], end['time']
    selected_client = [r for r in client if start <= r.get('time', r.get('presentedTime', -1)) < stop]
    render = [r for r in selected_client if r.get('type') == 'render' and finite_number(r.get('presentedTime'))]
    host_stats = [r for r in host if r.get('type') == 'stats']
    pairs = []
    for r in host_stats:
        v = r.get('values', {})
        if not isinstance(v, dict): continue
        pair = {k: v[k] for k, allowed in PAIR_ENUMS.items() if isinstance(v.get(k), str) and v[k] in allowed}
        if len(pair) == len(PAIR_ENUMS) and pair not in pairs: pairs.append(pair)
    client_pairs = []
    for r in selected_client:
        v = r.get('values', {}) if r.get('type') == 'stats' else {}
        if not isinstance(v, dict): continue
        pair = {k: v[k] for k, allowed in PAIR_ENUMS.items() if isinstance(v.get(k), str) and v[k] in allowed}
        if len(pair) == len(PAIR_ENUMS) and pair not in client_pairs: client_pairs.append(pair)
    window_rtts = [r.get('values', {}).get('currentRoundTripTime') for r in host_stats + selected_client
                   if r.get('type') == 'stats' and isinstance(r.get('values'), dict)]
    window_rtts = [1000*x for x in window_rtts if finite_number(x) and x > 0]
    lifetime_floors = [r.get('values', {}).get('rttFloorMs') for r in host_stats + selected_client
                       if r.get('type') == 'stats' and isinstance(r.get('values'), dict)]
    lifetime_floors = [x for x in lifetime_floors if finite_number(x) and x > 0]
    per_second = []
    for second in range(30):
        n = sum(start + second <= r['presentedTime'] < start + second + 1 for r in render)
        per_second.append({'second': second, 'presented_frames': n})
    decoded = []
    stats = sorted((r for r in client if r.get('type') == 'stats' and r.get('side') == 'client'
                    and finite_number(r.get('time'))), key=lambda r:r['time'])
    for a, b in zip(stats, stats[1:]):
        dt = b['time'] - a['time']; v = b.get('values', {})
        if (start <= b['time'] < stop and 0 < dt <= 5 and isinstance(v, dict)
                and finite_number(v.get('framesDecodedDelta')) and v['framesDecodedDelta'] >= 0):
            decoded.append({'second': int(b['time'] - start), 'fps': v['framesDecodedDelta'] / dt, 'interval_s': dt})
    def durations(first, second):
        return [1000 * (r[second] - r[first]) for r in render if finite_number(r.get(first))
                and finite_number(r.get(second)) and r[second] >= r[first]]
    render_split = {}
    for label, first, second in [('decode_to_submitted', 'decodeTime', 'submittedTime'),
                                 ('submitted_to_presented', 'submittedTime', 'presentedTime'),
                                 ('acquisition_wait', 'acquisitionRequestedTime', 'acquisitionReturnedTime'),
                                 ('presentation_to_receipt', 'presentedTime', 'receiptDeliveryTime')]:
        v = durations(first, second)
        render_split[label] = {'count': len(v), 'p50_ms': quantile(v, .5), 'p95_ms': quantile(v, .95), 'max_ms': max(v) if v else None}
    transitions = {r['marker_id'] for r in source_markers if r.get('scene_transition') is True and
                   r.get('scene') in ('text', 'photo') and type(r.get('marker_id')) is int}
    change_delays = [r['screen_to_screen_ms'] for r in detail.get('samples', [])
                     if r.get('marker_id') in transitions and finite_number(r.get('screen_to_screen_ms'))]
    times = sorted(r['presentedTime'] for r in render)
    render_coverage = len(times) >= 2 and times[0] <= start + .25 and times[-1] >= stop - .25
    locked = locked_25ms_runs(render)
    locked['coverage'] = 'observed_window' if render_coverage else 'unverified'
    decoded_duration = sum(r['interval_s'] for r in decoded)
    decoded_window_fps = (sum(r['fps'] * r['interval_s'] for r in decoded) / decoded_duration
                          if decoded_duration >= 29 else None)
    codec = set(); implementations = set(); capture_sizes = set()
    for r in sanitize_stage0(host):
        if r['type'] != 'stats': continue
        for v in [r['values'], *r.get('streams', [])]:
            if v.get('codec_mimeType'): codec.add(v['codec_mimeType'])
            if v.get('encoderImplementation'): implementations.add(v['encoderImplementation'])
            if all(finite_number(v.get(k)) and v[k] > 0 and float(v[k]).is_integer() for k in ('captureWidth', 'captureHeight')):
                capture_sizes.add((int(v['captureWidth']), int(v['captureHeight'])))
    observed_pairs = [pair for pair in pairs if all(v != 'unknown' for v in pair.values())]
    observed_client_pairs = [pair for pair in client_pairs if all(v != 'unknown' for v in pair.values())]
    return {'selected_pairs': pairs, 'client_selected_pairs': client_pairs,
            'pair_status': ('changed' if len(pairs) > 1 or len(client_pairs) > 1 else
                            'observed' if observed_pairs or observed_client_pairs else 'unverified'),
            'codecs': sorted(codec), 'encoder_implementations': sorted(implementations),
            'capture_sizes': [{'width': w, 'height': h} for w, h in sorted(capture_sizes)],
            'rtt_floor_ms': min(window_rtts) if window_rtts else None,
            'lifetime_rtt_floor_ms': min(lifetime_floors) if lifetime_floors else None,
            'flags': {k: v for k, v in begin['settings'].items() if k in FLAG_KEYS},
            'network_host': network_intervals(host),
            'network_client': network_intervals(client, start, stop),
            'presented_frames_per_second': per_second, 'decoded_fps_by_interval': decoded,
            'locked_25ms': locked, 'render_split': render_split,
            'presented_window_fps': len(times) / (stop - start) if render_coverage else None,
            'decoded_window_fps': decoded_window_fps,
            'fps_note': 'Window averages include idle time; compare active content separately.',
            'large_change_first_frame_ms': {'count': len(change_delays), 'p50': quantile(change_delays, .5),
                                             'p95': quantile(change_delays, .95),
                                             'note': 'observed scene transitions only; not a sharpness measurement'},
            'screen_to_screen': detail.get('screen_to_screen'),
            'encoded_frame_sizes': [r for r in sanitize_stage0(host) if r['type'] == 'encoded_frame_sizes'],
            'estimate_drops_over_50_percent': [r for r in sanitize_stage0(host) if r['type'] == 'stream_event']}


def selected_fixes(value):
    parts = value.split('+') if isinstance(value, str) else []
    if (not parts or len(set(parts)) != len(parts) or parts != sorted(parts)
            or any(part not in ('F1', 'F2', 'F3', 'F4', 'R60') for part in parts)
            or ('R60' in parts and len(parts) != 1)):
        raise ValueError('Expected R60 alone, or unique sorted F1–F4 fixes joined by +.')
    return parts


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
    fixes = selected_fixes(fix)
    first_settings = begins[0]['settings']
    f1_delay = fixes == ['F1'] and first_settings.get('f1Playout') is True
    r60 = fixes == ['R60']
    incremental = fixes != ['F1'] and not r60
    if r60 and (type(first_settings.get('f1Playout')) is not bool or
                type(first_settings.get('f1MaximumDelayMs')) is not int or
                first_settings['f1MaximumDelayMs'] not in (10, 20) or
                any(first_settings.get(k) is not False for k in ('f2Encoder', 'f3Sender', 'f4Renderer'))):
        raise ValueError('R60 requires an explicit F1 baseline and F2/F3/F4 off.')
    if (incremental or f1_delay) and (first_settings.get('f1Playout') is not True or
                                      first_settings.get('f1MaximumDelayMs') != 10):
        raise ValueError('F1 baseline must use a 10 ms maximum delay.')
    keys = [{'F1': 'f1Playout', 'F2': 'f2Encoder', 'F3': 'f3Sender', 'F4': 'f4Renderer', 'R60': 'renderHint60'}[part]
            for part in fixes if not (part == 'F1' and (incremental or f1_delay))]
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
        if f1_delay:
            if settings.pop('f1MaximumDelayMs', None) != (20 if index % 2 == 0 else 10):
                raise ValueError('F1 delay comparison must alternate 10 ms and 20 ms.')
        for key in keys:
            if settings.pop(key, None) is not (index % 2 == 0):
                raise ValueError('Every selected toggle must alternate A off, B on.')
        if fixed is not None and settings != fixed:
            raise ValueError('A nonselected setting changed during the pairs.')
        fixed = settings
        result.append((begin, end))
    if r60 and completed[0].get('settings') != result[-1][0]['settings']:
        raise ValueError('R60 completion does not retain the final measured settings.')
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
    scene_interval = source.get('scene_interval_s')
    if 'scene_interval_s' in source:
        if (not finite_number(scene_interval) or scene_interval not in (2, 8)):
            raise ValueError('Fixture scene interval must be 2 or 8 seconds.')
        scene_interval = int(scene_interval)
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
        marker_caveat = 'fewer than 10 source markers' if len(selected_markers) < 10 else None
        selected_client = [r for r in client if r.get('type') == 'clock'
                           or start <= r.get('time', r.get('presentedTime', -1)) < stop]
        stem = output_directory / f'{begin["pair"]}-{begin["arm"]}'
        marker_path = stem.with_suffix('.markers.json')
        selected_path = stem.with_suffix('.client.jsonl')
        telemetry_path = stem.with_suffix('.host.jsonl')
        marker_path.write_text(json.dumps({**source, 'duration_s': 30, 'markers': selected_markers}))
        write_trace(selected_path, selected_client)
        write_trace(telemetry_path, host)
        try:
            detail = device_summary(marker_path, selected_path, telemetry_path)
        except ValueError as error:
            if selected_markers and str(error) != 'No matched markers with a recent clock estimate':
                raise
            # Keep the run, but never turn absent screen-to-screen evidence into a pass.
            marker_caveat = 'no matched marker with a recent clock estimate'
            detail = {'samples': [], 'screen_to_screen': {}, 'all_frame_decode_to_present': {},
                      'host_stages': {'encodeMs': {}, 'packetSendMs': {}},
                      'client_stages': {k: {} for k in ('jitterBufferMs', 'jitterBufferTargetMs', 'decodeMs', 'processingMs')},
                      'matched_marker_count': 0, 'source_marker_count': len(selected_markers)}
        client_stats = [r for r in selected_client if r.get('type') == 'stats' and r.get('side') == 'client']
        host_stats = [r for r in host if r.get('type') == 'stats' and hstart <= r.get('time', -1) < hstop]
        reports = [v for r in client_stats for v in r.get('reports', {}).values()]
        freeze_values = [v['freezeCountDelta'] for v in reports if 'freezeCountDelta' in v]
        metrics = {}
        metrics['present_interval_p95_ms'] = present_interval_p95_ms(selected_client)
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
        selected_host = [r for r in host if hstart <= r.get('time', -1) < hstop]
        stage0 = stage0_window(client, selected_host, begin, end, detail, selected_markers)
        if begin['fix'] == 'R60':
            # Requested state is not proof that the display link applied it.
            stage0['render_hint_application'] = 'unverified'
        missing_evidence = []
        if begin['fix'] == 'R60': missing_evidence.append('render hint application unverified')
        if stage0['pair_status'] != 'observed': missing_evidence.append('selected pair missing or changed')
        if stage0['rtt_floor_ms'] is None: missing_evidence.append('RTT floor missing')
        if not all(k in stage0['flags'] for k in ('f1Playout', 'f1MaximumDelayMs', 'f2Encoder', 'f3Sender', 'f4Renderer')):
            missing_evidence.append('F flags missing')
        if metrics['screen_to_screen_p50_ms'] is None or metrics['screen_to_screen_p95_ms'] is None:
            missing_evidence.append('screen-to-screen unavailable')
        if stage0['locked_25ms']['coverage'] != 'observed_window': missing_evidence.append('presentation coverage incomplete')
        if stage0['decoded_window_fps'] is None: missing_evidence.append('decoded coverage incomplete')
        if not stage0['codecs']: missing_evidence.append('codec missing')
        if not stage0['encoder_implementations']: missing_evidence.append('encoder implementation missing')
        if not stage0['capture_sizes']: missing_evidence.append('capture size missing')
        byte_rows = stage0['encoded_frame_sizes']
        if (not byte_rows or not all(r.get('complete') is True and r.get('count', 0) > 0 for r in byte_rows)
                or sum(r.get('intervalSeconds', 0) for r in byte_rows) < 29):
            missing_evidence.append('encoded frame byte coverage incomplete')
        stage0['missing_comparison_evidence'] = missing_evidence
        stage0['comparison_evidence_complete'] = not missing_evidence
        metrics['presented_fps'] = stage0['presented_window_fps']
        metrics['decoded_fps'] = stage0['decoded_window_fps']
        metrics['locked_25ms_runs'] = (stage0['locked_25ms']['observed_runs']
                                       if stage0['locked_25ms']['coverage'] == 'observed_window' else None)
        metrics['rtt_floor_ms'] = stage0['rtt_floor_ms']
        stem.with_suffix('.fixture-sanitized.json').write_text(json.dumps({'duration_s': 30, 'scene_interval_s': scene_interval,
                                                                        'markers': sanitize_fixture_markers(selected_markers)}, indent=2) + '\n')
        write_trace(stem.with_suffix('.client-sanitized.jsonl'), sanitize_stage0(selected_client))
        write_trace(stem.with_suffix('.host-sanitized.jsonl'), sanitize_stage0(selected_host))
        entry = {'scene_interval_s': scene_interval, 'stage0': stage0, 'marker_caveat': marker_caveat, 'pair': begin['pair'], 'arm': begin['arm'], 'settings': begin['settings'],
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
    return {'scene_interval_s': scene_interval, 'fix': windows[0][0]['fix'], 'pairs': 4, 'run': windows[0][0]['run'],
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
