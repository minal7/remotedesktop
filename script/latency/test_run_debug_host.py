"""Unit checks for isolated host validation and exact-child shutdown."""
import json
from pathlib import Path
import plistlib
import signal
import tempfile
import unittest
import run_device_pairs as device_runner
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
            qa_flag=self.root / 'qa', output=self.root / 'output', timeout=1, resources_only=False)
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
            self.assertNotIn('LATENCY_LAB_RESOURCES_ONLY', kwargs['env'])
            self.assertEqual(kwargs['env']['REMOTE_DESKTOP_LATENCY_HOST_ID'], self.args.host_id.upper())
            handlers[signal.SIGINT](signal.SIGINT, None)
            return child
        with patch.object(runner, 'validate_entitlements'), \
             patch.object(runner, 'running_pids_with_executable', return_value=[]), \
             patch.object(runner.signal, 'signal', side_effect=install), \
             patch.object(runner.subprocess, 'Popen', side_effect=spawn):
            self.assertEqual(runner.guarded_run(self.args), 128 + signal.SIGINT)
        child.terminate.assert_called_once_with()
        child.wait.assert_called_once_with(timeout=30)
        state = json.loads((self.args.output / 'state.json').read_text())
        self.assertEqual((state['status'], state['pid'], state['reason']), ('stopped', 12345, 'signal'))

    def test_resource_opt_in_is_explicit_and_keeps_sole_selector(self):
        self.args.resources_only = True
        def spawn(command, **kwargs):
            self.assertEqual(command[-1:], ['--debug-latency-host'])
            self.assertEqual(len(command), 2)
            self.assertEqual(kwargs['env']['LATENCY_LAB_RESOURCES_ONLY'], '1')
            raise RuntimeError('stop before launch')
        with patch.object(runner, 'validate_entitlements'), \
             patch.object(runner, 'running_pids_with_executable', return_value=[]), \
             patch.object(runner.subprocess, 'Popen', side_effect=spawn):
            with self.assertRaisesRegex(RuntimeError, 'stop before launch'):
                runner.guarded_run(self.args)


class DeviceWindowSafetyTests(unittest.TestCase):
    def test_handoff_required_and_qa_blocks_even_with_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            handoff, qa = root / 'handoff', root / 'qa'
            with patch.object(device_runner, 'IPAD_HANDOFF', handoff), patch.object(device_runner, 'RELEASE_QA', qa):
                with self.assertRaisesRegex(ValueError, 'not been handed'):
                    device_runner.require_device_window()
                handoff.touch()
                device_runner.require_device_window()
                qa.touch()
                with self.assertRaisesRegex(ValueError, 'Release QA'):
                    device_runner.require_device_window()
                qa.unlink(); handoff.unlink()
                with self.assertRaisesRegex(ValueError, 'not been handed'):
                    device_runner.require_device_window()

    def test_installed_client_identity_and_version_fail_closed(self):
        device_runner.require_lab_bundle(device_runner.CLIENT_BUNDLE)
        with self.assertRaises(ValueError):
            device_runner.require_lab_bundle('other.bundle')
        row = {'bundleIdentifier': device_runner.CLIENT_BUNDLE, 'bundleVersion': '9', 'version': '1.2.1'}
        result = {'info': {'outcome': 'success'}, 'result': {'apps': [row]}}
        device_runner.verify_installed_lab(result, '1.2.1', '9')
        device_runner.verify_installed_lab({'info': {'outcome': 'success'},
            'result': {'apps': [{'bundleIdentifier': 'unrelated'}, row]}}, '1.2.1', '9')
        for bad in ({}, {'info': {'outcome': 'success'}, 'result': {'apps': [row, row]}},
                    {'info': {'outcome': 'success'}, 'result': {'apps': [{**row, 'bundleVersion': '8'}]}},
                    {'info': {'outcome': 'success'}, 'result': {'apps': [{**row, 'bundleIdentifier': 'other'}]}}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                device_runner.verify_installed_lab(bad, '1.2.1', '9')

    def test_install_precedes_installed_version_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'build/latency/client.app'
            app.mkdir(parents=True)
            config = root / 'build/latency/lab-v2/ipad-handoff-config.json'
            config.parent.mkdir()
            config.write_text(json.dumps({'device_id': 'fixture-device'}))
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': device_runner.CLIENT_BUNDLE,
                'CFBundleVersion': '9', 'CFBundleShortVersionString': '1.2.1'}))
            handoff, qa = root / 'handoff', root / 'qa'
            handoff.touch()
            calls = []
            def command(args, **_kwargs):
                calls.append(args)
                if args[0] == 'codesign':
                    return SimpleNamespace(stdout=plistlib.dumps({'get-task-allow': True,
                        'com.apple.developer.icloud-container-environment': 'Development'}))
                if 'info' in args:
                    Path(args[args.index('--json-output') + 1]).write_text(json.dumps({
                        'info': {'outcome': 'success'}, 'result': {'apps': [{
                            'bundleIdentifier': device_runner.CLIENT_BUNDLE,
                            'bundleVersion': '9', 'version': '1.2.1'}]}}))
                return SimpleNamespace(returncode=0)
            with patch.object(device_runner, 'ROOT', root), patch.object(device_runner, 'IPAD_HANDOFF', handoff), \
                 patch.object(device_runner, 'RELEASE_QA', qa), patch.object(device_runner.subprocess, 'run', side_effect=command):
                with self.assertRaisesRegex(ValueError, 'not the configured iPad'):
                    device_runner.install_verified_lab_app('wrong-device', app)
                self.assertEqual(calls, [])
                device_runner.install_verified_lab_app('fixture-device', app)
            self.assertEqual(['codesign', 'install', 'info'],
                [args[0] if args[0] == 'codesign' else ('install' if 'install' in args else 'info') for args in calls])

    def test_install_never_starts_without_handoff_or_while_qa_active(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            handoff, qa = root / 'handoff', root / 'qa'
            with patch.object(device_runner, 'IPAD_HANDOFF', handoff), patch.object(device_runner, 'RELEASE_QA', qa), \
                 patch.object(device_runner.subprocess, 'run') as command:
                with self.assertRaises(ValueError):
                    device_runner.install_verified_lab_app('fixture-device', root / 'missing.app')
                handoff.touch(); qa.touch()
                with self.assertRaises(ValueError):
                    device_runner.install_verified_lab_app('fixture-device', root / 'missing.app')
                command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
