#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
HOST_DIRECTORY = SCRIPT_DIRECTORY.parent
SCRIPT_PATH = SCRIPT_DIRECTORY / "package_llama_runtime.sh"


class PackageLlamaRuntimeBuildPhaseTests(unittest.TestCase):
    def run_phase(self, build_directory: pathlib.Path, *, signing_allowed: str | None) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "SRCROOT": str(HOST_DIRECTORY),
                "TARGET_BUILD_DIR": str(build_directory),
                "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Contents/Resources",
                "EXPANDED_CODE_SIGN_IDENTITY": "",
            }
        )
        environment.pop("CODE_SIGNING_ALLOWED", None)
        if signing_allowed is not None:
            environment["CODE_SIGNING_ALLOWED"] = signing_allowed
        return subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH)],
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_unsigned_compile_phase_still_verifies_and_copies_pinned_runtime(self) -> None:
        with tempfile.TemporaryDirectory(prefix="llama-runtime-unsigned-phase-") as directory:
            build_directory = pathlib.Path(directory)
            result = self.run_phase(build_directory, signing_allowed="NO")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("verified pinned llama runtime copied for compile-only unsigned build", result.stdout)
            self.assertIn("code signing skipped", result.stdout)
            destination = (
                build_directory
                / "Contents/Resources/ComputerUseRuntime/llama-b9992"
            )
            self.assertTrue((destination / "runtime-manifest.json").is_file())
            self.assertTrue((destination / "llama-server").is_file())
            self.assertTrue((destination / "libllama.0.dylib").is_symlink())

    def test_default_signing_path_still_requires_a_selected_identity(self) -> None:
        with tempfile.TemporaryDirectory(prefix="llama-runtime-signing-required-") as directory:
            build_directory = pathlib.Path(directory)
            result = self.run_phase(build_directory, signing_allowed=None)

            self.assertEqual(result.returncode, 65)
            self.assertIn("Missing required Xcode build variable: EXPANDED_CODE_SIGN_IDENTITY", result.stderr)
            destination = (
                build_directory
                / "Contents/Resources/ComputerUseRuntime/llama-b9992"
            )
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
