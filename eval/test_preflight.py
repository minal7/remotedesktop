from __future__ import annotations

import unittest

import run_suite
from preflight import (EXPECTED_CHECKS, _trust_seed_request_is_valid, evaluate,
                       task_infra_row, trust_seeds_for_tasks)


class PreflightTrustSeedTests(unittest.TestCase):
    def test_smoke_suite_trust_seeds_are_bounded_and_deterministic(self) -> None:
        tasks = [task.value for task in run_suite.smoke_tasks()]
        seeds = trust_seeds_for_tasks(tasks)
        self.assertEqual(seeds, [
            {"kind": "app", "identity": "Finder"},
            {"kind": "app", "identity": "Notes"},
            {"kind": "app", "identity": "Safari"},
            {"kind": "app", "identity": "TextEdit"},
            {"kind": "web", "identity": "http://127.0.0.1:8765"},
        ])
        self.assertTrue(_trust_seed_request_is_valid(seeds))

    def test_only_declared_apps_and_exact_fixture_origin_are_seedable(self) -> None:
        app = {"surface": "app", "start": {"app": "Terminal"}}
        with self.assertRaises(ValueError):
            trust_seeds_for_tasks([app])
        self.assertFalse(_trust_seed_request_is_valid([{"kind": "app", "identity": "Terminal"}]))
        self.assertFalse(_trust_seed_request_is_valid([{"kind": "web", "identity": "https://example.test"}]))


class GUIPolicyPreflightTests(unittest.TestCase):
    def test_ready_gui_owl_preflight_is_accepted_but_unknown_or_mismatched_policy_is_rejected(self) -> None:
        seeds = [
            {"kind": "app", "identity": "Safari"},
            {"kind": "web", "identity": "http://127.0.0.1:8765"},
        ]
        response = {
            "operation": "preflight", "real_host_app": True, "outcome": "ready",
            "checks": [{"name": name, "status": "passed"} for name in EXPECTED_CHECKS],
            "active_environment": "pixel", "policy": "gui-owl15-4b",
            "trusted_surfaces": [
                {"kind": "app", "identity": "com.apple.Safari"},
                {"kind": "web", "identity": "http://127.0.0.1:8765"},
            ],
            "trust_store_path": "/Users/test/Library/Application Support/RemoteDesktopHost/AgentTrust",
            "model_status": "loaded",
        }

        self.assertTrue(evaluate(response, "gui-owl15-4b", seeds).passed)
        self.assertFalse(evaluate(response, "unknown-policy", seeds).passed)
        mismatched = {**response, "policy": "ui-tars15-7b"}
        self.assertFalse(evaluate(mismatched, "gui-owl15-4b", seeds).passed)

    def test_gui_owl_infrastructure_rows_request_full_display_capture(self) -> None:
        row = task_infra_row("native-008", "native", 1, ["native"], "real-host",
                             "host preflight failed", requested_policy="gui-owl15-4b")
        self.assertEqual(row["requested_policy"], "gui-owl15-4b")
        self.assertEqual(row["requested_crop_mode"], "full-display")


if __name__ == "__main__":
    unittest.main()
