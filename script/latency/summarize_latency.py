#!/usr/bin/env python3
"""Summarize measured transitions and interval deltas from local latency probes."""
import json
import math
import sys
from pathlib import Path


def summary(values):
    values = sorted(values)
    if not values:
        return {'count': 0}
    def percentile(p):
        return values[max(0, math.ceil(p * len(values)) - 1)]
    return dict(count=len(values), mean_ms=sum(values)/len(values), min_ms=values[0],
                p50_ms=percentile(.5), p95_ms=percentile(.95),
                p99_ms=percentile(.99), max_ms=values[-1])


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
    main(sys.argv[1:])
