import json
from pathlib import Path
import tempfile
import unittest

from summarize_pairs import F3_PACER_TRIAL, summarize


class PairedSummaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def manifest(self):
        paths = []
        # A difference of pooled medians would be zero; the paired median is
        # +10 ms. This fixture catches accidental pooling across drifting runs.
        for index, (a, b) in enumerate(zip([10, 20, 30, 100], [20, 30, 40, 10])):
            for arm, encode in [('A', a), ('B', b)]:
                path = self.root / f'{index}-{arm}.json'
                sender = path.with_suffix('.sender.jsonl')
                receiver = path.with_suffix('.receiver.jsonl')
                sender.write_text(json.dumps({'type': 'stats', 'time': 20, 'side': 'loopback_sender',
                    'values': {'encodeMs': encode, 'packetSendMs': 1,
                               'currentRoundTripTime': .2 if index == 3 else .01},
                    'reports': {'out': {}}}) + '\n')
                receiver.write_text(json.dumps({'type': 'stats', 'time': 20, 'side': 'loopback_receiver',
                    'values': {'decodeMs': 5, 'jitterBufferMs': 30, 'jitterBufferTargetMs': 25},
                    'reports': {'in': {'freezeCountDelta': 1 if arm == 'B' else 0}}}) + '\n')
                path.write_text(json.dumps({'measurement_start_s': 10, 'measurement_end_s': 40,
                    'sender_trace': str(sender), 'receiver_trace': str(receiver),
                    'lab_configuration': {'f2Encoder': arm == 'B', 'f1Playout': False},
                    'native_text_ssim': .98 if arm == 'B' else .99, 'video_size': '2400x1552',
                    'viewer_marker_count': 298, 'source_marker_count': 300,
                    'compositor_to_compositor': {'p50_ms': encode, 'p95_ms': encode + 10}}))
                paths.append(str(path))
        return {'fix': 'F2', 'pairs': 4, 'session': 'fixture', 'runs': paths}

    def testPairsPreserveDriftSpikesFreezesAndSharpnessLoss(self):
        result = summarize(self.manifest())
        self.assertEqual(result['median_paired_B_minus_A']['encodeMs_p50'], 10)
        self.assertEqual(result['median_paired_B_minus_A']['freezes_per_minute'], 2)
        self.assertAlmostEqual(result['median_paired_B_minus_A']['native_text_ssim'], -.01)
        self.assertEqual(len(result['runs']), 8, 'Wi-Fi spikes still count')
        self.assertTrue(result['runs'][-1]['wifi_spike'])
        self.assertEqual(result['runs'][-1]['rtt_ms_p95'], 200)
        self.assertEqual(result['runs'][0]['marker_coverage'], [298, 300])

    def testPacerPairsRequireOnlyTrialChangeAndMatchingSenderEvidence(self):
        manifest = self.manifest()
        manifest['fix'] = 'F3Pacer'
        for index, name in enumerate(manifest['runs']):
            path = Path(name)
            run = json.loads(path.read_text())
            enabled = index % 2 == 1
            run['lab_configuration']['f2Encoder'] = False
            run['lab_configuration']['f3Sender'] = False
            run['lab_configuration']['f3Pacer'] = enabled
            run['sender_field_trial'] = F3_PACER_TRIAL if enabled else None
            run['sender_field_trial_effective'] = 'unverified'
            path.write_text(json.dumps(run))
            sender = Path(run['sender_trace'])
            with sender.open('a') as trace:
                trace.write(json.dumps({'type': 'lab_configuration', 'component': 'f3_pacer_trial',
                    'side': 'loopback_sender', 'configured': enabled,
                    'field_trial': F3_PACER_TRIAL if enabled else None, 'effective': 'unverified'}) + '\n')
        self.assertEqual(summarize(manifest)['pairs'], 4)

        b = Path(manifest['runs'][1])
        changed = json.loads(b.read_text())
        changed['lab_configuration']['f3Sender'] = True
        b.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            summarize(manifest)
        changed['lab_configuration']['f3Sender'] = False
        changed['sender_field_trial'] = None
        b.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            summarize(manifest)
        changed['sender_field_trial'] = F3_PACER_TRIAL
        b.write_text(json.dumps(changed))
        sender = Path(changed['sender_trace'])
        lines = sender.read_text().splitlines()
        event = json.loads(lines[-1]); event['field_trial'] = None
        lines[-1] = json.dumps(event); sender.write_text('\n'.join(lines) + '\n')
        with self.assertRaises(ValueError):
            summarize(manifest)
        event['field_trial'] = F3_PACER_TRIAL
        lines[-1] = json.dumps(event); sender.write_text('\n'.join(lines) + '\n')
        for name in manifest['runs'][2:4]:
            path = Path(name); run = json.loads(path.read_text())
            run['lab_configuration']['f1Playout'] = True
            path.write_text(json.dumps(run))
        with self.assertRaises(ValueError):
            summarize(manifest)

    def testMissingSharpnessIsUnknownRatherThanAFreePass(self):
        manifest = self.manifest()
        path = Path(manifest['runs'][3])
        run = json.loads(path.read_text())
        run['native_text_ssim'] = None
        path.write_text(json.dumps(run))
        self.assertIsNone(summarize(manifest)['median_paired_B_minus_A']['native_text_ssim'])

    def testF1RequiresReceiverTrialAndReportedJitterTargets(self):
        manifest = self.manifest()
        manifest['fix'] = 'F1'
        trial = 'WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:0/'
        for index, name in enumerate(manifest['runs']):
            path = Path(name); run = json.loads(path.read_text())
            enabled = index % 2 == 1
            run['lab_configuration'].update(f1Playout=enabled, f1MaximumDelayMs=0,
                                            f2Encoder=False, f3Sender=False)
            run['receiver_field_trial'] = trial if enabled else None
            run['receiver_field_trial_effective'] = 'unverified'
            path.write_text(json.dumps(run))
            with Path(run['receiver_trace']).open('a') as trace:
                trace.write(json.dumps({'type': 'lab_configuration', 'component': 'f1_playout_trial',
                    'side': 'loopback_receiver', 'configured': enabled,
                    'field_trial': trial if enabled else None, 'effective': 'unverified'}) + '\n')
        self.assertEqual(summarize(manifest)['median_paired_B_minus_A']['jitterBufferTargetMs_p50'], 0)
        path = Path(manifest['runs'][1]); run = json.loads(path.read_text())
        run['receiver_field_trial'] = None
        path.write_text(json.dumps(run))
        with self.assertRaises(ValueError): summarize(manifest)
        run['receiver_field_trial'] = trial; run['lab_configuration']['f2Encoder'] = True
        path.write_text(json.dumps(run))
        with self.assertRaises(ValueError): summarize(manifest)
        run['lab_configuration']['f2Encoder'] = False; path.write_text(json.dumps(run))
        trace = Path(run['receiver_trace']); lines = trace.read_text().splitlines()
        stats = json.loads(lines[0]); del stats['values']['jitterBufferTargetMs']
        lines[0] = json.dumps(stats); trace.write_text('\n'.join(lines) + '\n')
        with self.assertRaises(ValueError): summarize(manifest)

    def testRejectsIncompletePairsAndSimultaneousChanges(self):
        manifest = self.manifest()
        with self.assertRaises(ValueError):
            summarize({**manifest, 'runs': manifest['runs'][:6]})
        path = Path(manifest['runs'][1])
        run = json.loads(path.read_text())
        run['lab_configuration']['f1Playout'] = True
        path.write_text(json.dumps(run))
        with self.assertRaises(ValueError):
            summarize(manifest)


if __name__ == '__main__':
    unittest.main()
