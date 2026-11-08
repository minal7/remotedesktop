from __future__ import annotations

import subprocess
import re
import unittest
from unittest.mock import patch

import native_start


class NativeStartTests(unittest.TestCase):
    def test_reset_reports_not_running_and_has_documents_without_quitting(self):
        calls = []

        def runner(argv, **kwargs):
            source = kwargs.get("input", "")
            calls.append(source)
            if len(calls) == 1:
                value = "not_running"
            else:
                value = ["48125", "1", "48125"][len(calls) - 2]
            return subprocess.CompletedProcess(argv, 0, value, "")

        self.assertEqual(native_start.reset_empty_textedit(runner=runner),
                         native_start.TextEditReset("not_running", None, 0))
        result = native_start.reset_empty_textedit(runner=runner)
        self.assertEqual(result, native_start.TextEditReset("has_documents", 48125, 1))
        self.assertEqual(len(calls), 4)
        self.assertNotIn("quit", calls[-1])

    def test_not_running_reset_executes_only_system_events_probe(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "not_running", "")

        result = native_start.reset_empty_textedit(runner=runner)
        self.assertEqual(result, native_start.TextEditReset("not_running", None, 0))
        self.assertEqual(len(calls), 1)
        self.assertIn('tell application "System Events"', calls[0])
        self.assertNotIn('tell application id "com.apple.TextEdit"', calls[0])

    def test_zero_document_reset_quits_and_waits_for_exact_pid_exit(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs.get("input", ""))
            value = ["48125", "0", "48125", "quit"][len(calls) - 1]
            return subprocess.CompletedProcess(argv, 0, value, "")

        result = native_start.reset_empty_textedit(
            runner=runner, monotonic=iter([0.0, 0.0, 0.01]).__next__,
            sleep=lambda _seconds: None,
            pid_probe=lambda pid, signal: (_ for _ in ()).throw(ProcessLookupError())
            if (pid, signal) == (48125, 0) else None,
        )
        self.assertEqual(result, native_start.TextEditReset("quit", 48125, 0))
        self.assertIn("quit", calls[3])

    def test_zero_document_reset_can_retain_process_for_next_untitled_task(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs.get("input", ""))
            value = ["48125", "0", "48125"][len(calls) - 1]
            return subprocess.CompletedProcess(argv, 0, value, "")

        result = native_start.reset_empty_textedit(runner=runner, quit_if_empty=False)
        self.assertEqual(result, native_start.TextEditReset("empty", 48125, 0))
        self.assertEqual(len(calls), 3)
        self.assertTrue(all("quit" not in source for source in calls))

    def test_reset_times_out_if_old_pid_does_not_exit(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs.get("input", ""))
            value = ["48125", "0", "48125", "quit"][len(calls) - 1]
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
            value = ["48125", "0", "48125", "has_documents"][len(calls) - 1]
            return subprocess.CompletedProcess(argv, 0, value, "")

        result = native_start.reset_empty_textedit(runner=runner)
        self.assertEqual(result, native_start.TextEditReset("has_documents", 48125, None))

    def test_reset_rechecks_captured_pid_immediately_before_quit(self):
        sources = []

        def runner(argv, **kwargs):
            source = kwargs.get("input", "")
            sources.append(source)
            if len(sources) < 4:
                value = ["48125", "0", "48125"][len(sources) - 1]
                return subprocess.CompletedProcess(argv, 0, value, "")
            return subprocess.CompletedProcess(argv, 1, "", "process changed")

        with self.assertRaisesRegex(RuntimeError, "process changed"):
            native_start.reset_empty_textedit(runner=runner)
        self.assertIn("if currentPID is not 48125", sources[3])
        self.assertLess(sources[3].index("if currentPID is not 48125"), sources[3].index("        quit\n"))

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

    def test_open_panel_dismissal_targets_only_standard_cancel_control(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "dismissed", "")

        result = native_start.dismiss_empty_textedit_open_panel(48125, runner=runner)
        self.assertEqual(result, "dismissed")
        self.assertEqual(len(calls), 1)
        source = calls[0]
        self.assertIn('if documentCount is not 0 then return "has_documents"', source)
        self.assertIn('windows of targetProcess whose value of attribute "AXIdentifier" is "open-panel"', source)
        self.assertIn("splitter groups of panel", source)
        self.assertIn('buttons of panelLayout whose value of attribute "AXIdentifier" is "CancelButton"', source)
        self.assertIn("Cancel control count=", source)
        self.assertIn('click first button of panelLayout whose value of attribute "AXIdentifier" is "CancelButton"', source)
        self.assertNotIn("entire contents", source)
        self.assertIn("if appPID is not 48125", source)
        self.assertNotIn('whose name is "Open"', source)
        self.assertNotIn("Untitled", source)

    def test_open_panel_without_documents_is_noop_when_panel_absent(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "no_panel", "")

        self.assertEqual(native_start.dismiss_empty_textedit_open_panel(48125, runner), "no_panel")
        self.assertEqual(len(calls), 1)

    def test_open_panel_is_not_dismissed_when_any_document_exists(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "has_documents", "")

        self.assertEqual(native_start.dismiss_empty_textedit_open_panel(48125, runner), "has_documents")
        self.assertEqual(len(calls), 1)

    def test_open_panel_dismissal_rejects_invalid_process_identity(self):
        runner = unittest.mock.Mock()
        with self.assertRaises(ValueError):
            native_start.dismiss_empty_textedit_open_panel(0, runner)
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

    def test_notes_setup_returns_verified_empty_selection_without_mutation(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "already_clear|||0|0", "")

        result = native_start.prepare_notes_no_selection(runner)
        self.assertEqual(result.as_dict(), {
            "status": "already_clear", "folder_name": None, "folder_id": None,
            "folder_note_count": None, "selected_note_count": 0,
        })
        self.assertEqual(len(calls), 1)
        self.assertLess(calls[0].index("activate"), calls[0].index("initialSelectionCount"))
        self.assertIn("count of selection", calls[0])
        self.assertNotIn("set selection", calls[0])
        self.assertLess(calls[0].index('return "already_clear|||0|0"'), calls[0].index("make new folder"))
        self.assertNotIn("make new note", calls[0].casefold())

    def test_notes_already_clear_still_reopens_and_verifies_main_window(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "already_clear|||0|0", "")

        native_start.prepare_notes_no_selection(runner)
        source = calls[0]
        self.assertIn("reopen", source)
        self.assertIn('subrole is "AXStandardWindow"', source)
        self.assertLess(source.index("verify-standard-window"), source.index('return "already_clear|||0|0"'))

    def test_notes_setup_fails_closed_when_main_window_does_not_reopen(self):
        def runner(argv, **kwargs):
            source = kwargs["input"]
            self.assertIn("repeat with attempt from 1 to 10", source)
            self.assertIn("if not windowReady then error", source)
            self.assertLess(source.index("verify-standard-window"), source.index("check-existing-selection"))
            name = re.search(r'set folderName to "([^\"]+)"', source).group(1)
            return subprocess.CompletedProcess(
                argv, 0, f"setup_error|verify-standard-window|{name}||-2700", "")

        with self.assertRaisesRegex(RuntimeError, "Notes setup failed at verify-standard-window"):
            native_start.prepare_notes_no_selection(runner)

    def test_notes_setup_creates_and_verifies_unique_empty_default_folder(self):
        calls = []

        def runner(argv, **kwargs):
            source = kwargs["input"]
            calls.append(source)
            name = re.search(r'set folderName to "([^"]+)"', source).group(1)
            self.assertRegex(name, r"^RemoteDesktop Eval [0-9a-f]{32}$")
            return subprocess.CompletedProcess(argv, 0, f"fixture_created|{name}|folder-id-123|0|0", "")

        result = native_start.prepare_notes_no_selection(runner)
        self.assertEqual(result.as_dict(), {
            "status": "fixture_created", "folder_name": result.folder_name,
            "folder_id": "folder-id-123", "folder_note_count": 0,
            "selected_note_count": 0,
        })
        source = calls[0]
        self.assertIn("default account", source)
        self.assertIn("make new folder at defaultAccount", source)
        self.assertIn("show fixtureFolder", source)
        self.assertIn("count of notes of fixtureFolder", source)
        self.assertIn("count of selection", source)
        self.assertIn("set end of folderOutlines to contents of candidateOutline", source)
        self.assertNotIn('name of candidateOutline is "Folders"', source)
        self.assertIn('windows of notesProcess whose subrole is "AXStandardWindow"', source)
        self.assertIn("set folderRowObject to contents of folderRowReference", source)
        self.assertIn("set rowElements to UI elements of folderRowObject", source)
        self.assertIn('value of attribute "AXRole" of folderCellObject is "AXCell"', source)
        self.assertIn("set cellElements to UI elements of folderCellObject", source)
        self.assertIn("set folderNodeObject to contents of folderNodeReference", source)
        self.assertIn("text fields of folderNodeObject", source)
        self.assertNotIn('value of attribute "AXIdentifier"', source)
        self.assertIn("set selected of ownedFolderRow to true", source)
        self.assertIn("delay 0.2", source)
        self.assertNotIn("rows of first item of notes", source)
        self.assertNotIn("set selection", source)
        self.assertNotIn("delete", source.casefold())
        self.assertNotIn("make new note", source.casefold())

    def test_notes_setup_does_not_swallow_unverified_empty_state(self):
        def runner(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 1, "", "selection query rejected")

        with self.assertRaisesRegex(RuntimeError, "Notes eval setup failed") as raised:
            native_start.prepare_notes_no_selection(runner)
        self.assertNotIn("TextEdit", str(raised.exception))
        self.assertNotIn("set selection to {}", str(raised.exception))

    def test_notes_setup_rejects_nonempty_or_still_selected_fixture(self):
        def runner(argv, **kwargs):
            source = kwargs["input"]
            name = re.search(r'set folderName to "([^"]+)"', source).group(1)
            return subprocess.CompletedProcess(argv, 0, f"fixture_created|{name}|folder-id-123|1|0", "")

        with self.assertRaisesRegex(RuntimeError, "invalid selection receipt"):
            native_start.prepare_notes_no_selection(runner)

    def test_notes_folder_row_failure_reports_only_owned_folder_identity(self):
        def runner(argv, **kwargs):
            source = kwargs["input"]
            name = re.search(r'set folderName to "([^\"]+)"', source).group(1)
            return subprocess.CompletedProcess(argv, 0, f"setup_error|select-owned-folder-row|{name}|folder-id-owned|-2700", "")

        with self.assertRaisesRegex(RuntimeError, "select-owned-folder-row") as raised:
            native_start.prepare_notes_no_selection(runner)
        self.assertIn("folder-id-owned", str(raised.exception))
        self.assertIn("AppleScript error -2700", str(raised.exception))
        self.assertNotIn("personal", str(raised.exception).casefold())

    def test_notes_setup_timeout_becomes_bounded_runtime_error(self):
        def runner(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, kwargs["timeout"], output="private note", stderr="private note")

        with self.assertRaisesRegex(RuntimeError, "Notes eval setup failed: AppleScript evaluation timed out after 15s") as raised:
            native_start.prepare_notes_no_selection(runner)
        self.assertNotIn("private note", str(raised.exception))

    def test_notes_setup_errors_do_not_expose_script_stderr(self):
        def runner(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 1, "", "sensitive account note text")

        with self.assertRaisesRegex(RuntimeError, "Notes eval setup failed") as raised:
            native_start.prepare_notes_no_selection(runner)
        self.assertNotIn("sensitive account note text", str(raised.exception))

    def test_fresh_launch_rejects_contradictory_reset_diagnostics(self):
        runner = unittest.mock.Mock()
        contradictory = native_start.TextEditReset("not_running", 48125, 0)
        with self.assertRaisesRegex(RuntimeError, "consistent zero-document reset"):
            native_start.launch_fresh_textedit(contradictory, runner=runner)
        runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
