import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "host-mac/scripts/run_osatlas_acceptance.sh"


class OSAtlasAcceptanceRunnerContractTests(unittest.TestCase):
    def run_script(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), *arguments],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_actual_model_requires_explicit_release_before_build(self) -> None:
        defaulted = self.run_script("--actual-model")
        explicit_debug = self.run_script(
            "--actual-model", "--configuration", "Debug"
        )

        for completed in (defaulted, explicit_debug):
            self.assertEqual(completed.returncode, 2)
            self.assertIn(
                "Actual-model and live acceptance require --configuration Release.",
                completed.stderr,
            )
        model_flag = Path(
            f"/tmp/com.threadmark.remotedesktop.osatlas-model-e2e-{os.getuid()}"
        )
        self.assertFalse(model_flag.exists())

    def test_live_debug_rejects_before_task_environment_or_build(self) -> None:
        completed = self.run_script(
            "--live-doordash",
            "--allow-visible-ui",
            "--configuration",
            "Debug",
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn(
            "Actual-model and live acceptance require --configuration Release.",
            completed.stderr,
        )
        self.assertNotIn("DOORDASH_EXPECTED_ITEM", completed.stderr)

    def test_configuration_value_is_required_and_allowlisted(self) -> None:
        missing = self.run_script("--configuration")
        invalid = self.run_script("--configuration", "Profile")

        self.assertEqual(missing.returncode, 2)
        self.assertIn("Missing value for --configuration.", missing.stderr)
        self.assertEqual(invalid.returncode, 2)
        self.assertIn("Unsupported configuration: Profile", invalid.stderr)

    def test_all_xcodebuild_lanes_share_the_selected_configuration(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertEqual(source.count('-configuration "$configuration"'), 3)
        self.assertEqual(source.count("-disableAutomaticPackageResolution"), 3)
        self.assertEqual(
            source.count("-onlyUsePackageVersionsFromResolvedFile"), 3
        )
        self.assertEqual(source.count("ENABLE_TESTABILITY=YES"), 3)
        self.assertNotIn("    -configuration Debug \\\n", source)
        self.assertIn('configuration="Debug"', source)
        self.assertNotIn("DETERMINISTIC_EXPECTED_TESTS=", source)
        self.assertIn('"${deterministic_selectors[@]}"', source)
        self.assertIn('--result "$deterministic_result"', source)

    def test_future_package_is_a_separate_explicit_release_lane(self) -> None:
        completed = self.run_script("--future-semantic-package")
        self.assertEqual(completed.returncode, 2)
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("testCurrentProductionPackageRoutesNaturalLanguageToGroundedApproval", source)
        self.assertIn('if [[ $run_future_semantic_package -eq 1 ]]; then', source)


if __name__ == "__main__":
    unittest.main()
