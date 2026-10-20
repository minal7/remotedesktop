import pathlib
import os
import subprocess
import tempfile
import textwrap
import unittest


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[3]
RELEASE_WORKFLOW = REPOSITORY_ROOT / ".github" / "workflows" / "release.yml"


class ReleaseWorkflowSecurityContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

    def test_published_windows_release_requires_authenticode_secrets(self) -> None:
        self.assertIn(
            "Published Windows releases require Authenticode secrets",
            self.workflow,
        )
        self.assertIn(
            "WINDOWS_CERTIFICATE_PFX: ${{ secrets.WINDOWS_CERTIFICATE_PFX }}",
            self.workflow,
        )
        self.assertIn(
            "WINDOWS_CERTIFICATE_PASSWORD: ${{ secrets.WINDOWS_CERTIFICATE_PASSWORD }}",
            self.workflow,
        )
        self.assertIn(
            "WINDOWS_SIGNING_STORE_NAME: "
            "RemoteDesktopSigning-${{ github.run_id }}-${{ github.run_attempt }}",
            self.workflow,
        )
        self.assertIn("-CertStoreLocation $storePath", self.workflow)
        self.assertNotIn(
            "-CertStoreLocation Cert:\\CurrentUser\\My",
            self.workflow,
        )

    def test_inner_executable_is_signed_before_installer_is_built(self) -> None:
        sign_executable = self.workflow.index(
            "- name: Sign Windows host executable"
        )
        build_installer = self.workflow.index("- name: Build installer")
        self.assertLess(sign_executable, build_installer)
        self.assertGreaterEqual(
            self.workflow.count("/s $env:WINDOWS_SIGNING_STORE_NAME"),
            2,
        )

    def test_installer_is_verified_before_any_windows_upload(self) -> None:
        verify_installer = self.workflow.index(
            "- name: Sign and verify Windows installer"
        )
        release_upload = self.workflow.index(
            "- name: Upload Windows release installer"
        )
        candidate_upload = self.workflow.index(
            "- name: Upload SHA-bound Windows candidate"
        )
        self.assertLess(verify_installer, release_upload)
        self.assertLess(verify_installer, candidate_upload)
        self.assertGreaterEqual(self.workflow.count("/td SHA256"), 2)
        self.assertGreaterEqual(self.workflow.count("/tr $env:TIMESTAMP_URL"), 2)
        self.assertGreaterEqual(
            self.workflow.count("TimeStamperCertificate"),
            2,
        )
        self.assertGreaterEqual(
            self.workflow.count("if ($LASTEXITCODE -ne 0)"),
            5,
        )

    def test_unsigned_candidates_are_not_packaged_or_uploaded(self) -> None:
        self.assertIn(
            "No Windows candidate will be packaged or uploaded because "
            "Authenticode signing is not configured.",
            self.workflow,
        )
        guarded_steps = [
            "- name: Build installer",
            "- name: Create Windows candidate provenance",
            "- name: Upload SHA-bound Windows candidate",
        ]
        for step in guarded_steps:
            start = self.workflow.index(step)
            snippet = self.workflow[start : start + 300]
            self.assertIn(
                "steps.windows-signing.outputs.configured == 'true'",
                snippet,
            )

        cleanup = self.workflow.index(
            "- name: Remove imported Windows signing material"
        )
        cleanup_snippet = self.workflow[cleanup : cleanup + 1_500]
        self.assertIn("if: always()", cleanup_snippet)
        self.assertNotIn(
            "steps.windows-signing.outputs.configured",
            cleanup_snippet,
        )
        self.assertIn(
            "Refusing to remove a Windows certificate store without "
            "a matching ownership marker.",
            cleanup_snippet,
        )
        self.assertIn(
            "Remove-Item -LiteralPath $storePath -Recurse -Force",
            cleanup_snippet,
        )

    def test_failed_macos_debug_tests_retain_exact_result_bundle(self) -> None:
        self.assertIn(
            '-resultBundlePath "$RUNNER_TEMP/host-tests.xcresult"',
            self.workflow,
        )
        summarize = self.workflow.index(
            "- name: Summarize failed macOS Debug tests"
        )
        upload = self.workflow.index(
            "- name: Upload failed macOS Debug test result"
        )
        archive = self.workflow.index("- name: Build signed archive")
        self.assertLess(summarize, upload)
        self.assertLess(upload, archive)
        self.assertIn(
            "xcrun xcresulttool get test-results summary",
            self.workflow[summarize:upload],
        )
        self.assertIn(
            "if: ${{ failure() }}",
            self.workflow[summarize:archive],
        )
        self.assertIn(
            "macos-debug-xcresult-"
            "${{ needs.resolve-version.outputs.release_sha }}-attempt-"
            "${{ github.run_attempt }}",
            self.workflow[upload:archive],
        )

    def test_archive_hardens_xcode_embedded_swift_compatibility_code(
        self,
    ) -> None:
        archive = self.workflow.index("- name: Build signed archive")
        validate = self.workflow.index(
            "- name: Validate macOS distribution signature"
        )
        archive_block = self.workflow[archive:validate]
        self.assertIn(
            'OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"',
            archive_block,
        )

        notarize = self.workflow.index("- name: Notarize and staple app")
        validation_block = self.workflow[validate:notarize]
        self.assertIn(
            "Nested Mach-O code is missing the hardened runtime",
            validation_block,
        )
        self.assertIn(
            "Nested code is missing a secure timestamp",
            validation_block,
        )

    def test_version_resolver_uses_platform_versions_and_rejects_mismatches(self) -> None:
        resolver = self._resolve_version_script()
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = pathlib.Path(temporary_directory)
            self._initialize_test_repository(repository)
            head_sha = self._git(repository, "rev-parse", "HEAD")

            accepted = self._run_resolver(
                repository,
                resolver,
                event="workflow_dispatch",
                requested_version="0.3.0",
                publish="false",
                event_sha=head_sha,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            outputs = dict(line.split("=", 1) for line in accepted.outputs.splitlines())
            self.assertEqual(outputs["version"], "0.3.0")
            self.assertEqual(outputs["macos_version"], "0.3.0")
            self.assertEqual(outputs["macos_build"], "1")
            self.assertEqual(outputs["windows_version"], "0.2.1")
            self.assertEqual(outputs["tag_name"], "v0.3.0")
            self.assertEqual(outputs["publish"], "false")

            old_windows_version = self._run_resolver(
                repository,
                resolver,
                event="workflow_dispatch",
                requested_version="0.2.1",
                publish="false",
                event_sha=head_sha,
            )
            self.assertNotEqual(old_windows_version.returncode, 0)
            self.assertIn("does not match macOS host version 0.3.0", old_windows_version.stdout)

            wrong_event_sha = self._run_resolver(
                repository,
                resolver,
                event="workflow_dispatch",
                requested_version="0.3.0",
                publish="false",
                event_sha="0" * 40,
            )
            self.assertNotEqual(wrong_event_sha.returncode, 0)
            self.assertIn("does not match immutable event commit", wrong_event_sha.stdout)

            self._git(repository, "tag", "v0.3.0", head_sha)
            published = self._run_resolver(
                repository,
                resolver,
                event="workflow_dispatch",
                requested_version="0.3.0",
                publish="true",
                event_sha=head_sha,
            )
            self.assertEqual(published.returncode, 0, published.stderr)
            published_outputs = dict(
                line.split("=", 1) for line in published.outputs.splitlines()
            )
            self.assertEqual(published_outputs["publish"], "true")
            self.assertEqual(published_outputs["artifact_suffix"], "")

            self._git(repository, "tag", "-f", "v0.3.0", "HEAD^")
            wrong_tag_sha = self._run_resolver(
                repository,
                resolver,
                event="workflow_dispatch",
                requested_version="0.3.0",
                publish="true",
                event_sha=head_sha,
            )
            self.assertNotEqual(wrong_tag_sha.returncode, 0)
            self.assertIn("points to", wrong_tag_sha.stdout)

    def _resolve_version_script(self) -> str:
        lines = self.workflow.splitlines()
        step = lines.index("      - name: Resolve version")
        run_marker = lines.index("        run: |", step)
        script_lines = []
        for line in lines[run_marker + 1 :]:
            if line and not line.startswith("          "):
                break
            script_lines.append(line[10:] if line else "")
        return textwrap.dedent("\n".join(script_lines))

    def _initialize_test_repository(self, repository: pathlib.Path) -> None:
        (repository / "host-windows").mkdir()
        (repository / "host-mac").mkdir()
        (repository / "host-windows" / "Cargo.toml").write_text(
            '[package]\nname = "test"\nversion = "0.2.1"\n', encoding="utf-8"
        )
        (repository / "host-mac" / "project.yml").write_text(
            "settings:\n  MARKETING_VERSION: 0.3.0\n"
            "  CURRENT_PROJECT_VERSION: 1\n",
            encoding="utf-8",
        )
        self._git(repository, "init", "-q")
        self._git(repository, "add", ".")
        self._git(repository, "-c", "user.name=Contract Test", "-c",
                  "user.email=contract@example.test", "-c", "commit.gpgsign=false",
                  "commit", "-m", "fixture")
        (repository / "fixture.txt").write_text("second commit\n", encoding="utf-8")
        self._git(repository, "add", "fixture.txt")
        self._git(repository, "-c", "user.name=Contract Test", "-c",
                  "user.email=contract@example.test", "-c", "commit.gpgsign=false",
                  "commit", "-m", "second fixture")

    def _git(self, repository: pathlib.Path, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def _run_resolver(
        self,
        repository: pathlib.Path,
        script: str,
        *,
        event: str,
        requested_version: str,
        publish: str,
        event_sha: str,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile(dir=repository, delete=False) as output_file:
            output_path = pathlib.Path(output_file.name)
        try:
            environment = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "GITHUB_EVENT_NAME": event,
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_SHA": event_sha,
                "GITHUB_OUTPUT": str(output_path),
                "REQUESTED_VERSION": requested_version,
                "REQUESTED_PUBLISH": publish,
            }
            result = subprocess.run(
                ["/bin/bash", "-c", script],
                cwd=repository,
                env=environment,
                capture_output=True,
                text=True,
            )
            result.outputs = output_path.read_text(encoding="utf-8")
            return result
        finally:
            output_path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
