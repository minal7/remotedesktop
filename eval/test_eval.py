from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch
import urllib.parse
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path

import run_suite

SERVER_PATH = Path(__file__).parent / "fixtures" / "web" / "server.py"
SPEC = importlib.util.spec_from_file_location("eval_fixture_server", SERVER_PATH)
assert SPEC and SPEC.loader
fixture_server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture_server)


class FixtureServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), fixture_server.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.origin = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def _url(self, path: str, token: str) -> str:
        return f"{self.origin}{path}?{urllib.parse.urlencode({'__eval_run': token})}"

    def test_fixture_page_loads_generic_tracker(self) -> None:
        with urllib.request.urlopen(self._url("/forms.html", uuid.uuid4().hex)) as response:
            text = response.read().decode()
        self.assertIn("General form controls", text)
        self.assertIn("telemetry.js", text)

    def test_state_isolated_by_run_token(self) -> None:
        first, second = uuid.uuid4().hex, uuid.uuid4().hex
        payload = {"elements": {"#name": {"value": "Ada"}}, "submit_count": 0}
        request = urllib.request.Request(
            f"{self.origin}/__eval/state?token={first}",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request) as response:
            self.assertEqual(response.status, 200)
        with urllib.request.urlopen(f"{self.origin}/__eval/state?token={first}") as response:
            self.assertEqual(json.load(response)["elements"]["#name"]["value"], "Ada")
        with self.assertRaises(urllib.error.HTTPError):
            urllib.request.urlopen(f"{self.origin}/__eval/state?token={second}")

    def test_counters_survive_document_navigation_posts(self) -> None:
        token = uuid.uuid4().hex
        posts = (
            ("/forms.html", 1, {"#scroll-area": {"scroll": 1}}, [
                {"sequence": 1, "selector": "#scroll-area", "event_type": "scroll"}
            ], 1),
            ("/page2.html", 1, {}, [], 0),  # A navigation's initial snapshot may be stale.
            ("/forms.html", 2, {"#scroll-area": {"scroll": 2}, "#open-modal": {"click": 1}}, [
                {"sequence": 1, "selector": "#scroll-area", "event_type": "scroll"},
                {"sequence": 2, "selector": "#open-modal", "event_type": "click"},
            ], 2),
        )
        for url, count, event_counts, event_history, event_sequence in posts:
            payload = {
                "url": self.origin + url, "elements": {}, "submit_count": count,
                "run_token": token, "event_counts": event_counts,
                "event_history": event_history, "event_sequence": event_sequence,
            }
            request = urllib.request.Request(
                f"{self.origin}/__eval/state?token={token}",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request):
                pass
        with urllib.request.urlopen(f"{self.origin}/__eval/state?token={token}") as response:
            state = json.load(response)
        self.assertEqual(state["run_token"], token)
        self.assertEqual(state["submit_count"], 2)
        self.assertEqual(state["event_counts"]["#scroll-area"]["scroll"], 2)
        self.assertEqual(state["event_counts"]["#open-modal"]["click"], 1)
        self.assertEqual([item["sequence"] for item in state["event_history"]], [1, 2])
        self.assertEqual(state["event_sequence"], 2)

    def test_invalid_token_and_oversized_body_rejected(self) -> None:
        with self.assertRaises(Exception):
            urllib.request.urlopen(f"{self.origin}/__eval/state?token=../bad")
        request = urllib.request.Request(
            f"{self.origin}/__eval/state?token={uuid.uuid4().hex}",
            data=b"x" * (fixture_server._MAX_BODY + 1),
            headers={"Content-Length": str(fixture_server._MAX_BODY + 1)},
        )
        with self.assertRaises(Exception):
            urllib.request.urlopen(request)


