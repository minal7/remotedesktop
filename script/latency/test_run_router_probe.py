import json
import os
import subprocess
import tempfile
import unittest
from unittest import mock
import run_router_probe as p


class ParsingTests(unittest.TestCase):
    def test_loss_reorder_duplicates_and_privacy(self):
        m = p.Measurements(offset=5)
        for seq in range(3):
            m.observe(f'64 bytes to 192.0.2.1: icmp_seq={seq}', 10 + seq * .1)
        m.observe('Request timeout for icmp_seq 1', 11)
        m.observe('64 bytes from 192.0.2.1: icmp_seq=2 ttl=64 time=3.200 ms', 11.01)
        m.observe('64 bytes from 192.0.2.1: icmp_seq=0 ttl=64 time=2.100 ms', 11.02)
        m.observe('64 bytes from 192.0.2.1: icmp_seq=0 ttl=64 time=2.100 ms (DUP!)', 11.03)
        result = m.result()
        self.assertEqual([r['status'] for r in result['records']], [1, 2, 1])
        self.assertAlmostEqual(result['records'][1]['request_interval_s'], .1)
        self.assertEqual(result['records'][0]['request_observed_s'], 15)
        self.assertEqual(result['records'][0]['rtt_ms'], 2.1)
        self.assertEqual(result['counts']['duplicates'], 1)
        self.assertEqual(result['counts']['reordered_responses'], 1)
        self.assertEqual(result['counts']['unanswered_observed_requests'], 1)
        self.assertNotIn('192.0.2.1', json.dumps(result))
        self.assertNotIn('ttl', json.dumps(result))

    def test_late_reply_and_unobserved_sequence_not_claimed_lost(self):
        m = p.Measurements()
        m.observe('64 bytes to 10.0.0.1: icmp_seq=0', 1)
        m.observe('64 bytes to 10.0.0.1: icmp_seq=2', 2)
        m.observe('Request timeout for icmp_seq 0', 3)
        m.observe('64 bytes from 10.0.0.1: icmp_seq=0 ttl=4 time=3.000 ms', 4)
        result = m.result()
        self.assertEqual(result['unobserved_request_sequences'], [1])
        self.assertEqual(result['records'][0]['status'], 3)
        self.assertEqual(result['counts']['unanswered_observed_requests'], 1)

    def test_malformed_and_out_of_range(self):
        m = p.Measurements()
        for line in ('64 bytes to 10.0.0.1: icmp_seq=-1',
                     '64 bytes from 10.0.0.1: icmp_seq=1 ttl=2 time=NaN ms',
                     '64 bytes to 10.0.0.1: icmp_seq=90000', 'PING 10.0.0.1'):
            m.observe(line, 1)
        m.observe('64 bytes to 10.0.0.1: icmp_seq=2', float('nan'))
        self.assertEqual(m.result()['records'], [])
        self.assertEqual(m.result()['counts']['malformed'], 4)
        self.assertNotIn('10.0.0.1', json.dumps(m.result()))

    def test_numeric_only_result_and_bounded_records(self):
        m = p.Measurements()
        for seq in range(p.MAX_RECORDS + 5):
            m.observe(f'64 bytes to 192.0.2.1: icmp_seq={seq}', seq * .1)
        result = m.result()
        self.assertEqual(len(result['records']), p.MAX_RECORDS)
        self.assertEqual(result['counts']['malformed'], 5)
        self.assertLess(len(json.dumps(result).encode()), p.MAX_OUTPUT_BYTES)
        def check(value):
            if isinstance(value, dict):
                for child in value.values(): check(child)
            elif isinstance(value, list):
                for child in value: check(child)
            else:
                self.assertTrue(value is None or (type(value) in (int, float)))
        check(result)

    def test_reply_without_observed_request(self):
        m = p.Measurements()
        m.observe('64 bytes from 10.0.0.1: icmp_seq=1 ttl=4 time=4.1 ms', 5)
        self.assertIsNone(m.result()['records'][0]['request_observed_s'])


class ValidationTests(unittest.TestCase):
    def test_duration_closed_and_finite(self):
        for value in ('0', '121', '-1', 'NaN', 'inf', 'words'):
            with self.subTest(value=value), self.assertRaises(Exception): p.duration(value)
        self.assertEqual(p.duration('120'), 120)
        self.assertEqual(p.duration('1'), 1)

    def test_path_must_be_absolute(self):
        for value in ('file.json', '.', '/tmp/a\0b'):
            with self.subTest(value=value), self.assertRaises(Exception): p.output_path(value)
        self.assertEqual(str(p.output_path('/tmp/probe.json')), '/tmp/probe.json')

    @mock.patch('run_router_probe.subprocess.run')
    def test_discovery_single_ipv4_router(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, ' gateway: 192.0.2.1\n')
        self.assertEqual(p.discover_router(), '192.0.2.1')
        self.assertEqual(run.call_args.args[0], ['/sbin/route', '-n', 'get', 'default'])
        for output in ('gateway: ::1\n', 'gateway: 127.0.0.1\n', 'gateway: 192.0.2.1\ngateway: 192.0.2.2\n', 'no gateway'):
            run.return_value = subprocess.CompletedProcess([], 0, output)
            with self.subTest(output=output), self.assertRaisesRegex(RuntimeError, 'default IPv4 router unavailable'):
                p.discover_router()

    def test_clock_matches_foundation_on_mac(self):
        if p.sys.platform != 'darwin': self.skipTest('macOS only')
        sample = p.system_uptime_calibration()
        self.assertLess(abs(sample['offset_seconds']), .01)
        self.assertLess(sample['uncertainty_seconds'], .01)


