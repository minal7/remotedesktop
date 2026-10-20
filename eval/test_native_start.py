from __future__ import annotations

import subprocess
import unittest
from unittest.mock import patch

import native_start


class NativeStartTests(unittest.TestCase):
    def test_reset_reports_not_running_and_has_documents_without_quitting(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs.get("input", ""))
            value = "not_running" if len(calls) == 1 else "48125:1"
            return subprocess.CompletedProcess(argv, 0, value, "")

        self.assertEqual(native_start.reset_empty_textedit(runner=runner),
                         native_start.TextEditReset("not_running", None, 0))
        result = native_start.reset_empty_textedit(runner=runner)
        self.assertEqual(result, native_start.TextEditReset("has_documents", 48125, 1))
        self.assertEqual(len(calls), 2)
        self.assertNotIn("quit", calls[-1])

    def test_zero_document_reset_quits_and_waits_for_exact_pid_exit(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs.get("input", ""))
            value = "48125:0" if len(calls) == 1 else "quit"
            return subprocess.CompletedProcess(argv, 0, value, "")

        result = native_start.reset_empty_textedit(
            runner=runner, monotonic=iter([0.0, 0.0, 0.01]).__next__,
            sleep=lambda _seconds: None,
            pid_probe=lambda pid, signal: (_ for _ in ()).throw(ProcessLookupError())
            if (pid, signal) == (48125, 0) else None,
        )
        self.assertEqual(result, native_start.TextEditReset("quit", 48125, 0))
        self.assertIn("quit", calls[1])

    def test_reset_times_out_if_old_pid_does_not_exit(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs.get("input", ""))
            value = "48125:0" if len(calls) == 1 else "quit"
            return subprocess.CompletedProcess(argv, 0, value, "")

        ticks = iter([0.0, 0.0, 4.0])
        with self.assertRaisesRegex(RuntimeError, "pid 48125 did not exit"):
            native_start.reset_empty_textedit(runner=runner, monotonic=lambda: next(ticks),
                                               sleep=lambda _seconds: None,
                                               pid_probe=lambda _pid, _signal: None)

    def test_reset_race_reports_unknown_document_count_without_fabricating_one(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs.get("input", ""))
            value = "48125:0" if len(calls) == 1 else "has_documents"
            return subprocess.CompletedProcess(argv, 0, value, "")

        result = native_start.reset_empty_textedit(runner=runner)
        self.assertEqual(result, native_start.TextEditReset("has_documents", 48125, None))

    def test_reset_rechecks_captured_pid_immediately_before_quit(self):
        sources = []

        def runner(argv, **kwargs):
            source = kwargs.get("input", "")
            sources.append(source)
            if len(sources) == 1:
                return subprocess.CompletedProcess(argv, 0, "48125:0", "")
            return subprocess.CompletedProcess(argv, 1, "", "process changed")

        with self.assertRaisesRegex(RuntimeError, "process changed"):
            native_start.reset_empty_textedit(runner=runner)
        self.assertIn("if currentPID is not 48125", sources[1])
        self.assertLess(sources[1].index("if currentPID is not 48125"), sources[1].index("        quit\n"))

    def test_fresh_launch_uses_exact_bundle_and_no_document_argument(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[0] == "/usr/bin/open":
                return subprocess.CompletedProcess(argv, 0, "", "")
            return subprocess.CompletedProcess(argv, 0, "48125", "")

        with patch.object(native_start.time, "monotonic", side_effect=[0.0, 0.0]):
            pid = native_start.launch_fresh_textedit(
                native_start.TextEditReset("not_running", None, 0), runner=runner)
        self.assertEqual(pid, 48125)
        self.assertEqual(calls[0][0], ["/usr/bin/open", "-F", "-b", "com.apple.TextEdit"])
        self.assertEqual(len(calls), 2)

    def test_fresh_launch_refuses_restored_documents(self):
        runner = unittest.mock.Mock()
        with self.assertRaisesRegex(RuntimeError, "status.*has_documents"):
            native_start.launch_fresh_textedit(
                native_start.TextEditReset("has_documents", 48125, 1), runner=runner)
        runner.assert_not_called()

    def test_prepare_creates_one_document_after_expected_pid_check(self):
        calls = []

        def runner(argv, **kwargs):
            source = kwargs.get("input", "")
            calls.append(source)
            self.assertIn('if appPID is not 48125', source)
            self.assertIn("if (count of documents) is not 0", source)
            self.assertIn("make new document", source)
            self.assertIn("matchingWindows", source)
            return subprocess.CompletedProcess(argv, 0, "48125:640", "")

        lease = native_start.prepare_textedit_untitled(48125, runner=runner)
        self.assertEqual(lease, native_start.NativeDocumentLease(48125, 640))
        self.assertEqual(len(calls), 1)
        self.assertNotIn("launch\n", calls[0])
        self.assertNotIn("path of newDocument", calls[0])
        self.assertNotIn("Start.txt", calls[0])

    def test_prepare_returns_serializable_exact_document_lease(self):
        def runner(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, "4321:98765\n", "")

        lease = native_start.prepare_textedit_untitled(4321, runner)
        self.assertEqual(lease.as_dict(), {"pid": 4321, "window_id": 98765})
        self.assertEqual(native_start.NativeDocumentLease.from_dict(lease.as_dict()), lease)

    def test_close_targets_only_leased_document_and_process(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "closed\n", "")

        native_start.close_textedit_untitled({"pid": 4321, "window_id": 98765}, runner)
        self.assertIn("appPID is not 4321", calls[0])
        self.assertIn("id is 98765", calls[0])
        self.assertIn("saving no", calls[0])
        self.assertIn("document of first item of matchingWindows", calls[0])
        self.assertIn("(count of matchingWindows) is not 1", calls[0])

    def test_close_rejects_invalid_or_ambiguous_lease(self):
        with self.assertRaises(ValueError):
            native_start.NativeDocumentLease.from_dict({"pid": True, "window_id": 9})
        with self.assertRaises(ValueError):
            native_start.close_textedit_untitled({"pid": 1, "window_id": -1})

    def test_notes_setup_only_clears_selection(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "", "")

        native_start.prepare_notes_no_selection(runner)
        self.assertIn("set selection to {}", calls[0])
        self.assertNotIn("delete", calls[0].casefold())
        self.assertNotIn("make new note", calls[0].casefold())

    def test_fresh_launch_rejects_contradictory_reset_diagnostics(self):
        runner = unittest.mock.Mock()
        contradictory = native_start.TextEditReset("not_running", 48125, 0)
        with self.assertRaisesRegex(RuntimeError, "consistent zero-document reset"):
            native_start.launch_fresh_textedit(contradictory, runner=runner)
        runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
