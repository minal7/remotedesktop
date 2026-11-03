#!/usr/bin/env python3
"""Summarize measured transitions and interval deltas from local latency probes."""
import json
import math
import sys
from pathlib import Path


def strict_loads(line):
    def reject_constant(value):
        raise ValueError(f'Non-finite number: {value}')
    value = json.loads(line, parse_constant=reject_constant)
    def check(item):
        if isinstance(item, float) and not math.isfinite(item):
            raise ValueError('Non-finite number')
        if isinstance(item, dict):
            for child in item.values(): check(child)
        elif isinstance(item, list):
            for child in item: check(child)
    check(value)
    return value


def summary(values, unit='ms'):
    values = sorted(values)
    if not values:
        return {'count': 0}
    def percentile(p):
        return values[max(0, math.ceil(p * len(values)) - 1)]
    return {'count': len(values), f'mean_{unit}': sum(values)/len(values),
            f'min_{unit}': values[0], f'p50_{unit}': percentile(.5),
            f'p95_{unit}': percentile(.95), f'p99_{unit}': percentile(.99),
            f'max_{unit}': values[-1]}


def marker_population_bounds(total, observed):
    """Bound nearest-rank quantiles when unobserved nonnegative delays are unknown."""
    if not isinstance(total, int) or isinstance(total, bool) or total <= 0:
        raise ValueError('Marker population must be a positive integer')
    values = list(observed)
    if len(values) > total:
        raise ValueError('More observed markers than the source population')
    if any(not isinstance(v, (int, float)) or isinstance(v, bool) or
           not math.isfinite(v) or v < 0 for v in values):
        raise ValueError('Observed marker delays must be finite nonnegative numbers')
    values.sort()
    missing = total - len(values)
    result = {'total': total, 'recorded': len(values), 'unknown': missing,
              'population_scope': 'source_observed_marker_ids',
              'excludes_unobserved_source_transitions': True,
              'method': ('Nearest-rank bounds for nonnegative delays; unknown outcomes are not proven nondelivery. '
                         'The upper bound is unbounded when unknown outcomes can occupy the requested rank. '
                         'Bounds are conditional on recorded timestamps and do not include clock uncertainty.')}
    for name, p in (('p50', .50), ('p95', .95), ('p99', .99)):
        rank = math.ceil(p * total)
        unbounded = rank > len(values)
        result[name] = {'rank': rank, 'lower_ms': 0 if rank <= missing else values[rank - missing - 1],
                        'upper_ms': None if unbounded else values[rank - 1],
                        'upper_unbounded': unbounded}
    return result


def resource_summary(host_records, client_records, clocks, host_start, host_end):
    """Use only samples in the marker window and a recent client clock estimate."""
    def number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

    cpu = [r['processCPUPercent'] for r in host_records if r.get('type') == 'resource'
           and number(r.get('time')) and host_start <= r['time'] <= host_end
           and number(r.get('processCPUPercent')) and r['processCPUPercent'] >= 0]
    client = []
    for record in client_records:
        t = record.get('time')
        if record.get('type') != 'resource' or not number(t):
            continue
        available = [c for c in clocks if c['time'] <= t and t - c['time'] <= 15]
        if available and host_start <= t + available[-1]['offset'] <= host_end:
            client.append(record)
    client.sort(key=lambda r: r['time'])
    thermal_counts, battery_states = {}, {}
    for record in client:
        for key, counts in (('thermalState', thermal_counts), ('batteryState', battery_states)):
            value = record.get(key)
            if isinstance(value, int) and not isinstance(value, bool):
                counts[str(value)] = counts.get(str(value), 0) + 1
    levels = [r for r in client if number(r.get('batteryLevel')) and 0 <= r['batteryLevel'] <= 1]
    battery = {'valid_level_samples': len(levels), 'state_counts': battery_states,
               'level_delta_fraction': None, 'duration_s': None,
               'ten_minute_drain_verdict': None, 'within_15_percent_verdict': None}
    if len(levels) >= 2:
        first, last = levels[0], levels[-1]
        battery.update({'first_level': first['batteryLevel'], 'last_level': last['batteryLevel'],
                        'first_state': first.get('batteryState'), 'last_state': last.get('batteryState'),
                        'level_delta_fraction': last['batteryLevel'] - first['batteryLevel'],
                        'duration_s': last['time'] - first['time']})
    battery['note'] = ('Raw last minus first level; 0 is unknown, 1 unplugged, 2 charging, 3 full. '
                       'Short, charging, coarse or incomplete observations cannot establish ten-minute drain; '
                       'a baseline comparison and adequate resolution are required for a 15% verdict.')
    return {'host_process_cpu_percent': summary(cpu, 'percent'),
            'host_cpu_note': 'Process-wide CPU; 100 percent is one core. GPU use is not measured.',
            'client_thermal_state_counts': thermal_counts,
            'client_resource_samples': len(client), 'client_battery': battery}


