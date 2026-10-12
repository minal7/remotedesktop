import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "host-mac/scripts/run_osatlas_acceptance.sh"


class OSAtlasAcceptanceRunnerContractTests(unittest.TestCase):
    def run_script(self, *arguments: str, path: str | None = None) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        if path is not None:
            environment["PATH"] = path
        return subprocess.run(
            [str(SCRIPT), *arguments],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )

    def test_configuration_value_is_required_and_allowlisted(self) -> None:
        missing = self.run_script("--configuration")
        invalid = self.run_script("--configuration", "Profile")

        self.assertEqual(missing.returncode, 2)
        self.assertIn("Missing value for --configuration.", missing.stderr)
        self.assertEqual(invalid.returncode, 2)
        self.assertIn("Unsupported configuration: Profile", invalid.stderr)

    def test_removed_acceptance_lanes_fail_fast_as_unknown_options(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "xcodebuild-called"
            fake_xcodebuild = Path(directory) / "xcodebuild"
            fake_xcodebuild.write_text(
                f"#!/bin/sh\ntouch '{marker}'\nexit 99\n", encoding="utf-8"
            )
            fake_xcodebuild.chmod(0o755)

            for obsolete_flag in (
                "--actual-model",
                "--future-semantic-package",
                "--live-doordash",
                "--allow-visible-ui",
            ):
                with self.subTest(flag=obsolete_flag):
                    completed = self.run_script(obsolete_flag, path=directory)
                    self.assertEqual(completed.returncode, 2)
                    self.assertIn(f"Unknown option: {obsolete_flag}", completed.stderr)
                    self.assertFalse(marker.exists())

    def test_deterministic_lane_keeps_selected_configuration_lock_and_inventory(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertEqual(source.count("xcodebuild test"), 1)
        self.assertEqual(source.count('-configuration "$configuration"'), 1)
        self.assertEqual(source.count("-disableAutomaticPackageResolution"), 1)
        self.assertEqual(source.count("-onlyUsePackageVersionsFromResolvedFile"), 1)
        self.assertEqual(source.count("ENABLE_TESTABILITY=YES"), 1)
        self.assertIn('configuration="Debug"', source)
        self.assertIn("    Debug|Release)", source)
        self.assertIn('"${deterministic_selectors[@]}"', source)
        self.assertIn("--selectors", source)
        self.assertIn('--result "$deterministic_result"', source)
        self.assertNotIn("DETERMINISTIC_EXPECTED_TESTS=", source)
        for removed_lane in ("actual_model", "future_semantic_package", "live_doordash"):
            self.assertNotIn(removed_lane, source)


if __name__ == "__main__":
    unittest.main()
