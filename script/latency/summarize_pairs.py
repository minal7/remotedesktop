#!/usr/bin/env python3
"""Summarize the lab's interleaved loopback runs; never silently discard Wi-Fi spikes."""
import argparse
import json
import math
from pathlib import Path
from statistics import median

F3_PACER_TRIAL = 'WebRTC-ProbingScreenshareBwe/2.5,2875,80,40,-60,3/'


def quantile(values, fraction):
    values = sorted(v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v))
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def run_summary(path):
    run = json.loads(Path(path).read_text())
    start, end = run['measurement_start_s'], run['measurement_end_s']
    sender_trace = [json.loads(line) for line in Path(run['sender_trace']).read_text().splitlines() if line.strip()]
    receiver_trace = [json.loads(line) for line in Path(run['receiver_trace']).read_text().splitlines() if line.strip()]
    traces = sender_trace + receiver_trace
    samples = [e for e in traces if e.get('type') == 'stats' and start <= e.get('time', -1) <= end]
    pacer_events = [event for event in sender_trace if event.get('type') == 'lab_configuration'
                    and event.get('component') == 'f3_pacer_trial' and event.get('side') == 'loopback_sender']
    result = {'path': str(path), 'settings': run['lab_configuration'], 'duration_s': end - start,
              'sender_field_trial': run.get('sender_field_trial'),
              'sender_field_trial_effective': run.get('sender_field_trial_effective'),
              'sender_pacer_events': pacer_events,
              'native_text_ssim': run.get('native_text_ssim'), 'video_size': run['video_size'],
              'marker_coverage': [run['viewer_marker_count'], run['source_marker_count']]}
    for key in ('encodeMs', 'packetSendMs', 'jitterBufferMs', 'jitterBufferTargetMs', 'decodeMs'):
        values = [e['values'][key] for e in samples if key in e.get('values', {})]
        for suffix, fraction in (('p50', .5), ('p95', .95)):
            result[f'{key}_{suffix}'] = quantile(values, fraction)
    for suffix in ('p50', 'p95'):
        result[f'compositor_ms_{suffix}'] = run['compositor_to_compositor'].get(f'{suffix}_ms')
    rtt = [e['values']['currentRoundTripTime'] * 1000 for e in samples
           if 'currentRoundTripTime' in e.get('values', {})]
    result['rtt_ms_p95'] = quantile(rtt, .95)
    result['wifi_spike'] = result['rtt_ms_p95'] is not None and result['rtt_ms_p95'] > 150
    freezes = sum(v.get('freezeCountDelta', 0) for e in samples
                  if e.get('side') == 'loopback_receiver' for v in e.get('reports', {}).values())
    has_freezes = any('freezeCountDelta' in v for e in samples
                     if e.get('side') == 'loopback_receiver' for v in e.get('reports', {}).values())
    result['freezes_per_minute'] = freezes * 60 / (end - start) if has_freezes else None
    events = [e for e in traces if e.get('type') == 'stream_event' and start <= e.get('time', -1) <= end]
    result['freeze_correlations'] = []
    for event in events:
        if event.get('event') != 'freezeCount':
            continue
        nearby = sorted({e['event'] for e in events if e.get('event') != 'freezeCount'
                         and abs(e['time'] - event['time']) <= 2})
        if any(e.get('values', {}).get('currentRoundTripTime', 0) > .150
               and abs(e['time'] - event['time']) <= 2 for e in samples):
            nearby.append('RTT >150 ms')
        result['freeze_correlations'].append({'time': event['time'], 'count': event['delta'], 'nearby': nearby})
    return result


def summarize(manifest):
    runs = [run_summary(path) for path in manifest['runs']]
    if len(runs) < 8 or len(runs) % 2:
        raise ValueError('At least four complete interleaved A/B pairs are required.')
    fix_key = {'F2': 'f2Encoder', 'F3': 'f3Sender', 'F3Pacer': 'f3Pacer'}[manifest['fix']]
    paired = []
    fixed_settings = None
    metrics = [key for key in runs[0] if key.endswith(('_p50', '_p95'))]
    metrics += ['freezes_per_minute', 'native_text_ssim']
    for index in range(0, len(runs), 2):
        a, b = runs[index:index + 2]
        if min(a['duration_s'], b['duration_s']) < 29.9:
            raise ValueError('A trial is shorter than 30 seconds.')
        sa, sb = dict(a['settings']), dict(b['settings'])
        if sa.pop(fix_key, None) is not False or sb.pop(fix_key, None) is not True or sa != sb:
            raise ValueError('Each pair must change exactly the selected toggle from off to on.')
        if fixed_settings is not None and sa != fixed_settings:
            raise ValueError('All other settings must remain fixed across pairs.')
        fixed_settings = sa
        if manifest['fix'] == 'F3Pacer':
            for run, expected in ((a, None), (b, F3_PACER_TRIAL)):
                events = run['sender_pacer_events']
                if (run['sender_field_trial'] != expected or run['sender_field_trial_effective'] != 'unverified'
                    or len(events) != 1 or events[0].get('configured') is not (expected is not None)
                    or events[0].get('field_trial') != expected or events[0].get('effective') != 'unverified'):
                    raise ValueError('F3Pacer metadata and sender trace must agree on the configured trial.')
        differences = {key: b[key] - a[key] if a.get(key) is not None and b.get(key) is not None else None
                       for key in metrics}
        paired.append({'pair': index // 2 + 1, 'B_minus_A': differences})
    medians = {key: median([p['B_minus_A'][key] for p in paired])
               if all(p['B_minus_A'][key] is not None for p in paired) else None for key in metrics}
    return {'fix': manifest['fix'], 'pairs': len(paired), 'session': manifest['session'],
            'note': 'Mac compositor proxy; stage quantiles are one-second interval averages. '
                    'Fresh peer connections per trial; direction-finding only until iPad validation. '
                    'Freeze correlations use a two-second window around stats polls, not causal proof.',
            'median_paired_B_minus_A': medians, 'paired_differences': paired, 'runs': runs}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = summarize(json.loads(args.manifest.read_text()))
    text = json.dumps(result, indent=2, sort_keys=True) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text)
