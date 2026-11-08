"""Source-level tests for device handoff and owned-process cleanup."""
import json
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import run_device_pairs as runner


class DevicePairSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        host = root / 'host' / 'Contents'
        host.mkdir(parents=True)
        (host / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.threadmark.remotedesktop.host.debug'}))
        lease = root / 'lease.json'
        from datetime import datetime, timedelta
        now = datetime.now().astimezone().replace(second=0, microsecond=0)
        lease.write_text(json.dumps({'holder': 'B', 'purpose': 'F1', 'app_build': '9003',
                                     'started': now.strftime('%H:%M'),
                                     'expires': (now + timedelta(minutes=20)).strftime('%H:%M')}))
        log = root / 'log.md'
        log.write_text('test checkpoint\n')
        for name, value in (('ROOT', root), ('RELEASE_QA', (root / 'qa').resolve()),
                            ('LEASE', lease), ('COORDINATION_LOG', log),
                            ('IPAD_QUEUE', root / 'queue'), ('IPAD_ID', 'device')):
            patcher = patch.object(runner, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.install = patch.object(runner, 'install_verified_lab_app', side_effect=self.fake_install)
        self.install_mock = self.install.start()
        self.addCleanup(self.install.stop)
        marker = root / 'marker'
        marker.touch()
        self.args = SimpleNamespace(
            not_before='2000-01-01T00:00:00Z', qa_flag=root / 'qa',
            host_app=host.parent, guarded=True, output=root / 'output',
            marker_binary=marker.resolve(), device='device', host_id='host', fix='F1',
            f1_max_ms=0, bundle_id=runner.CLIENT_BUNDLE, host_traces=root / 'traces',
            client_app=root / 'lab.app', fixture_photo=None, lab60=False)

    def fake_install(self, device, app):
        runner.require_selected_ipad(device)
        self.assertEqual(app, self.args.client_app)

    def test_lease_refuses_expired_wrong_holder_build_and_queue(self):
        from datetime import datetime, timedelta
        lease = json.loads(runner.LEASE.read_text())
        now = datetime.now().astimezone().replace(second=0, microsecond=0)
        self.assertEqual(runner.require_device_window(now), 9003)
        for key, value in [('holder', 'A'), ('app_build', '7'), ('purpose', '')]:
            bad = dict(lease, **{key: value})
            runner.LEASE.write_text(json.dumps(bad))
            with self.subTest(key=key), self.assertRaises(ValueError):
                runner.require_device_window(now)
        lease['expires'] = now.strftime('%H:%M')
        lease['started'] = (now - timedelta(minutes=20)).strftime('%H:%M')
        runner.LEASE.write_text(json.dumps(lease))
        with self.assertRaises(ValueError): runner.require_device_window(now)
        lease['started'] = now.strftime('%H:%M')
        lease['expires'] = (now + timedelta(minutes=20)).strftime('%H:%M')
        runner.LEASE.write_text(json.dumps(lease))
        runner.IPAD_QUEUE.write_text('A waiting\n')
        with self.assertRaisesRegex(ValueError, 'queued'): runner.require_device_window(now)

    def test_wrong_device_and_changed_lease_build_refused(self):
        with self.assertRaises(ValueError): runner.require_selected_ipad('other')
        with self.assertRaises(ValueError): runner.require_selected_ipad('device', 9004)

    def test_verify_installed_build_mismatch_refused(self):
        data = {'info': {'outcome': 'success'}, 'result': {'apps': [
            {'bundleIdentifier': runner.CLIENT_BUNDLE, 'bundleVersion': '7', 'version': '1.2.1'}]}}
        with self.assertRaises(ValueError): runner.verify_installed_lab(data, '1.2.1', '9003')

    def test_invalid_and_future_handoff_never_launch(self):
        with patch.object(runner.subprocess, 'Popen') as launch:
            for handoff in ('not-a-date', '2000-01-01T00:00:00', '2999-01-01T00:00:00Z'):
                with self.subTest(handoff=handoff):
                    self.args.not_before = handoff
                    with self.assertRaises(ValueError):
                        runner.run(self.args)
            launch.assert_not_called()
            self.assertFalse(self.args.output.exists())

    def test_active_qa_never_launches_or_creates_output(self):
        self.args.qa_flag.touch()
        with patch.object(runner.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(ValueError, 'Release QA'):
                runner.run(self.args)
            launch.assert_not_called()
        self.assertFalse(self.args.output.exists())

    def test_qa_interruption_uses_exact_launch_json_pid_after_console_timeout(self):
        marker = Mock()
        marker.poll.return_value = None
        attached = Mock()
        attached.poll.return_value = None
        attached.wait.side_effect = [subprocess.TimeoutExpired('devicectl', 2), 0]

        def popen(command, **kwargs):
            if command[0] == str(self.args.marker_binary):
                kwargs['stdout'].write('MARKER_READY yes\n')
                kwargs['stdout'].flush()
                return marker
            self.assertIn('--console', command)
            self.assertEqual(kwargs['stdout'], subprocess.DEVNULL)
            self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            self.assertFalse((self.args.output / 'launch.log').exists())
            self.assertIn('LatencyLabPairToken', command)
            index = command.index('--json-output')
            Path(command[index + 1]).write_text(json.dumps(
                {'result': {'process': {'processIdentifier': 4321}}}))
            self.args.qa_flag.touch()
            return attached

        with patch.object(runner.subprocess, 'Popen', side_effect=popen), \
             patch.object(runner.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as terminate, \
             patch.object(runner.signal, 'signal'):
            with self.assertRaisesRegex(ValueError, 'Release QA'):
                runner.run(self.args)
        self.install_mock.assert_called_once_with(self.args.device, self.args.client_app)
        attached.send_signal.assert_called_once_with(signal.SIGINT)
        command = terminate.call_args.args[0]
        self.assertEqual(command[-2:], ['--pid', '4321'])
        self.assertIn('terminate', command)
        marker.terminate.assert_called_once()

    def test_cleanup_failure_is_reported_when_no_pid_available(self):
        marker = Mock()
        marker.poll.return_value = None
        attached = Mock()
        attached.poll.return_value = None
        attached.wait.side_effect = [subprocess.TimeoutExpired('devicectl', 2), 0]

        def popen(command, **kwargs):
            if command[0] == str(self.args.marker_binary):
                kwargs['stdout'].write('MARKER_READY yes\n')
                kwargs['stdout'].flush()
                return marker
            self.args.qa_flag.touch()
            return attached

        with patch.object(runner.subprocess, 'Popen', side_effect=popen), \
             patch.object(runner.subprocess, 'run') as terminate, \
             patch.object(runner.signal, 'signal'):
            with self.assertRaisesRegex(RuntimeError, 'cleanup is required'):
                runner.run(self.args)
        self.install_mock.assert_called_once_with(self.args.device, self.args.client_app)
        terminate.assert_not_called()
        attached.kill.assert_called_once()

    def test_signal_during_console_spawn_retains_handle_for_cleanup(self):
        marker = Mock()
        marker.poll.return_value = None
        attached = Mock()
        attached.poll.side_effect = [None, 0]
        attached.wait.return_value = 0
        handlers = {}

        def install_handler(signum, handler):
            handlers[signum] = handler

        def popen(command, **kwargs):
            if command[0] == str(self.args.marker_binary):
                kwargs['stdout'].write('MARKER_READY yes\n')
                kwargs['stdout'].flush()
                return marker
            handlers[signal.SIGINT](signal.SIGINT, None)
            return attached

        with patch.object(runner.subprocess, 'Popen', side_effect=popen), \
             patch.object(runner.subprocess, 'run') as terminate, \
             patch.object(runner.signal, 'signal', side_effect=install_handler):
            with self.assertRaises(KeyboardInterrupt):
                runner.run(self.args)
        self.install_mock.assert_called_once_with(self.args.device, self.args.client_app)
        attached.send_signal.assert_called_once_with(signal.SIGINT)
        attached.wait.assert_called_once_with(timeout=2)
        terminate.assert_not_called()
        marker.terminate.assert_called_once()

    def exercise_completion(self, statuses, *, fail_export=False, trace_run="run-1", process_data=None, stop_timeout=False, stop_failure=False, launch_pid=None):
        import itertools
        marker, attached = Mock(), Mock()
        state = {'marker_done': False, 'console_done': False, 'token': None, 'status': 0, 'copies': 0, 'process_checks': 0, 'inventories': 0, 'waits': 0, 'terminations': 0}
        marker.poll.side_effect = lambda: 0 if state['marker_done'] else None
        marker.returncode = 0
        attached.poll.side_effect = lambda: 0 if state['console_done'] else None
        def marker_signal(sig):
            self.assertEqual(sig, signal.SIGUSR1)
            self.assertEqual(state['copies'], 0, 'Markers must be written before full device export')
            (self.args.output / 'markers.json').write_text(json.dumps({'markers': [{'marker_id': 1, 'host_display_s': 10}]}))
            state['marker_done'] = True
        marker.send_signal.side_effect = marker_signal
        def wait_console(timeout=None):
            state['waits'] += 1
            if stop_timeout and state['waits'] == 1:
                raise subprocess.TimeoutExpired('devicectl', timeout)
            state['console_done'] = True
            return 0
        attached.wait.side_effect = wait_console
        def popen(command, **kwargs):
            if command[0] == str(self.args.marker_binary):
                kwargs['stdout'].write('MARKER_READY yes\n'); kwargs['stdout'].flush()
                return marker
            state['token'] = command[command.index('LatencyLabPairToken') + 1]
            if launch_pid is not None:
                Path(command[command.index('--json-output') + 1]).write_text(json.dumps(
                    {'result': {'process': {'processIdentifier': launch_pid}}}))
            return attached
        def command(command, **kwargs):
            if 'process' in command and 'terminate' in command:
                self.assertEqual(command[command.index('--pid') + 1], '4321')
                self.assertTrue(state['marker_done'])
                state['terminations'] += 1
                return SimpleNamespace(returncode=1 if stop_failure else 0)
            if 'info' in command and 'processes' in command:
                self.assertTrue(state['marker_done'], 'Marker must flush before stopping and verifying the client')
                self.assertTrue(state['console_done'] or state['terminations'] == 1,
                                'Stop must precede verification')
                state['process_checks'] += 1
                path = Path(command[command.index('--json-output') + 1])
                listing = process_data if process_data is not None else {
                    'info': {'outcome': 'success'}, 'result': {'runningProcesses': [{'processIdentifier': 17}]}}
                path.write_text(json.dumps(listing))
                return SimpleNamespace(returncode=0)
            if 'info' in command and 'files' in command:
                self.assertEqual(state['process_checks'], 1, 'Verify the stopped client before inventory')
                state['inventories'] += 1
                self.assertIn('--no-recurse', command)
                self.assertEqual(command[command.index('--subdirectory') + 1], runner.TRACE_DIRECTORY)
                self.assertEqual(kwargs.get('stdout'), subprocess.DEVNULL)
                path = Path(command[command.index('--json-output') + 1])
                path.write_text(json.dumps({'info': {'outcome': 'success'}, 'result': {'files': [{
                    'relativePath': 'client-00000000-0000-0000-0000-000000000001.jsonl',
                    'metadata': {'size': 5000, 'lastModDate': '2026-11-04T15:00:00Z'},
                    'resources': {'isDirectory': False, 'isSymbolicLink': False}}]}}))
                return SimpleNamespace(returncode=0)
            if 'copy' not in command:
                return SimpleNamespace(returncode=0)
            source = command[command.index('--source') + 1]
            destination = Path(command[command.index('--destination') + 1])
            if source.endswith('pair-status.json'):
                index = min(state['status'], len(statuses) - 1)
                status = dict(statuses[index]); state['status'] += 1
                status.setdefault('launchToken', state['token'])
                status.setdefault('processIdentifier', 4321)
                destination.write_text(json.dumps(status))
            else:
                self.assertEqual(source, runner.TRACE_DIRECTORY + '/client-00000000-0000-0000-0000-000000000001.jsonl')
                self.assertEqual(kwargs.get('stdout'), subprocess.DEVNULL)
                state['copies'] += 1
                if fail_export: return SimpleNamespace(returncode=1)
                rows = []
                for i in range(1, 9):
                    start = 100 + (i - 1) * 40
                    event = {'type': 'lab_pair', 'run': trace_run, 'fix': 'F1', 'trial': i,
                             'pair': (i + 1) // 2, 'arm': 'A' if i % 2 else 'B', 'peerNonce': None,
                             'settings': {'f1Playout': i % 2 == 0, 'f1MaximumDelayMs': 0,
                                          'f2Encoder': False, 'f3Sender': False, 'f4Renderer': False}}
                    rows.extend([{**event, 'stage': 'requested', 'time': start - 6},
                                 {**event, 'stage': 'begin', 'time': start},
                                 {**event, 'stage': 'end', 'time': start + 30}])
                rows.append({**event, 'stage': 'complete', 'time': start + 30})
                destination.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            return SimpleNamespace(returncode=0)
        def summarize(markers, client, traces, output):
            self.assertEqual(json.loads(markers.read_text())['markers'][0]['host_display_s'], 10)
            self.assertTrue(client.is_file())
            from summarize_device_pairs import segments
            rows = list(map(json.loads, client.read_text().splitlines()))
            arms = [begin['arm'] for begin, _ in segments(rows)]
            self.assertEqual(arms, ['A', 'B'] * 4)
            return {'median_paired_B_minus_A': {}}
        clock = itertools.count(0, 11)
        with patch.object(runner.subprocess, 'Popen', side_effect=popen), \
             patch.object(runner.subprocess, 'run', side_effect=command), \
             patch.object(runner.signal, 'signal'), \
             patch.object(runner.time, 'monotonic', side_effect=lambda: next(clock)), \
             patch.object(runner.time, 'sleep'), \
             patch.object(runner, 'summarize', side_effect=summarize) as summarizer:
            try:
                result = runner.run(self.args)
                error = None
            except (ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
                result, error = None, exc
        return result, error, marker, attached, state, summarizer

    def test_completed_marker_survives_client_copy_failure_and_owned_cleanup(self):
        result, error, marker, attached, state, summary = self.exercise_completion(
            [{'stage': 'complete', 'run': 'run-1'}], fail_export=True)
        self.assertIsNone(result)
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(str(error), 'Private device export failed.')
        self.assertEqual(json.loads((self.args.output / 'markers.json').read_text())['markers'][0]['host_display_s'], 10)
        marker.send_signal.assert_called_once_with(signal.SIGUSR1)
        marker.terminate.assert_not_called()
        attached.send_signal.assert_called_once_with(signal.SIGINT)
        summary.assert_not_called()
        self.assertFalse((self.args.output / 'summary.json').exists())

    def test_completed_copy_produces_summary_after_marker_flush(self):
        result, error, marker, attached, state, summary = self.exercise_completion(
            [{'stage': 'complete', 'run': 'run-1'}])
        self.assertEqual(result, 0)
        self.assertIsNone(error)
        marker.send_signal.assert_called_once_with(signal.SIGUSR1)
        summary.assert_called_once()
        self.assertTrue((self.args.output / 'summary.json').exists())
        self.assertEqual((self.args.output / 'client.jsonl').stat().st_mode & 0o777, 0o600)

    def test_console_timeout_uses_only_owned_pid_then_verifies_before_export(self):
        result, error, marker, attached, state, summary = self.exercise_completion(
            [{'stage': 'complete', 'run': 'run-1'}], stop_timeout=True)
        self.assertEqual(result, 0)
        self.assertIsNone(error)
        self.assertEqual(state['terminations'], 1)
        self.assertEqual(state['process_checks'], 1)
        self.assertEqual(state['inventories'], 1)
        summary.assert_called_once()

    def test_stop_failure_blocks_inventory_and_retains_marker(self):
        result, error, marker, attached, state, summary = self.exercise_completion(
            [{'stage': 'complete', 'run': 'run-1'}], stop_timeout=True, stop_failure=True)
        self.assertIsNone(result)
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(state['terminations'], 1)
        self.assertEqual(state['process_checks'], 0)
        self.assertEqual(state['inventories'], 0)
        self.assertEqual(state['copies'], 0)
        self.assertTrue((self.args.output / 'markers.json').is_file())
        summary.assert_not_called()

    def test_conflicting_launched_pid_blocks_export(self):
        result, error, marker, attached, state, summary = self.exercise_completion(
            [{'stage': 'complete', 'run': 'run-1'}], launch_pid=4322)
        self.assertIsNone(result)
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(state['inventories'], 0)
        self.assertEqual(state['copies'], 0)
        self.assertTrue((self.args.output / 'markers.json').is_file())
        summary.assert_not_called()

    def test_client_still_running_blocks_inventory_and_preserves_marker(self):
        live = {'info': {'outcome': 'success'}, 'result': {'runningProcesses': [{'processIdentifier': 4321}]}}
        result, error, marker, attached, state, summary = self.exercise_completion(
            [{'stage': 'complete', 'run': 'run-1'}], process_data=live)
        self.assertIsNone(result)
        self.assertIsInstance(error, RuntimeError)
        self.assertTrue((self.args.output / 'markers.json').is_file())
        self.assertEqual(state['inventories'], 0)
        self.assertEqual(state['copies'], 0)
        summary.assert_not_called()
        self.assertFalse((self.args.output / 'summary.json').exists())

    def test_unverifiable_process_list_blocks_export(self):
        for data in ({}, {'error': {}, 'result': {'runningProcesses': []}},
                     {'info': {'outcome': 'failure'}, 'result': {'runningProcesses': []}},
                     {'info': {'outcome': 'success'}, 'result': {'runningProcesses': [{}]}},
                     {'info': {'outcome': 'success'}, 'result': {'runningProcesses': 'invalid'}}):
            with self.subTest(data=data), self.assertRaises((ValueError, RuntimeError)):
                runner.verify_owned_pid_absent(data, 4321)
        self.assertIsNone(runner.verify_owned_pid_absent(
            {'info': {'outcome': 'success'}, 'result': {'runningProcesses': [{'processIdentifier': 17}]}}, 4321))
        self.assertIsNone(runner.verify_owned_pid_absent(
            {'result': {'runningProcesses': [{'processIdentifier': 17}]}}, 4321))

    def test_eight_window_trace_with_different_run_is_rejected_and_marker_retained(self):
        result, error, marker, attached, state, summary = self.exercise_completion(
            [{'stage': 'complete', 'run': 'run-1'}], trace_run='different-run')
        self.assertIsNone(result)
        self.assertIsInstance(error, ValueError)
        marker.send_signal.assert_called_once_with(signal.SIGUSR1)
        self.assertTrue((self.args.output / 'markers.json').is_file())
        self.assertFalse((self.args.output / 'client.jsonl').exists())
        summary.assert_not_called()

    def test_stale_completion_and_aborted_status_do_not_finalize_marker(self):
        result, error, marker, attached, state, summary = self.exercise_completion([
            {'stage': 'complete', 'run': 'other', 'launchToken': 'stale'},
            {'stage': 'aborted', 'run': 'run-1'}])
        self.assertIsNone(result)
        self.assertIsInstance(error, RuntimeError)
        marker.send_signal.assert_not_called()
        marker.terminate.assert_called_once()
        summary.assert_not_called()
        self.assertFalse((self.args.output / 'summary.json').exists())

    def test_partial_status_then_abort_never_finalizes_or_summarizes(self):
        result, error, marker, attached, state, summary = self.exercise_completion([
            {'stage': 'begin', 'run': 'run-1'}, {'stage': 'aborted', 'run': 'run-1'}])
        self.assertIsNone(result)
        self.assertIsInstance(error, RuntimeError)
        marker.send_signal.assert_not_called()
        marker.terminate.assert_called_once()
        summary.assert_not_called()
        self.assertFalse((self.args.output / 'summary.json').exists())

    def test_complete_without_run_identity_does_not_finalize_marker(self):
        result, error, marker, attached, state, summary = self.exercise_completion([{'stage': 'complete'}])
        self.assertIsNone(result)
        self.assertIsInstance(error, ValueError)
        marker.send_signal.assert_not_called()
        marker.terminate.assert_called_once()
        self.assertEqual(state['copies'], 0)
        summary.assert_not_called()

    def test_inventory_selects_newest_and_rejects_ambiguous_or_unsafe_entries(self):
        import copy
        def entry(suffix, date='2026-11-04T15:00:00Z', size=123):
            return {'relativePath': f'client-00000000-0000-0000-0000-{suffix:012d}.jsonl',
                    'metadata': {'size': size, 'lastModDate': date}, 'resources': {'isDirectory': False, 'isSymbolicLink': False}}
        old, newest = entry(1), entry(2, '2026-11-04T15:00:01Z')
        inv = {'info': {'outcome': 'success'}, 'result': {'files': [old, newest]}}
        self.assertEqual(runner.newest_client_trace(inv), newest['relativePath'])
        variants = [None, {}, {'info': [], 'result': {}},
                    {'info': {'outcome': 'failure'}, 'result': {'files': []}},
                    {'info': {'outcome': 'success'}, 'result': {'files': 'bad'}},
                    {'info': {'outcome': 'success'}, 'result': {'files': [old, entry(3)]}},
                    {'info': {'outcome': 'success'}, 'result': {'files': [old, old]}},
                    {'info': {'outcome': 'success'}, 'result': {'files': [entry(4, size=8_000_001)]}},
                    {'info': {'outcome': 'success'}, 'result': {'files': [entry(4, date='2026-11-04T15:00:00')]}},
                    {'info': {'outcome': 'success'}, 'result': {'files': [{**old, 'relativePath': '../' + old['relativePath']}]}},
                    {'info': {'outcome': 'success'}, 'result': {'files': [{**old, 'relativePath': 'client-evil.jsonl'}]}},
                    {'info': {'outcome': 'success'}, 'result': {'files': [{**old, 'resources': {'isDirectory': True, 'isSymbolicLink': False}}]}},
                    {'info': {'outcome': 'success'}, 'result': {'files': [{**old, 'resources': {'isDirectory': False, 'isSymbolicLink': True}}]}}]
        for inv in variants:
            with self.subTest(inventory=type(inv).__name__), self.assertRaises(ValueError):
                runner.newest_client_trace(copy.deepcopy(inv))

    def test_trace_requires_matching_run_and_all_eight_windows(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'client.jsonl'
            path.write_text(json.dumps({'type': 'lab_pair', 'stage': 'complete', 'run': 'wrong'}) + '\n')
            with self.assertRaises(ValueError): runner.verify_client_trace(path, 'expected', 'F1')
            path.write_text('{bad json}\n')
            with self.assertRaises(ValueError): runner.verify_client_trace(path, 'expected', 'F1')

class StageZeroRunnerTests(unittest.TestCase):
    def test_r60_requires_explicit_baseline_and_keeps_lab_flags(self):
        for f1 in ('on', 'off'):
            for delay in (10, 20):
                args = SimpleNamespace(fix='R60', r60_f1=f1, f1_max_ms=delay, lab60=True)
                env = runner.client_experiment_environment(args)
                self.assertEqual(env['LATENCY_LAB'], '1')
                self.assertEqual(env['LATENCY_LAB_R60_F1'], '1' if f1 == 'on' else '0')
                self.assertEqual(env['LATENCY_LAB_F1_MAX_MS'], str(delay))
                self.assertNotIn('LATENCY_RENDER_HINT_60', env)
        for f1, delay in [(None, 10), ('on', None), ('off', 0), ('invalid', 10)]:
            args = SimpleNamespace(fix='R60', r60_f1=f1, f1_max_ms=delay, lab60=False)
            with self.subTest(f1=f1, delay=delay), self.assertRaises(ValueError):
                runner.client_experiment_environment(args)
        args = SimpleNamespace(fix='F1', r60_f1='on', f1_max_ms=10, lab60=False)
        with self.assertRaises(ValueError): runner.client_experiment_environment(args)

    def test_fixture_requires_existing_readable_photo_and_sets_only_fixture_flags(self):
        with tempfile.TemporaryDirectory() as folder:
            photo=Path(folder)/'licensed.jpg'
            with self.assertRaises(FileNotFoundError): runner.fixture_environment(photo)
            photo.write_bytes(b'fixture')
            env=runner.fixture_environment(photo)
            self.assertEqual(env['LATENCY_OPTICAL'],'1')
            self.assertEqual(env['LATENCY_LARGE_CHANGE_PHOTO'],str(photo.resolve()))

    def test_lab60_sets_explicit_fps_and_baseline_qos(self):
        args=SimpleNamespace(f1_max_ms=10, lab60=True)
        env=runner.client_experiment_environment(args)
        self.assertEqual(env['LATENCY_LAB_F1_MAX_MS'],'10')
        self.assertEqual(env['LATENCY_QOS_FPS'],'60')
        self.assertEqual(env['LATENCY_QOS_PREFERENCE'],'fluency')
        args.lab60=False
        self.assertNotIn('LATENCY_QOS_FPS',runner.client_experiment_environment(args))

if __name__ == '__main__':
    unittest.main()