def interval_stats(run):
    def by_type(stage, kind):
        return next((s['values'] for s in run[stage] if s['type'] == kind and s['values'].get('kind') == 'video'), {})
    result = {}
    for kind, ratios in [
        ('outbound-rtp', [('encode_ms_per_frame', 'totalEncodeTime', 'framesEncoded')]),
        ('inbound-rtp', [('decode_ms_per_frame', 'totalDecodeTime', 'framesDecoded'),
                         ('jitter_buffer_ms_per_frame', 'jitterBufferDelay', 'jitterBufferEmittedCount'),
                         ('receive_processing_ms_per_frame', 'totalProcessingDelay', 'framesDecoded')])]:
        before, after = by_type('stats_before', kind), by_type('stats_after', kind)
        for name, numerator, denominator in ratios:
            n = after.get(numerator, 0) - before.get(numerator, 0)
            d = after.get(denominator, 0) - before.get(denominator, 0)
            result[name] = 1000*n/d if d > 0 else None
        for name in ('framesEncoded', 'framesDecoded', 'framesDropped', 'packetsLost', 'freezeCount', 'bytesSent'):
            if name in after:
                result[name] = after[name] - before.get(name, 0)
        for name in ('encoderImplementation', 'decoderImplementation', 'qualityLimitationReason'):
            if name in after:
                result[name] = after[name]
    one = by_type('stats_at_one_second', 'outbound-rtp')
    two = by_type('stats_at_two_seconds', 'outbound-rtp')
    result['video_mbps_at_2s'] = (two.get('bytesSent', 0) - one.get('bytesSent', 0)) * 8 / 1e6
    result['text_ssim'] = run.get('text_ssim')
    result['encoded_fps'] = result.get('framesEncoded', 0) / run['duration_s']
    result['decoded_fps'] = result.get('framesDecoded', 0) / run['duration_s']
    result['video_mbps'] = result.get('bytesSent', 0) * 8 / run['duration_s'] / 1e6
    result['rtcp_rtt_ms_at_end'] = [s['values']['roundTripTime'] * 1000 for s in run['stats_after'] if s['type'] == 'remote-inbound-rtp' and 'roundTripTime' in s['values']]
    return result


