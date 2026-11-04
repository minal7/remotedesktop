import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import subprocess

import run_cellular_attempt as runner


class CellularAttemptTests(unittest.TestCase):
    def test_config_accepts_only_fixed_ipad_and_uuid(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'private.json'
            data = {'device_id': runner.guard.IPAD_ID, 'host_id': 'c4e48f89-5be4-487d-acbb-640715d8bbca'}
            path.write_text(json.dumps(data))
            self.assertEqual(runner.private_config(path)[0], runner.guard.IPAD_ID)
            data['device_id'] = 'other'; path.write_text(json.dumps(data))
            with self.assertRaises(ValueError): runner.private_config(path)
            data['device_id'] = runner.guard.IPAD_ID; data['host_id'] = 'invalid'; path.write_text(json.dumps(data))
            with self.assertRaises(ValueError): runner.private_config(path)

    def test_client_environment_pins_all_experiments_for_each_mode(self):
        for mode in ('baseline', 'mapped', 'wifi'):
            with self.subTest(mode=mode):
                env = runner.client_environment(mode)
                self.assertEqual(env['LATENCY_LAB'], '1')
                self.assertEqual(env['CONNECTIVITY_DIAGNOSTICS'], '1')
                self.assertEqual(env['LATENCY_LAB_F1'], '1' if mode == 'wifi' else '0')
                self.assertEqual(env['LATENCY_LAB_F1_MAX_MS'], '10' if mode == 'wifi' else '0')
                for key in ('LATENCY_LAB_F2', 'LATENCY_LAB_F3', 'LATENCY_LAB_F4'):
                    self.assertEqual(env[key], '0')

    def test_new_attempt_selected_and_multiple_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            old = path / 'connectivity-old.jsonl'; old.write_text('{}\n')
            current = path / 'connectivity-new.jsonl'
            current.write_text(json.dumps({'type': 'connectivity', 'event': 'attempt_start', 'attempt': 'opaque', 'time': 1}) + '\n')
            self.assertEqual(runner.current_connectivity(path, {old.name}), {})
            (path / 'connectivity-another.jsonl').write_text('{}\n')
            with self.assertRaises(ValueError): runner.current_connectivity(path, {old.name})

    def test_invalid_or_truncated_trace_never_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'trace'
            path.write_text('{"type":"connectivity"}')
            with self.assertRaises(ValueError): runner.read_rows(path)
            path.write_text('{"type":"truncated"}\n')
            with self.assertRaises(ValueError): runner.read_rows(path)

    def test_watchdog_stops_owned_child_if_lease_revoked(self):
        attempt = runner.Attempt('ipad', 9003)
        child = Mock(returncode=None)
        child.poll.side_effect = [None, None, None]
        with patch.object(attempt, 'check', side_effect=[None, None, ValueError('stop')]), \
             patch.object(runner.subprocess, 'Popen', return_value=child), \
             patch.object(runner.time, 'sleep'):
            with self.assertRaises(ValueError): attempt.command(['fake'])
        child.terminate.assert_called_once()
        child.wait.assert_called_once()

    def test_spawn_does_not_persist_console_or_raw_output(self):
        attempt = runner.Attempt('ipad', 9003)
        child = Mock(returncode=0); child.poll.return_value = 0
        with patch.object(attempt, 'check'), patch.object(runner.subprocess, 'Popen', return_value=child) as spawn:
            attempt.command(['fake'])
        self.assertEqual(spawn.call_args.kwargs['stdout'], subprocess.DEVNULL)
        self.assertEqual(spawn.call_args.kwargs['stderr'], subprocess.DEVNULL)

    def test_cleanup_uses_pid_from_exact_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            attempt = runner.Attempt('ipad', 9003)
            attempt.launch_json = Path(folder) / 'launch.json'
            attempt.launch_json.write_text(json.dumps({'result': {'process': {'processIdentifier': 777}}}))
            attempt.client = Mock()
            attempt.client.poll.side_effect = [None, 0]
            attempt.client.wait.side_effect = subprocess.TimeoutExpired('client', 3)
            with patch.object(runner.guard, 'read_coordination_log'), \
                 patch.object(runner.subprocess, 'run', return_value=Mock(returncode=0)) as terminate:
                attempt.cleanup()
            self.assertEqual(terminate.call_args.args[0][-2:], ['--pid', '777'])

    def test_baseline_reports_failure_as_partial_and_cleans_up(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            marker = root / 'marker'; marker.touch(); marker.chmod(0o700)
            args = SimpleNamespace(config=root / 'config', marker=marker,
                client_app=root / 'app', timeout=2, mode='baseline', output=root / 'output')
            process = Mock(); process.poll.return_value = None
            def snapshot(attempt, destination):
                destination.mkdir(parents=True, exist_ok=True)
                if destination.name == 'snapshot':
                    records = [dict(type='connectivity', event='attempt_start', attempt='x', time=1),
                               dict(type='connectivity', event='failure', attempt='x', time=2, stage='ice_checking')]
                    (destination / 'connectivity-new.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in records))
            with patch.object(runner, 'private_config', return_value=('ipad', 'private')), \
                 patch.object(runner.guard, 'require_device_window', return_value=9003), \
                 patch.object(runner.guard, 'require_selected_ipad'), \
                 patch.object(runner.Attempt, 'install'), \
                 patch.object(runner.Attempt, 'snapshot', autospec=True, side_effect=snapshot), \
                 patch.object(runner.Attempt, 'spawn', return_value=process) as spawn, \
                 patch.object(runner.Attempt, 'cleanup') as cleanup:
                result = runner.run(args)
            self.assertEqual(result, {'status': 'partial', 'diagnostics': {'failure_stage': 'ice_checking'}, 'measurement': None})
            cleanup.assert_called_once()
            spawn.assert_called_once()
            self.assertEqual(spawn.call_args.args[0][:4], ['xcrun', 'devicectl', 'device', 'process'])
            self.assertNotIn('LocalUnixClock', str(spawn.call_args))
            command = spawn.call_args.args[0]
            launch_env = json.loads(command[command.index('--environment-variables') + 1])
            self.assertEqual(launch_env, runner.client_environment('baseline'))

    def test_wifi_returns_first_video_and_pair_without_clock(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            marker = root / 'marker'; marker.touch(); marker.chmod(0o700)
            args = SimpleNamespace(config=root / 'config', marker=marker,
                client_app=root / 'app', timeout=2, mode='wifi', output=root / 'output')
            process = Mock(); process.poll.return_value = None
            events = [dict(type='connectivity', event='attempt_start', attempt='x', time=1),
                      dict(type='connectivity', event='first_presented', attempt='x', time=2),
                      dict(type='connectivity', event='selected_pair', attempt='x', time=2,
                           localType='host', localFamily='v4', remoteType='host', remoteFamily='v4', protocol='udp')]
            def snapshot(attempt, destination):
                destination.mkdir(parents=True, exist_ok=True)
                if destination.name == 'snapshot':
                    (destination / 'connectivity-new.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in events))
            with patch.object(runner, 'private_config', return_value=('ipad', 'private')), \
                 patch.object(runner.guard, 'require_device_window', return_value=9003), \
                 patch.object(runner.guard, 'require_selected_ipad'), \
                 patch.object(runner.Attempt, 'install'), \
                 patch.object(runner.Attempt, 'snapshot', autospec=True, side_effect=snapshot), \
                 patch.object(runner.Attempt, 'spawn', return_value=process), \
                 patch.object(runner.Attempt, 'cleanup'), \
                 patch.object(runner, 'recent_client') as clock:
                result = runner.run(args)
            self.assertEqual(result['diagnostics']['time_to_video_ms'], 1000)
            self.assertEqual(result['diagnostics']['selected_pair']['remoteType'], 'host')
            self.assertIsNone(result['measurement'])
            clock.assert_not_called()

    def test_mapped_attempt_starts_marker_only_after_fresh_protocol_clock(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            marker = root / 'marker'; marker.touch(); marker.chmod(0o700)
            args = SimpleNamespace(config=root / 'config', marker=marker, client_app=root / 'app',
                                   timeout=2, mode='mapped', output=root / 'output')
            client = Mock(); client.poll.return_value = None
            marker_process = Mock(returncode=0); marker_process.poll.return_value = 0
            clock_trace = root / 'fresh-client.jsonl'
            def snapshot(attempt, destination):
                destination.mkdir(parents=True, exist_ok=True)
            with patch.object(runner, 'private_config', return_value=('ipad', 'private')), \
                 patch.object(runner.guard, 'require_device_window', return_value=9003), \
                 patch.object(runner.guard, 'require_selected_ipad'), \
                 patch.object(runner.Attempt, 'install'), \
                 patch.object(runner.Attempt, 'snapshot', autospec=True, side_effect=snapshot), \
                 patch.object(runner.Attempt, 'spawn', side_effect=[client, marker_process]) as spawn, \
                 patch.object(runner.Attempt, 'cleanup'), \
                 patch.object(runner, 'current_connectivity', return_value={'time_to_video_ms': 1}), \
                 patch.object(runner, 'recent_client', return_value=clock_trace) as fresh_clock, \
                 patch.object(runner.time, 'sleep'):
                runner.run(args)
            fresh_clock.assert_called_once()
            self.assertEqual(spawn.call_count, 2)
            self.assertEqual(spawn.call_args_list[0].args[0][0], 'xcrun')
            self.assertEqual(spawn.call_args_list[1].args[0], [str(marker)])
            command = spawn.call_args_list[0].args[0]
            launch_env = json.loads(command[command.index('--environment-variables') + 1])
            self.assertEqual(launch_env, runner.client_environment('mapped'))

    def test_already_exited_console_terminates_exact_owned_pid(self):
        with tempfile.TemporaryDirectory() as folder:
            attempt = runner.Attempt('ipad', 9003)
            attempt.launch_json = Path(folder) / 'launch.json'
            attempt.launch_json.write_text(json.dumps({'result': {'process': {'processIdentifier': 777}}}))
            attempt.client = Mock(); attempt.client.poll.return_value = 0
            with patch.object(runner.guard, 'read_coordination_log'), \
                 patch.object(runner.subprocess, 'run', return_value=Mock(returncode=0)) as terminate:
                attempt.cleanup()
            terminate.assert_called_once()
            self.assertEqual(terminate.call_args.args[0][-2:], ['--pid', '777'])
            attempt.client.send_signal.assert_not_called()

    def test_evidence_whitelist_and_stale_exclusion(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); snapshot = root / 'snapshot'; snapshot.mkdir()
            out = root / 'out'; out.mkdir()
            token = 'c4e48f89-5be4-487d-acbb-640715d8bbca'
            event = {'type': 'connectivity', 'event': 'attempt_start', 'attempt': token, 'time': 1,
                     'private': 'NEVER_COPY'}
            (snapshot / 'connectivity-new.jsonl').write_text(json.dumps(event) + '\n')
            (snapshot / 'connectivity-old.jsonl').write_text('NEVER_COPY\n')
            trace = [{'type': 'clock', 'time': 1, 'offset': .1, 'samples': 50, 'secret': 'NEVER_COPY'},
                     {'type': 'stats', 'secret': 'NEVER_COPY'},
                     {'type': 'marker', 'marker_id': 3, 'presentedTime': 2, 'secret': 'NEVER_COPY'}]
            (snapshot / 'client-new.jsonl').write_text(''.join(json.dumps(x) + '\n' for x in trace))
            (snapshot / 'client-old.jsonl').write_text('NEVER_COPY\n')
            runner.preserve_snapshot(snapshot, {'connectivity-old.jsonl'}, {'client-old.jsonl'}, out)
            saved = ''.join(p.read_text() for p in out.iterdir())
            self.assertNotIn('NEVER_COPY', saved)
            self.assertNotIn('stats', saved)
            self.assertIn('presentedTime', saved)
            self.assertIn('attempt_start', saved)
            (snapshot / 'client-another.jsonl').write_text(json.dumps(trace[0]) + '\n')
            (out / 'client-timing.jsonl').unlink()
            runner.preserve_snapshot(snapshot, {'connectivity-old.jsonl'}, {'client-old.jsonl'}, out)
            self.assertFalse((out / 'client-timing.jsonl').exists())

    def test_existing_output_directory_is_refused(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / 'binary'; binary.touch(); binary.chmod(0o700)
            args = SimpleNamespace(config=root / 'config', marker=binary, output=root)
            with patch.object(runner, 'private_config', return_value=('ipad', 'private')), \
                 patch.object(runner.guard, 'require_device_window', return_value=9003), \
                 patch.object(runner.guard, 'require_selected_ipad'):
                with self.assertRaises(FileExistsError): runner.run(args)

    def test_marker_source_omits_unrelated_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); output = root / 'out'; output.mkdir()
            source = root / 'source.json'
            source.write_text(json.dumps({'duration_s': 60, 'initial_marker_observed_before_timing': True,
                'secret': 'NEVER_COPY', 'markers': [{'marker_id': 1, 'host_display_s': 2, 'secret': 'NEVER_COPY'}]}))
            runner.preserve_marker(source, output)
            result = json.loads((output / 'marker.json').read_text())
            self.assertEqual(result['markers'], [{'marker_id': 1, 'host_display_s': 2}])
            self.assertNotIn('NEVER_COPY', json.dumps(result))
