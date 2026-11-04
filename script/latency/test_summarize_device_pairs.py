import json
from pathlib import Path
import tempfile
import unittest

from summarize_device_pairs import host_time, present_interval_p95_ms, read_trace, segments, selected_fixes, summarize


class DevicePairSummaryTests(unittest.TestCase):
    def test_present_interval_p95_uses_render_callbacks_only(self):
        rows = [{'type': 'render', 'presentedTime': value} for value in (1.0, 1.01, 1.03, 1.06)]
        rows.extend([{'type': 'marker', 'presentedTime': 1.055},
                     {'type': 'render', 'presentedTime': None},
                     {'type': 'render', 'presentedTime': True}])
        self.assertAlmostEqual(present_interval_p95_ms(rows), 30)
        self.assertIsNone(present_interval_p95_ms(rows[:1]))
        self.assertIsNone(present_interval_p95_ms([]))

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.host_dir = self.root / 'host'
        self.host_dir.mkdir()
        self.client_path = self.root / 'client.jsonl'
        self.marker_path = self.root / 'markers.json'
        self.output = self.root / 'out'

    @staticmethod
    def write_rows(path, rows):
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))

    def fixture(self):
        client, markers = [], []
        a_delays = [10, 20, 30, 100]
        b_delays = [20, 30, 40, 10]
        marker_id = 0
        for index in range(8):
            trial = index + 1
            start = 100.0 + index * 40
            stop = start + 30
            arm = 'A' if index % 2 == 0 else 'B'
            settings = {'f1Playout': arm == 'B', 'f1MaximumDelayMs': 0,
                        'f2Encoder': False, 'f3Sender': False, 'f4Renderer': False}
            nonce = None if index == 0 else f'peer-{trial}'
            event = {'type': 'lab_pair', 'run': 'run-1', 'fix': 'F1', 'trial': trial,
                     'pair': index // 2 + 1, 'arm': arm, 'settings': settings, 'peerNonce': nonce}
            client.append({**event, 'stage': 'requested', 'time': start - 6})
            client.append({**event, 'stage': 'begin', 'time': start})
            for time in (start - 1, start + 10, start + 20, stop):
                client.append({'type': 'clock', 'time': time, 'offset': 1000.0,
                               'rtt': .01, 'uncertainty': .001, 'samples': 50})
            delay = (a_delays if arm == 'A' else b_delays)[index // 2] / 1000
            for offset in (1, 1.02, 1.05):
                client.append({'type': 'render', 'decodeTime': start + offset - .005,
                               'presentedTime': start + offset})
            for offset in range(1, 13):
                marker_id += 1
                host = start + offset + 1000
                markers.append({'marker_id': marker_id, 'host_display_s': host})
                client.append({'type': 'marker', 'marker_id': marker_id,
                               'decodeTime': start + offset + delay - .005,
                               'presentedTime': start + offset + delay})
            client.append({'type': 'stats', 'side': 'client', 'time': start + 10,
                           'values': {'currentRoundTripTime': .2 if trial == 8 else .01,
                                      'jitterBufferMs': 10, 'decodeMs': 4},
                           'reports': {'video': {'freezeCountDelta': 1 if arm == 'B' else 0}}})
            client.append({**event, 'stage': 'end', 'time': stop})
            if trial == 8:
                client.append({**event, 'stage': 'complete', 'time': stop})
            self.write_rows(self.host_dir / f'host-{trial}.jsonl', [
                {'type': 'lab_peer', 'peerNonce': nonce},
                {'type': 'stats', 'side': 'host', 'time': start + 1010,
                 'values': {'encodeMs': 5, 'packetSendMs': 1},
                 'reports': {'out': {'encoderImplementation': 'fixture'}}}])
        self.write_rows(self.client_path, client)
        self.marker_path.write_text(json.dumps({'duration_s': 400, 'markers': markers}))
        return client

    def run_summary(self):
        return summarize(self.marker_path, self.client_path, self.host_dir, self.output)

    def test_eight_windows_use_paired_median_and_keep_freezes_and_wifi_spikes(self):
        self.fixture()
        # A corrupt unrelated old host file must not invalidate current peers.
        (self.host_dir / 'host-old.jsonl').write_bytes(b'\xff\xfe')
        result = self.run_summary()
        self.assertEqual(result['pairs'], 4)
        self.assertEqual([r['arm'] for r in result['runs']], ['A', 'B'] * 4)
        self.assertAlmostEqual(result['median_paired_B_minus_A']['screen_to_screen_p50_ms'], 10, places=5)
        self.assertEqual(result['median_paired_B_minus_A']['freezes_per_minute'], 2)
        self.assertTrue(result['runs'][-1]['wifi_spike'])
        self.assertEqual(result['runs'][-1]['metrics']['rtt_p95_ms'], 200)
        self.assertEqual(result['runs'][0]['marker_coverage'], [12, 12])
        self.assertAlmostEqual(result['runs'][0]['metrics']['present_interval_p95_ms'], 30)
        self.assertAlmostEqual(result['median_paired_B_minus_A']['present_interval_p95_ms'], 0)
        self.assertEqual(Path(result['runs'][0]['host_trace']).name, 'host-1.jsonl')
        self.assertEqual(Path(result['runs'][1]['host_trace']).name, 'host-2.jsonl')

    def test_requires_complete_ordered_windows_and_stable_nonselected_settings(self):
        rows = self.fixture()
        events = [r for r in rows if r.get('type') == 'lab_pair']
        self.assertEqual(len(segments(rows)), 8)
        with self.assertRaises(ValueError):
            segments([r for r in rows if r is not events[-2]])
        reordered = list(rows)
        begin_index = reordered.index(events[1]); end_index = reordered.index(events[2])
        reordered[begin_index], reordered[end_index] = reordered[end_index], reordered[begin_index]
        with self.assertRaises(ValueError):
            segments(reordered)
        bad = [dict(r) for r in rows]
        next(r for r in bad if r.get('stage') == 'complete')['time'] -= 1
        with self.assertRaises(ValueError):
            segments(bad)
        bad = [dict(r) for r in rows]
        begin = next(r for r in bad if r.get('stage') == 'begin' and r.get('trial') == 3)
        begin['settings'] = {**begin['settings'], 'f2Encoder': True}
        with self.assertRaises(ValueError):
            segments(bad)

    def test_combined_check_requires_every_selected_toggle_and_canonical_names(self):
        for invalid in ('', 'F1+', '+F4', 'F1+F1', 'F4+F1', 'F1+F5', 'F1,F4', None):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                selected_fixes(invalid)
        self.assertEqual(selected_fixes('F1+F4'), ['F1', 'F4'])
        rows = self.fixture()
        for row in rows:
            if row.get('type') == 'lab_pair':
                row['fix'] = 'F1+F4'
                row['settings'] = {**row['settings'], 'f1Playout': True, 'f1MaximumDelayMs': 10,
                                   'f4Renderer': row['arm'] == 'B'}
        self.assertEqual(len(segments(rows)), 8)
        self.write_rows(self.client_path, rows)
        result = self.run_summary()
        self.assertEqual(result['fix'], 'F1+F4')
        self.assertEqual(result['pairs'], 4)
        # A partial application throughout B is not a valid combined arm.
        for row in rows:
            if row.get('type') == 'lab_pair' and row.get('trial') == 2:
                row['settings']['f4Renderer'] = False
        with self.assertRaises(ValueError):
            segments(rows)

    def test_f1_delay_comparison_requires_10_vs_20_with_f1_on(self):
        rows = self.fixture()
        for row in rows:
            if row.get('type') == 'lab_pair':
                row['settings'] = {**row['settings'], 'f1Playout': True,
                                   'f1MaximumDelayMs': 20 if row['arm'] == 'B' else 10}
        self.assertEqual(len(segments(rows)), 8)
        bad = next(row for row in rows if row.get('stage') == 'begin' and row.get('trial') == 2)
        bad['settings'] = {**bad['settings'], 'f1MaximumDelayMs': 10}
        with self.assertRaises(ValueError):
            segments(rows)

    def test_incremental_fix_requires_f1_on_in_both_arms(self):
        for fix, key in [('F2', 'f2Encoder'), ('F4', 'f4Renderer')]:
            rows = self.fixture()
            for row in rows:
                if row.get('type') == 'lab_pair':
                    row['fix'] = fix
                    row['settings'] = {**row['settings'], 'f1Playout': True, 'f1MaximumDelayMs': 10,
                                       key: row['arm'] == 'B'}
            self.assertEqual(len(segments(rows)), 8)
            for row in rows:
                if row.get('type') == 'lab_pair' and row['arm'] == 'A':
                    row['settings']['f1Playout'] = False
            with self.assertRaises(ValueError):
                segments(rows)

    def test_clock_uses_latest_valid_recent_offset_and_rejects_stale_or_invalid(self):
        rows = [{'type': 'clock', 'time': 90, 'offset': 5, 'rtt': .1, 'uncertainty': .01, 'samples': 50},
                {'type': 'clock', 'time': 99, 'offset': 7, 'rtt': .2, 'uncertainty': .01, 'samples': 50},
                {'type': 'clock', 'time': 100, 'offset': 100, 'rtt': -1, 'uncertainty': .01, 'samples': 50}]
        self.assertEqual(host_time(rows, 100), 107)
        with self.assertRaises(ValueError):
            host_time(rows, 116)
        with self.assertRaises(ValueError):
            host_time([{'type': 'clock', 'time': 100, 'samples': 50}], 100)

    def test_host_nonce_must_match_and_matching_trace_must_be_unique(self):
        rows = self.fixture()
        host = self.host_dir / 'host-2.jsonl'
        data = [json.loads(line) for line in host.read_text().splitlines()]
        data[0]['peerNonce'] = 'wrong-peer'
        self.write_rows(host, data)
        with self.assertRaises(ValueError):
            self.run_summary()
        data[0]['peerNonce'] = 'peer-2'
        self.write_rows(host, data)
        self.write_rows(self.host_dir / 'host-duplicate.jsonl', data)
        with self.assertRaises(ValueError):
            self.run_summary()
        bad = [dict(r) for r in rows]
        del next(r for r in bad if r.get('stage') == 'begin')['peerNonce']
        with self.assertRaises(ValueError):
            segments(bad)

    def test_rejects_truncated_client_or_matching_host_trace(self):
        self.fixture()
        with self.client_path.open('a') as trace:
            trace.write(json.dumps({'type': 'truncated'}) + '\n')
        with self.assertRaises(ValueError):
            self.run_summary()
        self.fixture()
        with (self.host_dir / 'host-1.jsonl').open('a') as trace:
            trace.write(json.dumps({'type': 'trace_truncated'}) + '\n')
        with self.assertRaises(ValueError):
            self.run_summary()
        incomplete = self.root / 'incomplete.jsonl'
        incomplete.write_bytes(b'{}')
        with self.assertRaises(ValueError):
            read_trace(incomplete)


if __name__ == '__main__':
    unittest.main()
