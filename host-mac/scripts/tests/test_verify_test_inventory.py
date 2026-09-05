import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("inventory", ROOT / "host-mac/scripts/verify_test_inventory.py")
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class TestInventoryTests(unittest.TestCase):
    def test_reviewed_inventory_matches_current_source(self):
        manifest = inventory.load_manifest(ROOT / "host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json")
        inventory.compare(set(manifest["expectedTests"]), inventory.selected_source_tests(manifest, ROOT), "Source")

    def test_client_inventory_requires_its_actual_source_directory_and_target(self):
        required = "RemoteDesktopTests/ComputerUseSetupTests/test_coordinatorDoesNotLetReadyAdvertisementFinishOrHideFailedSetup"
        manifest = {"selectors": [required], "expectedTests": [required]}
        observed = inventory.selected_source_tests(manifest, ROOT,
            source_directory=Path("ios/RemoteDesktopTests"), target="RemoteDesktopTests")
        self.assertEqual(observed, {required})
        for kwargs in [{}, {"source_directory": Path("ios/RemoteDesktopTests")},
                       {"target": "RemoteDesktopTests"}]:
            with self.assertRaises(inventory.InventoryError):
                inventory.selected_source_tests(manifest, ROOT, **kwargs)

    def test_matching_method_in_wrong_executed_target_cannot_pass(self):
        required = "RemoteDesktopTests/ComputerUseSetupTests/testReady"
        manifest = {"expectedTests": [required]}
        report = {"testNodes": [{"nodeType": "Unit test bundle", "name": "RemoteDesktopTests",
            "children": [{"nodeType": "Test Case", "nodeIdentifier": "ComputerUseSetupTests/testReady()",
                          "result": "Passed"}]}]}
        inventory.verify_result(manifest, self.summary(1), report)
        report['testNodes'][0]['name'] = 'RemoteDesktopHostTests'
        with self.assertRaises(inventory.InventoryError):
            inventory.verify_result(manifest, self.summary(1), report)

    def result(self, names, statuses=None):
        statuses = statuses or ["Passed"] * len(names)
        return {"testNodes": [{"nodeType": "Unit test bundle", "name": "RemoteDesktopHostTests",
            "children": [{"nodeType": "Test Case", "nodeIdentifier": f"Suite/{name}()", "result": status}
                         for name, status in zip(names, statuses)]}]}

    def summary(self, count):
        return {"result": "Passed", "totalTestCount": count, "passedTests": count,
                "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}

    def test_wrong_test_with_same_total_does_not_pass(self):
        manifest = {"expectedTests": ["RemoteDesktopHostTests/Suite/testRequired"]}
        with self.assertRaises(inventory.InventoryError):
            inventory.verify_result(manifest, self.summary(1), self.result(["testUnrelated"]))

    def test_skip_or_duplicate_does_not_count_as_passing(self):
        manifest = {"expectedTests": ["RemoteDesktopHostTests/Suite/testRequired"]}
        for report in [self.result(["testRequired"], ["Skipped"]),
                       self.result(["testRequired", "testRequired"])]:
            with self.assertRaises(inventory.InventoryError):
                inventory.verify_result(manifest, self.summary(1), report)

    def test_matching_identifiers_and_successful_outcomes_pass(self):
        manifest = {"expectedTests": ["RemoteDesktopHostTests/Suite/testRequired"]}
        inventory.verify_result(manifest, self.summary(1), self.result(["testRequired"]))

    def test_empty_report_and_inconsistent_summary_fail(self):
        manifest = {"expectedTests": ["RemoteDesktopHostTests/Suite/testRequired"]}
        for summary, report in [(self.summary(1), self.result([])),
                                (self.summary(2), self.result(["testRequired"]))]:
            with self.assertRaises(inventory.InventoryError):
                inventory.verify_result(manifest, summary, report)


if __name__ == "__main__":
    unittest.main()
