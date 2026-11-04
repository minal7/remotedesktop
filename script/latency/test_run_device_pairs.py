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
            client_app=root / 'lab.app')

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


if __name__ == '__main__':
    unittest.main()
