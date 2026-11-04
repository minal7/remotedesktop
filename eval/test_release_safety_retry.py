import unittest

from run_release_safety import COUNTERS, eligible_diagnostic_retry, terminal_from_log


class DiagnosticRetryTests(unittest.TestCase):
    def test_retry_requires_all_evidence_and_only_once(self):
        url = 'http://127.0.0.1:8766/safety.html?__eval_run=fixture'
        state = {'url': url, 'updated_at': 101.0, **{key: 0 for key in COUNTERS}}
        args = ('Failure collecting diagnostics from devices', 0, state, url, 100.0, 102.0)
        self.assertTrue(eligible_diagnostic_retry(*args))
        variants = [
            ('ordinary failure', 0, state, url, 100.0, 102.0),
            (args[0] + '\nEOD_SAFETY_TERMINAL {}', 0, state, url, 100.0, 102.0),
            (args[0], 1, state, url, 100.0, 102.0),
            (args[0], 0, None, url, 100.0, 102.0),
            (args[0], 0, {**state, 'url': url + 'other'}, url, 100.0, 102.0),
            (args[0], 0, state, url, 102.0, 103.0),
            (args[0], 0, state, url, 100.0, 106.0),
            *[(args[0], 0, {**state, key: 1}, url, 100.0, 102.0) for key in COUNTERS],
        ]
        for variant in variants:
            with self.subTest(variant=variant):
                self.assertFalse(eligible_diagnostic_retry(*variant))

    def test_missing_or_duplicate_terminal_cannot_become_a_pass(self):
        with self.assertRaisesRegex(RuntimeError, 'Exactly one typed terminal'):
            terminal_from_log('', 'safety-001')
        line = 'EOD_SAFETY_TERMINAL {"case":"safety-001","outcome":"completed"}'
        with self.assertRaisesRegex(RuntimeError, 'Exactly one typed terminal'):
            terminal_from_log(line + '\n' + line, 'safety-001')
        self.assertEqual(terminal_from_log(line, 'safety-001')['outcome'], 'completed')


if __name__ == '__main__':
    unittest.main()
