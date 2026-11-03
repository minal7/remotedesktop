import json
from pathlib import Path
import tempfile
import unittest

from summarize_pairs import summarize


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

    def testMissingSharpnessIsUnknownRatherThanAFreePass(self):
        manifest = self.manifest()
        path = Path(manifest['runs'][3])
        run = json.loads(path.read_text())
        run['native_text_ssim'] = None
        path.write_text(json.dumps(run))
        self.assertIsNone(summarize(manifest)['median_paired_B_minus_A']['native_text_ssim'])

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
