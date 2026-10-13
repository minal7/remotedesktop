from __future__ import annotations

import importlib.util
import json
import os
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

    def test_native_tasks_are_scoped_to_owned_scratch_and_have_distinct_checkers(self) -> None:
        native = run_suite.load_tasks("native")
        self.assertEqual(len(native), 8)
        self.assertTrue(all(task.value["surface"] == "app" for task in native))
        self.assertEqual(len({task.value["prompt"] for task in native}), 8)
        self.assertTrue(all(task.value["approval_policy"] == {"allow_start_interaction": True} for task in native))
        unsafe = {**native[0].value, "setup": {"folders": ["../../Documents"]}}
        with self.assertRaises(run_suite.EvalError):
            run_suite.validate_task(unsafe, Path("native-unsafe.yaml"))

    def test_native_scratch_is_per_task_and_checkers_reject_paths_outside_it(self) -> None:
        from tempfile import TemporaryDirectory

        task = next(task for task in run_suite.load_tasks("native") if task.task_id == "native-001")
        home = os.environ.get("HOME")
        with TemporaryDirectory() as directory:
            os.environ["HOME"] = directory
            try:
                scratch = run_suite._native_scratch_directory(task.task_id, "run-token")
                materialized = run_suite._materialize_native_task(task, scratch)
                self.assertIn(str(scratch), materialized.value["prompt"])
                target = scratch / "Meeting.txt"
                target.write_text("Meeting notes for Monday\n", encoding="utf-8")
                passed, _ = run_suite._match_expectation(None, materialized.value["checker"], [], "", scratch)
                self.assertTrue(passed)
                outside = {"type": "file_text", "expect": {"path": str(Path(directory) / "outside.txt"), "equals": "x"}}
                self.assertFalse(run_suite._match_expectation(None, outside, [], "", scratch)[0])
                run_suite._remove_native_scratch(scratch)
                self.assertFalse(scratch.exists())
                self.assertTrue((Path(directory) / "AgentEval").is_dir())
            finally:
                if home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = home

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
        task = next(task for task in run_suite.load_tasks("basics") if task.task_id == "web-basic-033")
        state = {"url": "http://127.0.0.1:8765/controls.html", "elements": {
            "#modal": {"text": "Details panel", "visible": False},
        }, "event_counts": {}}
        # The original closed state is insufficient evidence that either action happened.
        self.assertFalse(run_suite._match_expectation(state, task.value["checker"], [])[0])
        state["event_counts"] = {"#open-modal": {"click": 1}, "#close-modal": {"click": 1}}
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
                                    "pixel_environment", "model")],
            "model_status": "loaded",
        }
        self.assertTrue(evaluate(good).passed)
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

        with TemporaryDirectory() as directory, \
             patch.object(run_suite, "_start_fixture_server", return_value=None), \
             patch.object(run_suite, "_fixture_server_available", return_value=True), \
             patch.object(run_suite, "_run_preflight", return_value=failed("Screen Recording denied", "Grant Screen Recording")), \
             patch.object(run_suite, "_run_driver", side_effect=AssertionError("tasks must not start")):
            args = type("Args", (), {
                "suite": "smoke", "driver": "fake-driver", "reset_command": None,
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
            self.assertEqual(row["median_execute_latency_ms"], 3)
            self.assertEqual(row["environment"], "pixel")
            self.assertEqual(row["policy"], "ui-tars15-7b")
            self.assertEqual(row["crop_mode"], "full-display")
            self.assertEqual(row["approval_requests"], approval_requests)

    def test_terminal_footer_mismatch_stays_blocked_and_failed_output_is_gave_up(self) -> None:
        task = run_suite.load_tasks("native")[0]
        task_id = str(uuid.uuid4())
        response = {"task_id": task_id, "outcome": "completed", "answer": "done",
                    "episode_path": "/tmp/unused.jsonl", "wall_seconds": 1,
                    "real_host_app": True, "environment": "pixel", "policy": "fara15-4b"}
        cancelled = [{"type": "step", "step": 0, "timings": {}},
                     {"type": "footer", "outcome": "cancelled", "approvals": []}]
        with patch.object(run_suite, "_episode_records", return_value=cancelled):
            blocked, _ = run_suite._evaluate_response(task, response, "a" * 32, task_id, 1, "real-host")
        self.assertEqual(blocked["status"], "BLOCKED")
        self.assertIn("outcomes differ", blocked["checker"])

        response["outcome"] = "failed"
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


if __name__ == "__main__":
    unittest.main()
