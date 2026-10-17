from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from runner_recovery import (
    Checkpoint,
    MacStateUnknown,
    RecoveryError,
    RunnerAlreadyActive,
    RunnerLifecycle,
    ScreenLocked,
    is_local_input_interruption,
    _command_for_checkpoint,
    pin_run_identity,
    supervise,
)


class FakeProcess:
    def __init__(self, code: int | None = None) -> None:
        self.code = code
        self.terminated = False
        self.killed = False
        self.waited = False

    def poll(self):
        return self.code

    def terminate(self):
        self.terminated = True

    def wait(self, timeout=None):
        self.waited = True
        if timeout is not None and getattr(self, "timeouts", 0) > 0:
            self.timeouts -= 1
            from subprocess import TimeoutExpired
            raise TimeoutExpired("fake", timeout)
        return self.code or 0

    def kill(self):
        self.killed = True


class RecoveryTests(unittest.TestCase):
    def test_lock_and_caffeinate_child_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            child = FakeProcess()
            create = Mock(return_value=child)
            lifecycle = RunnerLifecycle(Path(directory), popen=create,
                                        screen_probe=lambda: True, idle_probe=lambda: 60,
                                        global_lock=False)
            with lifecycle:
                self.assertTrue((Path(directory) / ".runner.lock").exists())
                with self.assertRaises(RunnerAlreadyActive):
                    with RunnerLifecycle(Path(directory), popen=Mock(), global_lock=False):
                        pass
            self.assertEqual(create.call_args.args[0], ["/usr/bin/caffeinate", "-dimsu", "-w", str(__import__("os").getpid())])
            self.assertTrue(child.terminated)
            self.assertTrue(child.waited)
            self.assertEqual(lifecycle._lock_streams, [])

    def test_global_lock_prevents_two_real_host_outputs_running_together(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch("runner_recovery.tempfile.gettempdir", return_value=directory):
                first = RunnerLifecycle(Path(directory) / "first", popen=Mock(return_value=FakeProcess()))
                second = RunnerLifecycle(Path(directory) / "second", popen=Mock())
                with first:
                    with self.assertRaises(RunnerAlreadyActive):
                        with second:
                            pass

    def test_caffeinate_timeout_is_killed_during_teardown(self):
        with tempfile.TemporaryDirectory() as directory:
            child = FakeProcess()
            child.timeouts = 1
            with RunnerLifecycle(Path(directory), popen=Mock(return_value=child), global_lock=False):
                pass
            self.assertTrue(child.terminated)
            self.assertTrue(child.killed)

    def test_failed_caffeinate_start_releases_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RecoveryError):
                with RunnerLifecycle(Path(directory), popen=Mock(return_value=FakeProcess(1)), global_lock=False):
                    pass
            with RunnerLifecycle(Path(directory), popen=Mock(return_value=FakeProcess()),
                                 screen_probe=lambda: True, idle_probe=lambda: 60,
                                 global_lock=False):
                pass

    def test_screen_lock_and_unknown_state_fail_closed_before_task(self):
        with tempfile.TemporaryDirectory() as directory:
            lifecycle = RunnerLifecycle(Path(directory), popen=Mock(return_value=FakeProcess()),
                                        screen_probe=lambda: False, global_lock=False)
            with lifecycle:
                with self.assertRaises(ScreenLocked):
                    lifecycle.check_screen_unlocked()
            lifecycle = RunnerLifecycle(Path(directory), popen=Mock(return_value=FakeProcess()),
                screen_probe=lambda: (_ for _ in ()).throw(RuntimeError("probe")),
                global_lock=False)
            with lifecycle:
                with self.assertRaises(MacStateUnknown):
                    lifecycle.check_screen_unlocked()

    def test_idle_wait_requires_contiguous_60_second_hid_idle(self):
        samples = iter([4.0, 58.0, 60.0])
        events = []
        with tempfile.TemporaryDirectory() as directory:
            lifecycle = RunnerLifecycle(Path(directory), popen=Mock(return_value=FakeProcess()),
                screen_probe=lambda: events.append("screen") or True,
                idle_probe=lambda: next(samples), sleep=lambda seconds: events.append(seconds),
                global_lock=False)
            with lifecycle:
                lifecycle.wait_for_local_idle()
        self.assertEqual(events, ["screen", 56.0, "screen", 2.0, "screen"])

    def test_locked_mac_during_idle_wait_stops_instead_of_waiting(self):
        with tempfile.TemporaryDirectory() as directory:
            lifecycle = RunnerLifecycle(Path(directory), popen=Mock(return_value=FakeProcess()),
                screen_probe=lambda: (_ for _ in ()).throw(ScreenLocked("locked")),
                global_lock=False)
            with lifecycle:
                with self.assertRaises(ScreenLocked):
                    lifecycle.wait_for_local_idle()

    def test_interruption_retry_is_once_and_original_attempts_are_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Checkpoint(Path(directory), ["1:n001"])
            self.assertTrue(checkpoint.record_interruption({
                "task_key": "1:n001", "episode_path": "/episodes/first.jsonl", "answer": "paused"
            }))
            self.assertFalse(checkpoint.record_interruption({
                "task_key": "1:n001", "episode_path": "/episodes/retry.jsonl", "answer": "paused"
            }))
            restored = Checkpoint(Path(directory), ["1:n001"])
            self.assertEqual([row["episode_path"] for row in restored.interrupted_attempts],
                             ["/episodes/first.jsonl", "/episodes/retry.jsonl"])
            self.assertEqual([row["retry_allowed"] for row in restored.interrupted_attempts], [True, False])
            self.assertFalse(restored.is_completed("1:n001"))
            self.assertEqual(restored.pending_local_input_decision("1:n001"), "terminal-interrupted")

    def test_atomic_checkpoint_restores_completed_and_inflight_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Checkpoint(Path(directory), ["1:first", "1:second"])
            checkpoint.mark_completed("1:first", {"task_id": "first", "status": "PASS"})
            checkpoint.mark_inflight("1:second", "attempt-2")
            restored = Checkpoint(Path(directory), ["1:first", "1:second"])
            self.assertTrue(restored.is_completed("1:first"))
            self.assertFalse(restored.is_completed("1:second"))
            abandoned = restored.record_abandoned_inflight()
            self.assertEqual(abandoned[0]["task_key"], "1:second")
            again = Checkpoint(Path(directory), ["1:first", "1:second"])
            self.assertTrue(again.is_completed("1:first"))
            self.assertFalse(again.is_completed("1:second"))
            self.assertEqual(again.interrupted_attempts[0]["kind"], "abandoned-after-runner-stop")
            self.assertTrue(again.record_interruption({"task_key": "1:second", "episode_path": "retry.jsonl"}))

    def test_cleanup_pending_resumes_without_replaying_or_completing_task(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Checkpoint(Path(directory), ["task"])
            checkpoint.mark_cleanup_pending("task", {"kind": "native_windows", "app": "TextEdit"})
            restored = Checkpoint(Path(directory), ["task"])
            self.assertFalse(restored.is_completed("task"))
            self.assertEqual(restored.cleanup_pending(), {
                "task": {"kind": "native_windows", "app": "TextEdit"}})
            restored.clear_cleanup_pending("task")
            self.assertEqual(Checkpoint(Path(directory), ["task"]).cleanup_pending(), {})

    def test_checkpoint_refuses_changed_task_sequence_and_does_not_skip_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            Checkpoint(Path(directory), ["a", "b"]).mark_completed("a", {"status": "PASS"})
            with self.assertRaises(RecoveryError):
                Checkpoint(Path(directory), ["b", "a"])
            restored = Checkpoint(Path(directory), ["a", "b"])
            self.assertEqual([row["status"] for row in restored.rows()], ["PASS"])

    def test_local_input_classifier_is_specific_and_not_model_failure(self):
        self.assertTrue(is_local_input_interruption({"outcome": "paused",
            "answer": "AI paused because control of the Mac changed."}))
        self.assertFalse(is_local_input_interruption({"outcome": "failed", "answer": "model timed out"}))
        self.assertTrue(is_local_input_interruption({}, {"checker": {
            "reason": "AI paused because control of the Mac changed."}}))

    def test_identity_pins_driver_tasks_and_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "driver"
            binary.write_text("version one")
            output = Path(directory) / "output"
            first = pin_run_identity(output, [str(binary)], [{"id": "a"}], "fara15-4b")
            self.assertEqual(first["policy"], "fara15-4b")
            self.assertEqual(pin_run_identity(output, [str(binary)], [{"id": "a"}], "fara15-4b"), first)
            with self.assertRaisesRegex(RecoveryError, "changed"):
                pin_run_identity(output, [str(binary)], [{"id": "b"}], "fara15-4b")

    def test_supervisor_restarts_partial_checkpoint_then_stops_on_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            checkpoint = Checkpoint(output, ["a", "b"])
            results = iter([SimpleNamespace(returncode=1), SimpleNamespace(returncode=1)])

            def run(_command, _timeout=None):
                result = next(results)
                if not checkpoint.is_completed("a"):
                    checkpoint.mark_completed("a", {"status": "INFRA-BLOCKED"})
                else:
                    checkpoint.mark_completed("b", {"status": "INFRA-BLOCKED"})
                return result

            sleeps = []
            code = supervise(["suite"], log_stream=io.StringIO(), output=output,
                             run=run, screen_probe=lambda: True, sleep=sleeps.append)
            self.assertEqual(code, 1)
            self.assertEqual(len(sleeps), 1)
            self.assertEqual(len(checkpoint.rows()), 2)

    def test_supervisor_pins_child_output_and_adds_resume_only_after_checkpoint_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run"
            calls = []
            checkpoint = Checkpoint(output, ["a", "b"])

            def run(command, _timeout=None):
                calls.append(command)
                self.assertEqual(command[-2:], ["--output", str(output.resolve())]
                                 if len(calls) == 1 else [str(output.resolve()), "--resume"])
                if len(calls) == 1:
                    checkpoint.mark_completed("a", {"status": "INFRA-BLOCKED"})
                else:
                    checkpoint.mark_completed("b", {"status": "INFRA-BLOCKED"})
                return SimpleNamespace(returncode=1)

            code = supervise(["python", "eval/run_suite.py", "--suite", "smoke"],
                             log_stream=io.StringIO(), output=output, run=run,
                             screen_probe=lambda: True, sleep=lambda _: None)
            self.assertEqual(code, 1)
            self.assertEqual(len(calls), 2)
            self.assertNotIn("--resume", calls[0])
            self.assertIn("--resume", calls[1])

    def test_supervisor_child_output_must_match_and_resume_flag_can_start_fresh(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "fresh"
            child = _command_for_checkpoint(["python", "run_suite.py", "--resume"], output)
            self.assertEqual(child[-2:], ["--output", str(output.resolve())])
            with self.assertRaisesRegex(RecoveryError, "must match"):
                _command_for_checkpoint(["python", "run_suite.py", "--output", str(Path(directory) / "other")],
                                        output)

    def test_supervisor_waits_for_unlock_then_resumes_and_deadline_is_bounded(self):
        states = iter([ScreenLocked("locked"), True])
        runs = []
        sleeps = []
        code = supervise(["suite"], log_stream=io.StringIO(), max_restarts=1,
            run=lambda *_args, **_kwargs: runs.append(1) or SimpleNamespace(returncode=0),
            screen_probe=lambda: (lambda state: (_ for _ in ()).throw(state)
                                  if isinstance(state, Exception) else state)(next(states)),
            sleep=sleeps.append)
        self.assertEqual(code, 0)
        self.assertEqual(len(runs), 1)
        self.assertEqual(len(sleeps), 1)


if __name__ == "__main__":
    unittest.main()