class LifecycleTests(unittest.TestCase):
    def test_interrupt_cleans_exact_child_and_sanitizes(self):
        children = []
        class Child:
            def __init__(self, args, **kwargs):
                children.append(self); self.args = args; self.terminated = False
                self.slave = os.dup(kwargs['stdout'])
                os.write(self.slave, b'64 bytes to 192.0.2.1: icmp_seq=0\n64 bytes from 192.0.2.1: icmp_seq=0 ttl=64 time=2.000 ms\n')
            def poll(self): return 0 if self.terminated else None
            def terminate(self): self.terminated = True; os.close(self.slave)
            def wait(self, timeout): return 0
            def kill(self): raise AssertionError('unexpected kill')
        calls = [0]
        def stop():
            calls[0] += 1
            return calls[0] > 1
        result = p.collect('192.0.2.1', 1, {'offset_seconds': 0, 'uncertainty_seconds': 0}, stop, Child)
        self.assertTrue(children[0].terminated)
        self.assertEqual(result['end_reason'], 1)
        self.assertEqual(result['counts']['requests_observed'], 1)
        self.assertEqual(result['counts']['responses_observed'], 1)
        self.assertNotIn('192.0.2.1', json.dumps(result))
        self.assertEqual(children[0].args[:5], ['/sbin/ping', '-n', '-i', '0.09', '--apple-print-req'])
        self.assertEqual(result['requested_interval_s'], 0.09)

    def test_main_exclusive_private_output_and_no_raw_data(self):
        with tempfile.TemporaryDirectory() as temp:
            path = os.path.join(temp, 'router.json')
            clock = {'offset_seconds': 0, 'uncertainty_seconds': 0}
            measurement = {'end_reason': 0, 'records': [], 'counts': {}}
            with mock.patch.object(p, 'system_uptime_calibration', return_value=clock), \
                 mock.patch.object(p, 'discover_router', return_value='192.0.2.1'), \
                 mock.patch.object(p, 'collect', return_value=measurement):
                self.assertEqual(p.main(['--seconds', '1', '--output', path]), 0)
                with open(path) as written:
                    content = written.read()
                self.assertNotIn('192.0.2.1', content)
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
                with mock.patch('sys.stderr'):
                    self.assertEqual(p.main(['--seconds', '1', '--output', path]), 1)
                with open(path) as written:
                    self.assertEqual(written.read(), content)

    def test_main_signal_sets_stop_flag_and_restores_handlers(self):
        with tempfile.TemporaryDirectory() as temp:
            handlers = {}
            restored = []
            def signal_handler(sig, handler):
                if callable(handler): handlers[sig] = handler
                else: restored.append(sig)
                return 0
            def fake_collect(router, seconds, clock, stop):
                self.assertFalse(stop())
                handlers[p.signal.SIGTERM](p.signal.SIGTERM, None)
                self.assertTrue(stop())
                return {'end_reason': 1}
            with mock.patch.object(p, 'system_uptime_calibration', return_value={'offset_seconds': 0}), \
                 mock.patch.object(p, 'discover_router', return_value='192.0.2.1'), \
                 mock.patch.object(p, 'collect', side_effect=fake_collect), \
                 mock.patch.object(p.signal, 'signal', side_effect=signal_handler):
                result = p.main(['--seconds', '1', '--output', os.path.join(temp, 'stop.json')])
            self.assertEqual(result, 1)
            self.assertEqual(set(restored), {p.signal.SIGINT, p.signal.SIGTERM, p.signal.SIGHUP})

    def test_unresponsive_child_escalates_only_to_owned_kill(self):
        children = []
        class Child:
            def __init__(self, *args, **kwargs): children.append(self); self.killed = False
            def poll(self): return None
            def terminate(self): pass
            def wait(self, timeout):
                if not self.killed: raise subprocess.TimeoutExpired('ping', timeout)
                return -9
            def kill(self): self.killed = True
        result = p.collect('192.0.2.1', 1, {'offset_seconds': 0, 'uncertainty_seconds': 0}, lambda: True, Child)
        self.assertTrue(children[0].killed)
        self.assertEqual(result['end_reason'], 1)

    def test_early_utility_exit_not_success(self):
        class Child:
            def __init__(self, *args, **kwargs): pass
            def poll(self): return 1
        result = p.collect('192.0.2.1', 1, {'offset_seconds': 0, 'uncertainty_seconds': 0}, lambda: False, Child)
        self.assertEqual(result['end_reason'], 2)
        self.assertEqual(result['counts']['responses_observed'], 0)


if __name__ == '__main__': unittest.main()
