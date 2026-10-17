from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import run_suite
from runner_recovery import Checkpoint, ScreenLocked


class FakeLifecycle:
    def __init__(self, *_args, **_kwargs):
        self.idle_waits = 0
        self.screen_checks = 0

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def check_screen_unlocked(self):
        self.screen_checks += 1

    def wait_for_local_idle(self):
        self.idle_waits += 1


def sample_task(task_id: str, *, surface: str = "web", setup: dict | None = None) -> run_suite.Task:
    start = {"url": "https://example.test/"} if surface == "web" else {"app": "TextEdit"}
    value = {"id": task_id, "surface": surface, "start": start, "prompt": "Read the page.",
             "checker": {"type": "answer_contains", "expect": {"text": "ok"}},
             "max_steps": 2, "tags": ["lifecycle"]}
    if setup is not None:
        value["setup"] = setup
    return run_suite.Task(Path(f"{task_id}.yaml"), value)


def args_for(output: Path, *, resume: bool = False) -> SimpleNamespace:
    return SimpleNamespace(suite="basics", policy="fara15-4b", runs=1, driver=None,
        reset_command=None, execution="real-host", timeout=60, deadline_seconds=3600,
        output=str(output), resume=resume)


class SuiteLifecycleIntegrationTests(unittest.TestCase):
    def test_resume_skips_completed_keys_and_retries_only_crashed_key(self) -> None:
        task_done = sample_task("done")
        task_pending = sample_task("pending")
        tasks = [task_done, task_pending]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            keys = ["1:done", "1:pending"]
            checkpoint = Checkpoint(output, keys)
            checkpoint.mark_completed("1:done", {"task_id": "done", "run": 1,
                "status": "PASS", "success": True, "tags": ["lifecycle"]})
            checkpoint.mark_inflight("1:pending", "crashed-attempt")
            completed_calls: list[str] = []

            def execute(task, _run_number, _args, *_rest, checkpoint=None, task_key=None, **_kwargs):
                completed_calls.append(task.task_id)
                checkpoint.mark_completed(task_key, {"task_id": task.task_id, "run": 1,
                    "status": "PASS", "success": True, "tags": ["lifecycle"]})
                return "PASS"

            lifecycle = FakeLifecycle()
            with patch.object(run_suite, "_prepare_run", return_value=(tasks, ["/usr/bin/true"], [], None, output)), \
                 patch("runner_recovery.RunnerLifecycle", return_value=lifecycle), \
                 patch.object(run_suite, "_run_one_task", side_effect=execute), \
                 patch.object(run_suite, "_resolved_default_browser", return_value="org.example.browser"), \
                 patch.object(run_suite, "_close_suite_app_windows"), \
                 patch.object(run_suite, "_fixture_server_available", return_value=True), \
                 patch.object(run_suite, "_run_preflight", return_value=SimpleNamespace(passed=True)):
                result = run_suite.run(args_for(output, resume=True))

            self.assertEqual(result, 0)
            self.assertEqual(completed_calls, ["pending"])
            self.assertEqual({row["task_id"] for row in Checkpoint(output, keys).rows()}, {"done", "pending"})
            history = json.loads((output / "interrupted_attempts.json").read_text())
            self.assertEqual(history[0]["kind"], "abandoned-after-runner-stop")

    def test_generic_infra_stops_suite_and_reports_before_releasing_lock(self) -> None:
        tasks = [sample_task("first"), sample_task("second")]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            server = SimpleNamespace(stopped=False)
            server.terminate = lambda: setattr(server, "stopped", True)
            server.wait = lambda **_kwargs: None
            report_written = []
            executed = []

            class TrackingLifecycle(FakeLifecycle):
                def __exit__(self, *_args):
                    self.assert_order()
                    return None

                def assert_order(self):
                    if not server.stopped or not report_written:
                        raise AssertionError("runner lock released before fixture/report cleanup")

            lifecycle = TrackingLifecycle()

            def blocked(task, *_args, **_kwargs):
                executed.append(task.task_id)
                return "INFRA-BLOCKED (episode evaluation failed)"

            with patch.object(run_suite, "_prepare_run", return_value=(tasks, ["/usr/bin/true"], [], None, output)), \
                 patch("runner_recovery.RunnerLifecycle", return_value=lifecycle), \
                 patch.object(run_suite, "_start_fixture_server", return_value=server), \
                 patch.object(run_suite, "_resolved_default_browser", return_value="org.example.browser"), \
                 patch.object(run_suite, "_close_suite_app_windows"), \
                 patch.object(run_suite, "_fixture_server_available", return_value=True), \
                 patch.object(run_suite, "_run_preflight", return_value=SimpleNamespace(passed=True)), \
                 patch.object(run_suite, "_run_one_task", side_effect=blocked), \
                 patch.object(run_suite, "_write_report", side_effect=lambda *_args: report_written.append(True)):
                result = run_suite.run(args_for(output))

        self.assertEqual(result, 1)
        self.assertEqual(executed, ["first"])
        self.assertTrue(server.stopped)
        self.assertTrue(report_written)

    def test_resume_terminalizes_two_local_interruptions_without_third_attempt(self) -> None:
        task = sample_task("web-paused")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            checkpoint = Checkpoint(output, ["1:web-paused"])
            for number in (1, 2):
                checkpoint.record_interruption({"task_key": "1:web-paused", "task_id": task.task_id,
                    "run": 1, "driver_task_id": f"attempt-{number}", "kind": "local-input",
                    "answer": "Control of the Mac changed during the task.",
                    "episode_path": f"/episodes/attempt-{number}.jsonl", "unsafe_count": 2})

            lifecycle = FakeLifecycle()
            with patch.object(run_suite, "_prepare_run", return_value=([task], ["/usr/bin/true"], [], None, output)), \
                 patch("runner_recovery.RunnerLifecycle", return_value=lifecycle), \
                 patch.object(run_suite, "_start_fixture_server", return_value=None), \
                 patch.object(run_suite, "_run_preflight", side_effect=AssertionError("no task remains to preflight")), \
                 patch.object(run_suite, "_run_one_task", side_effect=AssertionError("third attempt is forbidden")):
                result = run_suite.run(args_for(output, resume=True))

            resumed = Checkpoint(output, ["1:web-paused"])
            self.assertEqual(result, 1)
            self.assertTrue(resumed.is_completed("1:web-paused"))
            row = resumed.rows()[0]
            self.assertEqual(row["status"], "INTERRUPTED")
            self.assertEqual(row["failure_class"], "interrupted-by-local-input")
            self.assertEqual(row["driver_task_id"], "attempt-2")
            self.assertEqual(row["unsafe_count"], 2)

    def test_local_input_interruption_retries_once_and_keeps_attempt_evidence(self) -> None:
        task = sample_task("web-probe")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            key = "1:web-probe"
            checkpoint = Checkpoint(output, [key])
            lifecycle = FakeLifecycle()
            responses = [
                ({"outcome": "handoff", "answer": "AI paused because control of the Mac changed.",
                  "episode_path": "/episodes/interrupted.jsonl", "wall_seconds": 3}, None),
                ({"outcome": "completed", "answer": "ok", "episode_path": "/episodes/retry.jsonl",
                  "wall_seconds": 4}, None),
            ]
            evaluated = [
                ({"task_id": task.task_id, "status": "INFRA-BLOCKED", "success": False,
                  "failure_class": "infra", "unsafe_count": 1, "steps": 1,
                  "episode_path": "/episodes/interrupted.jsonl"}, "INFRA-BLOCKED"),
                ({"task_id": task.task_id, "status": "PASS", "success": True,
                  "failure_class": None, "unsafe_count": 0, "steps": 1,
                  "episode_path": "/episodes/retry.jsonl"}, "PASS"),
            ]
            with patch.object(run_suite, "_run_driver", side_effect=responses) as driver, \
                 patch.object(run_suite, "_evaluate_response", side_effect=evaluated), \
                 patch.object(run_suite, "_write_report"):
                status = run_suite._run_one_task(task, 1, args_for(output), ["driver"], [], None,
                    output, [], checkpoint=checkpoint, task_key=key, lifecycle=lifecycle)

            self.assertEqual(status, "PASS")
            self.assertEqual(driver.call_count, 2)
            self.assertEqual(lifecycle.idle_waits, 1)
            self.assertEqual(checkpoint.rows()[0]["status"], "PASS")
            attempts = json.loads((output / "interrupted_attempts.json").read_text())
            self.assertEqual(len(attempts), 1)
            self.assertEqual(attempts[0]["failure_class"], "interrupted-by-local-input")
            self.assertEqual(attempts[0]["unsafe_count"], 1)

    def test_second_local_input_pause_is_terminal_and_not_infra(self) -> None:
        task = sample_task("web-probe")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            key = "1:web-probe"
            checkpoint = Checkpoint(output, [key])
            response = {"outcome": "handoff", "answer": "AI paused because control of the Mac changed.",
                        "episode_path": "/episodes/interrupted.jsonl", "wall_seconds": 3}
            evaluated = ({"task_id": task.task_id, "status": "INFRA-BLOCKED", "success": False,
                          "failure_class": "infra", "unsafe_count": 0, "steps": 0}, "INFRA-BLOCKED")
            with patch.object(run_suite, "_run_driver", return_value=(response, None)) as driver, \
                 patch.object(run_suite, "_evaluate_response", return_value=evaluated), \
                 patch.object(run_suite, "_write_report"):
                status = run_suite._run_one_task(task, 1, args_for(output), ["driver"], [], None,
                    output, [], checkpoint=checkpoint, task_key=key)

            self.assertEqual(status, "INTERRUPTED (second local-input pause)")
            self.assertEqual(driver.call_count, 2)
            self.assertEqual(checkpoint.rows()[0]["status"], "INTERRUPTED")
            self.assertEqual(checkpoint.rows()[0]["failure_class"], "interrupted-by-local-input")
            history = json.loads((output / "interrupted_attempts.json").read_text())
            self.assertEqual([row["retry_allowed"] for row in history], [True, False])

    def test_driver_blocker_keeps_task_pending_and_records_attempt_identity(self) -> None:
        task = sample_task("web-blocked")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            key = "1:web-blocked"
            checkpoint = Checkpoint(output, [key])
            with patch.object(run_suite, "_run_driver", return_value=(None, "driver invocation failed: TimeoutExpired")), \
                 patch.object(run_suite, "_write_report"):
                status = run_suite._run_one_task(task, 1, args_for(output), ["driver"], [], None,
                    output, [], checkpoint=checkpoint, task_key=key)

            self.assertEqual(status, "INFRA-BLOCKED (driver unavailable)")
            self.assertFalse(checkpoint.is_completed(key))
            self.assertIn(key, checkpoint.inflight)
            blocker = json.loads((output / "blockers.json").read_text())[0]
            self.assertEqual(blocker["kind"], "task-blocked")
            self.assertEqual(blocker["driver_task_id"], checkpoint.inflight[key]["attempt_id"])
            run_suite._resolve_blockers(output, task_key=key)
            resolved = json.loads((output / "blockers.json").read_text())[0]
            self.assertTrue(resolved["resolved"])

    def test_native_setup_exception_records_pending_blocker_without_name_error(self) -> None:
        task = sample_task("native-001", surface="app", setup={"new_untitled": True})
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            scratch = output / "scratch"
            checkpoint = Checkpoint(output, ["1:native-001"])
            with patch.object(run_suite, "_native_scratch_directory", return_value=scratch), \
                 patch.object(run_suite, "_seed_native_task"), \
                 patch.object(run_suite, "_materialize_native_task", return_value=task), \
                 patch("native_start.prepare_textedit_untitled", side_effect=RuntimeError("open panel unavailable")), \
                 patch.object(run_suite, "_cleanup_native_outputs"), \
                 patch.object(run_suite, "_write_report"):
                status = run_suite._run_one_task(task, 1, args_for(output), ["driver"], [], None,
                    output, [], checkpoint=checkpoint, task_key="1:native-001")

            self.assertEqual(status, "INFRA-BLOCKED (open panel unavailable)")
            self.assertFalse(checkpoint.is_completed("1:native-001"))
            self.assertEqual(checkpoint.cleanup_pending(), {})
            blocker = json.loads((output / "blockers.json").read_text())[0]
            self.assertEqual(blocker["kind"], "task-blocked")

    def test_screen_lock_exception_propagates_from_task_boundary(self) -> None:
        task = sample_task("web-blocked")
        class LockedLifecycle(FakeLifecycle):
            def check_screen_unlocked(self):
                raise ScreenLocked("locked")

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            checkpoint = Checkpoint(output, ["1:web-blocked"])
            with self.assertRaises(ScreenLocked):
                run_suite._run_one_task(task, 1, args_for(output), ["driver"], [], None,
                    output, [], checkpoint=checkpoint, task_key="1:web-blocked",
                    lifecycle=LockedLifecycle())

    def test_completed_result_survives_cleanup_failure_for_resume(self) -> None:
        task = sample_task("native-001", surface="app", setup={"new_untitled": True})
        with tempfile.TemporaryDirectory() as home, patch.dict("os.environ", {"HOME": home}):
            output = Path(home) / "output"
            checkpoint = Checkpoint(output, ["1:native-001"])
            lease = {"pid": 123, "window_id": 456}
            native_lease = __import__("native_start").NativeDocumentLease.from_dict(lease)
            response = {"outcome": "completed", "answer": "ok", "episode_path": "/episodes/ok.jsonl",
                        "wall_seconds": 2}
            evaluated = ({"task_id": task.task_id, "run": 1, "status": "PASS", "success": True,
                          "failure_class": None, "unsafe_count": 0, "steps": 1,
                          "tags": ["lifecycle"]}, "PASS")
            with patch.object(run_suite, "_run_driver", return_value=(response, None)), \
                 patch.object(run_suite, "_evaluate_response", return_value=evaluated), \
                 patch("native_start.prepare_textedit_untitled", return_value=native_lease), \
                 patch("native_start.close_textedit_untitled", side_effect=RuntimeError("close failed")), \
                 patch.object(run_suite, "_write_report"):
                status = run_suite._run_one_task(task, 1, args_for(output), ["driver"], [], None,
                    output, [], checkpoint=checkpoint, task_key="1:native-001")

            self.assertEqual(status, "INFRA-BLOCKED (native fixture cleanup failed)")
            self.assertEqual(checkpoint.rows()[0]["status"], "PASS")
            self.assertEqual(checkpoint.cleanup_pending()["1:native-001"]["lease"], lease)

            lifecycle = FakeLifecycle()
            with patch.object(run_suite, "_prepare_run", return_value=([task], ["/usr/bin/true"], [], None, output)), \
                 patch("runner_recovery.RunnerLifecycle", return_value=lifecycle), \
                 patch("native_start.close_textedit_untitled") as close, \
                 patch.object(run_suite, "_cleanup_native_outputs") as cleanup, \
                 patch.object(run_suite, "_run_one_task") as execute:
                result = run_suite.run(args_for(output, resume=True))

            self.assertEqual(result, 0)
            close.assert_called_once()
            cleanup.assert_called_once()
            execute.assert_not_called()
            resumed_checkpoint = Checkpoint(output, ["1:native-001"])
            self.assertEqual(resumed_checkpoint.cleanup_pending(), {})
            self.assertEqual(resumed_checkpoint.rows()[0]["status"], "PASS")

    def test_report_separates_interrupted_attempts_and_keeps_unsafe_count(self) -> None:
        from report import write_report

        row = {"task_id": "interrupted", "status": "INTERRUPTED", "success": False,
               "failure_class": "interrupted-by-local-input", "unsafe_count": 2,
               "tags": ["lifecycle"], "steps": 1, "policy": "fara15-4b"}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "interrupted_attempts.json").write_text(json.dumps([
                {"task_id": "interrupted", "kind": "local-input", "unsafe_count": 3},
                {"task_id": "interrupted-unknown", "kind": "local-input"},
                {"task_id": "crashed", "kind": "abandoned-after-runner-stop", "unsafe_count": 1},
                {"task_id": "crashed-unknown", "kind": "abandoned-after-runner-stop"},
            ]))
            (output / "blockers.json").write_text(json.dumps([
                {"kind": "runner-blocked", "owner_action": "Unlock the Mac"},
                {"kind": "task-blocked", "owner_action": "Retry old task", "resolved": True}
            ]))
            write_report(output, [row], "real-host")
            metadata = json.loads((output / "run_metadata.json").read_text())
            summary = json.loads((output / "by_skill.json").read_text())["lifecycle"]

        self.assertEqual(metadata["evaluated_task_runs"], 0)
        self.assertEqual(metadata["interrupted_task_runs"], 1)
        self.assertEqual(metadata["interrupted_attempts"], 2)
        self.assertEqual(metadata["interrupted_unsafe_count"], 3)
        self.assertEqual(metadata["interrupted_unsafe_sample_count"], 1)
        self.assertEqual(metadata["interrupted_unsafe_unknown_count"], 1)
        self.assertEqual(metadata["abandoned_runner_attempts"], 2)
        self.assertEqual(metadata["abandoned_runner_unsafe_count"], 1)
        self.assertEqual(metadata["abandoned_runner_unsafe_sample_count"], 1)
        self.assertEqual(metadata["abandoned_runner_unsafe_unknown_count"], 1)
        self.assertEqual(metadata["owner_actions"], ["Unlock the Mac"])
        self.assertEqual(len(metadata["active_blockers"]), 1)
        self.assertEqual(len(metadata["blockers"]), 2)
        self.assertEqual(summary["tasks"], 0)
        self.assertEqual(summary["interrupted"], 1)
        self.assertEqual(summary["interrupted_unsafe_count"], 2)


if __name__ == "__main__":
    unittest.main()
