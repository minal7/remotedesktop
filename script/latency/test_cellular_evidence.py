import unittest
from cellular_evidence import clean_client, clean_host

class CellularEvidenceTests(unittest.TestCase):
    def test_sanitized_allowlist_and_timing(self):
        rows = [dict(type='connectivity', event='attempt_start', attempt='private', time=1),
                dict(type='connectivity', event='first_presented', attempt='private', time=2.5),
                dict(type='connectivity', event='selected_pair', attempt='private', time=2,
                     localType='host', localFamily='v4', remoteType='srflx', remoteFamily='v4', protocol='udp', secret='hidden')]
        result = clean_client(rows)
        self.assertEqual(result['time_to_video_ms'], 1500)
        self.assertEqual(result['selected_pair']['remoteType'], 'srflx')
        self.assertNotIn('private', str(result))
        self.assertNotIn('hidden', str(result))
        self.assertEqual(clean_host(['port_mapping=mapped ms=10', 'port_mapping=unexpected']), {'mapping_statuses': ['mapped']})

    def test_candidate_events_and_signaling_stages_are_strictly_sanitized(self):
        start = dict(type='connectivity', event='attempt_start', attempt='opaque', time=0)
        def event(kind, **fields):
            return dict(type='connectivity', event=kind, attempt='opaque', time=1, **fields)
        rows = [start, event('stage', stage='offer_sent'), event('stage', stage='answer_received'),
                event('stage', stage='answer_applied'), event('stage', stage='ice_connected'),
                event('stage', stage='secret'),
                event('remote_candidate_received', candidateType='host', family='v4', count=1, elapsedMs=3, address='secret'),
                event('remote_candidate_added', candidateType='srflx', family='v6', count=2, elapsedMs=4.5),
                event('remote_candidate_add_failed', candidateType='unknown', family='unknown', count=3, elapsedMs=5),
                event('remote_candidate_added', candidateType='relay', family='v4', count=4, elapsedMs=1),
                event('remote_candidate_added', candidateType='host', family='secret', count=4, elapsedMs=1),
                event('remote_candidate_added', candidateType='host', family='v4', count=True, elapsedMs=1),
                event('remote_candidate_added', candidateType='host', family='v4', count=10001, elapsedMs=1),
                event('remote_candidate_added', candidateType='host', family='v4', count=1, elapsedMs=float('nan')),
                event('remote_candidate_added', candidateType='host', family='v4', count=1, elapsedMs=-1)]
        result = clean_client(rows)
        self.assertEqual(result['signaling_stages'], ['offer_sent', 'answer_received', 'answer_applied', 'ice_connected'])
        self.assertEqual(len(result['candidate_events']), 3)
        self.assertEqual(result['candidate_events'][0], dict(event='remote_candidate_received', candidateType='host', family='v4', count=1, elapsedMs=3))
        self.assertNotIn('secret', str(result))
        self.assertNotIn('opaque', str(result))

    def test_missing_mixed_or_injected_values_fail_closed(self):
        with self.assertRaises(ValueError): clean_client([])
        with self.assertRaises(ValueError): clean_client([dict(type='connectivity', event='attempt_start', attempt='x', time=1), dict(type='connectivity', event='failure', attempt='y', time=2)])
        rows = [dict(type='connectivity', event='attempt_start', attempt='x', time=1), dict(type='connectivity', event='failure', attempt='x', stage='unknown sensitive text')]
        self.assertNotIn('failure_stage', clean_client(rows))

class CellularMeasurementTests(unittest.TestCase):
    def test_complete_window_and_freeze_detection(self):
        import json
        import tempfile
        from pathlib import Path
        from cellular_evidence import measurement
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = [dict(marker_id=i + 1, host_display_s=100 + i / 10) for i in range(600)]
            marker = {'markers': source, 'duration_s': 60, 'initial_marker_observed_before_timing': True}
            records = [dict(type='clock', time=t, offset=0, rtt=.01, uncertainty=.001, samples=50) for t in range(99, 161, 5)]
            records += [dict(type='marker', marker_id=r['marker_id'], presentedTime=r['host_display_s'] + .05) for r in source]
            records += [dict(type='render', presentedTime=r['host_display_s'] + .05) for r in source]
            host = base / 'host.json'; client = base / 'client.jsonl'
            host.write_text(json.dumps(marker)); client.write_text(''.join(json.dumps(r) + '\n' for r in records))
            result = measurement(host, client, records)
            self.assertEqual(result['screen_to_screen_30s']['count'], 300)
            self.assertFalse(result['freeze_over_2s'])
            missing_frames = [r for r in records if r.get('type') != 'render' or not 120 < r['presentedTime'] < 123]
            self.assertTrue(measurement(host, client, missing_frames)['freeze_over_2s'])
            marker['duration_s'] = 59
            host.write_text(json.dumps(marker))
            with self.assertRaises(ValueError): measurement(host, client, records)
