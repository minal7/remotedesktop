from __future__ import annotations

import unittest

import run_suite
from preflight import _trust_seed_request_is_valid, trust_seeds_for_tasks


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


if __name__ == "__main__":
    unittest.main()
