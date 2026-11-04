"""Unit checks for isolated host validation and exact-child shutdown."""
import json
from pathlib import Path
import plistlib
import signal
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import run_debug_host as runner


class DebugHostLauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.build = self.root / 'build' / 'latency'
        self.app = self.build / 'DebugHost.app'
        contents = self.app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': runner.BUNDLE_ID, 'CFBundleExecutable': 'RemoteDesktopHost'}))
        (contents / 'MacOS' / 'RemoteDesktopHost').touch()
        self.args = SimpleNamespace(host_app=self.app, host_id='8f8f6c31-7bf6-4c51-ae04-5b94b01a59a2',
            qa_flag=self.root / 'qa', output=self.root / 'output', timeout=1)
        self.build_patch = patch.object(runner, 'BUILD_ROOT', self.build)
        self.build_patch.start()
        self.addCleanup(self.build_patch.stop)

    def test_validates_bundle_path_identity_and_uuid(self):
        app, executable = runner.validate_bundle(self.app)
        self.assertEqual(app, self.app.resolve())
        self.assertEqual(executable.name, 'RemoteDesktopHost')
        self.assertEqual(runner.normalized_host_id(self.args.host_id), self.args.host_id.upper())
        with self.assertRaises(ValueError): runner.normalized_host_id('not-a-uuid')
        with patch.object(runner, 'BUILD_ROOT', self.root / 'elsewhere'):
            with self.assertRaises(ValueError): runner.validate_bundle(self.app)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.threadmark.remotedesktop.host', 'CFBundleExecutable': 'RemoteDesktopHost'}))
        with self.assertRaises(ValueError): runner.validate_bundle(self.app)

    def test_requires_development_icloud_entitlements(self):
        def result(environment):
            return SimpleNamespace(stdout=plistlib.dumps({
                'com.apple.developer.icloud-container-environment': environment,
                'com.apple.developer.icloud-container-identifiers': ['iCloud.com.threadmark.remotedesktop']}))
        with patch.object(runner.subprocess, 'run', return_value=result('Development')):
            runner.validate_entitlements(self.app)
        with patch.object(runner.subprocess, 'run', return_value=result('Production')):
            with self.assertRaises(ValueError): runner.validate_entitlements(self.app)

    def test_qa_and_duplicate_host_fail_before_spawn(self):
        self.args.qa_flag.touch()
        with patch.object(runner.subprocess, 'Popen') as spawn:
            with self.assertRaises(ValueError): runner.guarded_run(self.args)
            spawn.assert_not_called()
        self.args.qa_flag.unlink()
        with patch.object(runner, 'validate_entitlements'), \
             patch.object(runner, 'running_pids_with_executable', return_value=[123]), \
             patch.object(runner.subprocess, 'Popen') as spawn:
            with self.assertRaises(ValueError): runner.guarded_run(self.args)
            spawn.assert_not_called()

    def test_signal_during_spawn_is_deferred_and_stops_only_owned_child(self):
        child = Mock(pid=12345, returncode=0)
        child.poll.side_effect = [None, None, 0]
        child.wait.return_value = 0
        handlers = {}
        def install(sig, handler):
            old = handlers.get(sig, signal.SIG_DFL)
            handlers[sig] = handler
            return old
        def spawn(command, **kwargs):
            self.assertEqual(command, [str((self.app / 'Contents/MacOS/RemoteDesktopHost').resolve()), '--debug-latency-host'])
            self.assertIs(kwargs['preexec_fn'], runner.ignore_sigint)
            self.assertEqual(kwargs['env']['LATENCY_LAB'], '1')
            self.assertEqual(kwargs['env']['LATENCY_LAB_F2'], '1')
            self.assertEqual(kwargs['env']['REMOTE_DESKTOP_LATENCY_HOST_ID'], self.args.host_id.upper())
            handlers[signal.SIGINT](signal.SIGINT, None)
            return child
        with patch.object(runner, 'validate_entitlements'), \
             patch.object(runner, 'running_pids_with_executable', return_value=[]), \
             patch.object(runner.signal, 'signal', side_effect=install), \
             patch.object(runner.subprocess, 'Popen', side_effect=spawn):
            self.assertEqual(runner.guarded_run(self.args), 128 + signal.SIGINT)
        child.terminate.assert_called_once_with()
        child.wait.assert_called_once_with(timeout=5.5)
        state = json.loads((self.args.output / 'state.json').read_text())
        self.assertEqual((state['status'], state['pid'], state['reason']), ('stopped', 12345, 'signal'))


if __name__ == '__main__':
    unittest.main()
