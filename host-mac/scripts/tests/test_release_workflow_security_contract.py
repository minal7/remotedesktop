import pathlib
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


if __name__ == "__main__":
    unittest.main()
