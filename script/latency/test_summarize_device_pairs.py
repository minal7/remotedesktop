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
        self.assertFalse(result['runs'][0]['stage0']['comparison_evidence_complete'])
        self.assertIn('selected pair missing or changed', result['runs'][0]['stage0']['missing_comparison_evidence'])
        self.assertIn('decoded coverage incomplete', result['runs'][0]['stage0']['missing_comparison_evidence'])
        self.assertIn('codec missing', result['runs'][0]['stage0']['missing_comparison_evidence'])
        self.assertIn('encoder implementation missing', result['runs'][0]['stage0']['missing_comparison_evidence'])
        self.assertIn('capture size missing', result['runs'][0]['stage0']['missing_comparison_evidence'])
        self.assertIn('encoded frame byte coverage incomplete', result['runs'][0]['stage0']['missing_comparison_evidence'])
        self.assertAlmostEqual(result['runs'][0]['metrics']['present_interval_p95_ms'], 30)
        self.assertAlmostEqual(result['median_paired_B_minus_A']['present_interval_p95_ms'], 0)
        self.assertEqual(Path(result['runs'][0]['host_trace']).name, 'host-1.jsonl')
        self.assertEqual(Path(result['runs'][1]['host_trace']).name, 'host-2.jsonl')

    def test_scene_interval_survives_sanitization_and_summary(self):
        for interval in (2, 8):
            with self.subTest(interval=interval):
                self.fixture()
                source = json.loads(self.marker_path.read_text())
                source['scene_interval_s'] = interval
                source['private_unrelated'] = 'must not survive'
                self.marker_path.write_text(json.dumps(source))
                result = self.run_summary()
                self.assertEqual(result['scene_interval_s'], interval)
                self.assertTrue(all(run['scene_interval_s'] == interval for run in result['runs']))
                saved = json.loads((self.output / '1-A.fixture-sanitized.json').read_text())
                self.assertEqual(saved['scene_interval_s'], interval)
                self.assertNotIn('private_unrelated', saved)

    def test_invalid_scene_interval_is_rejected_and_legacy_is_unknown(self):
        self.fixture()
        self.assertIsNone(self.run_summary()['scene_interval_s'])
        for invalid in (True, None, 0, 3, 2.5, '8'):
            with self.subTest(invalid=invalid):
                source = json.loads(self.marker_path.read_text())
                source['scene_interval_s'] = invalid
                self.marker_path.write_text(json.dumps(source))
                with self.assertRaises(ValueError): self.run_summary()

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

    def test_r60_all_eight_arms_hold_explicit_f1_and_retain_sanitized_hint(self):
        from summarize_device_pairs import sanitize_stage0
        for f1 in (False, True):
            for delay in (10, 20):
                rows = self.fixture()
                for row in rows:
                    if row.get('type') == 'lab_pair':
                        row['fix'] = 'R60'
                        row['settings'] = {'f1Playout': f1, 'f1MaximumDelayMs': delay,
                                           'f2Encoder': False, 'f3Sender': False,
                                           'f4Renderer': False, 'renderHint60': row['arm'] == 'B'}
                windows = segments(rows)
                self.assertEqual([a['settings']['renderHint60'] for a, _ in windows], [False, True] * 4)
                self.write_rows(self.client_path, rows)
                result = self.run_summary()
                for run in result['runs']:
                    self.assertEqual(run['stage0']['render_hint_application'], 'unverified')
                    self.assertIn('render hint application unverified', run['stage0']['missing_comparison_evidence'])
                    self.assertFalse(run['stage0']['comparison_evidence_complete'])
                    self.assertEqual(run['stage0']['flags']['renderHint60'], run['arm'] == 'B')
                    self.assertIn('presented_fps', run['metrics'])
                    self.assertIn('decoded_fps', run['metrics'])
                    self.assertAlmostEqual(run['metrics']['present_interval_p95_ms'], 30)
                safe = sanitize_stage0(rows)
                events = [r for r in safe if r['type'] == 'lab_pair']
                self.assertTrue(events)
                self.assertTrue(all(type(r['settings'].get('renderHint60')) is bool for r in events))
                self.assertTrue(all('peerNonce' not in r and 'run' not in r for r in events))

    def test_r60_rejects_mixed_fixes_and_inconsistent_or_missing_settings(self):
        import copy
        for invalid in ('R60+F1', 'F1+R60', 'R60+F4', 'R60+R60'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError): selected_fixes(invalid)
        rows = self.fixture()
        for row in rows:
            if row.get('type') == 'lab_pair':
                row['fix'] = 'R60'
                row['settings'] = {'f1Playout': False, 'f1MaximumDelayMs': 20,
                                   'f2Encoder': False, 'f3Sender': False,
                                   'f4Renderer': False, 'renderHint60': row['arm'] == 'B'}
        for key, value in [('f1Playout', None), ('f1MaximumDelayMs', 0),
                           ('f2Encoder', True), ('f3Sender', True), ('f4Renderer', True),
                           ('renderHint60', None)]:
            bad = copy.deepcopy(rows)
            for r in bad:
                if r.get('type') == 'lab_pair': r['settings'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): segments(bad)
        bad = copy.deepcopy(rows)
        for r in bad:
            if r.get('type') == 'lab_pair' and r['trial'] == 4: r['settings']['f1Playout'] = True
        with self.assertRaises(ValueError): segments(bad)
        bad = copy.deepcopy(rows)
        for r in bad:
            if r.get('type') == 'lab_pair' and r['trial'] == 6: r['settings']['renderHint60'] = False
        with self.assertRaises(ValueError): segments(bad)
        bad = copy.deepcopy(rows)
        next(r for r in bad if r.get('stage') == 'complete')['settings']['renderHint60'] = False
        with self.assertRaises(ValueError): segments(bad)

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

