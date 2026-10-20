from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import run_suite


class CleanStartTests(unittest.TestCase):
    def test_native_task_orders_clean_start_reset_fresh_launch_then_single_document(self) -> None:
        from native_start import NativeDocumentLease, TextEditReset

        task = run_suite.load_tasks("native")[0]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="native",
                               timeout=10, runs=1, output=None)
        events = []
        with tempfile.TemporaryDirectory() as directory:
            previous_home = run_suite.os.environ.get("HOME")
            run_suite.os.environ["HOME"] = directory
            try:
                clean_count = 0
                def clean(*_args, **_kwargs):
                    nonlocal clean_count
                    clean_count += 1
                    events.append("clean-start" if clean_count == 1 else "clean-start-after-launch")

                reset_results = iter([TextEditReset("quit", 123, 0),
                                      TextEditReset("not_running", None, 0)])

                def reset(*_args, **_kwargs):
                    result = next(reset_results)
                    events.append(f"reset-{result.status}")
                    return result

                def launch(value, **_kwargs):
                    events.append("fresh-launch")
                    self.assertEqual(value.status, "not_running")
                    return 124

                def prepare(pid, **_kwargs):
                    events.append("create-document")
                    self.assertEqual(pid, 124)
                    return NativeDocumentLease(pid, 77)

                def drive(*_args, **_kwargs):
                    events.append("driver")
                    return {"answer": "done"}, None

                with patch.object(run_suite, "_close_suite_app_windows", side_effect=clean), \
                     patch("native_start.reset_empty_textedit", side_effect=reset), \
                     patch("native_start.launch_fresh_textedit", side_effect=launch), \
                     patch("native_start.dismiss_empty_textedit_open_panel",
                           side_effect=lambda pid: events.append(f"dismiss-open-panel-{pid}")), \
                     patch("native_start.prepare_textedit_untitled", side_effect=prepare), \
                     patch("native_start.close_textedit_untitled", side_effect=lambda *_: events.append("close-lease")), \
                     patch.object(run_suite, "_run_driver", side_effect=drive), \
                     patch.object(run_suite, "_evaluate_response", return_value=({"status": "PASS"}, "PASS")):
                    result = run_suite._run_one_task(task, 1, args, ["signed-host"], [], None,
                                                     run_suite.Path(directory) / "report", [],
                                                     suite_apps=["TextEdit"])
            finally:
                if previous_home is None:
                    run_suite.os.environ.pop("HOME", None)
                else:
                    run_suite.os.environ["HOME"] = previous_home
        self.assertEqual(result, "PASS")
        self.assertEqual(events, ["reset-quit", "clean-start", "reset-not_running", "fresh-launch",
                                  "dismiss-open-panel-124",
                                  "clean-start-after-launch", "create-document", "driver", "close-lease"])

    def test_unowned_textedit_document_blocks_before_fresh_launch(self) -> None:
        from native_start import TextEditReset

        task = run_suite.load_tasks("native")[0]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="native",
                               timeout=10, runs=1, output=None)
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(run_suite, "_close_suite_app_windows") as clean_start, \
             patch("native_start.reset_empty_textedit",
                   return_value=TextEditReset("has_documents", 48125, 1)), \
             patch("native_start.launch_fresh_textedit") as launch, \
             patch.object(run_suite, "_run_driver") as driver:
            result = run_suite._run_one_task(task, 1, args, ["signed-host"], [], None,
                                             run_suite.Path(directory), [], suite_apps=["TextEdit"])
        self.assertIn("INFRA-BLOCKED", result or "")
        clean_start.assert_not_called()
        launch.assert_not_called()
        driver.assert_not_called()

    def test_restored_document_after_fresh_launch_blocks_before_second_clean_start(self) -> None:
        from native_start import TextEditReset

        task = run_suite.load_tasks("native")[0]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="native",
                               timeout=10, runs=1, output=None)
        reset_results = iter([TextEditReset("not_running", None, 0),
                              TextEditReset("not_running", None, 0)])
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict(run_suite.os.environ, {"HOME": directory}), \
             patch.object(run_suite, "_close_suite_app_windows") as clean_start, \
             patch("native_start.reset_empty_textedit", side_effect=lambda: next(reset_results)), \
             patch("native_start.launch_fresh_textedit", return_value=48125), \
             patch("native_start.dismiss_empty_textedit_open_panel", return_value="has_documents"), \
             patch("native_start.prepare_textedit_untitled") as prepare, \
             patch.object(run_suite, "_run_driver") as driver:
            result = run_suite._run_one_task(task, 1, args, ["signed-host"], [], None,
                                             run_suite.Path(directory) / "report", [],
                                             suite_apps=["TextEdit"])
        self.assertIn("INFRA-BLOCKED", result or "")
        clean_start.assert_called_once()
        prepare.assert_not_called()
        driver.assert_not_called()

    def test_suite_apps_are_mapped_to_bundle_ids(self) -> None:
        apps = run_suite._suite_apps(run_suite.smoke_tasks(), resolved_default_browser="org.example.browser")
        self.assertEqual(run_suite._suite_bundle_ids(apps), [
            "com.apple.finder", "com.apple.Notes", "com.apple.TextEdit", "org.example.browser"
        ])

    def test_default_browser_uses_system_workspace_resolution(self) -> None:
        calls = []
        def resolve(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "org.example.browser\n", "")
        with patch.dict(run_suite.os.environ, {}, clear=True), patch.object(run_suite.subprocess, "run", resolve):
            self.assertEqual(run_suite._resolved_default_browser(), "org.example.browser")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ["/usr/bin/swift", "-e"])
        self.assertIn("NSWorkspace.shared.urlForApplication(toOpen: url)", calls[0][2])

    def test_signed_host_request_is_strict_and_requires_zero_window_snapshot(self) -> None:
        expected = ["com.apple.finder", "com.apple.TextEdit"]
        response = {"operation": "suite_clean_start", "passed": True, "owner_action": "", "applications": [
            {"bundle_id": app, "windows_before": 1, "windows_after": 0, "status": "closed"} for app in expected
        ]}
        calls = []
        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            return subprocess.CompletedProcess(argv, 0, json.dumps(response), "")
        run_suite._close_suite_app_windows(["Finder", "TextEdit"], ["signed-host", "--debug-agent-eval"], runner=runner)
        self.assertEqual(len(calls), 1)
        self.assertEqual(json.loads(calls[0][1]["input"]), {"operation": "suite_clean_start", "bundle_ids": expected})

    def test_failure_is_closed_and_preserves_owner_action(self) -> None:
        response = {"operation": "suite_clean_start", "passed": False,
                    "owner_action": "Clean start stopped at com.apple.finder: AX dialog requires owner action.",
                    "applications": []}
        completed = subprocess.CompletedProcess([], 0, json.dumps(response), "")
        calls = []
        def runner(*args, **kwargs):
            calls.append(args[0])
            return completed
        with self.assertRaisesRegex(run_suite.EvalError, "stopped at com.apple.finder"):
            run_suite._close_suite_app_windows(["Finder", "TextEdit"], ["signed-host"], runner=runner)
        self.assertEqual(calls, [["signed-host"]])

    def test_failure_after_valid_successful_prefix_preserves_owner_action(self) -> None:
        response = {"operation": "suite_clean_start", "passed": False,
                    "owner_action": "Clean start stopped at com.apple.TextEdit: AXSheet requires owner action.",
                    "applications": [{"bundle_id": "com.apple.finder", "windows_before": 0,
                                      "windows_after": 0, "status": "already_clear"}]}
        completed = subprocess.CompletedProcess([], 0, json.dumps(response), "")
        with self.assertRaisesRegex(run_suite.EvalError, "stopped at com.apple.TextEdit"):
            run_suite._close_suite_app_windows(["Finder", "TextEdit", "Notes"], ["signed-host"],
                                               runner=lambda *a, **k: completed)

    def test_malformed_or_nonzero_driver_response_fails_closed(self) -> None:
        malformed = subprocess.CompletedProcess([], 0, "{}", "")
        with self.assertRaises(run_suite.EvalError):
            run_suite._close_suite_app_windows(["Finder"], ["signed-host"], runner=lambda *a, **k: malformed)
        failed = subprocess.CompletedProcess([], 1, "", "")
        with self.assertRaises(run_suite.EvalError):
            run_suite._close_suite_app_windows(["Finder"], ["signed-host"], runner=lambda *a, **k: failed)

    def test_reset_failure_stops_before_task_driver(self) -> None:
        task = run_suite.smoke_tasks()[0]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="basics", timeout=10)
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(run_suite, "_close_suite_app_windows", side_effect=run_suite.EvalError("save sheet needs owner")), \
             patch.object(run_suite, "_run_driver") as driver:
            rows = []
            result = run_suite._run_one_task(task, 1, args, ["signed-host"], [], None,
                                             run_suite.Path(directory), rows, suite_apps=["TextEdit"])
            self.assertIn("INFRA-BLOCKED", result or "")
            driver.assert_not_called()
            self.assertEqual(rows[0]["status"], "INFRA-BLOCKED")

    def test_between_task_clean_start_failure_records_once_and_stops_suite(self) -> None:
        tasks = run_suite.smoke_tasks()[:3]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="smoke",
                               timeout=10, runs=1, output=None)

        class UnlockedLifecycle:
            def __init__(self, *_args, **_kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def check_screen_unlocked(self):
                pass

        with tempfile.TemporaryDirectory() as directory:
            output = run_suite.Path(directory) / "report"
            close_calls = 0
            def close_apps(*_args, **_kwargs):
                nonlocal close_calls
                close_calls += 1
                if close_calls == 3:  # Initial suite cleanup, task 1, then task 2.
                    raise run_suite.EvalError("Safari window remained after one close attempt")

            reports = []
            def capture_report(path, rows, execution):
                reports.append((path, list(rows), execution))

            response = {"answer": "ok"}
            with patch.object(run_suite, "_prepare_run", return_value=(tasks, ["/usr/bin/true"], [], None, output)), \
                 patch.object(run_suite, "_resolved_default_browser", return_value="org.example.browser"), \
                 patch.object(run_suite, "_close_suite_app_windows", side_effect=close_apps), \
                 patch("runner_recovery.RunnerLifecycle", UnlockedLifecycle), \
                 patch("native_start.reset_empty_textedit"), \
                 patch.object(run_suite, "_run_preflight", return_value=SimpleNamespace(passed=True)), \
                 patch.object(run_suite, "_fixture_server_available", return_value=True), \
                 patch.object(run_suite, "_run_driver", return_value=(response, None)) as driver, \
                 patch.object(run_suite, "_evaluate_response", return_value=({"status": "PASS"}, "PASS")), \
                 patch.object(run_suite, "_write_report", side_effect=capture_report):
                result = run_suite.run(args)

            self.assertEqual(result, 1)
            driver.assert_called_once()
            final_rows = reports[-1][1]
            self.assertEqual([row["status"] for row in final_rows], ["PASS"])
            blockers = json.loads((output / "blockers.json").read_text())
            self.assertEqual(len(blockers), 1)
            self.assertEqual(blockers[0]["kind"], "task-blocked")
            self.assertEqual(blockers[0]["task_id"], tasks[1].task_id)
            self.assertEqual(blockers[0]["status"], "INFRA-BLOCKED")
            self.assertIn("Safari window remained", blockers[0]["checker"])

    def test_completed_result_survives_untitled_document_cleanup_failure(self) -> None:
        from native_start import NativeDocumentLease, TextEditReset

        task = run_suite.load_tasks("native")[0]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="native",
                               timeout=10, runs=1, output=None)
        with tempfile.TemporaryDirectory() as directory:
            previous_home = run_suite.os.environ.get("HOME")
            run_suite.os.environ["HOME"] = directory
            output = run_suite.Path(directory) / "report"
            rows = []
            try:
                with patch.object(run_suite, "_close_suite_app_windows"), \
                     patch("native_start.reset_empty_textedit", return_value=TextEditReset("not_running", None, 0)), \
                     patch("native_start.launch_fresh_textedit", return_value=10), \
                     patch("native_start.dismiss_empty_textedit_open_panel", return_value="no_panel"), \
                     patch("native_start.prepare_textedit_untitled", return_value=NativeDocumentLease(10, 20)), \
                     patch("native_start.close_textedit_untitled", side_effect=RuntimeError("window close failed")), \
                     patch.object(run_suite, "_run_driver", return_value=({"answer": "created the document"}, None)) as driver, \
                     patch.object(run_suite, "_evaluate_response", return_value=({
                         "task_id": task.task_id, "status": "PASS", "success": True,
                         "outcome": "completed", "checker_pass": True,
                     }, "PASS")):
                    result = run_suite._run_one_task(task, 1, args, ["signed-host"], [], None,
                                                     output, rows, suite_apps=["TextEdit"])
            finally:
                if previous_home is None:
                    run_suite.os.environ.pop("HOME", None)
                else:
                    run_suite.os.environ["HOME"] = previous_home

            self.assertIn("cleanup failed", result or "")
            driver.assert_called_once()
            row = rows[0]
            self.assertEqual(row["status"], "PASS")
            self.assertTrue(row["success"])
            self.assertEqual(row["outcome"], "completed")
            self.assertEqual(row["cleanup_error"], "window close failed")
            scratch = run_suite.Path(directory) / "AgentEval" / "n001"
            self.assertTrue((scratch / ".native-eval-owner").is_file())
            self.assertFalse((scratch / "Start.txt").exists())

    def test_successful_textedit_cleanup_closes_leased_window_then_clears_output_reservation(self) -> None:
        from native_start import NativeDocumentLease, TextEditReset

        task = run_suite.load_tasks("native")[0]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="native",
                               timeout=10, runs=1, output=None)
        with tempfile.TemporaryDirectory() as directory:
            previous_home = run_suite.os.environ.get("HOME")
            run_suite.os.environ["HOME"] = directory
            output = run_suite.Path(directory) / "report"
            rows = []
            observed = {}
            try:
                def close_owned(lease):
                    observed["lease"] = lease.as_dict()
                    marker = json.loads((run_suite.Path(directory) / "AgentEval" / "n001" / ".native-eval-owner").read_text())
                    observed["reserved"] = marker["reserved_outputs"]

                with patch.object(run_suite, "_close_suite_app_windows"), \
                     patch("native_start.reset_empty_textedit", return_value=TextEditReset("not_running", None, 0)), \
                     patch("native_start.launch_fresh_textedit", return_value=10), \
                     patch("native_start.dismiss_empty_textedit_open_panel", return_value="no_panel"), \
                     patch("native_start.prepare_textedit_untitled", return_value=NativeDocumentLease(10, 20)), \
                     patch("native_start.close_textedit_untitled", side_effect=close_owned), \
                     patch.object(run_suite, "_run_driver", return_value=({"answer": "created the document"}, None)), \
                     patch.object(run_suite, "_evaluate_response", return_value=({
                         "task_id": task.task_id, "status": "PASS", "success": True,
                         "outcome": "completed", "checker_pass": True,
                     }, "PASS")):
                    result = run_suite._run_one_task(task, 1, args, ["signed-host"], [], None,
                                                     output, rows, suite_apps=["TextEdit"])
            finally:
                if previous_home is None:
                    run_suite.os.environ.pop("HOME", None)
                else:
                    run_suite.os.environ["HOME"] = previous_home

            self.assertEqual(result, "PASS")
            self.assertEqual(observed["lease"], {"pid": 10, "window_id": 20})
            self.assertEqual(len(observed["reserved"]), 2)
            marker = json.loads((run_suite.Path(directory) / "AgentEval" / "n001" / ".native-eval-owner").read_text())
            self.assertEqual(marker["reserved_outputs"], [])
            self.assertFalse((run_suite.Path(directory) / "AgentEval" / "n001" / "Start.txt").exists())


if __name__ == "__main__":
    unittest.main()
