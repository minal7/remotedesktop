import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "run_native_text_model_acceptance.py"
spec = importlib.util.spec_from_file_location("native_model_acceptance", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class NativeModelAcceptanceTests(unittest.TestCase):
    def test_default_shell_gate_runs_tests_and_preserves_their_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for name in ('xcrun', 'codesign', 'swift'):
                path = directory / name
                path.write_text('#!/bin/sh\n' + ('printf "%s\\n" "$@"\nexit 17\n' if name == 'swift' else 'exit 0\n'))
                path.chmod(0o700)
            environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'])
            environment.pop('COMPUTER_USE_TEST_XUNIT_REPORT', None)
            result = subprocess.run(['/bin/bash', str(SCRIPT.with_name('run_text_edit_acceptance.sh'))],
                                    env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 17, result.stderr)
            self.assertIn('--no-parallel', result.stdout)
            self.assertIn('--filter', result.stdout)

    def test_zero_tests_wrong_tests_duplicates_and_skips_cannot_pass(self):
        names = ["testRealNativeNaturalLanguageGoalsAndResume", "testRealBrowserNaturalLanguageGoalsAndResume"]
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "tests.xml"
            valid = ''.join(f'<testcase name="{name}" />' for name in names)
            report.write_text('<testsuites><testsuite>' + valid + '</testsuite></testsuites>')
            self.assertEqual(runner.verify_test_report(report), sorted(names))
            for body in ['', '<testcase name="unrelated" />', valid + valid,
                         valid.replace('/>', '><skipped /></testcase>', 1),
                         valid.replace('/>', '><failure /></testcase>', 1)]:
                with self.subTest(body=body):
                    report.write_text('<testsuites><testsuite>' + body + '</testsuite></testsuites>')
                    with self.assertRaises(ValueError):
                        runner.verify_test_report(report)

    def test_aborted_scope_terminates_its_actual_child(self):
        child = None
        try:
            with self.assertRaisesRegex(RuntimeError, 'fixture failure'):
                with runner.process_scope() as children:
                    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
                    children.append(child)
                    raise RuntimeError('fixture failure')
            self.assertIsNotNone(child.poll())
        finally:
            if child is not None and child.poll() is None:
                runner.stop(child)

    def test_modified_model_cannot_pass_the_frozen_hash_check(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / 'candidate.gguf'
            model.write_bytes(b'abc')
            digest = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
            self.assertEqual(runner.verified_path(model, digest, 3), model.resolve())
            model.write_bytes(b'abd')
            with self.assertRaisesRegex(ValueError, 'SHA-256'):
                runner.verified_path(model, digest, 3)


if __name__ == '__main__':
    unittest.main()
