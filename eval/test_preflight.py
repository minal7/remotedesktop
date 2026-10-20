from __future__ import annotations

import unittest

import run_suite
from preflight import (EXPECTED_CHECKS, _trust_receipt_is_valid, _trust_seed_request_is_valid, evaluate,
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

    def test_https_origins_are_canonical_deduplicated_and_only_declared_origins_are_seeded(self) -> None:
        tasks = [
            {"surface": "web", "start": {"url": "https://EXAMPLE.test:443/a?q=1"}},
            {"surface": "web", "start": {"url": "https://example.test/b"}},
            {"surface": "web", "start": {"url": "https://other.test/path"}},
        ]
        self.assertEqual(trust_seeds_for_tasks(tasks), [
            {"kind": "app", "identity": "Safari"},
            {"kind": "web", "identity": "https://example.test"},
            {"kind": "web", "identity": "https://other.test"},
        ])

    def test_demo_public_origins_are_seeded_without_unrelated_hosts(self) -> None:
        tasks = [task.value for task in run_suite.load_tasks("demo")]
        seeds = trust_seeds_for_tasks(tasks)
        origins = [seed["identity"] for seed in seeds if seed["kind"] == "web"]
        self.assertEqual(origins, [
            "http://127.0.0.1:8765", "https://en.wikipedia.org", "https://mail.google.com",
            "https://www.apple.com", "https://www.google.com",
        ])
        self.assertNotIn("https://example.com", origins)

    def test_bad_or_userinfo_start_urls_are_rejected(self) -> None:
        for url in ["", "not a url", "https://user:pass@example.test/a",
                    "https://example.test:444/a", "http://example.test/", "https://example.test:bad",
                    "https://exa_mple.test", "https://example.test%2f.evil", "https://[2001:db8::1]/"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                trust_seeds_for_tasks([{"surface": "web", "start": {"url": url}}])

    def test_only_declared_apps_and_canonical_origins_are_seedable(self) -> None:
        app = {"surface": "app", "start": {"app": "Terminal"}}
        with self.assertRaises(ValueError):
            trust_seeds_for_tasks([app])
        self.assertFalse(_trust_seed_request_is_valid([{"kind": "app", "identity": "Terminal"}]))
        self.assertTrue(_trust_seed_request_is_valid([{"kind": "web", "identity": "https://example.test"}]))
        for identity in ["https://EXAMPLE.test", "https://example.test/", "https://u:p@example.test",
                         "https://example.test:443", "https://example.test:8443", "http://example.test",
                         "https://exa_mple.test", "https://example.test%2f.evil", "https://[2001:db8::1]"]:
            with self.subTest(identity=identity):
                self.assertFalse(_trust_seed_request_is_valid([{"kind": "web", "identity": identity}]))
        self.assertFalse(_trust_seed_request_is_valid([
            {"kind": "web", "identity": "https://example.test"},
            {"kind": "web", "identity": "https://example.test"},
        ]))
        bounded = [{"kind": "web", "identity": f"https://host{index}.example"} for index in range(32)]
        self.assertTrue(_trust_seed_request_is_valid(bounded))
        self.assertFalse(_trust_seed_request_is_valid(bounded + [{"kind": "web", "identity": "https://extra.example"}]))

    def test_trust_receipt_must_match_each_canonical_requested_origin(self) -> None:
        base = {"trust_store_path": "/Users/test/Library/Application Support/RemoteDesktopHost/AgentTrust"}
        seeds = [{"kind": "web", "identity": "https://example.test"}]
        self.assertTrue(_trust_receipt_is_valid({**base, "trusted_surfaces": seeds}, seeds))
        self.assertFalse(_trust_receipt_is_valid({**base, "trusted_surfaces": [
            {"kind": "web", "identity": "https://other.test"},
        ]}, seeds))


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
