from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import run_suite


class CleanStartTests(unittest.TestCase):
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
            with patch.object(run_suite, "_prepare_run", return_value=(tasks, ["signed-host"], [], None, output)), \
                 patch.object(run_suite, "_resolved_default_browser", return_value="org.example.browser"), \
                 patch.object(run_suite, "_close_suite_app_windows", side_effect=close_apps), \
                 patch.object(run_suite, "_run_preflight", return_value=SimpleNamespace(passed=True)), \
                 patch.object(run_suite, "_fixture_server_available", return_value=True), \
                 patch.object(run_suite, "_run_driver", return_value=(response, None)) as driver, \
                 patch.object(run_suite, "_evaluate_response", return_value=({"status": "PASS"}, "PASS")), \
                 patch.object(run_suite, "_write_report", side_effect=capture_report):
                result = run_suite.run(args)

            self.assertEqual(result, 1)
            driver.assert_called_once()
            final_rows = reports[-1][1]
            self.assertEqual(len(final_rows), 2)
            self.assertEqual([row["status"] for row in final_rows], ["PASS", "INFRA-BLOCKED"])
            self.assertIn("Safari window remained", final_rows[-1]["checker"])

    def test_completed_result_survives_fixture_cleanup_failure_and_stops_next_task(self) -> None:
        tasks = run_suite.load_tasks("native")[:2]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="native",
                               timeout=10, runs=1, output=None)
        with tempfile.TemporaryDirectory() as directory:
            previous_home = run_suite.os.environ.get("HOME")
            run_suite.os.environ["HOME"] = directory
            output = run_suite.Path(directory) / "report"
            reports = []
            closes = 0

            def close_apps(*_args, **_kwargs):
                nonlocal closes
                closes += 1
                if closes == 3:  # Suite, task start, then post-task fixture cleanup.
                    raise run_suite.EvalError("fixture window could not be closed")

            def capture_report(path, rows, execution):
                reports.append((path, json.loads(json.dumps(rows)), execution))

            try:
                with patch.object(run_suite, "_prepare_run", return_value=(tasks, ["signed-host"], [], None, output)), \
                     patch.object(run_suite, "_close_suite_app_windows", side_effect=close_apps), \
                     patch.object(run_suite, "_run_preflight", return_value=SimpleNamespace(passed=True)), \
                     patch.object(run_suite, "_fixture_server_available", return_value=True), \
                     patch.object(run_suite, "_run_driver", return_value=({"answer": "created the note"}, None)) as driver, \
                     patch.object(run_suite, "_evaluate_response", return_value=({
                         "task_id": tasks[0].task_id, "status": "PASS", "success": True,
                         "outcome": "completed", "checker_pass": True,
                     }, "PASS")), \
                     patch.object(run_suite, "_write_report", side_effect=capture_report):
                    result = run_suite.run(args)
            finally:
                if previous_home is None:
                    run_suite.os.environ.pop("HOME", None)
                else:
                    run_suite.os.environ["HOME"] = previous_home

            self.assertEqual(result, 1)
            driver.assert_called_once()
            row = reports[-1][1][0]
            self.assertEqual(row["status"], "PASS")
            self.assertTrue(row["success"])
            self.assertEqual(row["outcome"], "completed")
            self.assertEqual(row["cleanup_error"], "fixture window could not be closed")
            retained = list((run_suite.Path(directory) / "AgentEval").glob("native-001-*/Start.txt"))
            self.assertEqual(len(retained), 1)

    def test_successful_fixture_cleanup_closes_before_removing_blank_document(self) -> None:
        tasks = run_suite.load_tasks("native")[:1]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="native",
                               timeout=10, runs=1, output=None)
        with tempfile.TemporaryDirectory() as directory:
            previous_home = run_suite.os.environ.get("HOME")
            run_suite.os.environ["HOME"] = directory
            output = run_suite.Path(directory) / "report"
            closes = 0
            saw_document_during_close = False
            try:
                def close_apps(*_args, **_kwargs):
                    nonlocal closes, saw_document_during_close
                    closes += 1
                    if closes == 3:  # Post-task close happens while the private fixture still exists.
                        files = list((run_suite.Path(directory) / "AgentEval").glob("native-001-*/Start.txt"))
                        saw_document_during_close = len(files) == 1 and files[0].read_bytes() == b""

                with patch.object(run_suite, "_prepare_run", return_value=(tasks, ["signed-host"], [], None, output)), \
                     patch.object(run_suite, "_close_suite_app_windows", side_effect=close_apps), \
                     patch.object(run_suite, "_run_preflight", return_value=SimpleNamespace(passed=True)), \
                     patch.object(run_suite, "_fixture_server_available", return_value=True), \
                     patch.object(run_suite, "_run_driver", return_value=({"answer": "created the note"}, None)), \
                     patch.object(run_suite, "_evaluate_response", return_value=({
                         "task_id": tasks[0].task_id, "status": "PASS", "success": True,
                         "outcome": "completed", "checker_pass": True,
                     }, "PASS")), \
                     patch.object(run_suite, "_write_report"):
                    result = run_suite.run(args)
            finally:
                if previous_home is None:
                    run_suite.os.environ.pop("HOME", None)
                else:
                    run_suite.os.environ["HOME"] = previous_home

            self.assertEqual(result, 0)
            self.assertTrue(saw_document_during_close)
            self.assertEqual(list((run_suite.Path(directory) / "AgentEval").glob("native-001-*/Start.txt")), [])


if __name__ == "__main__":
    unittest.main()
