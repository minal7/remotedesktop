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


if __name__ == "__main__":
    unittest.main()