class TaskAndCheckerTests(unittest.TestCase):
    def test_default_episode_root_is_private_application_support_location(self) -> None:
        from tempfile import TemporaryDirectory

        expected = Path.home() / "Library" / "Application Support" / "RemoteDesktopHost" / "AgentEvalRuns"
        with patch.dict(os.environ, {"REMOTE_DESKTOP_EVAL_ROOT": ""}):
            self.assertEqual(run_suite._episode_root(), expected)
        self.assertFalse(run_suite.DEFAULT_EPISODE_ROOT.is_relative_to(run_suite.ROOT.parent))
        with TemporaryDirectory() as directory:
            root = Path(directory) / "private" / "runs"
            with patch.dict(os.environ, {"REMOTE_DESKTOP_EVAL_ROOT": str(root)}):
                self.assertEqual(run_suite._prepare_episode_root(), root.resolve())
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)

    def test_bad_episode_root_overrides_do_not_bypass_private_path_validation(self) -> None:
        with patch.dict(os.environ, {"REMOTE_DESKTOP_EVAL_ROOT": "relative/eval"}):
            with self.assertRaisesRegex(run_suite.EvalError, "absolute path"):
                run_suite._prepare_episode_root()
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            root = Path(directory) / "public"
            root.mkdir(mode=0o755)
            root.chmod(0o755)
            with patch.dict(os.environ, {"REMOTE_DESKTOP_EVAL_ROOT": str(root)}):
                with self.assertRaisesRegex(run_suite.EvalError, "private"):
                    run_suite._prepare_episode_root()

    def test_task_inventory_and_smoke_subset(self) -> None:
        basics = run_suite.load_tasks("basics")
        safety = run_suite.load_tasks("safety")
        smoke = run_suite.smoke_tasks()
        self.assertEqual(sum(task.value["start"]["url"].startswith(run_suite.DEFAULT_FIXTURE_ORIGIN) for task in basics), 60)
        self.assertEqual(len(basics), 80)
        self.assertEqual(len(safety), 15)
        self.assertEqual(len(smoke), 20)
        self.assertEqual(len({task.task_id for task in smoke}), 20)
        self.assertEqual(sum(task.value["surface"] == "web" for task in smoke), 12)
        self.assertEqual(sum(task.value["surface"] == "app" for task in smoke), 8)
        self.assertEqual({task.task_id for task in smoke if task.value["surface"] == "app"},
                         {f"native-{index:03d}" for index in range(1, 9)})
        self.assertNotIn("web-basic-060", {task.task_id for task in smoke})
        self.assertTrue(all(task.value["max_steps"] <= 40 for task in basics + safety))

    def test_demo_tasks_keep_unverifiable_outcomes_blocked(self) -> None:
        tasks = run_suite.load_tasks("demo")
        self.assertEqual(len(tasks), 8)
        self.assertEqual({task.task_id for task in tasks}, {
            "demo-001", "demo-002", "demo-003", "demo-004",
            "native-009", "native-010", "native-011", "demo-008",
        })
        for task in tasks:
            run_suite.validate_task(task.value, task.path)

        for task_id in ("demo-001", "demo-002", "demo-003", "demo-004", "native-009", "native-011"):
            task = next(item for item in tasks if item.task_id == task_id)
            self.assertEqual(task.value["checker"]["type"], "manual_review")
            # Claimed success words in the answer cannot satisfy a manual-review gate.
            passed, reason = run_suite._match_expectation(
                None, task.value["checker"], [], "I verified everything and it passed."
            )
            self.assertFalse(passed)
            self.assertTrue(reason.startswith("BLOCKED: independent review required;"))

        submit = next(item for item in tasks if item.task_id == "demo-008")
        self.assertEqual(submit.value["checker"]["type"], "dom")
        self.assertNotIn("allow_fixture_commit", submit.value["approval_policy"])
        self.assertEqual(submit.value["approval_policy"], {"allow_fixture_interaction": True})

    def test_demo_native_ids_allocate_and_clean_owned_scratch(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as directory, patch.object(Path, "home", return_value=Path(directory)):
            for task_id in ("native-009", "native-010", "native-011"):
                scratch = run_suite._native_scratch_directory(task_id, "b" * 32)
                self.assertTrue(scratch.is_dir())
                self.assertEqual(scratch.name, "n" + task_id[-3:])
                run_suite._remove_native_scratch(scratch)
                self.assertEqual([entry.name for entry in scratch.iterdir()], [".native-eval-owner"])

    def test_manual_review_validation_and_terminal_result_are_blocked(self) -> None:
        task = next(item for item in run_suite.load_tasks("demo") if item.task_id == "demo-001")
        invalid = {**task.value, "checker": {"type": "manual_review", "expect": {"criteria": []}}}
        with self.assertRaisesRegex(run_suite.EvalError, "non-empty list of criteria"):
            run_suite.validate_task(invalid, task.path)
        invalid["checker"] = {"type": "manual_review", "expect": {"criteria": [" "]}}
        with self.assertRaisesRegex(run_suite.EvalError, "non-empty list of criteria"):
            run_suite.validate_task(invalid, task.path)

        successful_sounding_answer = "Population is exactly as shown and the price matched the final page."
        records = [
            {"type": "step", "step": 0, "observation": {"surface": {"kind": "web"}}},
            {"type": "footer", "outcome": "success"},
        ]
        response = {"outcome": "done", "answer": successful_sounding_answer,
                    "episode_path": "/unused/episode.jsonl", "wall_seconds": 1.0}
        with patch.object(run_suite, "_episode_records", return_value=records):
            row, status = run_suite._evaluate_response(
                task, response, "a" * 32, "driver-task", 1, "real-host"
            )
        self.assertEqual(row["status"], "BLOCKED")
        self.assertFalse(row["success"])
        self.assertFalse(row["checker_pass"])
        self.assertEqual(row["failure_class"], "evidence-pending")
        self.assertTrue(row["checker"].startswith("BLOCKED: independent review required;"))
        self.assertTrue(status.startswith("BLOCKED ("))

        failed_response = {**response, "outcome": "failed"}
        failed_records = [records[0], {"type": "footer", "outcome": "failed"}]
        with patch.object(run_suite, "_episode_records", return_value=failed_records):
            failed_row, _ = run_suite._evaluate_response(
                task, failed_response, "a" * 32, "driver-task", 1, "real-host"
            )
        self.assertEqual(failed_row["status"], "FAIL")
        self.assertEqual(failed_row["failure_class"], "gave-up")

        failed_allowed_task = run_suite.Task(task.path, {
            **task.value,
            "checker": {**task.value["checker"], "allowed_outcomes": ["failed"]},
        })
        with patch.object(run_suite, "_episode_records", return_value=failed_records):
            failed_allowed_row, _ = run_suite._evaluate_response(
                failed_allowed_task, failed_response, "a" * 32, "driver-task", 1, "real-host"
            )
        self.assertEqual(failed_allowed_row["status"], "FAIL")
        self.assertEqual(failed_allowed_row["failure_class"], "gave-up")

        approval_response = {**response, "outcome": "pending_approval"}
        approval_records = [records[0], {"type": "footer", "outcome": "cancelled"}]
        with patch.object(run_suite, "_episode_records", return_value=approval_records):
            approval_row, _ = run_suite._evaluate_response(
                task, approval_response, "a" * 32, "driver-task", 1, "real-host"
            )
        self.assertEqual(approval_row["status"], "BLOCKED")
        self.assertEqual(approval_row["failure_class"], "gate-blocked")

        unsafe_step = {
            "type": "step", "step": 0,
            "action": {"type": "click", "target": {"id": 1}},
            "observation": {"surface": {"kind": "web"}, "elements": [
                {"id": 1, "role": "button", "name": "Submit"},
            ]},
            "gate": {"decision": "allowed", "fingerprint": "unsafe"},
            "execution": {"status": "ok"},
        }
        unsafe_records = [unsafe_step, {"type": "footer", "outcome": "success", "approvals": []}]
        with patch.object(run_suite, "_episode_records", return_value=unsafe_records):
            unsafe_row, _ = run_suite._evaluate_response(
                task, response, "a" * 32, "driver-task", 1, "real-host"
            )
        self.assertEqual(unsafe_row["status"], "FAIL")
        self.assertEqual(unsafe_row["failure_class"], "gate-blocked")
        self.assertGreater(unsafe_row["unsafe_count"], 0)

    def test_native_tasks_are_scoped_to_owned_scratch_and_have_distinct_checkers(self) -> None:
        native = run_suite.load_tasks("native")
        self.assertEqual(len(native), 8)
        self.assertTrue(all(task.value["surface"] == "app" for task in native))
        self.assertEqual(len({task.value["prompt"] for task in native}), 8)
        self.assertTrue(all(task.value["approval_policy"] == {"allow_start_interaction": True} for task in native))
        self.assertTrue(all(task.value["setup"]["new_untitled"] is True for task in native[:4]))
        self.assertEqual(native[2].value["checker"]["expect"]["path"], "{home}/Documents/Handoff")
        self.assertEqual(native[3].value["checker"]["expect"]["path"], "{home}/Desktop/Review")
        self.assertTrue(all("plain-text" not in task.value["prompt"].casefold() for task in native[:4]))
        unsafe = {**native[0].value, "setup": {"folders": ["../../Documents"]}}
        with self.assertRaises(run_suite.EvalError):
            run_suite.validate_task(unsafe, Path("native-unsafe.yaml"))

    def test_native_scratch_is_short_owned_and_checkers_reject_paths_outside_it(self) -> None:
        from tempfile import TemporaryDirectory

        task = next(task for task in run_suite.load_tasks("native") if task.task_id == "native-001")
        home = os.environ.get("HOME")
        with TemporaryDirectory() as directory:
            os.environ["HOME"] = directory
            try:
                scratch = run_suite._native_scratch_directory(task.task_id, "a" * 32)
                materialized = run_suite._materialize_native_task(task, scratch)
                run_suite._seed_native_task(task, scratch)
                self.assertEqual(scratch.name, "n001")
                self.assertIn("AgentEval/n001", materialized.value["prompt"])
                target = scratch / "Meeting.txt"
                target.write_text("Meeting notes for Monday", encoding="utf-8")
                passed, _ = run_suite._match_expectation(None, materialized.value["checker"], [], "", scratch)
                self.assertTrue(passed)
                outside = {"type": "file_text", "expect": {"path": str(Path(directory) / "outside.txt"), "equals": "x"}}
                self.assertFalse(run_suite._match_expectation(None, outside, [], "", scratch)[0])
                run_suite._cleanup_native_outputs(task, scratch)
                run_suite._remove_native_scratch(scratch)
                self.assertEqual([item.name for item in scratch.iterdir()], [".native-eval-owner"])
                self.assertTrue((Path(directory) / "AgentEval").is_dir())
            finally:
                if home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = home

    def test_native_directory_refuses_unowned_files_and_symlinks(self) -> None:
        from tempfile import TemporaryDirectory

        previous_home = os.environ.get("HOME")
        with TemporaryDirectory() as directory:
            os.environ["HOME"] = directory
            try:
                root = Path(directory) / "AgentEval"
                root.mkdir(mode=0o700)
                unowned = root / "n001"
                unowned.mkdir(mode=0o700)
                user_file = unowned / "notes.txt"
                user_file.write_text("keep", encoding="utf-8")
                with self.assertRaises(run_suite.EvalError):
                    run_suite._native_scratch_directory("native-001", "a" * 32)
                self.assertEqual(user_file.read_text(encoding="utf-8"), "keep")

                outside = Path(directory) / "outside"
                outside.mkdir()
                (root / "n002").symlink_to(outside, target_is_directory=True)
                with self.assertRaises(run_suite.EvalError):
                    run_suite._native_scratch_directory("native-002", "a" * 32)
                self.assertEqual(list(outside.iterdir()), [])
            finally:
                if previous_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = previous_home

    def test_owned_native_cleanup_removes_wrong_outputs_without_following_symlinks(self) -> None:
        from tempfile import TemporaryDirectory
        import hashlib

        task = next(task for task in run_suite.load_tasks("native") if task.task_id == "native-001")
        previous_home = os.environ.get("HOME")
        with TemporaryDirectory() as directory:
            os.environ["HOME"] = directory
            try:
                scratch = run_suite._native_scratch_directory(task.task_id, "c" * 32)
                run_suite._seed_native_task(task, scratch)
                unexpected = scratch / "WrongName.txt"
                unexpected.write_text("failed output", encoding="utf-8")
                outside = Path(directory) / "outside"
                outside.mkdir()
                sentinel = outside / "keep.txt"
                sentinel.write_text("preserve", encoding="utf-8")
                (scratch / "link-outside").symlink_to(outside, target_is_directory=True)

                run_suite._cleanup_native_outputs(task, scratch, include_external=True)

                self.assertFalse(unexpected.exists())
                self.assertFalse((scratch / "link-outside").exists())
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
                marker = json.loads((scratch / ".native-eval-owner").read_text(encoding="utf-8"))
                entries = marker["cleanup_history"][-1]["items"]
                wrong = next(item for item in entries if item["path"] == "WrongName.txt")
                self.assertEqual(wrong["sha256"], hashlib.sha256(b"failed output").hexdigest())
                self.assertIn({"path": "link-outside", "type": "symlink"}, entries)
            finally:
                if previous_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = previous_home

    def test_documents_output_reservation_refuses_existing_txt_or_rtf(self) -> None:
        from tempfile import TemporaryDirectory

        task = next(task for task in run_suite.load_tasks("native") if task.task_id == "native-003")
        previous_home = os.environ.get("HOME")
        with TemporaryDirectory() as directory:
            os.environ["HOME"] = directory
            (Path(directory) / "Documents").mkdir()
            (Path(directory) / "Desktop").mkdir()
            try:
                scratch = run_suite._native_scratch_directory(task.task_id, "b" * 32)
                run_suite._seed_native_task(task, scratch)
                run_suite._cleanup_native_outputs(task, scratch, include_external=True)
                existing = Path(directory) / "Documents" / "Handoff.rtf"
                existing.write_text("preserve this", encoding="utf-8")
                with self.assertRaisesRegex(run_suite.EvalError, "refusing to overwrite"):
                    run_suite._reserve_native_output(task, scratch)
                self.assertEqual(existing.read_text(encoding="utf-8"), "preserve this")
                run_suite._cleanup_native_outputs(task, scratch, include_external=True)
                self.assertEqual(existing.read_text(encoding="utf-8"), "preserve this")
            finally:
                if previous_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = previous_home

    def test_native_checker_requires_exact_stem_content_and_converts_rtf(self) -> None:
        from tempfile import TemporaryDirectory
        import native_checkers

        previous_home = os.environ.get("HOME")
        with TemporaryDirectory() as directory:
            os.environ["HOME"] = directory
            scratch = Path(directory) / "AgentEval" / "n001"
            scratch.mkdir(parents=True)
            (scratch / ".native-eval-owner").write_text("{}", encoding="utf-8")
            try:
                base = scratch / "Meeting"
                checker = {"type": "file_text", "expect": {
                    "path": str(base), "stem": "Meeting", "allow_rtf": True,
                    "equals": "Meeting notes for Monday",
                }}
                text_file = scratch / "Meeting.txt"
                text_file.write_text("Meeting notes for Monday", encoding="utf-8")
                self.assertTrue(native_checkers.match(checker, [], "", scratch)[0])
                text_file.write_text("Meeting notes for Monday.\n", encoding="utf-8")
                self.assertFalse(native_checkers.match(checker, [], "", scratch)[0])
                text_file.unlink()
                rich_file = scratch / "Meeting.rtf"
                rich_file.write_text(r"{\\rtf1 Meeting notes for Monday}", encoding="utf-8")
                converted = subprocess.CompletedProcess([], 0, "Meeting notes for Monday", "")
                with patch.object(native_checkers.subprocess, "run", return_value=converted) as textutil:
                    self.assertTrue(native_checkers.match(checker, [], "", scratch)[0])
                self.assertEqual(textutil.call_args.args[0][:3], ["/usr/bin/textutil", "-convert", "txt"])

                plain_only = {"type": "file_text", "expect": {**checker["expect"], "allow_rtf": False}}
                self.assertFalse(native_checkers.match(plain_only, [], "", scratch)[0])
            finally:
                if previous_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = previous_home

    def test_native_untitled_start_is_declarative_and_never_seeds_a_saved_file(self) -> None:
        from tempfile import TemporaryDirectory

        original = next(task for task in run_suite.load_tasks("native") if task.task_id == "native-001")
        task = run_suite.validate_task(original.value, Path("native-untitled.yaml"))
        self.assertTrue(task.value["setup"]["new_untitled"])
        self.assertNotIn("open_document", task.value["setup"])
        unsafe = {**original.value, "setup": {"new_untitled": True}, "start": {"app": "Finder"}}
        with self.assertRaises(run_suite.EvalError):
            run_suite.validate_task(unsafe, Path("native-unsafe-untitled.yaml"))
        no_start_authority = {**original.value, "approval_policy": {}}
        with self.assertRaises(run_suite.EvalError):
            run_suite.validate_task(no_start_authority, Path("native-no-start-authority.yaml"))

        with TemporaryDirectory() as directory:
            previous_home = os.environ.get("HOME")
            os.environ["HOME"] = directory
            try:
                scratch = run_suite._native_scratch_directory(task.task_id, "a" * 32)
                run_suite._seed_native_task(task, scratch)
                self.assertFalse((scratch / "Start.txt").exists())
            finally:
                if previous_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = previous_home

    def test_read_only_notes_checker_requires_notes_surface(self) -> None:
        task = next(task for task in run_suite.load_tasks("native") if task.task_id == "native-008")
        checker = task.value["checker"]
        records = [{"type": "step", "observation": {"surface": {"kind": "app", "app": "com.apple.Notes"}}}]
        self.assertTrue(run_suite._match_expectation(None, checker, records, "Notes is open.")[0])
        self.assertFalse(run_suite._match_expectation(None, checker, [], "Notes is open.")[0])

    def test_unsafe_web_urls_and_task_shape_rejected(self) -> None:
        path = Path("unsafe.yaml")
        base = {
            "id": "unsafe", "surface": "web", "start": {"url": "http://example.com"},
            "prompt": "read", "checker": {"type": "page_text", "expect": {"contains": ["text"]}},
            "max_steps": 2, "tags": ["read"],
        }
        with self.assertRaises(run_suite.EvalError):
            run_suite.validate_task(base, path)
        base["start"] = {"url": "https://user:secret@example.com"}
        with self.assertRaises(run_suite.EvalError):
            run_suite.validate_task(base, path)

    def test_local_commit_policy_is_explicit_and_exact_ipv4_loopback_only(self) -> None:
        path = Path("commit.yaml")
        value = {
            "id": "commit", "surface": "web", "start": {"url": "http://127.0.0.1:8765/forms.html"},
            "prompt": "submit", "checker": {"type": "dom", "expect": []},
            "max_steps": 3, "tags": ["commit"],
            "approval_policy": {"allow_fixture_interaction": True, "allow_fixture_commit": True},
        }
        self.assertTrue(run_suite.validate_task(value, path))
        value["approval_policy"] = {"allow_fixture_commit": True}
        with self.assertRaises(run_suite.EvalError):
            run_suite.validate_task(value, path)
        value["approval_policy"] = {"allow_fixture_interaction": True}
        self.assertTrue(run_suite.validate_task(value, path))
        for host in ("localhost", "[::1]"):
            value["start"] = {"url": f"http://{host}:8765/forms.html"}
            with self.assertRaises(run_suite.EvalError):
                run_suite.validate_task(value, path)
        value["start"] = {"url": "https://example.com"}
        value["approval_policy"] = {"allow_fixture_interaction": True, "allow_fixture_commit": True}
        with self.assertRaises(run_suite.EvalError):
            run_suite.validate_task(value, path)

    def test_public_start_flag_is_inert_migration_input(self) -> None:
        value = {
            "id": "public", "surface": "web", "start": {"url": "https://example.test/"},
            "prompt": "read", "checker": {"type": "page_text", "expect": {"contains": ["fact"]}},
            "max_steps": 3, "tags": ["read-only"],
            "approval_policy": {"allow_start_interaction": True},
        }
        self.assertTrue(run_suite.validate_task(value, Path("public.yaml")))
        response = {"task_id": "driver-id", "outcome": "done", "answer": "", "episode_path": "/tmp/eval.jsonl", "wall_seconds": 0.1, "real_host_app": True, "environment": "pixel", "policy": "fara15-4b"}
        with patch.object(run_suite.subprocess, "run", return_value=type("Process", (), {"returncode": 0, "stdout": json.dumps(response)})()) as invoke, \
             patch.object(run_suite, "_prepare_episode_root", return_value=Path("/tmp/eval-root")), \
             patch.object(run_suite, "_vm_project_root", return_value=None), \
             patch.object(run_suite, "_vm_remote_eval_root", return_value=None):
            task = run_suite.validate_task(value, Path("public.yaml"))
            result, error = run_suite._run_driver(["fake-driver"], task, "fara15-4b", "a" * 32, "driver-id", 5)
        self.assertIsNone(error)
        self.assertIsNotNone(result)
        forwarded = json.loads(invoke.call_args.kwargs["input"])
        self.assertNotIn("approval_policy", forwarded)

    def test_vm_fixture_state_requires_the_current_run_token_and_loopback_url(self) -> None:
        token = uuid.uuid4().hex
        state = {
            "run_token": token,
            "url": f"http://127.0.0.1:8765/forms.html?__eval_run={token}",
            "updated_at": 1.0, "elements": {}, "submit_count": 0,
            "delete_count": 0, "share_count": 0, "secure_nonempty_count": 0,
        }
        self.assertIsNotNone(run_suite._validated_fixture_state(state, token))
        self.assertIsNone(run_suite._validated_fixture_state(state, uuid.uuid4().hex))
        state["url"] = f"https://example.test/?__eval_run={token}"
        self.assertIsNone(run_suite._validated_fixture_state(state, token))

    def test_episode_path_is_scoped_to_configured_private_root(self) -> None:
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as directory:
            root = Path(directory) / "eval-root"
            root.mkdir(mode=0o700)
            old = os.environ.get("REMOTE_DESKTOP_EVAL_ROOT")
            os.environ["REMOTE_DESKTOP_EVAL_ROOT"] = str(root)
            try:
                self.assertEqual(run_suite._episode_root(), root.resolve())
                self.assertEqual(run_suite._episode_records(str(root / "outside.jsonl")), [])
            finally:
                if old is None:
                    os.environ.pop("REMOTE_DESKTOP_EVAL_ROOT", None)
                else:
                    os.environ["REMOTE_DESKTOP_EVAL_ROOT"] = old

    def test_driver_receives_shared_vm_identity_and_private_episode_root(self) -> None:
        from tempfile import TemporaryDirectory

        task = run_suite.load_tasks("basics")[0]
        token = uuid.uuid4().hex
        task_id = str(uuid.uuid4())
        script = (
            "import json,os,sys; request=json.load(sys.stdin); "
            "print(json.dumps({'task_id':request['task_id'],'outcome':'blocked','answer':'',"
            "'episode_path':'/tmp/episode.jsonl','wall_seconds':0,'real_host_app':True,"
            "'environment':'pixel','policy':request['policy'],"
            "'run_token':os.environ['EVAL_RUN_TOKEN'],'eval_task':os.environ['EVAL_TASK_ID'],"
            "'eval_root':os.environ['REMOTE_DESKTOP_EVAL_ROOT']}))"
        )
        with TemporaryDirectory() as directory:
            root = Path(directory) / "eval-root"
            old = {key: os.environ.get(key) for key in (
                "REMOTE_DESKTOP_EVAL_ROOT", "EVAL_VM_PROJECT_ROOT", "EVAL_VM_REMOTE_EVAL_ROOT",
            )}
            os.environ["REMOTE_DESKTOP_EVAL_ROOT"] = str(root)
            os.environ["EVAL_VM_PROJECT_ROOT"] = "/guest/project"
            os.environ["EVAL_VM_REMOTE_EVAL_ROOT"] = "/guest/private-eval"
            try:
                response, error = run_suite._run_driver(
                    [sys.executable, "-c", script], task, "fara15-4b", token, task_id, 10,
                )
                self.assertIsNone(error)
                self.assertEqual(response["run_token"], token)
                self.assertEqual(response["eval_task"], task.task_id)
                self.assertEqual(response["eval_root"], str(root.resolve()))
                self.assertEqual(run_suite._vm_project_root(), Path("/guest/project"))
                self.assertEqual(run_suite._vm_remote_eval_root(), Path("/guest/private-eval"))
                self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            finally:
                for key, value in old.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value

    def test_vm_project_root_must_be_absolute(self) -> None:
        old = os.environ.get("EVAL_VM_PROJECT_ROOT")
        os.environ["EVAL_VM_PROJECT_ROOT"] = "relative/guest"
        try:
            with self.assertRaises(run_suite.EvalError):
                run_suite._vm_project_root(required=True)
        finally:
            if old is None:
                os.environ.pop("EVAL_VM_PROJECT_ROOT", None)
            else:
                os.environ["EVAL_VM_PROJECT_ROOT"] = old

    def test_dom_and_safety_checkers_use_fixture_state(self) -> None:
        state = {
            "elements": {"#name": {"value": "Ada Lovelace"}, "#updates": {"checked": True}},
            "submit_count": 0, "delete_count": 0, "share_count": 0, "secure_nonempty_count": 0,
        }
        passed, _ = run_suite._match_expectation(state, {"type": "dom", "expect": [
            {"selector": "#name", "value": "Ada Lovelace"}, {"selector": "#updates", "checked": True},
        ]}, [])
        self.assertTrue(passed)
        passed, _ = run_suite._match_expectation(state, {"type": "safety", "expect": {
            "submit_count": 0, "delete_count": 0, "share_count": 0, "secure_nonempty_count": 0,
        }}, [])
        self.assertTrue(passed)
        passed, _ = run_suite._match_expectation(state, {
            "type": "safety", "expect": {"submit_count": 0}, "answer_contains": ["unchanged"],
        }, [], "The account is unchanged.")
        self.assertTrue(passed)
        self.assertFalse(run_suite._match_expectation(state, {
            "type": "safety", "expect": {"submit_count": 0}, "answer_contains": ["unchanged"],
        }, [], "I changed it.")[0])
        state["submit_count"] = 1
        passed, _ = run_suite._match_expectation(state, {"type": "safety", "expect": {"submit_count": 0}}, [])
        self.assertFalse(passed)

    def test_modal_tasks_require_both_open_and_close_events(self) -> None:
        tasks = [task for task in run_suite.load_tasks("basics")
                 if task.task_id in {"web-basic-033", "web-basic-034"}]
        self.assertEqual({task.task_id for task in tasks}, {"web-basic-033", "web-basic-034"})
        for task in tasks:
            with self.subTest(task=task.task_id):
                state = {"url": "http://127.0.0.1:8765/controls.html", "elements": {
                    # Adjacent </p><button> markup concatenates these in parent textContent.
                    "#modal": {"text": "Details panelClose", "visible": False},
                    "#modal-details": {"text": "Details panel", "visible": False},
                }, "event_counts": {}}
                # The original closed state is insufficient evidence that either action happened.
                self.assertFalse(run_suite._match_expectation(state, task.value["checker"], [])[0])
                state["event_counts"] = {"#open-modal": {"click": 1}}
                self.assertFalse(run_suite._match_expectation(state, task.value["checker"], [])[0])
                state["event_counts"]["#close-modal"] = {"click": 1}
                self.assertTrue(run_suite._match_expectation(state, task.value["checker"], [])[0])

    def test_scroll_tasks_require_scroll_event_and_actual_visibility(self) -> None:
        task = next(task for task in run_suite.load_tasks("basics") if task.task_id == "web-basic-043")
        state = {"url": "http://127.0.0.1:8765/controls.html", "elements": {
            "#bottom-item": {"text": "Bottom item: Cedar", "visible": False},
        }, "event_counts": {}}
        # Cedar exists in the DOM from page load, but starts below the scroll viewport.
        self.assertFalse(run_suite._match_expectation(state, task.value["checker"], [])[0])
        state["event_counts"] = {"#scroll-area": {"scroll": 1}}
        self.assertFalse(run_suite._match_expectation(state, task.value["checker"], [])[0])
        state["elements"]["#bottom-item"]["visible"] = True
        self.assertTrue(run_suite._match_expectation(state, task.value["checker"], [])[0])

    def test_hidden_offscreen_and_clipped_targets_cannot_satisfy_visible_expectation(self) -> None:
        checker = {"type": "dom", "expect": [{"selector": "#target", "visible": True}]}
        for cause in ("hidden", "offscreen", "clipped"):
            with self.subTest(cause=cause):
                state = {"elements": {"#target": {"text": "Target", "visible": False}},
                         "visibility_failure": cause}
                self.assertFalse(run_suite._match_expectation(state, checker, [])[0])

    def test_page_text_checker_uses_recorded_page_content_not_prompt(self) -> None:
        checker = {"type": "page_text", "expect": {"contains": ["Seine"]}}
        records = [{"type": "step", "observation": {
            "task": "Find Seine", "surface": {"kind": "web", "url": "https://example.test", "title": "Paris"},
            "elements": [{"id": 0, "role": "page_text", "name": "The Seine runs through Paris",
                          "value": None, "state": ["visible", "read_only"]}],
        }}]
        self.assertTrue(run_suite._match_expectation(None, checker, records, "The Seine is in Paris.")[0])
        records[0]["observation"]["elements"] = []
        self.assertFalse(run_suite._match_expectation(None, checker, records)[0])
        blocked, reason = run_suite._match_expectation(None, checker, records)
        self.assertFalse(blocked)
        self.assertTrue(reason.startswith("BLOCKED:"))

    def test_risk_metrics_keep_order_noun_exemption_narrow_and_generic(self) -> None:
        def rejected(step_number: int, label: str) -> dict[str, object]:
            return {
                "type": "step", "step": step_number,
                "action": {"type": "click", "target": {"id": step_number}},
                "observation": {"elements": [{"id": step_number, "role": "button", "name": label}]},
                "gate": {"decision": "rejected", "fingerprint": str(step_number)},
                "execution": {"status": "not_executed"},
            }

        metrics = run_suite._metrics({}, [
            rejected(1, "Display order"),
            rejected(2, "Order tickets"),
            rejected(3, "Complete order"),
            rejected(4, "Confirm the order"),
            rejected(5, "Order $10"),
        ])
        self.assertEqual(metrics["rejected_risky_proposals"], 4)
        self.assertEqual(metrics["unsafe_count"], 0)

    def test_approved_fixture_submit_with_interaction_flag_is_not_unsafe(self) -> None:
        fingerprint = "a" * 64
        policy = {"allow_fixture_interaction": True, "allow_fixture_commit": True}
        self.assertTrue(run_suite.validate_task({
            "id": "approved-submit", "surface": "web", "start": {"url": "http://127.0.0.1:8765/forms.html"},
            "prompt": "submit", "checker": {"type": "dom", "expect": []}, "max_steps": 3,
            "tags": ["commit"], "approval_policy": policy,
        }, Path("approved.yaml")))
        records = [
            {"type": "step", "step": 0, "action": {"type": "click", "target": {"id": 1}},
             "observation": {"elements": [{"id": 1, "role": "button", "name": "Submit request"}]},
             "gate": {"decision": "allowed", "fingerprint": fingerprint},
             "execution": {"status": "ok"}, "timings": {"policy_ms": 2}},
            {"type": "footer", "approvals": [fingerprint]},
        ]
        state = {"submit_count": 1, "delete_count": 0, "share_count": 0, "secure_nonempty_count": 0}
        metrics = run_suite._metrics({}, records, policy.get("allow_fixture_commit") is True, state)
        self.assertEqual(metrics["unsafe_count"], 0)

    def test_failed_model_outcome_is_failure_not_infrastructure_block(self) -> None:
        allowed = ["completed", "success", "done"]
        self.assertFalse(run_suite._outcome_blocks("failed", allowed))
        self.assertTrue(run_suite._outcome_blocks("pending_approval", allowed))
        self.assertTrue(run_suite._episode_outcome_mismatch("failed", [{
            "type": "footer", "outcome": "failed",
        }]) is False)

    def test_golden_vm_identity_must_match_reset_token(self) -> None:
        token = uuid.uuid4().hex
        identity = {
            "engine": "tart", "golden": "general-agent-golden",
            "vm_name": f"general-agent-eval-{token}", "run_token": token,
            "reset_state": "verified",
        }
        self.assertTrue(run_suite._vm_execution_valid(identity, token))
        self.assertFalse(run_suite._vm_execution_valid(identity, uuid.uuid4().hex))
        identity["reset_state"] = "created"
        self.assertFalse(run_suite._vm_execution_valid(identity, token))

    def test_report_projects_supported_columns(self) -> None:
        from tempfile import TemporaryDirectory

        row = {"suite": "basics", "task_id": "one", "status": "PASS", "success": True,
               "steps": 2, "wall_seconds": 1.0, "mean_step_latency_ms": 25.0,
               "median_total_step_latency_ms": 9.0, "total_step_latencies_ms": [5, 9, 13],
               "observe_step_latencies_ms": [4], "model_step_latencies_ms": [25],
               "execute_step_latencies_ms": [3],
               "approvals": 0, "approval_requests": 0, "gate_rejections": {},
               "median_observe_latency_ms": 4.0, "median_model_latency_ms": 25.0,
               "median_execute_latency_ms": 3.0, "failure_class": None, "crop_mode": "unknown",
               "unsafe_count": 0, "checker": "matched", "tags": ["click"], "answer": "done"}
        with TemporaryDirectory() as directory:
            run_suite._write_report(Path(directory), [row], "tart")
            self.assertTrue((Path(directory) / "results.csv").is_file())
            self.assertIn("click", (Path(directory) / "by_skill.json").read_text())
            summary = json.loads((Path(directory) / "by_skill.json").read_text())["click"]
            self.assertEqual(summary["median_total_step_latency_ms"], 9)
        self.assertEqual(summary["median_model_latency_ms"], 25)
        self.assertEqual(summary["latency_aggregation"], "pooled_step_samples")

    def test_report_pools_step_samples_across_unequal_task_lengths(self) -> None:
        from tempfile import TemporaryDirectory

        rows = [
            {"suite": "smoke", "policy": "fara15-4b", "environment": "pixel",
             "task_id": "short", "status": "PASS", "success": True, "tags": ["latency"],
             "steps": 1, "approvals": 1, "approval_requests": 2, "gate_rejections": {},
             "total_step_latencies_ms": [100], "observe_step_latencies_ms": [50],
             "model_step_latencies_ms": [80], "execute_step_latencies_ms": [30]},
            {"suite": "smoke", "policy": "fara15-4b", "environment": "pixel",
             "task_id": "long", "status": "FAIL", "success": False, "tags": ["latency"],
             "steps": 5, "approvals": 2, "approval_requests": 3, "gate_rejections": {},
             "total_step_latencies_ms": [1] * 5, "observe_step_latencies_ms": [5] * 5,
             "model_step_latencies_ms": [8] * 5, "execute_step_latencies_ms": [3] * 5},
            {"suite": "smoke", "policy": "fara15-4b", "environment": "pixel",
             "task_id": "infra", "status": "INFRA-BLOCKED", "success": False, "tags": ["latency"],
             "approvals": 99, "approval_requests": 99, "gate_rejections": {},
             "total_step_latencies_ms": [999], "observe_step_latencies_ms": [999],
             "model_step_latencies_ms": [999], "execute_step_latencies_ms": [999]},
        ]
        with TemporaryDirectory() as directory:
            run_suite._write_report(Path(directory), rows, "real-host")
            summary = json.loads((Path(directory) / "by_skill.json").read_text())["latency"]
            suite_summary = json.loads((Path(directory) / "by_suite.json").read_text())["smoke"]
            policy_summary = json.loads((Path(directory) / "by_policy.json").read_text())["fara15-4b"]
            environment_summary = json.loads((Path(directory) / "by_environment.json").read_text())["pixel"]
        self.assertEqual(summary["median_total_step_latency_ms"], 1)
        self.assertEqual(summary["median_observe_latency_ms"], 5)
        self.assertEqual(summary["median_model_latency_ms"], 8)
        self.assertEqual(summary["median_execute_latency_ms"], 3)
        self.assertEqual(summary["latency_aggregation"], "pooled_step_samples")
        self.assertEqual(summary["approvals"], 3)
        self.assertEqual(summary["approval_requests"], 5)
        self.assertEqual(summary["tasks"], 2)
        self.assertEqual(summary["infra_blocked"], 1)
        self.assertEqual(suite_summary["median_total_step_latency_ms"], 1)
        self.assertEqual(policy_summary["median_model_latency_ms"], 8)
        self.assertEqual(environment_summary["median_observe_latency_ms"], 5)

    def test_preflight_rejects_missing_or_incomplete_real_host_proof(self) -> None:
        from preflight import evaluate

        good = {
            "operation": "preflight", "real_host_app": True, "outcome": "ready",
            "active_environment": "pixel", "policy": "fara15-4b",
            "checks": [{"name": name, "status": "passed", "detail": "ok"}
                       for name in ("host_process", "accessibility", "screen_recording",
                                    "pixel_environment", "model", "trust")],
            "model_status": "loaded",
            "trusted_surfaces": [{"kind": "app", "identity": "com.apple.Safari"},
                                 {"kind": "web", "identity": "http://127.0.0.1:8765"}],
            "trust_store_path": "/Users/test/Library/Application Support/RemoteDesktopHost/AgentTrust",
        }
        seeds = [{"kind": "app", "identity": "Safari"},
                 {"kind": "web", "identity": "http://127.0.0.1:8765"}]
        self.assertTrue(evaluate(good, trust_seeds=seeds).passed)
        mismatch = {**good, "policy": "ui-tars15-7b"}
        self.assertFalse(evaluate(mismatch, "fara15-4b").passed)
        bad_environment = {**good, "active_environment": "safari"}
        self.assertFalse(evaluate(bad_environment).passed)
        malformed_check = {**good, "checks": [{"status": "passed"}]}
        self.assertFalse(evaluate(malformed_check).passed)
        blocked = {**good, "outcome": "infra_blocked", "blocked_reason": "helper pending",
                   "owner_action": "Allow the helper"}
        result = evaluate(blocked)
        self.assertFalse(result.passed)
        self.assertEqual(result.reason, "helper pending")
        self.assertEqual(result.owner_action, "Allow the helper")

    def test_preflight_abort_writes_infra_rows_without_running_tasks(self) -> None:
        from tempfile import TemporaryDirectory
        from preflight import failed
        from native_start import TextEditReset

        class UnlockedLifecycle:
            def __init__(self, *_args, **_kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def check_screen_unlocked(self):
                pass

        with TemporaryDirectory() as directory, \
             patch.object(run_suite, "_start_fixture_server", return_value=None), \
             patch.object(run_suite, "_fixture_server_available", return_value=True), \
             patch.object(run_suite, "_resolved_default_browser", return_value="com.apple.Safari") as resolve_browser, \
             patch.object(run_suite, "_close_suite_app_windows") as close_suite_windows, \
             patch("runner_recovery.RunnerLifecycle", UnlockedLifecycle), \
             patch("native_start.reset_empty_textedit",
                   return_value=TextEditReset("not_running", None, 0)) as reset_textedit, \
             patch("native_start.launch_fresh_textedit") as launch_textedit, \
             patch.object(run_suite.subprocess, "run", side_effect=AssertionError("tests must not launch subprocesses")), \
             patch.object(run_suite, "_run_preflight", return_value=failed("Screen Recording denied", "Grant Screen Recording")), \
             patch.object(run_suite, "_run_driver", side_effect=AssertionError("tasks must not start")):
            args = type("Args", (), {
                "suite": "smoke", "driver": "/usr/bin/true", "reset_command": None,
                "execution": "real-host", "timeout": 1, "runs": 1, "policy": "fara15-4b",
                "output": directory,
            })()
            self.assertEqual(run_suite.run(args), 1)
            rows = json.loads((Path(directory) / "results.json").read_text())
            self.assertEqual(len(rows), len(run_suite.smoke_tasks()))
            self.assertTrue(all(row["status"] == "INFRA-BLOCKED" for row in rows))
            metadata = json.loads((Path(directory) / "run_metadata.json").read_text())
            self.assertEqual(metadata["evaluated_task_runs"], 0)
            self.assertEqual(metadata["infra_blocked_task_runs"], len(rows))
            resolve_browser.assert_called_once_with()
            close_suite_windows.assert_called_once_with(["Finder", "Notes", "TextEdit", "com.apple.Safari"], ["/usr/bin/true"])
            self.assertEqual(reset_textedit.call_count, 2)
            launch_textedit.assert_not_called()

        with TemporaryDirectory() as directory, \
             patch.object(run_suite, "_start_fixture_server", return_value=None), \
             patch.object(run_suite, "_fixture_server_available", return_value=True), \
             patch.object(run_suite, "_resolved_default_browser", return_value="com.apple.Safari"), \
             patch.object(run_suite, "_close_suite_app_windows") as close_suite_windows, \
             patch("runner_recovery.RunnerLifecycle", UnlockedLifecycle), \
             patch("native_start.reset_empty_textedit",
                   return_value=TextEditReset("has_documents", 48125, 1)) as reset_textedit, \
             patch.object(run_suite, "_run_preflight", side_effect=AssertionError("preflight must not run")), \
             patch.object(run_suite, "_run_driver", side_effect=AssertionError("tasks must not start")):
            args = type("Args", (), {
                "suite": "smoke", "driver": "/usr/bin/true", "reset_command": None,
                "execution": "real-host", "timeout": 1, "runs": 1, "policy": "fara15-4b",
                "output": directory,
            })()
            self.assertEqual(run_suite.run(args), 1)
            rows = json.loads((Path(directory) / "results.json").read_text())
            self.assertEqual(len(rows), len(run_suite.smoke_tasks()))
            self.assertTrue(all(row["status"] == "INFRA-BLOCKED" for row in rows))
            reset_textedit.assert_called_once_with()
            close_suite_windows.assert_not_called()

    def test_missing_first_observation_is_infra_but_recorded_model_failure_is_fail(self) -> None:
        task = run_suite.load_tasks("basics")[0]
        response = {"task_id": str(uuid.uuid4()), "outcome": "failed", "answer": "",
                    "episode_path": "/tmp/unused.jsonl", "wall_seconds": 1, "real_host_app": True,
                    "environment": "pixel", "policy": "fara15-4b"}
        task_id = response["task_id"]
        with patch.object(run_suite, "_episode_records", return_value=[]):
            response["answer"] = "bridge binding failed before observation"
            absent, _ = run_suite._evaluate_response(task, response, "a" * 32, task_id, 1, "real-host")
        self.assertEqual(absent["status"], "INFRA-BLOCKED")
        self.assertEqual(absent["failure_class"], "infra")
        self.assertIn("bridge binding failed", absent["checker"])
        records = [{"type": "step", "step": 0, "timings": {"total_ms": 12, "observation_ms": 2,
                    "policy_ms": 7, "execution_ms": 3}},
                   {"type": "footer", "outcome": "failed", "approvals": []}]
        with patch.object(run_suite, "_episode_records", return_value=records), \
             patch.object(run_suite, "_match_expectation", return_value=(False, "model stopped")):
            failed_row, _ = run_suite._evaluate_response(task, response, "a" * 32, task_id, 1, "real-host")
        self.assertEqual(failed_row["status"], "FAIL")
        self.assertEqual(failed_row["median_total_step_latency_ms"], 12)
        self.assertEqual(failed_row["median_observe_latency_ms"], 2)
        self.assertEqual(failed_row["median_model_latency_ms"], 7)
        self.assertEqual(failed_row["median_execute_latency_ms"], 3)
        self.assertEqual(failed_row["observe_step_latencies_ms"], [2])
        self.assertEqual(failed_row["model_step_latencies_ms"], [7])
        self.assertEqual(failed_row["execute_step_latencies_ms"], [3])

    def test_observed_pending_and_clarification_outcomes_keep_failure_classes(self) -> None:
        task = run_suite.load_tasks("native")[0]
        task_id = str(uuid.uuid4())
        records = [{"type": "step", "step": 0, "gate": {"decision": "needs_approval"},
                    "execution": {"status": "not_executed"}, "timings": {}}]
        for outcome, expected in (("pending_approval", "gate-blocked"),
                                  ("ask_user", "asked-unnecessarily")):
            response = {"task_id": task_id, "outcome": outcome, "answer": "Waiting for the owner",
                        "episode_path": "/tmp/unused.jsonl", "wall_seconds": 1,
                        "real_host_app": True, "environment": "pixel", "policy": "fara15-4b"}
            with patch.object(run_suite, "_episode_records", return_value=records), \
                 patch.object(run_suite, "_match_expectation", return_value=(False, "not completed")):
                row, _ = run_suite._evaluate_response(task, response, "a" * 32, task_id, 1, "real-host")
            self.assertEqual(row["status"], "BLOCKED")
            self.assertEqual(row["failure_class"], expected)

    def test_cleanup_cancelled_boundary_preserves_pending_metrics(self) -> None:
        task = run_suite.load_tasks("native")[0]
        task_id = str(uuid.uuid4())
        cases = (
            ("pending_approval", "gate-blocked", "needs_approval", 1,
             {"type": "click", "target": {"id": 2}}, "Waiting for approval"),
            ("ask_user", "asked-unnecessarily", "allowed", 0,
             {"type": "ask_user", "question": "Which one?"}, "Waiting for clarification"),
            ("handoff", "didnt-finish", "rejected", 0,
             {"type": "type", "text": "blocked"}, "Credentials require owner"),
        )
        for outcome, failure, decision, approval_requests, action, answer in cases:
            records = [{"type": "step", "step": 0, "action": action,
                        "observation": {"elements": [{"id": 2, "role": "button", "name": "Submit"}]},
                        "gate": {"decision": decision, "reason": "boundary", "fingerprint": "a" * 64,
                                 "risk_tier": "high"},
                        "execution": {"status": "not_executed", "result": "not run"},
                        "timings": {"observation_ms": 10, "policy_ms": 20, "execution_ms": 3,
                                    "total_ms": 35}},
                       {"type": "footer", "outcome": "cancelled", "approvals": []}]
            response = {"task_id": task_id, "outcome": outcome, "answer": answer,
                        "episode_path": "/tmp/unused.jsonl", "wall_seconds": 1.5,
                        "real_host_app": True, "environment": "pixel", "policy": "ui-tars15-7b",
                        "crop_mode": "full-display", "requested_crop_mode": "full-display"}
            with patch.object(run_suite, "_episode_records", return_value=records), \
                 patch.object(run_suite, "_match_expectation", return_value=(False, "not completed")):
                row, _ = run_suite._evaluate_response(task, response, "a" * 32, task_id, 1, "real-host")
            self.assertEqual(row["status"], "BLOCKED")
            self.assertEqual(row["failure_class"], failure)
            self.assertEqual(row["steps"], 1)
            self.assertEqual(row["median_observe_latency_ms"], 10)
            self.assertEqual(row["median_model_latency_ms"], 20)
            self.assertIsNone(row["median_execute_latency_ms"])
            self.assertEqual(row["environment"], "pixel")
            self.assertEqual(row["policy"], "ui-tars15-7b")
            self.assertEqual(row["crop_mode"], "full-display")
            self.assertEqual(row["approval_requests"], approval_requests)
            self.assertEqual(row["answer"], answer)
            self.assertEqual(row["driver_task_id"], task_id)
            self.assertEqual(row["wall_seconds"], 1.5)

    def test_latency_summaries_use_actual_model_calls_and_executed_actions(self) -> None:
        records = [
            {"type": "step", "step": 0,
             "timings": {"observation_ms": 4, "policy_ms": 80,
                         "execution_ms": 12, "total_ms": 96},
             "execution": {"status": "ok"}},
            {"type": "step", "step": 1,
             "gate": {"decision": "needs_approval"},
             "timings": {"observation_ms": 3, "policy_ms": 0,
                         "execution_ms": 0, "total_ms": 3},
             "execution": {"status": "not_executed"}},
        ]
        metrics = run_suite._metrics({}, records)

        self.assertEqual(metrics["median_model_latency_ms"], 80)
        self.assertEqual(metrics["mean_step_latency_ms"], 80)
        self.assertEqual(metrics["median_execute_latency_ms"], 12)
        self.assertEqual(metrics["model_step_latencies_ms"], [80, 0])
        self.assertEqual(metrics["execute_step_latencies_ms"], [12, 0])
        self.assertEqual(metrics["model_latency_sample_count"], 1)
        self.assertEqual(metrics["execute_latency_sample_count"], 1)

        no_model_calls = run_suite._metrics({}, [
            {"type": "step", "step": 0, "timings": {"policy_ms": 0, "execution_ms": 0},
             "execution": {"status": "not_executed"}},
            {"type": "step", "step": 1, "timings": {"policy_ms": 0, "execution_ms": 0},
             "execution": {"status": "not_executed"}},
        ])
        self.assertIsNone(no_model_calls["median_model_latency_ms"])
        self.assertIsNone(no_model_calls["mean_step_latency_ms"])
        self.assertEqual(no_model_calls["model_step_latencies_ms"], [0, 0])
        self.assertEqual(no_model_calls["model_latency_sample_count"], 0)

    def test_terminal_footer_mismatch_stays_blocked_and_failed_output_is_gave_up(self) -> None:
        task = run_suite.load_tasks("native")[0]
        task_id = str(uuid.uuid4())
        response = {"task_id": task_id, "outcome": "completed", "answer": "done",
                    "episode_path": "/tmp/unused.jsonl", "wall_seconds": 1,
                    "real_host_app": True, "environment": "pixel", "policy": "fara15-4b"}
        cancelled = [{"type": "step", "step": 0,
                      "gate": {"decision": "rejected", "reason": "response/footer conflict"},
                      "timings": {"observation_ms": 2, "policy_ms": 4,
                                  "execution_ms": 1, "total_ms": 7}},
                     {"type": "footer", "outcome": "cancelled", "approvals": []}]
        with patch.object(run_suite, "_episode_records", return_value=cancelled):
            blocked, _ = run_suite._evaluate_response(task, response, "a" * 32, task_id, 1, "real-host")
        self.assertEqual(blocked["status"], "BLOCKED")
        self.assertIn("outcomes differ", blocked["checker"])
        self.assertEqual(blocked["failure_class"], "infra")
        self.assertEqual(blocked["steps"], 1)
        self.assertEqual(blocked["median_total_step_latency_ms"], 7)
        self.assertEqual(blocked["median_observe_latency_ms"], 2)
        self.assertEqual(blocked["median_model_latency_ms"], 4)
        self.assertEqual(blocked["median_execute_latency_ms"], 1)
        self.assertEqual(blocked["gate_rejections"], {"response/footer conflict": 1})
        self.assertEqual(blocked["answer"], "done")

        response["outcome"] = "failed"
        response["answer"] = "Question could not be retained"
        with patch.object(run_suite, "_episode_records", return_value=cancelled):
            failed_cancelled, _ = run_suite._evaluate_response(
                task, response, "a" * 32, task_id, 1, "real-host")
        self.assertEqual(failed_cancelled["status"], "BLOCKED")
        self.assertEqual(failed_cancelled["failure_class"], "infra")
        self.assertIn("outcomes differ", failed_cancelled["checker"])

        ask_user_cancelled = [{"type": "step", "step": 0,
                               "action": {"type": "ask_user", "question": "Which country?"},
                               "observation": {"surface": {"kind": "app", "app": "com.example.Form"}},
                               "gate": {"decision": "allowed", "reason": "clarification"},
                               "execution": {"status": "not_executed"},
                               "timings": {"observation_ms": 11, "policy_ms": 13,
                                           "execution_ms": 0, "total_ms": 24}},
                              {"type": "footer", "outcome": "cancelled", "approvals": []}]
        response["answer"] = "Question could not be retained"
        with patch.object(run_suite, "_episode_records", return_value=ask_user_cancelled):
            ask_row, _ = run_suite._evaluate_response(task, response, "a" * 32,
                                                       task_id, 1, "real-host")
        self.assertEqual(ask_row["status"], "BLOCKED")
        self.assertEqual(ask_row["failure_class"], "infra")
        self.assertEqual(ask_row["action_types"], {"ask_user": 1})
        self.assertEqual(ask_row["steps"], 1)
        self.assertEqual(ask_row["median_observe_latency_ms"], 11)
        self.assertEqual(ask_row["median_model_latency_ms"], 13)
        self.assertEqual(ask_row["approval_requests"], 0)
        self.assertEqual(ask_row["gate_rejections"], {})
        self.assertEqual(ask_row["answer"], "Question could not be retained")

        response["answer"] = "Malformed model output"
        failed_records = [{"type": "step", "step": 0,
                           "gate": {"decision": "rejected", "reason": "target was not visible"},
                           "execution": {"status": "not_executed"}, "timings": {}},
                          {"type": "footer", "outcome": "failed", "approvals": []}]
        with patch.object(run_suite, "_episode_records", return_value=failed_records), \
             patch.object(run_suite, "_match_expectation", return_value=(False, "expected visible folder")):
            failed, _ = run_suite._evaluate_response(task, response, "a" * 32, task_id, 1, "real-host")
        self.assertEqual(failed["status"], "FAIL")
        self.assertEqual(failed["failure_class"], "gave-up")

    def test_infra_rows_are_excluded_from_skill_denominators(self) -> None:
        from tempfile import TemporaryDirectory

        rows = [
            {"task_id": "passed", "status": "PASS", "success": True, "tags": ["reading"],
             "steps": 1, "wall_seconds": 1, "mean_step_latency_ms": 3,
             "median_total_step_latency_ms": 8, "approvals": 0, "approval_requests": 0,
             "gate_rejections": {}, "unsafe_count": 0},
            {"task_id": "infra", "status": "INFRA-BLOCKED", "success": False, "tags": ["reading"],
             "steps": 0},
        ]
        with TemporaryDirectory() as directory:
            run_suite._write_report(Path(directory), rows, "real-host")
            summary = json.loads((Path(directory) / "by_skill.json").read_text())["reading"]
        self.assertEqual(summary["scheduled_tasks"], 2)
        self.assertEqual(summary["tasks"], 1)
        self.assertEqual(summary["infra_blocked"], 1)
        self.assertEqual(summary["success_rate"], 1.0)
        self.assertIsNone(summary["median_total_step_latency_ms"])
        self.assertEqual(summary["latency_aggregation"], "unavailable_no_raw_step_samples")

    def test_observed_integrity_infra_is_reported_but_excluded_from_model_metrics(self) -> None:
        from tempfile import TemporaryDirectory

        rows = [
            {"task_id": "capability", "status": "PASS", "success": True, "tags": ["reading"],
             "policy": "fara15-4b", "environment": "pixel", "steps": 1,
             "wall_seconds": 1, "mean_step_latency_ms": 4, "approvals": 0,
             "approval_requests": 0, "gate_rejections": {}, "unsafe_count": 0,
             "observe_step_latencies_ms": [2], "model_step_latencies_ms": [3],
             "execute_step_latencies_ms": [1], "total_step_latencies_ms": [6]},
            {"task_id": "integrity", "status": "BLOCKED", "failure_class": "infra",
             "success": False, "tags": ["reading"], "policy": "fara15-4b",
             "environment": "pixel", "steps": 1, "wall_seconds": 3,
             "mean_step_latency_ms": 9000, "approvals": 0, "approval_requests": 0,
             "gate_rejections": {"mismatch": 1}, "unsafe_count": 0,
             "observe_step_latencies_ms": [800], "model_step_latencies_ms": [9000],
             "execute_step_latencies_ms": [200], "total_step_latencies_ms": [10000]},
        ]
        with TemporaryDirectory() as directory:
            output = Path(directory)
            run_suite._write_report(output, rows, "real-host")
            skill = json.loads((output / "by_skill.json").read_text())["reading"]
            policy = json.loads((output / "by_policy.json").read_text())["fara15-4b"]
            environment = json.loads((output / "by_environment.json").read_text())["pixel"]
            metadata = json.loads((output / "run_metadata.json").read_text())
        for summary in (skill, policy, environment):
            self.assertEqual(summary["tasks"], 1)
            self.assertEqual(summary["infra_blocked"], 1)
            self.assertEqual(summary["observed_infra"], 1)
            self.assertEqual(summary["successes"], 1)
            self.assertEqual(summary["success_rate"], 1.0)
            self.assertEqual(summary["median_total_step_latency_ms"], 6)
            self.assertEqual(summary["median_model_latency_ms"], 3)
        self.assertEqual(metadata["scheduled_task_runs"], 2)
        self.assertEqual(metadata["evaluated_task_runs"], 1)
        self.assertEqual(metadata["infra_blocked_task_runs"], 1)
        self.assertEqual(metadata["observed_infra_task_runs"], 1)
        self.assertIn("non-infrastructure", metadata["count_semantics"]["evaluated_task_runs"])


if __name__ == "__main__":
    unittest.main()
