from __future__ import annotations

import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import run_suite


class CleanStartTests(unittest.TestCase):
    def test_suite_clean_start_includes_all_used_apps_and_resolved_default_browser(self) -> None:
        tasks = run_suite.smoke_tasks()
        apps = run_suite._suite_apps(tasks, resolved_default_browser="MacSafari")
        self.assertEqual(set(apps), {"Finder", "MacSafari", "Notes", "TextEdit"})
        self.assertEqual(len(apps), len(set(apps)))

    def test_default_browser_uses_system_workspace_resolution(self) -> None:
        calls: list[list[str]] = []
        def resolve(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "org.example.browser\n", "")
        with patch.dict(run_suite.os.environ, {}, clear=True), patch.object(run_suite.subprocess, "run", resolve):
            self.assertEqual(run_suite._resolved_default_browser(), "org.example.browser")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ["/usr/bin/swift", "-e"])
        self.assertIn("NSWorkspace.shared.urlForApplication(toOpen: url)", calls[0][2])

    def test_clean_start_closes_only_suite_windows_without_save_prompts(self) -> None:
        apps = ["Finder", "MacSafari", "Notes", "TextEdit"]
        scripts = [run_suite._close_app_windows_script(app) for app in apps]
        self.assertIn("close every document saving no", scripts[-1])
        self.assertIn("close every window", scripts[0])
        self.assertIn("close every window", scripts[1])
        self.assertIn("close every window", scripts[2])
        for script in scripts:
            self.assertNotIn("saving yes", script.lower())
            self.assertNotIn("save every", script.lower())

        calls: list[list[str]] = []
        def succeed(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")
        run_suite._close_suite_app_windows(apps, runner=succeed)
        self.assertEqual(len(calls), len(apps))
        self.assertTrue(all(call[0] == "/usr/bin/osascript" for call in calls))
        self.assertEqual([call[-1] for call in calls], scripts)

    def test_clean_start_failure_stops_before_remaining_app_cleanup(self) -> None:
        calls: list[list[str]] = []
        def fail_on_notes(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            calls.append(argv)
            code = 1 if 'application id "com.apple.Notes"' in argv[-1] else 0
            return subprocess.CompletedProcess(argv, code, "", "close failed" if code else "")
        with self.assertRaises(run_suite.EvalError):
            run_suite._close_suite_app_windows(["Finder", "MacSafari", "Notes", "TextEdit"], runner=fail_on_notes)
        self.assertEqual(len(calls), 3)
        self.assertNotIn('application id "com.apple.TextEdit"', calls[-1][-1])

    def test_task_driver_is_not_called_when_clean_start_fails(self) -> None:
        task = run_suite.smoke_tasks()[0]
        args = SimpleNamespace(execution="real-host", policy="fara15-4b", suite="basics", timeout=10)
        with tempfile.TemporaryDirectory() as directory:
            output_directory = run_suite.Path(directory)
            rows: list[dict[str, object]] = []
            with patch.object(run_suite, "_close_suite_app_windows", side_effect=run_suite.EvalError("close failed")), \
                 patch.object(run_suite, "_run_driver") as driver:
                result = run_suite._run_one_task(task, 1, args, [], [], None, output_directory, rows, suite_apps=["Finder"])
            self.assertIn("INFRA-BLOCKED", result or "")
            driver.assert_not_called()
            self.assertEqual(rows[0]["status"], "INFRA-BLOCKED")


if __name__ == "__main__":
    unittest.main()
