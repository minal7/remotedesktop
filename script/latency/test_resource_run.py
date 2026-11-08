import json
import tempfile
import unittest
from pathlib import Path
from resource_run import read_trace, report, select


class ResourceRunTests(unittest.TestCase):
    def traces(self):
        host = [{'type': 'resource_mode', 'side': 'host', 'resourceCadenceSeconds': 1, 'statsCadenceSeconds': 10}]
        client = [{'type': 'resource_mode', 'side': 'client', 'resourceCadenceSeconds': 1, 'statsCadenceSeconds': 10}]
        for second in range(601):
            host.append({'type': 'resource', 'time': 1000 + second, 'processCPUPercent': 25})
            if second % 10 == 0:
                client.append({'type': 'clock', 'time': second, 'offset': 1000, 'rtt': .01, 'uncertainty': .005, 'samples': 50})
            client.append({'type': 'resource', 'time': second, 'batteryLevel': .8 if second < 600 else .79,
                           'batteryState': 1, 'thermalState': 0})
        return host, client

    def test_complete_run_and_charge_uncertainty(self):
        host, client = self.traces()
        result = report(host, client, 1000, 1600, 600)
        self.assertTrue(result['coverage_complete'])
        self.assertEqual(result['host_coverage']['span_s'], 600)
        self.assertTrue(result['resources']['client_battery']['continuous_unplugged_samples'])
        self.assertIsNone(result['within_15_percent_verdict'])
        self.assertIsNone(result['gpu_use'])
        client[-1]['batteryState'] = 2
        result = report(host, client, 1000, 1600, 600)
        self.assertFalse(result['resources']['client_battery']['continuous_unplugged_samples'])
        self.assertIsNone(result['resources']['client_battery']['ten_minute_drain_verdict'])

    def test_short_gaps_and_stale_clock_fail_coverage(self):
        host, client = self.traces()
        with self.assertRaises(ValueError):
            report(host, client, 1000, 1599, 600)
        host = [r for r in host if not (r.get('type') == 'resource' and 1200 <= r['time'] < 1210)]
        self.assertFalse(report(host, client, 1000, 1600, 600)['coverage_complete'])
        client = [r for r in client if r.get('type') != 'clock' or r['time'] == 0]
        self.assertFalse(report(host, client, 1000, 1600, 600)['client_coverage']['complete'])

    def test_selection_rejects_truncation_and_partial_records(self):
        host, _ = self.traces()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'host-one.jsonl'
            data = ''.join(json.dumps(r) + '\n' for r in host)
            path.write_text(data)
            self.assertEqual(select(directory, 'host', 1000, 1600)[0], path)
            path.write_text(data + '{"type":"truncated"}\n')
            with self.assertRaises(ValueError):
                read_trace(path, 'host')
            path.write_text(data + '{')
            with self.assertRaises(ValueError):
                read_trace(path, 'host')
            path.write_text(data + ' ' * 1_000_001)
            with self.assertRaises(ValueError):
                read_trace(path, 'host')


if __name__ == '__main__':
    unittest.main()