def device_summary(host_path, client_path, telemetry_path=None, metadata=None):
    """Join marker timestamps only when a measured clock estimate is available."""
    host = strict_loads(Path(host_path).read_text())
    records = [strict_loads(line) for line in Path(client_path).read_text().splitlines() if line.strip()]
    clocks = sorted((r for r in records if r.get('type') == 'clock' and
                     all(k in r for k in ('time', 'offset', 'uncertainty', 'rtt')) and
                     r.get('samples', 0) >= 50 and r['rtt'] >= 0 and r['uncertainty'] >= 0), key=lambda r: r['time'])
    markers = {r['marker_id']: r for r in host['markers']}
    if len(markers) != len(host['markers']) or not markers:
        raise ValueError('Missing or duplicate host marker IDs')
    if any(not isinstance(r.get('host_display_s'), (int, float)) for r in markers.values()):
        raise ValueError('Invalid host marker time')
    host_records = ([strict_loads(line) for line in Path(telemetry_path).read_text().splitlines() if line.strip()]
                    if telemetry_path else [])
    host_start = min(r['host_display_s'] for r in host['markers'])
    host_end = max(r['host_display_s'] for r in host['markers'])
    host_stats = [r for r in host_records if r.get('type') == 'stats' and r.get('side') == 'host'
                  and host_start - 2 <= r.get('time', -1) <= host_end]
    if telemetry_path and not host_stats:
        raise ValueError('No host telemetry overlaps marker interval')
    rows, rejected = [], 0
    for event in records:
        if event.get('type') != 'marker' or event.get('marker_id') not in markers or 'presentedTime' not in event:
            continue
        t = event['presentedTime']
        available = [c for c in clocks if c['time'] <= t and t - c['time'] <= 15]
        if not available:
            rejected += 1
            continue
        clock = available[-1]
        delay = (t + clock['offset'] - markers[event['marker_id']]['host_display_s']) * 1000
        if not 0 <= delay <= 2000:
            rejected += 1
            continue
        stats = [r for r in records if r.get('type') == 'stats' and r.get('side') == 'client' and r.get('time', float('inf')) <= t]
        row = {'marker_id': event['marker_id'], 'screen_to_screen_ms': delay,
               'network_one_way_ms': clock['rtt'] * 500, 'clock_uncertainty_ms': clock['uncertainty'] * 1000,
               'host_display_s': markers[event['marker_id']]['host_display_s'], 'client_presented_s': t}
        if 'decodeTime' in event and t >= event['decodeTime']:
            row['decode_to_present_ms'] = (t - event['decodeTime']) * 1000
        nearby_host = [r for r in host_stats if r['time'] <= row['host_display_s'] and row['host_display_s'] - r['time'] <= 2]
        if nearby_host:
            row['host_stats'] = max(nearby_host, key=lambda r: r['time']).get('values', {})
        if stats:
            row['stats'] = max(stats, key=lambda r: r['time']).get('values', {})
        rows.append(row)
    # Duplicated decoded frames must not overweight the same marker transition.
    unique = {}
    for row in rows:
        unique.setdefault(row['marker_id'], row)
    rows = list(unique.values())
    if not rows:
        raise ValueError('No matched markers with a recent clock estimate')
    inputs = []
    for event in host_records:
        if event.get('type') != 'input' or not all(k in event for k in ('clientTime', 'receiveTime', 'postTime')):
            continue
        if not host_start <= event['receiveTime'] <= host_end:
            continue
        clock_candidates = [c for c in clocks if c['time'] <= event['clientTime'] and event['clientTime'] - c['time'] <= 15]
        if not clock_candidates:
            continue
        offset = clock_candidates[-1]['offset']
        receive = (event['receiveTime'] - event['clientTime'] - offset) * 1000
        post = (event['postTime'] - event['clientTime'] - offset) * 1000
        if 0 <= receive <= post:
            inputs.append((receive, post))
    # Presence is independent of whether a point estimate or bracket is usable.
    capture_events = {}
    for event in host_records:
        if event.get('type') == 'capture_marker' and event.get('marker_id') in markers:
            capture_events.setdefault(event['marker_id'], []).append(event)
    captured_ids = set(capture_events)
    capture_handoff, capture_discrepancies, sample_discrepancies, bounds = [], [], [], []
    valid_point_ids = set()
    invalid_brackets = 0
    def finite_number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    for marker_id, events in capture_events.items():
        marker = markers[marker_id]
        # The first capture sample containing this ID is the tightest upper
        # bound on the transition; do not substitute later duplicated frames.
        candidates = [e for e in events if finite_number(e.get('pushTime'))
                      and finite_number(e.get('sampleDisplayTime'))]
        if not candidates:
            continue
        event = min(candidates, key=lambda e: e['sampleDisplayTime'])
        push, sample = event['pushTime'], event['sampleDisplayTime']
        first_new = marker['host_display_s']
        delta = (push - first_new) * 1000
        capture_discrepancies.append(delta)
        sample_discrepancies.append((sample - first_new) * 1000)
        if 0 <= delta <= 2000 and sample <= push:
            capture_handoff.append(delta)
            valid_point_ids.add(marker_id)
        old = marker.get('previous_host_display_s')
        # The transition is after the last old observation and no later than
        # either first-new observation. The capture timestamp must be causal.
        if (finite_number(old) and finite_number(first_new) and old < min(first_new, sample) and sample <= push
                and push - old <= 2):
            transition_upper = min(first_new, sample)
            bounds.append({'marker_id': marker_id,
                           'capture_wait_lower_ms': (sample - transition_upper) * 1000,
                           'capture_wait_upper_ms': (sample - old) * 1000,
                           'handoff_lower_ms': (push - transition_upper) * 1000,
                           'handoff_upper_ms': (push - old) * 1000})
        elif old is not None:
            invalid_brackets += 1
    all_frame_render = []
    for event in records:
        if event.get('type') != 'render':
            continue
        decode, presented = event.get('decodeTime'), event.get('presentedTime')
        submitted = event.get('submittedTime')
        if (not finite_number(decode) or not finite_number(presented) or decode > presented
                or ('submittedTime' in event and
                    (not finite_number(submitted) or not decode <= submitted <= presented))):
            continue
        available = [c for c in clocks if c['time'] <= presented and presented - c['time'] <= 15]
        if available and host_start <= presented + available[-1]['offset'] <= host_end:
            all_frame_render.append((presented - decode) * 1000)
    sampled_rtt = []
    for event in records:
        if event.get('type') != 'stats' or event.get('side') != 'client':
            continue
        t = event.get('time')
        rtt = event.get('values', {}).get('currentRoundTripTime')
        if not isinstance(t, (int, float)) or not isinstance(rtt, (int, float)) or rtt < 0:
            continue
        available = [c for c in clocks if c['time'] <= t and t - c['time'] <= 15]
        if available and host_start <= t + available[-1]['offset'] <= host_end:
            sampled_rtt.append(rtt * 1000)
    result = {'kind': 'device_display_to_present', 'host_file': str(host_path), 'client_file': str(client_path),
            'source_marker_count': len(markers), 'matched_marker_count': len(rows), 'rejected_marker_count': rejected,
            'screen_to_screen': summary([r['screen_to_screen_ms'] for r in rows]),
            'screen_to_screen_note': 'Conditional distribution of matched marker transitions only.',
            'full_source_population_screen_to_screen_bounds': marker_population_bounds(
                len(markers), [r['screen_to_screen_ms'] for r in rows]),
            'network_one_way': summary([r['network_one_way_ms'] for r in rows]),
            'sampled_candidate_rtt': summary(sampled_rtt),
            'sampled_candidate_rtt_over_50ms_count': sum(rtt > 50 for rtt in sampled_rtt),
            'network_spike_note': 'Approximately one-second samples; brief spikes can be missed and their cause is unknown.',
            'clock_uncertainty': summary([r['clock_uncertainty_ms'] for r in rows]),
            'decode_to_present': summary([r['decode_to_present_ms'] for r in rows if 'decode_to_present_ms' in r]),
            'decode_to_present_note': 'Marker transitions only; not a per-frame distribution.',
            'all_frame_decode_to_present': summary(all_frame_render),
            'all_frame_decode_to_present_note': 'Causal render records in the host marker window with a recent client clock estimate.',
            'send_to_receive': summary([x[0] for x in inputs]), 'send_to_post': summary([x[1] for x in inputs]),
            'input_origin_note': 'Client timestamp is assigned at transmit; touch processing before transmit is not measured.',
            'host_display_to_capture_handoff': summary(capture_handoff),
            'capture_handoff_signed_first_seen_discrepancy': summary(capture_discrepancies),
            'capture_sample_signed_first_seen_discrepancy': summary(sample_discrepancies),
            'capture_marker_present_count': len(captured_ids),
            'capture_point_timing_valid_count': len(valid_point_ids),
            'capture_bracket_valid_count': len(bounds),
            'capture_bracket_unavailable_count': len(markers) - len(bounds),
            'capture_bracket_invalid_count': invalid_brackets,
            'capture_wait_lower_bound': summary([b['capture_wait_lower_ms'] for b in bounds]),
            'capture_wait_upper_bound': summary([b['capture_wait_upper_ms'] for b in bounds]),
            'capture_handoff_lower_bound': summary([b['handoff_lower_ms'] for b in bounds]),
            'capture_handoff_upper_bound': summary([b['handoff_upper_ms'] for b in bounds]),
            'capture_bounds_samples': bounds,
            'capture_bounds_note': 'S1 uses the capture wait upper bound, not the first-seen point estimate or bracket midpoint.',
            'unmatched_capture_marker_count': len(markers) - len(captured_ids),
            'unmatched_source_marker_count': max(0, len(markers) - len(rows)),
            'capture_sample_age_backlog_not_capture_wait': summary([r['sampleAgeMs'] for r in host_records if r.get('type') == 'capture'
                                           and host_start <= r.get('time', -1) <= host_end and r.get('sampleAgeMs', -1) >= 0]),
            'resources': resource_summary(host_records, records, clocks, host_start, host_end),
            'samples': rows}
    # Statistics are one-second interval averages. Count each actual report
    # once, independent of how many marker presentations happened nearby.
    client_stats = []
    for event in records:
        t = event.get('time')
        if (event.get('type') != 'stats' or event.get('side') != 'client' or
                not isinstance(t, (int, float)) or isinstance(t, bool)):
            continue
        available = [c for c in clocks if c['time'] <= t and t - c['time'] <= 15]
        if available and host_start <= t + available[-1]['offset'] <= host_end:
            client_stats.append(event)
    required_stages = {
        'host_stages': ('encodeMs', 'packetSendMs'),
        'client_stages': ('jitterBufferMs', 'decodeMs', 'processingMs'),
    }
    stage_records = {
        'host_stages': [r for r in host_stats if host_start <= r['time'] <= host_end],
        'client_stages': client_stats,
    }
    missing_stages = []
    for output_key, keys in required_stages.items():
        result[output_key] = {}
        for key in keys:
            values = [r.get('values', {}).get(key) for r in stage_records[output_key]]
            values = [v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool)
                      and math.isfinite(v) and v >= 0]
            result[output_key][key] = summary(values)
            if not values:
                missing_stages.append(f'{output_key}.{key}')
    result['stage_statistics_note'] = ('Each sample is one recorded approximately one-second WebRTC interval average; '
                                       'client samples require a recent clock estimate and are counted once.')
    result['missing_stage_metrics'] = missing_stages
    missing = len(markers) - len(rows)
    duration = host.get('duration_s')
    span = host_end - host_start
    reasons = []
    ordered_markers = sorted(markers.values(), key=lambda r: r['host_display_s'])
    source_gaps = sum((current['marker_id'] - current.get('previous_marker_id', previous['marker_id']) - 1) % 65534
                      for previous, current in zip(ordered_markers, ordered_markers[1:]))
    first_previous = ordered_markers[0].get('previous_marker_id')
    if isinstance(first_previous, int):
        source_gaps += (ordered_markers[0]['marker_id'] - first_previous - 1) % 65534
    result['source_observer_missing_id_count'] = source_gaps
    if not host.get('initial_marker_observed_before_timing'):
        reasons.append('initial marker warmup not established')
    if source_gaps:
        reasons.append('source observer missed marker IDs')
    if not isinstance(duration, (int, float)) or duration < 60 or span < 58:
        reasons.append('insufficient source duration or marker time span')
    if len(markers) < math.floor(span * 10 * .9):
        reasons.append('insufficient source observer coverage for 10 Hz marker')
    if missing:
        reasons.append('unmatched source markers; selection bias is possible')
    if not telemetry_path:
        reasons.append('host telemetry missing')
    elif not host_stats or min(r['time'] for r in host_stats) > host_start + 3 or max(r['time'] for r in host_stats) < host_end - 3:
        reasons.append('host statistics do not cover the run')
    if len(captured_ids) != len(markers):
        reasons.append('capture marker coverage incomplete')
    if len(bounds) != len(markers):
        reasons.append('capture transition bracket coverage incomplete')
    if missing_stages:
        reasons.append('missing required stage metrics: ' + ', '.join(missing_stages))
    result.update({'source_marker_span_s': span, 'baseline_eligible': not reasons, 'baseline_ineligible_reasons': reasons})
    if metadata:
        result['metadata'] = metadata
        host_hz, client_hz = metadata['host_refresh_hz'], metadata['client_refresh_hz']
        if host_hz <= 0 or client_hz <= 0:
            raise ValueError('Refresh assumptions must be positive')
        # Host displayTime is already after the host refresh. The remaining
        # client refresh wait is an assumed half-period, not a measurement.
        refresh_ms = 1000 / client_hz
        result['app_overhead_estimate'] = summary([r['screen_to_screen_ms'] - r['network_one_way_ms'] - refresh_ms / 2 for r in rows])
        goal_refresh_ms = 1000 / host_hz + refresh_ms
        result['goal_formula_overhead_estimate'] = summary([
            r['screen_to_screen_ms'] - r['network_one_way_ms'] - goal_refresh_ms / 2 for r in rows])
        result['goal_formula_assumptions'] = {
            'refresh_wait_estimate_ms': goal_refresh_ms / 2,
            'refresh_wait_possible_range_ms': [0, goal_refresh_ms],
            'note': 'Goal formula subtracts assumed half-period waits at both displays and RTT/2. Host displayTime already follows the host refresh, so this formula subtracts a host wait outside the measured boundary. Refresh phases and network asymmetry are unmeasured.'}
        result['app_overhead_assumptions'] = {'refresh_wait_estimate_ms': refresh_ms / 2,
            'refresh_wait_possible_range_ms': [0, refresh_ms],
            'clock_uncertainty': result['clock_uncertainty'],
            'note': 'Estimate subtracts half a client refresh period and RTT/2. Host displayTime already includes the host refresh. Client refresh phase and network asymmetry are unmeasured; this is not measured true overhead.'}
    return result


