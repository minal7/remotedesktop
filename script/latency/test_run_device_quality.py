"""Synthetic schema and ownership checks; no device access."""
import unittest
import signal
from unittest.mock import Mock
import run_device_quality as quality


class QualityOwnershipTests(unittest.TestCase):
    def test_fix_selection_is_bounded_unique_and_canonical(self):
        self.assertEqual(quality.selected_fixes('F4,F1,F3'), ['F1', 'F3', 'F4'])
        self.assertEqual(quality.selected_fixes('F4'), ['F4'])
        for invalid in ('', 'F2', 'F1,F1', 'F1,', 'f4'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                quality.selected_fixes(invalid)

    def test_only_exact_quality_runner_in_application_container_matches(self):
        name = 'RemoteDesktopLatencyQualityTests-Runner.app'
        exe = 'RemoteDesktopLatencyQualityTests-Runner'
        root = 'file:///private/var/containers/Bundle/Application/8F8F6C31-7BF6-4C51-AE04-5B94B01A59A2/'
        data = {'info': {'outcome': 'success'}, 'result': {'runningProcesses': [
            {'executable': root + name + '/' + exe, 'processIdentifier': 101},
            {'executable': root + 'RemoteDesktopLiveE2ETests-Runner.app/RemoteDesktopLiveE2ETests-Runner', 'processIdentifier': 102},
            {'executable': root + name + '/other', 'processIdentifier': 103},
            {'executable': 'file:///tmp/' + name + '/' + exe, 'processIdentifier': 104}]}}
        matches = quality.quality_processes(data, name, exe)
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0][0], 101)
        self.assertTrue(matches[0][1].endswith('/' + name + '/' + exe))

    def test_invalid_or_failed_process_list_fails_closed(self):
        with self.assertRaises(ValueError): quality.quality_processes({'info': {'outcome': 'failure'}}, 'r.app', 'r')
        self.assertEqual(quality.quality_processes({'info': {'outcome': 'success'}, 'result': {'runningProcesses': [{}]}}, 'r.app', 'r'), [])
        url = 'file:///private/var/containers/Bundle/Application/8F8F6C31-7BF6-4C51-AE04-5B94B01A59A2/r.app/r'
        with self.assertRaises(ValueError):
            quality.quality_processes({'info': {'outcome': 'success'}, 'result': {'runningProcesses': [{'executable': url}]}}, 'r.app', 'r')

    def test_all_owned_handles_signaled_before_cleanup_even_on_failure(self):
        events = []
        def handle(name, fail=False):
            process = Mock()
            process.poll.return_value = None
            def send(sig):
                events.append((name, sig))
                if fail: raise OSError('already exited')
            process.send_signal.side_effect = send
            return process
        errors = []
        quality.signal_owned(handle('test', True), handle('console'), handle('fixture'), errors)
        self.assertEqual(events, [('test', signal.SIGTERM), ('console', signal.SIGINT), ('fixture', signal.SIGTERM)])
        self.assertEqual(len(errors), 1)

    def test_testroot_rebased_without_touching_other_placeholders(self):
        data = {'path': '__TESTROOT__/Debug/runner.app', 'nested': ['__TESTHOST__/bundle', '__TESTROOT__/one']}
        self.assertEqual(quality.replace_testroot(data, '/tmp/products'),
            {'path': '/tmp/products/Debug/runner.app', 'nested': ['__TESTHOST__/bundle', '/tmp/products/one']})

    def test_destination_artifacts_replaces_install_paths(self):
        config = {'TestHostPath': '/local/runner.app', 'UITargetAppPath': '/local/client.app',
                  'TestBundlePath': '__TESTHOST__/PlugIns/RemoteDesktopLatencyQualityTests.xctest',
                  'DependentProductPaths': ['/local/client.app'], 'EnvironmentVariables': {'sentinel': 'kept'}}
        quality.use_destination_artifacts(config)
        for key in ('TestHostPath', 'UITargetAppPath', 'TestBundlePath', 'DependentProductPaths'):
            self.assertNotIn(key, config)
        self.assertIs(config['UseDestinationArtifacts'], True)
        self.assertEqual(config['TestHostBundleIdentifier'], quality.RUNNER_BUNDLE)
        self.assertEqual(config['UITargetAppBundleIdentifier'], quality.CLIENT_BUNDLE)
        self.assertEqual(config['TestBundleDestinationRelativePath'], '__TESTHOST__/PlugIns/RemoteDesktopLatencyQualityTests.xctest')
        self.assertEqual(config['EnvironmentVariables'], {'sentinel': 'kept'})


if __name__ == '__main__':
    unittest.main()
