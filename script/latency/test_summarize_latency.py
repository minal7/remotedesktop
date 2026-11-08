import json
import tempfile
import unittest
from pathlib import Path
from summarize_latency import device_summary, marker_population_bounds, resource_summary
from select_device_trace import select
from device_trace_tools import recent_client, host_telemetry
from unittest.mock import patch

class DeviceSummaryTests(unittest.TestCase):
    def test_marker_population_bounds_without_missing_values(self):
        result = marker_population_bounds(100, range(1, 101))
        self.assertEqual((result['total'], result['recorded'], result['unknown']), (100, 100, 0))
        self.assertEqual(result['population_scope'], 'source_observed_marker_ids')
        self.assertTrue(result['excludes_unobserved_source_transitions'])
        for key, expected in (('p50', 50), ('p95', 95), ('p99', 99)):
            self.assertEqual(result[key]['lower_ms'], expected)
            self.assertEqual(result[key]['upper_ms'], expected)
            self.assertFalse(result[key]['upper_unbounded'])

    def test_marker_population_bounds_respect_unbounded_threshold(self):
        result = marker_population_bounds(100, range(1, 96))
        self.assertEqual(result['p95']['lower_ms'], 90)
        self.assertEqual(result['p95']['upper_ms'], 95)
        self.assertFalse(result['p95']['upper_unbounded'])
        self.assertTrue(result['p99']['upper_unbounded'])
        self.assertIsNone(result['p99']['upper_ms'])
        result = marker_population_bounds(100, range(1, 95))
        self.assertEqual(result['p95']['lower_ms'], 89)
        self.assertIsNone(result['p95']['upper_ms'])
        self.assertTrue(result['p95']['upper_unbounded'])

    def test_marker_population_bounds_heavy_and_full_censoring(self):
        result = marker_population_bounds(10, [3, 7])
        self.assertEqual(result['p50']['lower_ms'], 0)
        self.assertIsNone(result['p50']['upper_ms'])
        self.assertTrue(result['p50']['upper_unbounded'])
        result = marker_population_bounds(10, [])
        self.assertEqual(result['unknown'], 10)
        self.assertEqual(result['p99']['lower_ms'], 0)
        self.assertIsNone(result['p99']['upper_ms'])
        self.assertNotIn('Infinity', json.dumps(result, allow_nan=False))

    def test_marker_population_bounds_reject_invalid_or_duplicate_count(self):
        with self.assertRaises(ValueError): marker_population_bounds(0, [])
        with self.assertRaises(ValueError): marker_population_bounds(1, [1, 2])
        with self.assertRaises(ValueError): marker_population_bounds(2, [float('nan')])
        # Equal delays on different markers remain valid observations.
        self.assertEqual(marker_population_bounds(2, [1, 1])['recorded'], 2)

    def test_resources_use_window_recent_clock_and_percentage_units(self):
        clocks = [{'time': 89, 'offset': 11}]
        host = [{'type': 'resource', 'time': 100, 'processCPUPercent': 125},
                {'type': 'resource', 'time': 101, 'processCPUPercent': 25},
                {'type': 'resource', 'time': 102, 'processCPUPercent': 999}]
        client = [{'type': 'resource', 'time': 89, 'batteryLevel': .8, 'batteryState': 1, 'thermalState': 0},
                  {'type': 'resource', 'time': 90, 'batteryLevel': .79, 'batteryState': 1, 'thermalState': 1},
                  {'type': 'resource', 'time': 90.5, 'batteryLevel': -1, 'batteryState': 0, 'thermalState': 1},
                  {'type': 'resource', 'time': 91, 'batteryLevel': .1, 'batteryState': 1, 'thermalState': 3}]
        result = resource_summary(host, client, clocks, 100, 101.5)
        cpu = result['host_process_cpu_percent']
        self.assertEqual(cpu['mean_percent'], 75)
        self.assertNotIn('mean_ms', cpu)
        self.assertEqual(result['client_thermal_state_counts'], {'0': 1, '1': 2})
        battery = result['client_battery']
        self.assertAlmostEqual(battery['level_delta_fraction'], -.01)
        self.assertEqual(battery['duration_s'], 1)
        self.assertEqual(battery['state_counts'], {'1': 2, '0': 1})
        self.assertIsNone(battery['ten_minute_drain_verdict'])
        self.assertIsNone(battery['within_15_percent_verdict'])

    def test_charging_and_stale_clock_never_create_drain_verdict(self):
        clocks = [{'time': 0, 'offset': 100}, {'time': 590, 'offset': 100}]
        client = [{'type': 'resource', 'time': 0, 'batteryLevel': .5, 'batteryState': 2},
                  {'type': 'resource', 'time': 300, 'batteryLevel': .6, 'batteryState': 2},
                  {'type': 'resource', 'time': 600, 'batteryLevel': .7, 'batteryState': 3}]
        battery = resource_summary([], client, clocks, 100, 700)['client_battery']
        self.assertEqual(battery['valid_level_samples'], 2)
        self.assertEqual(battery['duration_s'], 600)
        self.assertAlmostEqual(battery['level_delta_fraction'], .2)
        self.assertEqual(battery['state_counts'], {'2': 1, '3': 1})
        self.assertIsNone(battery['ten_minute_drain_verdict'])
        self.assertIsNone(battery['within_15_percent_verdict'])

    def write(self, root, clocks):
        host = root / 'host.json'
        client = root / 'client.jsonl'
        host.write_text(json.dumps({'markers': [{'marker_id': 1, 'host_display_s': 100.0}]}))
        events = clocks + [{'type': 'marker', 'marker_id': 1, 'decodeTime': 89.03, 'presentedTime': 89.05}]
        client.write_text('\n'.join(json.dumps(e) for e in events))
        return host, client

    def test_clock_conversion_and_duplicate_presentations(self):
        with tempfile.TemporaryDirectory() as d:
            host, client = self.write(Path(d), [{'type': 'clock', 'time': 89, 'offset': 11, 'uncertainty': .002, 'rtt': .01, 'samples': 50}])
            with client.open('a') as f:
                f.write('\n' + json.dumps({'type': 'marker', 'marker_id': 1, 'presentedTime': 89.06}))
            result = device_summary(host, client)
            self.assertEqual(result['matched_marker_count'], 1)
            population = result['full_source_population_screen_to_screen_bounds']
            self.assertEqual((population['total'], population['recorded'], population['unknown']), (1, 1, 0))
            self.assertAlmostEqual(population['p95']['upper_ms'], 50)
            self.assertAlmostEqual(result['screen_to_screen']['p50_ms'], 50)
            self.assertAlmostEqual(result['network_one_way']['p50_ms'], 5)
            self.assertAlmostEqual(result['decode_to_present']['p50_ms'], 20)

    def test_stage_summaries_count_intervals_not_markers_and_require_metrics(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            host = root / 'host.json'
            client = root / 'client.jsonl'
            telemetry = root / 'host-telemetry.jsonl'
            host.write_text(json.dumps({'markers': [
                {'marker_id': i + 1, 'host_display_s': t}
                for i, t in enumerate((100, 100.1, 100.2, 101.9))]}))
            client_events = [{'type': 'clock', 'time': 89, 'offset': 11,
                              'uncertainty': .002, 'rtt': .01, 'samples': 50}]
            client_events += [{'type': 'stats', 'side': 'client', 'time': t,
                               'values': {'jitterBufferMs': value, 'decodeMs': value, 'processingMs': value}}
                              for t, value in ((89, 2), (90, 10))]
            client_events += [{'type': 'marker', 'marker_id': i + 1, 'presentedTime': t - 11 + .01}
                              for i, t in enumerate((100, 100.1, 100.2, 101.9))]
            client.write_text('\n'.join(json.dumps(x) for x in client_events))
            telemetry.write_text('\n'.join(json.dumps(x) for x in [
                {'type': 'stats', 'side': 'host', 'time': t, 'values': {'encodeMs': value, 'packetSendMs': value}}
                for t, value in ((100, 2), (101, 10))]))
            result = device_summary(host, client, telemetry)
            for side, key in (('host_stages', 'encodeMs'), ('client_stages', 'decodeMs')):
                self.assertEqual(result[side][key]['count'], 2)
                self.assertEqual(result[side][key]['mean_ms'], 6)
            self.assertEqual(result['samples'][0]['host_stats']['encodeMs'], 2)
            self.assertEqual(result['missing_stage_metrics'], [])
            client_events[1]['values'].pop('processingMs')
            client_events[2]['values'].pop('processingMs')
            client.write_text('\n'.join(json.dumps(x) for x in client_events))
            result = device_summary(host, client, telemetry)
            self.assertIn('client_stages.processingMs', result['missing_stage_metrics'])
            self.assertTrue(any('missing required stage metrics' in reason
                                for reason in result['baseline_ineligible_reasons']))

    def test_host_input_and_overhead_join(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            host, client = self.write(root, [{'type': 'clock', 'time': 89, 'offset': 11, 'uncertainty': .002, 'rtt': .01, 'samples': 50}])
            host.write_text(json.dumps({'markers': [{'marker_id': 1, 'host_display_s': 100}, {'marker_id': 2, 'host_display_s': 100.1}]}))
            with client.open('a') as f:
                f.write('\n' + json.dumps({'type': 'stats', 'side': 'client', 'time': 89.02, 'values': {'currentRoundTripTime': .06}}))
                f.write('\n' + json.dumps({'type': 'resource', 'time': 89.02, 'batteryLevel': .8, 'batteryState': 1, 'thermalState': 0}))
            telemetry = root / 'host-telemetry.jsonl'
            telemetry.write_text('\n'.join(json.dumps(x) for x in [
                {'type': 'stats', 'side': 'host', 'time': 100, 'values': {'encodeMs': 4}},
                {'type': 'resource', 'time': 100.05, 'processCPUPercent': 42},
                {'type': 'capture_marker', 'marker_id': 1, 'sampleDisplayTime': 100.004, 'pushTime': 100.006},
                {'type': 'input', 'clientTime': 89.01, 'receiveTime': 100.015, 'postTime': 100.017}]))
            result = device_summary(host, client, telemetry, {'host_refresh_hz': 60, 'client_refresh_hz': 120})
            self.assertAlmostEqual(result['send_to_receive']['p50_ms'], 5)
            self.assertAlmostEqual(result['send_to_post']['p50_ms'], 7)
            self.assertAlmostEqual(result['app_overhead_estimate']['p50_ms'], 40.833333333333336)
            self.assertAlmostEqual(result['goal_formula_overhead_estimate']['p50_ms'], 32.5)
            self.assertEqual(result['samples'][0]['host_stats']['encodeMs'], 4)
            self.assertEqual(result['resources']['host_process_cpu_percent']['mean_percent'], 42)
            self.assertEqual(result['resources']['client_thermal_state_counts'], {'0': 1})
            self.assertEqual(result['sampled_candidate_rtt_over_50ms_count'], 1)
            self.assertAlmostEqual(result['host_display_to_capture_handoff']['p50_ms'], 6)
            self.assertFalse(result['baseline_eligible'])
            self.assertEqual(result['unmatched_source_marker_count'], 1)

    def test_capture_presence_signed_discrepancy_and_causal_bounds(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            host, client = self.write(root, [{'type': 'clock', 'time': 89, 'offset': 11,
                'uncertainty': .002, 'rtt': .01, 'samples': 50}])
            host.write_text(json.dumps({'duration_s': 60, 'initial_marker_observed_before_timing': True,
                'markers': [
                    {'marker_id': 2, 'previous_host_display_s': 99.990, 'host_display_s': 100.008},
                    {'marker_id': 3, 'host_display_s': 100.1},
                    {'marker_id': 5, 'previous_host_display_s': 100.19, 'host_display_s': 100.2}]}))
            client.write_text(client.read_text() + '\n' + '\n'.join(json.dumps({
                'type': 'marker', 'marker_id': i, 'presentedTime': t})
                for i, t in ((2, 89.05), (3, 89.15), (5, 89.25))))
            telemetry = root / 'telemetry.jsonl'
            telemetry.write_text('\n'.join(json.dumps(e) for e in [
                {'type': 'stats', 'side': 'host', 'time': 100, 'values': {}},
                {'type': 'capture_marker', 'marker_id': 2, 'sampleDisplayTime': 100.000, 'pushTime': 100.002},
                {'type': 'capture_marker', 'marker_id': 3, 'sampleDisplayTime': 100.101, 'pushTime': 100.102},
                {'type': 'capture_marker', 'marker_id': 5, 'sampleDisplayTime': 100.18, 'pushTime': 100.21}]))
            result = device_summary(host, client, telemetry)
            self.assertEqual(result['capture_marker_present_count'], 3)
            self.assertEqual(result['unmatched_capture_marker_count'], 0)
            self.assertEqual(result['capture_point_timing_valid_count'], 2)
            self.assertAlmostEqual(result['capture_handoff_signed_first_seen_discrepancy']['min_ms'], -6)
            self.assertEqual(result['capture_bracket_valid_count'], 1)
            bound = result['capture_bounds_samples'][0]
            self.assertAlmostEqual(bound['capture_wait_lower_ms'], 0)
            self.assertAlmostEqual(bound['capture_wait_upper_ms'], 10)
            self.assertAlmostEqual(bound['handoff_lower_ms'], 2)
            self.assertAlmostEqual(bound['handoff_upper_ms'], 12)
            self.assertEqual(result['source_observer_missing_id_count'], 1)
            self.assertFalse(result['baseline_eligible'])

    def test_old_traces_and_missing_capture_are_ineligible(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            host, client = self.write(root, [{'type': 'clock', 'time': 89, 'offset': 11,
                'uncertainty': .002, 'rtt': .01, 'samples': 50}])
            result = device_summary(host, client)
            self.assertEqual(result['capture_marker_present_count'], 0)
            self.assertEqual(result['unmatched_capture_marker_count'], 1)
            self.assertEqual(result['capture_bracket_unavailable_count'], 1)
            self.assertIn('initial marker warmup not established', result['baseline_ineligible_reasons'])
            self.assertFalse(result['baseline_eligible'])

    def test_complete_causal_bounds_allow_negative_point_but_losses_fail(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            host, client, telemetry = root / 'host.json', root / 'client.jsonl', root / 'host.jsonl'
            times = [100 + i / 10 for i in range(600)]
            markers = [{'marker_id': i + 2, 'previous_marker_id': i + 1,
                        'previous_host_display_s': t - .01, 'host_display_s': t}
                       for i, t in enumerate(times)]
            host.write_text(json.dumps({'duration_s': 60, 'initial_marker_observed_before_timing': True,
                                        'markers': markers}))
            client_events = [{'type': 'clock', 'time': t, 'offset': 0, 'uncertainty': .001,
                              'rtt': .01, 'samples': 50} for t in range(99, 161, 10)]
            client_events += [{'type': 'marker', 'marker_id': i + 2, 'decodeTime': t + .02,
                               'presentedTime': t + .04} for i, t in enumerate(times)]
            client_events += [{'type': 'stats', 'side': 'client', 'time': t,
                               'values': {'jitterBufferMs': 1, 'decodeMs': 1, 'processingMs': 1}}
                              for t in range(100, 160)]
            # Two valid render frames, including a non-marker frame, and one
            # causally invalid record which must not enter the distribution.
            client_events += [{'type': 'render', 'decodeTime': 100.02, 'submittedTime': 100.03, 'presentedTime': 100.04},
                              {'type': 'render', 'decodeTime': 100.10, 'submittedTime': 100.14, 'presentedTime': 100.15},
                              {'type': 'render', 'decodeTime': 100.20, 'submittedTime': 100.24, 'presentedTime': 100.23}]
            client.write_text('\n'.join(json.dumps(e) for e in client_events))
            stats = [{'type': 'stats', 'side': 'host', 'time': t,
                      'values': {'encodeMs': 1, 'packetSendMs': 1}} for t in range(100, 160)]
            captures = [{'type': 'capture_marker', 'marker_id': i + 2,
                         'sampleDisplayTime': t - .004, 'pushTime': t - .002}
                        for i, t in enumerate(times)]
            def write_telemetry(events):
                telemetry.write_text('\n'.join(json.dumps(e) for e in stats + events))
            write_telemetry(captures)
            result = device_summary(host, client, telemetry)
            self.assertTrue(result['baseline_eligible'], result['baseline_ineligible_reasons'])
            self.assertEqual(result['capture_marker_present_count'], 600)
            self.assertEqual(result['capture_bracket_valid_count'], 600)
            self.assertEqual(result['capture_point_timing_valid_count'], 0)
            self.assertLess(result['capture_handoff_signed_first_seen_discrepancy']['max_ms'], 0)
            self.assertEqual(result['decode_to_present']['count'], 600)
            self.assertEqual(result['all_frame_decode_to_present']['count'], 2)
            self.assertAlmostEqual(result['all_frame_decode_to_present']['mean_ms'], 35)
            write_telemetry(captures[:-1])
            lost = device_summary(host, client, telemetry)
            self.assertFalse(lost['baseline_eligible'])
            self.assertEqual(lost['unmatched_capture_marker_count'], 1)
            # Equal timestamps cannot bracket a transition between different IDs.
            captures[0]['sampleDisplayTime'] = markers[0]['previous_host_display_s']
            write_telemetry(captures)
            invalid = device_summary(host, client, telemetry)
            self.assertEqual(invalid['capture_marker_present_count'], 600)
            self.assertEqual(invalid['capture_bracket_unavailable_count'], 1)
            self.assertEqual(invalid['capture_bracket_invalid_count'], 1)
            self.assertFalse(invalid['baseline_eligible'])
            captures[0]['sampleDisplayTime'] = markers[0]['previous_host_display_s'] - .001
            write_telemetry(captures)
            reversed_bound = device_summary(host, client, telemetry)
            self.assertEqual(reversed_bound['capture_bracket_unavailable_count'], 1)
            self.assertEqual(reversed_bound['capture_bracket_invalid_count'], 1)
            self.assertFalse(reversed_bound['baseline_eligible'])

    def test_clock_readiness_converts_to_host_domain_and_rejects_nonfinite(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'client-test.jsonl'
            path.write_text(json.dumps({'type': 'clock', 'time': 90, 'offset': 10, 'uncertainty': .002, 'rtt': .01, 'samples': 50}))
            with patch('device_trace_tools.time.monotonic', return_value=101):
                self.assertEqual(recent_client(d, '99'), path)
                self.assertIsNone(recent_client(d, '100.5'))
                path.write_text('{"type":"clock","time":NaN,"offset":10,"uncertainty":0,"rtt":0,"samples":50}')
                self.assertIsNone(recent_client(d, '0'))

    def test_select_rejects_ambiguous_sessions(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            host = root / 'host.json'
            host.write_text(json.dumps({'markers': [{'marker_id': i, 'host_display_s': 100 + i * .1} for i in range(1, 12)]}))
            events = [{'type': 'clock', 'time': 89, 'offset': 11, 'uncertainty': .002, 'rtt': .01, 'samples': 50}]
            events += [{'type': 'marker', 'marker_id': i, 'presentedTime': 89 + i * .1 + .05} for i in range(1, 12)]
            for name in ('client-one.jsonl', 'client-two.jsonl'):
                (root / name).write_text('\n'.join(json.dumps(event) for event in events))
            with self.assertRaises(ValueError):
                select(host, root, root / 'selected.jsonl')

    def test_host_snapshot_rejects_partial_record(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            marker = root / 'markers.json'
            marker.write_text(json.dumps({'markers': [{'host_display_s': 100}, {'host_display_s': 160}]}))
            source = root / 'host-test.jsonl'
            records = [{'type': 'stats', 'side': 'host', 'time': 100}, {'type': 'stats', 'side': 'host', 'time': 160}]
            source.write_text('\n'.join(json.dumps(x) for x in records) + '\n{"type":')
            with self.assertRaises(ValueError):
                host_telemetry(marker, root, root / 'out.jsonl')
            source.write_text('\n'.join(json.dumps(x) for x in records) + '\n')
            host_telemetry(marker, root, root / 'out.jsonl')
            self.assertEqual((root / 'out.jsonl').read_bytes(), source.read_bytes())

    def test_missing_or_stale_clock_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            host, client = self.write(Path(d), [{'type': 'clock', 'time': 70, 'offset': 11, 'uncertainty': .002, 'rtt': .01, 'samples': 50}])
            with self.assertRaises(ValueError):
                device_summary(host, client)

if __name__ == '__main__':
    unittest.main()