def main(paths):
    runs = [json.loads(Path(p).read_text()) for p in paths]
    metrics = {
        'compositor_to_compositor': ('source_compositor_s', 'viewer_compositor_s'),
        'capture_pts_to_decode_callback': ('capture_pts_s', 'decode_callback_s'),
        'decode_callback_to_viewer_compositor': ('decode_callback_s', 'viewer_compositor_s'),
    }
    result = {'files': paths, 'runs': [], 'pooled': {}}
    for p, run in zip(paths, runs):
        assert run['source_marker_count'] == run['viewer_marker_count'] == run['decoded_marker_count'], f'Incomplete coverage: {p}'
        result['runs'].append({'file': p, 'duration_s': run['duration_s'], 'video_size': run['video_size'],
                              'observer_fps_limit': run['observer_fps_limit'],
                              'display': run['compositor_to_compositor'],
                              'pipeline': run['capture_pts_to_decode_callback'],
                              'render': run['decode_callback_to_viewer_compositor'],
                              'observer_intervals': run['observer_complete_frame_intervals'],
                              'stats': interval_stats(run)})
    for metric, (start, end) in metrics.items():
        values = [(sample[end] - sample[start])*1000 for run in runs for sample in run['samples'] if start in sample and end in sample]
        assert all(v >= 0 for v in values), f'Noncausal sample in {metric}'
        result['pooled'][metric] = summary(values)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    if len(sys.argv) in (4, 6) and sys.argv[1] == '--device':
        metadata = strict_loads(Path(sys.argv[5]).read_text()) if len(sys.argv) == 6 else None
        print(json.dumps(device_summary(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) == 6 else None, metadata), indent=2))
    else:
        main(sys.argv[1:])
