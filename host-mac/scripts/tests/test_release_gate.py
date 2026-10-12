"""Behavior checks for the fail-closed release gate aggregator."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "release_gate.py"
SPEC = importlib.util.spec_from_file_location("release_gate", SCRIPT)
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class ReleaseGateEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.trace_root = self.root / "Traces"
        self.trace_root.mkdir()
        self.now = datetime.now(timezone.utc).timestamp()
        self.commit = "a" * 40
        self.run_id = "1" * 32

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_run(self, run_id: str | None = None, job: str = "gmail",
                 bridge: bool = True, send_granted: bool = False,
                 trace_mtime: float | None = None) -> tuple[Path, dict[str, object]]:
        identity = run_id or self.run_id
        trace = self.trace_root / f"m0-acceptance-{job}-20261012-{identity}"
        trace.mkdir()
        expected = {"job": job, "run_id": identity}
        outcome = {"job": job, "run_id": identity, "raw_outcome": "taskCompleted",
                   "evidence": {"safari_bridge_verified": bridge,
                                "bridge_round_trip_p95_ms": 42,
                                "bridge_step_median_seconds": 2.1,
                                "send_approval_granted": send_granted}}
        checker = {"job": job, "run_id": identity, "passed": True,
                   "check": {"passed": True}}
        for name, data in (("expected.json", expected), ("outcome.json", outcome),
                           ("checker.json", checker)):
            (trace / name).write_text(json.dumps(data), encoding="utf-8")
        if trace_mtime is not None:
            import os
            os.utime(trace, (trace_mtime, trace_mtime))
        return trace, {"job": job, "run_id": identity, "passed": True,
                       "elapsed_seconds": 50.0, "trace": str(trace)}

    def validate(self, trace: Path, record: dict[str, object], runs: int = 1,
                 job: str = "gmail", started: float | None = None,
                 trace_mtime: float | None = None, runs_passed: int | None = None,
                 records: list[dict[str, object]] | None = None):
        summary_path = trace / "summary.json"
        summary_path.write_text(json.dumps({"job": job, "status": "passed",
            "runs_requested": runs, "runs_passed": runs if runs_passed is None else runs_passed,
            "runs": [record] * runs if records is None else records,
            "median_seconds": 50.0}), encoding="utf-8")
        if trace_mtime is not None:
            import os
            os.utime(trace, (trace_mtime, trace_mtime))
        with mock.patch.object(gate, "TRACE_ROOT", self.trace_root):
            return gate.validated_job_summary(summary_path, job, runs, self.commit,
                self.now - 100 if started is None else started, self.now + 1)

    def test_partial_job_summary_is_rejected(self) -> None:
        trace, run = self.make_run()
        summary, reason = self.validate(trace, run, runs=10, runs_passed=1, records=[run])
        self.assertIsNone(summary)
        self.assertEqual(reason, "partial run batch")

    def test_replayed_run_identity_is_rejected(self) -> None:
        trace, run = self.make_run()
        summary, reason = self.validate(trace, run, runs=2)
        self.assertIsNone(summary)
        self.assertEqual(reason, "run identity is missing, invalid, or replayed")

    def test_missing_bridge_attestation_is_not_inferred_from_job_pass(self) -> None:
        trace, run = self.make_run(bridge=False)
        summary, reason = self.validate(trace, run)
        self.assertIsNone(summary)
        self.assertEqual(reason, "missing fresh Safari bridge attestation")

    def test_send_approval_must_remain_ungranted(self) -> None:
        trace, run = self.make_run(send_granted=True)
        summary, reason = self.validate(trace, run)
        self.assertIsNone(summary)
        self.assertEqual(reason, "Gmail send approval was granted during acceptance")

    def test_missing_bridge_speed_proof_blocks_old_ax_job_pass(self) -> None:
        trace, run = self.make_run()
        outcome_path = trace / "outcome.json"
        outcome = json.loads(outcome_path.read_text(encoding="utf-8"))
        outcome["evidence"].pop("bridge_round_trip_p95_ms")
        outcome_path.write_text(json.dumps(outcome), encoding="utf-8")
        summary, reason = self.validate(trace, run)
        self.assertIsNone(summary)
        self.assertEqual(reason, "missing passing Safari bridge 1,000-round-trip speed evidence (<50ms)")

    def test_apple_mail_acceptance_does_not_require_safari_bridge(self) -> None:
        trace, run = self.make_run(job="email", bridge=False)
        summary, reason = self.validate(trace, run, job="email")
        self.assertIsNotNone(summary)
        self.assertEqual(reason, "independent checker passed")

    def test_old_job_trace_is_stale(self) -> None:
        trace, run = self.make_run()
        summary, reason = self.validate(trace, run, started=self.now - 100,
                                        trace_mtime=self.now - 500)
        self.assertIsNone(summary)
        self.assertEqual(reason, "run trace is stale or predates this gate invocation")

    def test_wrong_source_commit_report_cannot_be_reused(self) -> None:
        now = datetime.now(timezone.utc)
        report = {"schema": 1, "mode": "full", "commit": self.commit, "run_id": self.run_id,
                  "source_tree_clean": True,
                  "jobs": {},
                  "client_date": now.date().isoformat(), "generated_at": now.isoformat()}
        self.assertTrue(gate.valid_full_report(report, self.commit, now))
        self.assertFalse(gate.valid_full_report({**report, "commit": "b" * 40}, self.commit, now))
        self.assertFalse(gate.valid_full_report({**report, "generated_at": (now - timedelta(days=8)).isoformat()}, self.commit, now))
        self.assertFalse(gate.valid_full_report(report, self.commit, now, current_source_clean=False))
        self.assertFalse(gate.valid_full_report({**report, "source_tree_clean": False}, self.commit, now))

    def test_g6_requires_three_unique_client_dates_and_run_ids(self) -> None:
        reports = [{"mode": "full", "g1_g4_passed": True, "source_tree_clean": True,
                    "run_id": str(index) * 32,
                    "commit": self.commit, "client_date": f"2026-10-{day:02d}",
                    "generated_at": f"2026-10-{day:02d}T12:00:00+00:00"}
                   for index, day in ((1, 10), (2, 11), (3, 12))]
        passed, _ = gate.three_day_history(reports, datetime(2026, 10, 12).date(), self.commit)
        self.assertTrue(passed)
        reports[1]["client_date"] = reports[0]["client_date"]
        passed, reason = gate.three_day_history(reports, datetime(2026, 10, 12).date(), self.commit)
        self.assertFalse(passed)
        self.assertIn("distinct client dates", reason)

    def test_g6_does_not_skip_a_failed_full_run_between_passes(self) -> None:
        reports = [{"mode": "full", "g1_g4_passed": passed, "source_tree_clean": True,
                    "run_id": str(index) * 32,
                    "commit": self.commit, "client_date": f"2026-10-{day:02d}",
                    "generated_at": f"2026-10-{day:02d}T12:00:00+00:00"}
                   for index, day, passed in ((1, 10, True), (2, 11, False), (3, 12, True))]
        passed, _ = gate.three_day_history(reports, datetime(2026, 10, 12).date(), self.commit)
        self.assertFalse(passed)

    def test_latency_and_send_run_counts_are_enforced(self) -> None:
        drafts = {"runs_passed": 10, "runs_requested": 10, "median_seconds": 60}
        sends = {"runs_passed": 3, "runs_requested": 3}
        self.assertTrue(gate.evaluate_g1(drafts, sends)[0])
        self.assertFalse(gate.evaluate_g1({**drafts, "median_seconds": 60.1}, sends)[0])
        self.assertFalse(gate.evaluate_g1(drafts, {**sends, "runs_passed": 2})[0])
        upload = {"runs_passed": 10, "runs_requested": 10, "median_seconds": 45}
        self.assertTrue(gate.evaluate_g2(upload, upload)[0])
        self.assertFalse(gate.evaluate_g2({**upload, "median_seconds": 45.1}, upload)[0])

    def test_flights_accepts_nine_of_ten_independently_checked_results(self) -> None:
        records = []
        traces = []
        for index in range(10):
            identity = f"{index + 1:032d}"
            trace, record = self.make_run(run_id=identity, job="flights")
            outcome = json.loads((trace / "outcome.json").read_text(encoding="utf-8"))
            outcome["evidence"] = {}
            (trace / "outcome.json").write_text(json.dumps(outcome), encoding="utf-8")
            passed = index < 9
            checker = {"job": "flights", "run_id": identity, "passed": passed,
                       "check": {"passed": passed,
                                 "cheapest_option_correct": passed,
                                 "hallucinated_price_count": 0,
                                 "reason": "timeout" if not passed else ""}}
            (trace / "checker.json").write_text(json.dumps(checker), encoding="utf-8")
            record["passed"] = passed
            record["check"] = checker["check"]
            records.append(record)
            traces.append(trace)
        summary_path = traces[-1] / "summary.json"
        summary_path.write_text(json.dumps({"job": "flights", "status": "failed",
            "runs_requested": 10, "runs_passed": 9, "runs": records,
            "median_seconds": 100.0}), encoding="utf-8")
        with mock.patch.object(gate, "TRACE_ROOT", self.trace_root):
            summary, reason = gate.validated_job_summary(summary_path, "flights", 10,
                self.commit, self.now - 100, self.now + 1)
        self.assertIsNotNone(summary)
        self.assertEqual(summary["cheapest_options_correct_count"], 9)
        self.assertEqual(summary["hallucinated_price_count"], 0)
        self.assertEqual(reason, "independent checker passed")

    def test_flight_checker_requires_explicit_cheapest_and_price_counts(self) -> None:
        records = []
        traces = []
        for index in range(10):
            identity = f"{index + 1:032d}"
            trace, record = self.make_run(run_id=identity, job="flights")
            outcome = json.loads((trace / "outcome.json").read_text(encoding="utf-8"))
            outcome["evidence"] = {}
            (trace / "outcome.json").write_text(json.dumps(outcome), encoding="utf-8")
            checker = {"job": "flights", "run_id": identity, "passed": True,
                       "check": {"passed": True, "cheapest_option_correct": True,
                                 "hallucinated_price_count": 0}}
            (trace / "checker.json").write_text(json.dumps(checker), encoding="utf-8")
            records.append({**record, "check": checker["check"]})
            traces.append(trace)
        (traces[0] / "checker.json").write_text(json.dumps({"job": "flights",
            "run_id": records[0]["run_id"], "passed": True,
            "check": {"passed": True, "hallucinated_price_count": 0}}), encoding="utf-8")
        summary_path = traces[-1] / "summary.json"
        summary_path.write_text(json.dumps({"job": "flights", "status": "passed",
            "runs_requested": 10, "runs_passed": 10, "runs": records,
            "median_seconds": 100.0}), encoding="utf-8")
        with mock.patch.object(gate, "TRACE_ROOT", self.trace_root):
            summary, reason = gate.validated_job_summary(summary_path, "flights", 10,
                self.commit, self.now - 100, self.now + 1)
        self.assertIsNone(summary)
        self.assertEqual(reason, "flight independent checker is missing boolean cheapest_option_correct")

    def test_flight_checker_counts_hallucinated_prices_on_failed_rows(self) -> None:
        records = []
        traces = []
        for index in range(10):
            identity = f"{index + 1:032d}"
            trace, record = self.make_run(run_id=identity, job="flights")
            outcome = json.loads((trace / "outcome.json").read_text(encoding="utf-8"))
            outcome["evidence"] = {}
            (trace / "outcome.json").write_text(json.dumps(outcome), encoding="utf-8")
            passed = index < 9
            checker = {"job": "flights", "run_id": identity, "passed": passed,
                       "check": {"passed": passed, "cheapest_option_correct": passed,
                                 "hallucinated_price_count": 1 if index == 9 else 0}}
            (trace / "checker.json").write_text(json.dumps(checker), encoding="utf-8")
            record["passed"] = passed
            records.append({**record, "check": checker["check"]})
            traces.append(trace)
        summary_path = traces[-1] / "summary.json"
        summary_path.write_text(json.dumps({"job": "flights", "status": "failed",
            "runs_requested": 10, "runs_passed": 9, "runs": records,
            "median_seconds": 100.0}), encoding="utf-8")
        with mock.patch.object(gate, "TRACE_ROOT", self.trace_root):
            summary, reason = gate.validated_job_summary(summary_path, "flights", 10,
                self.commit, self.now - 100, self.now + 1)
        self.assertIsNone(summary)
        self.assertEqual(reason, "flight checker found a hallucinated price")

    def test_full_test_argv_requires_test_action_fresh_result_and_no_selectors(self) -> None:
        good = ["/usr/bin/xcodebuild", "-resultBundlePath", str(self.root / "fresh.xcresult"),
                "-parallel-testing-enabled", "NO", "test"]
        self.assertEqual(gate.xcode_test_result_path(good), (self.root / "fresh.xcresult").resolve())
        without_build = [*good[:-1], "test-without-building"]
        self.assertEqual(gate.xcode_test_result_path(without_build), (self.root / "fresh.xcresult").resolve())
        for bad in (
            [*good[:-1], "build-for-testing"],
            [*good, "-only-testing:RemoteDesktopHostTests/SomeTests/testOne"],
            [*good, "-skip-testing", "RemoteDesktopHostTests/SomeTests"],
            ["/usr/bin/xcodebuild", "test"],
        ):
            with self.subTest(argv=bad), self.assertRaises(ValueError):
                gate.xcode_test_result_path(bad)

    def test_default_host_suite_is_full_sequential_xcode_test_with_result_bundle(self) -> None:
        result = self.root / "full.xcresult"
        argv = gate.default_test_command(self.root / "DerivedData", result)
        self.assertEqual(argv[0], "/usr/bin/xcodebuild")
        self.assertIn("host-mac/RemoteDesktopHost.xcodeproj", argv)
        self.assertIn("RemoteDesktopHost", argv)
        self.assertIn("-parallel-testing-enabled", argv)
        self.assertEqual(argv[argv.index("-parallel-testing-enabled") + 1], "NO")
        self.assertEqual(gate.xcode_test_result_path(argv), result.resolve())

    def test_xcresult_requires_fresh_passed_nonempty_summary_and_zero_failures(self) -> None:
        bundle = self.root / "suite.xcresult"
        bundle.mkdir()
        now = time.time()
        passed = {"result": "Passed", "totalTestCount": 10, "passedTests": 9,
                  "skippedTests": 1, "failedTests": 0, "expectedFailures": 0}
        with mock.patch.object(gate.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, json.dumps(passed), "")):
            valid, detail = gate.validate_xcode_test_result(bundle, now - 1, time.time() + 1)
        self.assertTrue(valid)
        self.assertIn("1 skipped", detail)
        failed = {**passed, "passedTests": 8, "failedTests": 1}
        with mock.patch.object(gate.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, json.dumps(failed), "")):
            valid, detail = gate.validate_xcode_test_result(bundle, now - 1, time.time() + 1)
        self.assertFalse(valid)
        self.assertIn("zero failures", detail)

    def test_private_local_test_argv_uses_the_gates_fresh_result_destination(self) -> None:
        destination = self.root / "run-id" / "host-suite.xcresult"
        base = ["xcodebuild", "test", "HOST_BUNDLE_IDENTIFIER=local.test-host"]
        for configured in (base, [*base, "-resultBundlePath", "/tmp/old.xcresult"],
                           [*base, "-resultBundlePath=/tmp/old.xcresult"]):
            prepared = gate.with_test_result_bundle(configured, destination)
            self.assertEqual(gate.xcode_test_result_path(prepared), destination.resolve())
            self.assertIn("HOST_BUNDLE_IDENTIFIER=local.test-host", prepared)
            self.assertNotIn("/tmp/old.xcresult", prepared)

    def test_timed_out_command_kills_its_owned_descendant_process_group(self) -> None:
        marker = self.root / "descendant-survived"
        child = "import pathlib,time; time.sleep(.7); pathlib.Path(%r).write_text('alive')" % str(marker)
        parent = ("import subprocess,sys,time; "
                  "subprocess.Popen([sys.executable, '-c', %r]); time.sleep(30)") % child
        log = self.root / "timeout.log"
        code, elapsed = gate.run_command([sys.executable, "-c", parent], "timeout test", log, timeout=.3)
        self.assertEqual(code, 124)
        self.assertGreaterEqual(elapsed, .3)
        time.sleep(.9)
        self.assertFalse(marker.exists(), "descendant process outlived the timed-out command")


if __name__ == "__main__":
    unittest.main()
