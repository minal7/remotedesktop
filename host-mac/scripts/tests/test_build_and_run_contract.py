#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "script/build_and_run.sh"
INSTALL_SCRIPT = REPO_ROOT / "host-mac/scripts/install_host.sh"


class BuildAndRunContractTests(unittest.TestCase):
    def test_release_is_default_and_launch_stops_canonical_installed_host(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'SHARED_CONFIGURATION="${REMOTE_DESKTOP_APPLE_CONFIGURATION:-Release}"',
            source,
        )
        self.assertIn(
            'INSTALLED_APP_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"',
            source,
        )
        self.assertIn(
            '"$INSTALLED_APP_BINARY"',
            source.split("terminate_competing_installed_host() {", 1)[1],
        )

        open_body = source.split("open_app() {", 1)[1].split("\n}", 1)[0]
        self.assertLess(
            open_body.index("verify_cloudkit_configuration"),
            open_body.index("terminate_competing_installed_host"),
        )
        self.assertLess(
            open_body.index("terminate_competing_installed_host"),
            open_body.index('/usr/bin/open -n "$APP_BUNDLE"'),
        )

    def test_mixed_configuration_fails_before_build_or_launch(self) -> None:
        environment = dict(os.environ)
        environment.update({
            "REMOTE_DESKTOP_HOST_CONFIGURATION": "Debug",
            "REMOTE_DESKTOP_IOS_CONFIGURATION": "Release",
        })
        completed = subprocess.run(
            [str(SCRIPT)],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("Refusing mixed Apple configurations", completed.stderr)
        self.assertNotIn("xcodebuild", completed.stdout + completed.stderr)

    def test_installer_stops_exact_old_image_only_after_new_bundle_is_verified(self) -> None:
        source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        trust = source.index(
            '"$script_dir/verify_host_bundle_trust.sh" "$built_app"'
        )
        cloudkit = source.index("verify_cloudkit_configuration", trust)
        terminate_host = source.index(
            'terminate_exact_processes "$executable"',
            cloudkit,
        )
        terminate_runtime = source.index(
            'terminate_exact_processes "$installed_runtime"',
            terminate_host,
        )
        remove_old_bundle = source.index('rm -rf "$installed_app"')
        install_new_bundle = source.index(
            '/usr/bin/ditto "$built_app" "$installed_app"'
        )

        self.assertLess(trust, terminate_host)
        self.assertLess(trust, cloudkit)
        self.assertLess(cloudkit, terminate_host)
        self.assertLess(terminate_host, terminate_runtime)
        self.assertLess(terminate_runtime, remove_old_bundle)
        self.assertLess(remove_old_bundle, install_new_bundle)
        self.assertNotIn("pkill", source)

    def test_installer_checks_exact_signed_cloudkit_contract(self) -> None:
        source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        verifier = source.split(
            "verify_cloudkit_configuration() {", 1
        )[1].split("\n}", 1)[0]

        self.assertIn("expected_cloudkit_environment", verifier)
        self.assertIn("iCloud.com.threadmark.remotedesktop", verifier)
        self.assertIn("com.apple.developer.icloud-services:0", verifier)
        self.assertIn("*.debug.dylib", verifier)
        self.assertIn("*XCTest*", verifier)

    def test_installer_rejects_declared_mixed_pair_before_build(self) -> None:
        environment = dict(os.environ)
        environment.update({
            "REMOTE_DESKTOP_APPLE_CONFIGURATION": "Debug",
            "REMOTE_DESKTOP_HOST_CONFIGURATION": "Debug",
            "REMOTE_DESKTOP_IOS_CONFIGURATION": "Release",
        })
        completed = subprocess.run(
            [str(INSTALL_SCRIPT), "--debug", "--skip-build"],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("Refusing mixed Apple configurations", completed.stderr)
        self.assertNotIn("xcodebuild", completed.stdout + completed.stderr)


if __name__ == "__main__":
    unittest.main()