class StageZeroMetricsTests(unittest.TestCase):
    def test_locked_runs_require_twenty_consecutive_near_25ms_gaps(self):
        from summarize_device_pairs import locked_25ms_runs
        def render(gaps):
            t=0; out=[{'type':'render','presentedTime':t}]
            for gap in gaps:
                t+=gap/1000; out.append({'type':'render','presentedTime':t})
            return out
        self.assertEqual(locked_25ms_runs(render([25]*19))['observed_runs'], 0)
        self.assertEqual(locked_25ms_runs(render([25]*20))['observed_runs'], 1)
        self.assertEqual(locked_25ms_runs(render([25]*19+[33]+[25]*19))['observed_runs'], 0)
        self.assertEqual(locked_25ms_runs(render([25]*21+[33]+[25]*20))['observed_runs'], 2)
        self.assertEqual(locked_25ms_runs(render([33.3]*40))['observed_runs'], 0)

    def test_sanitizer_retains_stage_zero_fields_without_ids_or_untyped_values(self):
        from summarize_device_pairs import sanitize_stage0
        rows=[{'type':'stats','time':1,'values':{'localCandidateType':'host','localCandidateFamily':'v4',
            'remoteCandidateType':'srflx','remoteCandidateFamily':'v4','candidateProtocol':'udp','rttFloorMs':4,
            'captureWidth':2544,'captureHeight':1644,'encoderImplementation':'VideoToolbox','codec_mimeType':'video/H264',
            'address':'secret'},'reports':{'private-id':{'framesEncodedDelta':10,'encoderImplementation':'VideoToolbox','address':'secret'}}},
            {'type':'encoded_frame_sizes','time':2,'count':4,'p50Bytes':10,'p95Bytes':20,'maxBytes':30,'complete':True,'private':'secret'},
            {'type':'stream_event','time':3,'event':'bandwidth_estimate_drop','metric':'targetBitrate','beforeBps':100,'afterBps':49,'private':'secret'},
            {'type':'stream_event','time':4,'event':'bandwidth_estimate_drop','metric':'targetBitrate','beforeBps':100,'afterBps':50},
            {'type':'render','decodeTime':1,'submittedTime':2,'presentedTime':3,'receiptDeliveryTime':4,'private':'secret'},
            {'type':'lab_configuration','time':1,'settings':{'f1Playout':True,'f1MaximumDelayMs':10,'f2Encoder':False,'private':'secret'}}]
        out=sanitize_stage0(rows); text=json.dumps(out)
        self.assertNotIn('secret',text); self.assertNotIn('private-id',text)
        self.assertEqual(out[0]['values']['rttFloorMs'],4)
        self.assertEqual(out[0]['streams'][0]['framesEncodedDelta'],10)
        self.assertEqual(out[1]['p95Bytes'],20)
        self.assertEqual(sum(r['type']=='stream_event' for r in out),1)
        self.assertEqual(next(r for r in out if r['type']=='render')['receiptDeliveryTime'],4)
        self.assertEqual(next(r for r in out if r['type']=='lab_configuration')['settings']['f1MaximumDelayMs'],10)

    def test_window_reports_path_rates_transition_and_missing_as_unverified(self):
        from summarize_device_pairs import stage0_window
        begin={'time':10,'settings':{'f1Playout':False,'f1MaximumDelayMs':10}}; end={'time':40}
        pair={'localCandidateType':'host','localCandidateFamily':'v4','remoteCandidateType':'host',
              'remoteCandidateFamily':'v4','candidateProtocol':'udp','rttFloorMs':3.5,'currentRoundTripTime':.04,'captureWidth':2544,'captureHeight':1644,
              'codec_mimeType':'video/H264','encoderImplementation':'VideoToolbox'}
        host=[{'type':'stats','time':1011,'values':pair},{'type':'encoded_frame_sizes','time':1011,
               'count':2,'p50Bytes':100,'p95Bytes':200,'maxBytes':200,'complete':True}]
        client=[{'type':'stats','side':'client','time':10,'values':{}},
                {'type':'stats','side':'client','time':11,'values':{'framesDecodedDelta':55}},
                {'type':'render','decodeTime':10,'submittedTime':10.01,'presentedTime':10.03,'receiptDeliveryTime':10.04}]
        detail={'samples':[{'marker_id':1,'screen_to_screen_ms':80}], 'screen_to_screen':{'p50_ms':80}}
        marker=[{'marker_id':1,'scene':'text','scene_transition':True}]
        out=stage0_window(client,host,begin,end,detail,marker)
        self.assertEqual(out['pair_status'],'observed'); self.assertEqual(out['rtt_floor_ms'],40)
        self.assertEqual(out['lifetime_rtt_floor_ms'],3.5)
        self.assertEqual(out['decoded_fps_by_interval'][0]['fps'],55)
        self.assertEqual(out['presented_frames_per_second'][0]['presented_frames'],1)
        self.assertEqual(out['large_change_first_frame_ms']['p50'],80)
        self.assertEqual(out['capture_sizes'],[{'width':2544,'height':1644}])
        self.assertAlmostEqual(out['render_split']['submitted_to_presented']['p50_ms'],20)
        missing=stage0_window([],[],begin,end,{'samples':[]},[])
        self.assertEqual(missing['pair_status'],'unverified'); self.assertIsNone(missing['rtt_floor_ms'])
        self.assertIsNone(missing['large_change_first_frame_ms']['p50'])

    def test_missing_markers_remain_unverified_not_a_false_pass(self):
        from summarize_device_pairs import summarize
        from unittest.mock import patch
        # An unavailable marker match is explicitly represented rather than treated as zero latency.
        with patch('summarize_device_pairs.device_summary', side_effect=ValueError('No matched markers with a recent clock estimate')):
            fixture=DevicePairSummaryTests(methodName='test_eight_windows_use_paired_median_and_keep_freezes_and_wifi_spikes')
            fixture.setUp()
            try:
                fixture.fixture()
                out=fixture.run_summary()
                self.assertIsNone(out['median_paired_B_minus_A']['screen_to_screen_p50_ms'])
                self.assertTrue(all(r['marker_caveat'] for r in out['runs']))
                self.assertTrue(all(r['metrics']['screen_to_screen_p50_ms'] is None for r in out['runs']))
            finally:fixture.doCleanups()

    def test_rtt_floor_uses_current_window_and_unknown_pair_is_unverified(self):
        from summarize_device_pairs import stage0_window
        begin={'time':10,'settings':{}}; end={'time':40}
        unknown={'localCandidateType':'unknown','localCandidateFamily':'unknown',
                 'remoteCandidateType':'unknown','remoteCandidateFamily':'unknown','candidateProtocol':'unknown',
                 'rttFloorMs':1,'currentRoundTripTime':.08}
        host=[{'type':'stats','time':11,'values':unknown},
              {'type':'stats','time':12,'values':{'rttFloorMs':1,'currentRoundTripTime':.06}}]
        out=stage0_window([],host,begin,end,{'samples':[]},[])
        self.assertEqual(out['pair_status'],'unverified')
        self.assertEqual(out['rtt_floor_ms'],60)
        self.assertEqual(out['lifetime_rtt_floor_ms'],1)

    def test_network_interval_reports_actual_deltas_units_missing_and_privacy(self):
        from summarize_device_pairs import network_intervals, sanitize_stage0
        rows = [
            {'type': 'stats', 'side': 'host', 'time': 9, 'values': {}, 'reports': {'old': {'bytesSentDelta': 999}}},
            {'type': 'stats', 'side': 'host', 'time': 10, 'values': {}, 'reports': {}},
            {'type': 'stats', 'side': 'host', 'time': 12, 'values': {'currentRoundTripTime': .025,
                'availableOutgoingBitrate': 1200000, 'targetBitrate': 900000, 'packetSendMs': 8},
             'reports': {'secret-stream-id': {'bytesSentDelta': 250000, 'packetsSentDelta': 200,
                'packetsLostDelta': 4, 'jitter': .006, 'packetSendMs': 7, 'targetBitrate': 850000,
                'candidate': 'private-address'}}},
            {'type': 'stats', 'side': 'host', 'time': 20, 'values': {}, 'reports': {}},
            {'type': 'stats', 'side': 'host', 'time': 21, 'values': {}, 'reports': {'another': {
                'bytesReceivedDelta': 1000, 'packetsReceivedDelta': 10, 'packetsLostDelta': -1, 'jitter': True}}},
            {'type': 'stats', 'side': 'host', 'time': 22, 'values': {}, 'reports': {'next': {
                'bytesSentDelta': -1, 'bytesReceivedDelta': True, 'packetsSentDelta': float('nan')}}},
        ]
        out = network_intervals(rows, 10, 22)
        self.assertEqual(len(out['intervals']), 2)  # No boundary-crossing or >5-second gap.
        first, second = out['intervals']
        self.assertEqual(first['interval_s'], 2)
        self.assertEqual(first['streams'][0]['sent_bps'], 1000000)
        self.assertIsNone(first['streams'][0]['received_bps'])
        self.assertEqual(first['streams'][0]['packets_sent_delta'], 200)
        self.assertEqual(first['streams'][0]['packets_lost_delta'], 4)
        self.assertEqual(first['streams'][0]['rtp_jitter_ms'], 6)
        self.assertEqual(first['rtt_ms'], 25)
        self.assertEqual(first['target_bitrate_estimate_bps'], 900000)
        self.assertEqual(first['available_outgoing_estimate_bps'], 1200000)
        self.assertEqual(second['streams'][0]['received_bps'], 8000)
        self.assertIsNone(second['streams'][0]['packets_lost_delta'])
        self.assertIsNone(second['streams'][0]['rtp_jitter_ms'])
        self.assertIsNone(second['rtt_ms'])
        sanitized = sanitize_stage0(rows)
        text = json.dumps([out, sanitized])
        self.assertNotIn('secret-stream-id', text)
        self.assertNotIn('private-address', text)
        self.assertIn('bytesSentDelta', text)
        self.assertIn('packetsReceivedDelta', text)

    def test_fixture_sanitizer_keeps_scene_transition_without_private_payload(self):
        from summarize_device_pairs import sanitize_fixture_markers
        rows=[{'marker_id':1,'host_display_s':2.0,'scene':'photo','scene_transition':True,'photo_path':'private'},
              {'marker_id':2,'host_display_s':3.0,'scene':'private','scene_transition':'yes'}]
        result=sanitize_fixture_markers(rows)
        self.assertEqual(result[0]['scene'],'photo'); self.assertTrue(result[0]['scene_transition'])
        self.assertNotIn('private',json.dumps(result))
        self.assertNotIn('scene',result[1]); self.assertNotIn('scene_transition',result[1])

if __name__ == '__main__':
    unittest.main()
