#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "script/build_and_run.sh"
INSTALL_SCRIPT = REPO_ROOT / "host-mac/scripts/install_host.sh"
TRUST_SCRIPT = REPO_ROOT / "host-mac/scripts/verify_host_bundle_trust.sh"
HOST_APP = REPO_ROOT / "host-mac/RemoteDesktopHost/App.swift"
HEADLESS_SETTINGS = (
    REPO_ROOT / "host-mac/RemoteDesktopHost/HeadlessHostSettings.swift"
)


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
            '"$script_dir/verify_host_bundle_trust.sh" \\\n'
            '  "${trust_arguments[@]}"'
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
        validate_old_bundle = source.index(
            "validate_existing_installed_app",
            cloudkit,
        )
        remove_old_bundle = source.index(
            "remove_validated_installed_app",
            terminate_runtime,
        )
        install_new_bundle = source.index(
            '/usr/bin/ditto "$built_app" "$installed_app"'
        )

        self.assertLess(trust, terminate_host)
        self.assertLess(trust, cloudkit)
        self.assertLess(cloudkit, validate_old_bundle)
        self.assertLess(validate_old_bundle, terminate_host)
        self.assertLess(cloudkit, terminate_host)
        self.assertLess(terminate_host, terminate_runtime)
        self.assertLess(terminate_runtime, remove_old_bundle)
        self.assertLess(remove_old_bundle, install_new_bundle)
        self.assertNotIn("pkill", source)

    def test_installer_rejects_every_noncanonical_install_directory_before_work(
        self,
    ) -> None:
        for unsafe_path in [
            "/",
            "/Applications/",
            "/tmp/../Applications",
            "/tmp/installer-contract-probe",
        ]:
            with self.subTest(unsafe_path=unsafe_path):
                completed = subprocess.run(
                    [
                        str(INSTALL_SCRIPT),
                        "--install-dir",
                        unsafe_path,
                        "--help",
                    ],
                    cwd=REPO_ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(completed.returncode, 64)
                self.assertIn(
                    "Refusing noncanonical install directory",
                    completed.stderr,
                )
                self.assertNotIn("xcodebuild", completed.stdout + completed.stderr)

    def test_installer_accepts_explicit_applications_directory(self) -> None:
        completed = subprocess.run(
            [
                str(INSTALL_SCRIPT),
                "--install-dir",
                "/Applications",
                "--help",
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0)
        self.assertIn("Usage:", completed.stdout)
        self.assertIn(
            "--install-dir /Applications",
            completed.stdout,
        )
        self.assertNotIn("--install-dir PATH", completed.stdout)

    def test_installer_only_removes_validated_canonical_host_bundle(self) -> None:
        source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        validator = source.split(
            "validate_existing_installed_app() {", 1
        )[1].split("\n}", 1)[0]
        remover = source.split(
            "remove_validated_installed_app() {", 1
        )[1].split("\n}", 1)[0]

        self.assertIn(
            '[[ "$installed_app" != "/Applications/$app_name" ]]',
            validator,
        )
        self.assertIn('[[ -L "$installed_app"', validator)
        self.assertIn('-L "$info_plist"', validator)
        self.assertIn('-L "$installed_executable"', validator)
        self.assertIn('[[ "$installed_bundle_id" != "$bundle_id" ]]', validator)
        self.assertIn("validate_existing_installed_app", remover)
        self.assertIn(
            '/usr/bin/find -x "$installed_app" -depth -delete',
            remover,
        )
        self.assertNotIn('rm -rf "$installed_app"', source)

    def test_installer_defers_legacy_pairing_cleanup_to_symlink_safe_host(
        self,
    ) -> None:
        installer = INSTALL_SCRIPT.read_text(encoding="utf-8")
        headless = installer.split(
            'if [[ "$headless" -eq 1 ]]; then', 1
        )[1].split("\nfi", 1)[0]
        app = HOST_APP.read_text(encoding="utf-8")
        settings = HEADLESS_SETTINGS.read_text(encoding="utf-8")

        self.assertNotIn("legacy_pairing_code_file", installer)
        self.assertNotIn("pairing-code.txt", installer)
        self.assertNotIn("rm -f", headless)
        self.assertIn(
            "HeadlessHostSettings.removeLegacyManualPairingArtifacts()",
            app,
        )
        self.assertIn("O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC", settings)
        self.assertIn("AT_SYMLINK_NOFOLLOW", settings)
        self.assertIn("Darwin.openat(", settings)
        self.assertIn("O_RDONLY | O_NOFOLLOW | O_CLOEXEC", settings)
        self.assertIn(
            "finalStatus.st_ino == openedStatus.st_ino",
            settings,
        )
        self.assertIn("Darwin.unlinkat(directory, $0, 0)", settings)

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

    def test_installer_builds_from_a_clean_derived_data_product(self) -> None:
        source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        build = source.split(
            'if [[ "$configuration" == "Debug" && "$skip_build" -eq 0 ]]; then',
            1,
        )[1].split("\nfi", 1)[0]

        self.assertIn("xcodebuild", build)
        self.assertIn('clean build', build)
        self.assertNotIn(
            '\n    build\n',
            build,
        )

    def test_release_install_requires_explicit_current_source_artifact(self) -> None:
        environment = dict(os.environ)
        environment.update({
            "REMOTE_DESKTOP_APPLE_CONFIGURATION": "Release",
            "REMOTE_DESKTOP_HOST_CONFIGURATION": "Release",
            "REMOTE_DESKTOP_IOS_CONFIGURATION": "Release",
        })
        completed = subprocess.run(
            [str(INSTALL_SCRIPT)],
            cwd=REPO_ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 1)
        self.assertIn(
            "Release installation requires --host-artifact",
            completed.stderr,
        )
        self.assertNotIn("xcodebuild", completed.stdout + completed.stderr)

        source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        selection = source.split(
            "verify_release_artifact_selection() {", 1
        )[1].split("\n}", 1)[0]
        for contract in (
            '[[ "$host_artifact" != /* ]]',
            '[[ "$built_app" == "$installed_app" ]]',
            "^[0-9a-f]{40}$",
            "rev-parse --verify HEAD^{commit}",
            "--porcelain=v1 --untracked-files=normal",
        ):
            self.assertIn(contract, selection)

    def test_release_trust_gate_matches_distribution_contract(self) -> None:
        source = TRUST_SCRIPT.read_text(encoding="utf-8")
        for contract in (
            'expected_team_id="V9AX39SPJD"',
            "Authority=Developer ID Application:",
            "TeamIdentifier=$expected_team_id",
            "flags=[^[:space:]]*",
            "runtime(,[^,]+)*",
            "Timestamp=",
            "Timestamp=none",
            'has_entitlement "get-task-allow"',
            'has_entitlement "com.apple.security.get-task-allow"',
            'has_entitlement "aps-environment"',
            'has_entitlement "com.apple.developer.aps-environment"',
            'cloudkit_environment" != "Production"',
            'container" != "iCloud.com.threadmark.remotedesktop"',
            'service" != "CloudKit"',
            "/usr/bin/find \"$app_bundle/Contents\" -type f -print0",
            "stapler validate",
            "spctl --assess --type execute --verbose=4",
            "source=notarized developer id",
        ):
            self.assertIn(contract, source)
        self.assertIn(
            'elif [[ "$signature_details" == *"Authority=Apple Development:"* ]]',
            source,
        )

    def test_release_provenance_and_install_hash_are_fail_closed(self) -> None:
        trust = TRUST_SCRIPT.read_text(encoding="utf-8")
        installer = INSTALL_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            "-extract RemoteDesktopSourceCommit raw",
            trust,
        )
        self.assertIn(
            'artifact_source_commit" != "$expected_source_commit"',
            trust,
        )
        self.assertIn(
            'built_executable_sha256="$(/usr/bin/shasum -a 256',
            installer,
        )
        self.assertIn(
            'installed_executable_sha256" != "$built_executable_sha256"',
            installer,
        )
        self.assertGreaterEqual(
            installer.count('"$script_dir/verify_host_bundle_trust.sh"'),
            2,
        )

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
