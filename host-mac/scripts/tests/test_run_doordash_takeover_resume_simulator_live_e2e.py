#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock


SCRIPT_PATH = (
    pathlib.Path(__file__).resolve().parents[1]
    / "run_doordash_takeover_resume_simulator_live_e2e.py"
)
spec = importlib.util.spec_from_file_location("doordash_live_runner", SCRIPT_PATH)
assert spec is not None and spec.loader is not None
runner_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner_module
spec.loader.exec_module(runner_module)


class FakeProcess:
    def __init__(
        self,
        return_code: int,
        *,
        result_bundle: pathlib.Path | None = None,
        time_out_first: bool = False,
    ) -> None:
        self.pid = 99123
        self.return_code = return_code
        self.result_bundle = result_bundle
        self.time_out_first = time_out_first
        self.wait_calls = 0
        self.wait_timeouts: list[float | None] = []

    def wait(self, timeout: float | None = None) -> int:
        self.wait_timeouts.append(timeout)
        self.wait_calls += 1
        if self.time_out_first and self.wait_calls == 1:
            raise subprocess.TimeoutExpired("xcodebuild", runner_module.RUN_TIMEOUT_SECONDS)
        if self.result_bundle is not None:
            self.result_bundle.mkdir(parents=True, exist_ok=True)
        return self.return_code


class FakeExecutor:
    public_attachment_uuid = "11111111-2222-3333-4444-555555555555"
    public_attachment_filename = public_attachment_uuid + ".json"
    public_attachment_name = (
        "public_0_" + public_attachment_uuid + ".json"
    )
    public_attachment_payload = json.dumps({
        "authenticationHandoffObserved": True,
        "humanResumeObserved": True,
        "localQuoteStructureValidated": True,
        "strictVisibilityCompleted": True,
    }).encode("utf-8")

    def __init__(
        self,
        paths: runner_module.RunnerPaths,
        *,
        process_return_code: int = 0,
        permissions: dict[str, object] | None = None,
        host_running: bool = True,
        stale_host: bool = False,
        simulator_state: str = "Booted",
        schemes: list[str] | None = None,
        time_out_first: bool = False,
        build_return_code: int = 0,
        generated_xctestrun: object | None = None,
        generated_xctestrun_count: int = 1,
        attachment_manifest: object | None = None,
        attachment_payloads: dict[str, bytes] | None = None,
        attachment_export_return_code: int = 0,
        direct_result_payloads: dict[str, bytes] | None = None,
    ) -> None:
        self.paths = paths
        self.process_return_code = process_return_code
        self.permissions = permissions or {
            "screenRecording": True,
            "accessibility": True,
            "ok": True,
        }
        self.host_running = host_running
        self.stale_host = stale_host
        self.simulator_state = simulator_state
        self.schemes = schemes or [runner_module.SCHEME]
        self.time_out_first = time_out_first
        self.build_return_code = build_return_code
        self.generated_xctestrun = (
            self.default_xctestrun()
            if generated_xctestrun is None
            else generated_xctestrun
        )
        self.generated_xctestrun_count = generated_xctestrun_count
        if attachment_manifest is None:
            default_attachments: list[dict[str, object]] = []
            if process_return_code == 0:
                default_attachments.append({
                    "exportedFileName": self.public_attachment_filename,
                    "suggestedHumanReadableName": self.public_attachment_name,
                    "isAssociatedWithFailure": False,
                })
            self.attachment_manifest = [{
                "testIdentifier": runner_module.RESULT_TEST_IDENTIFIER,
                "testIdentifierURL": runner_module.RESULT_TEST_IDENTIFIER_URL,
                "attachments": default_attachments,
            }]
            default_payloads = (
                {
                    self.public_attachment_filename:
                        self.public_attachment_payload,
                }
                if process_return_code == 0 else {}
            )
        else:
            self.attachment_manifest = attachment_manifest
            default_payloads = {}
        self.attachment_payloads = (
            default_payloads
            if attachment_payloads is None
            else attachment_payloads
        )
        self.attachment_export_return_code = attachment_export_return_code
        self.direct_result_payloads = direct_result_payloads or {}
        self.run_calls: list[list[str]] = []
        self.run_environments: list[dict[str, str] | None] = []
        self.popen_calls: list[tuple[list[str], dict[str, str]]] = []
        self.process: FakeProcess | None = None
        self.generated_xctestrun_paths: list[pathlib.Path] = []
        self.launched_xctestrun_path: pathlib.Path | None = None
        self.launched_xctestrun: object | None = None
        self.launched_xctestrun_mode: int | None = None
        self.private_root_mode: int | None = None
        self.quarantined_result_path: pathlib.Path | None = None

    @staticmethod
    def default_xctestrun() -> dict[str, object]:
        return {
            "__xctestrun_metadata__": {
                "FormatVersion": 1,
                "ContainerInfo": {
                    "SchemeName": runner_module.SCHEME,
                },
            },
            runner_module.XCTESTRUN_TARGET_NAME: {
                "BlueprintName": runner_module.XCTESTRUN_TARGET_NAME,
                "IsUITestBundle": True,
                "PreferredScreenCaptureFormat": "screenRecording",
                "SystemAttachmentLifetime": "deleteOnSuccess",
                "UserAttachmentLifetime": "deleteOnSuccess",
                "DiagnosticCollectionPolicy": 1,
                "EnvironmentVariables": {
                    "PATH_PRESERVED_BY_XCODE": "yes",
                    "RUN_COMPUTER_USE_LIVE_E2E": "stale",
                    "RUN_OSATLAS_DOORDASH_SIMULATOR_E2E": "unsafe-stale",
                    "RUN_OSATLAS_DOORDASH_TAKEOVER_RESUME_SIMULATOR_E2E": "",
                    "OSATLAS_DOORDASH_EXPECTED_TOTAL": "$0.01",
                },
                "TestingEnvironmentVariables": {
                    "DYLD_FRAMEWORK_PATH": "__TESTROOT__",
                    "RUN_WRONG_TEST": "unsafe-stale",
                },
                "UITargetAppEnvironmentVariables": {
                    "APP_SAFE": "yes",
                    "DOORDASH_EXPECTED_EMAIL": "private@example.test",
                },
                "TestBundlePath": "__TESTHOST__/PlugIns/RemoteDesktopLiveE2ETests.xctest",
                "TestHostPath": "__TESTROOT__/Release-iphonesimulator/RemoteDesktopLiveE2ETests-Runner.app",
            },
        }

    def run(
        self,
        arguments: list[str],
        *,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        arguments = list(arguments)
        self.run_calls.append(arguments)
        self.run_environments.append(
            None if environment is None else dict(environment)
        )
        if arguments[0] == str(self.paths.ps):
            command = ""
            if self.host_running:
                binary_mtime = datetime.fromtimestamp(
                    self.paths.installed_executable.stat().st_mtime
                )
                process_start = binary_mtime + (
                    timedelta(minutes=-1 if self.stale_host else 1)
                )
                command = (
                    f"4321 {process_start.strftime('%a %b %d %H:%M:%S %Y')} "
                    f"{self.paths.installed_executable} --start-listening\n"
                )
            return subprocess.CompletedProcess(arguments, 0, command, "")
        if arguments == [
            str(self.paths.installed_executable),
            "--check-permissions-json",
        ]:
            return subprocess.CompletedProcess(
                arguments, 0, json.dumps(self.permissions), ""
            )
        if (
            arguments[0] == str(self.paths.xcodebuild)
            and len(arguments) > 1
            and arguments[1] == "build-for-testing"
        ):
            if self.build_return_code == 0:
                derived_data = pathlib.Path(
                    arguments[arguments.index("-derivedDataPath") + 1]
                )
                products = derived_data / "Build/Products"
                products.mkdir(parents=True, exist_ok=True)
                for index in range(self.generated_xctestrun_count):
                    path = products / (
                        f"{runner_module.SCHEME}_iphonesimulator26.5-arm64"
                        f"{'-' + str(index) if index else ''}.xctestrun"
                    )
                    self.generated_xctestrun_paths.append(path)
                    if isinstance(self.generated_xctestrun, bytes):
                        path.write_bytes(self.generated_xctestrun)
                    else:
                        with path.open("wb") as handle:
                            plistlib.dump(self.generated_xctestrun, handle)
            return subprocess.CompletedProcess(
                arguments,
                self.build_return_code,
                "TEST BUILD SUCCEEDED" if self.build_return_code == 0 else "",
                "build failed" if self.build_return_code else "",
            )
        if arguments[0] == str(self.paths.xcodebuild):
            return subprocess.CompletedProcess(
                arguments,
                0,
                json.dumps({"project": {"schemes": self.schemes}}),
                "",
            )
        if arguments[0:3] == [
            str(self.paths.xcrun),
            "simctl",
            "list",
        ]:
            device = {
                "name": runner_module.REQUIRED_SIMULATOR_NAME,
                "udid": "11111111-2222-3333-4444-555555555555",
                "state": self.simulator_state,
                "isAvailable": True,
            }
            return subprocess.CompletedProcess(
                arguments,
                0,
                json.dumps({"devices": {"runtime": [device]}}),
                "",
            )
        if arguments[0:4] == [
            str(self.paths.xcrun),
            "xcresulttool",
            "export",
            "attachments",
        ]:
            if self.attachment_export_return_code != 0:
                return subprocess.CompletedProcess(
                    arguments,
                    self.attachment_export_return_code,
                    "",
                    "could not export attachments",
                )
            output = pathlib.Path(
                arguments[arguments.index("--output-path") + 1]
            )
            output.mkdir(parents=True)
            (output / "manifest.json").write_text(
                json.dumps(self.attachment_manifest),
                encoding="utf-8",
            )
            for filename, payload in self.attachment_payloads.items():
                path = output / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            return subprocess.CompletedProcess(arguments, 0, "", "")
        raise AssertionError(f"Unexpected preflight command: {arguments}")

    def popen(
        self,
        arguments: list[str],
        *,
        environment: dict[str, str],
    ) -> FakeProcess:
        arguments = list(arguments)
        environment = dict(environment)
        self.popen_calls.append((arguments, environment))
        xctestrun = pathlib.Path(arguments[arguments.index("-xctestrun") + 1])
        self.launched_xctestrun_path = xctestrun
        self.launched_xctestrun_mode = xctestrun.stat().st_mode & 0o777
        with xctestrun.open("rb") as handle:
            self.launched_xctestrun = plistlib.load(handle)
        result_index = arguments.index("-resultBundlePath") + 1
        result_bundle = pathlib.Path(arguments[result_index])
        self.private_root_mode = result_bundle.parent.stat().st_mode & 0o777
        self.quarantined_result_path = result_bundle
        self.process = FakeProcess(
            self.process_return_code,
            result_bundle=result_bundle,
            time_out_first=self.time_out_first,
        )
        original_wait = self.process.wait

        def wait_and_write_result(timeout: float | None = None) -> int:
            return_code = original_wait(timeout)
            if result_bundle.exists():
                for filename, payload in self.direct_result_payloads.items():
                    path = result_bundle / filename
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(payload)
            return return_code

        self.process.wait = wait_and_write_result  # type: ignore[method-assign]
        return self.process


class DoorDashLiveRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="doordash-live-runner-")
        self.addCleanup(self.temporary.cleanup)
        root = pathlib.Path(self.temporary.name)
        project = root / "ios/RemoteDesktop.xcodeproj"
        project.mkdir(parents=True)
        scheme_file = (
            project
            / "xcshareddata/xcschemes/RemoteDesktopLiveE2E.xcscheme"
        )
        scheme_file.parent.mkdir(parents=True)
        scheme_file.write_text(
            """<?xml version="1.0" encoding="UTF-8"?>
<Scheme>
  <TestAction buildConfiguration="Release">
    <Testables>
      <TestableReference skipped="NO">
        <BuildableReference BlueprintName="RemoteDesktopLiveE2ETests" />
      </TestableReference>
    </Testables>
  </TestAction>
</Scheme>
""",
            encoding="utf-8",
        )
        installed_app = root / "Applications/RemoteDesktopHost.app"
        release_app = (
            root
            / "host-mac/build/DerivedData/Build/Products/Release/RemoteDesktopHost.app"
        )
        for app in (installed_app, release_app):
            executable = app / "Contents/MacOS/RemoteDesktopHost"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"same-release-host")
            executable.chmod(0o755)
            info = app / "Contents/Info.plist"
            with info.open("wb") as handle:
                plistlib.dump(
                    {"CFBundleIdentifier": "com.threadmark.remotedesktop.host"},
                    handle,
                )
        self.paths = runner_module.RunnerPaths(
            project=project,
            scheme_file=scheme_file,
            derived_data=root / "derived-data",
            installed_app=installed_app,
            release_app=release_app,
            xcodebuild=pathlib.Path("/test/bin/xcodebuild"),
            xcrun=pathlib.Path("/test/bin/xcrun"),
            ps=pathlib.Path("/test/bin/ps"),
            result_directory=root / "results",
        )

    def make_runner(
        self,
        executor: FakeExecutor,
        *,
        base_environment: dict[str, str] | None = None,
    ) -> tuple[runner_module.DoorDashLiveRunner, io.StringIO, io.StringIO]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        runner = runner_module.DoorDashLiveRunner(
            paths=self.paths,
            executor=executor,
            base_environment=base_environment or {"PATH": "/usr/bin:/bin"},
            stdout=stdout,
            stderr=stderr,
        )
        return runner, stdout, stderr

    def published_results(self) -> list[pathlib.Path]:
        if not self.paths.result_directory.exists():
            return []
        return sorted(self.paths.result_directory.glob("*.xcresult"))

    def assert_private_workspace_cleaned(self) -> None:
        if not self.paths.result_directory.exists():
            return
        self.assertFalse(
            any(
                path.name.startswith(runner_module.PRIVATE_RUN_PREFIX)
                for path in self.paths.result_directory.iterdir()
            )
        )

    @staticmethod
    def manifest_with_attachment(
        *,
        name: str,
        filename: str,
    ) -> list[dict[str, object]]:
        return [{
            "testIdentifier": runner_module.RESULT_TEST_IDENTIFIER,
            "testIdentifierURL": runner_module.RESULT_TEST_IDENTIFIER_URL,
            "attachments": [{
                "exportedFileName": filename,
                "suggestedHumanReadableName": name,
                "isAssociatedWithFailure": False,
            }],
        }]

    def test_missing_visible_ui_opt_in_refuses_before_constructing_runner(self) -> None:
        stderr = io.StringIO()
        with (
            contextlib.redirect_stderr(stderr),
            mock.patch.object(runner_module, "DoorDashLiveRunner") as live_runner,
        ):
            return_code = runner_module.main([])

        self.assertEqual(return_code, 2)
        self.assertIn("--allow-visible-ui", stderr.getvalue())
        self.assertIn("No Xcode or Simulator action", stderr.getvalue())
        live_runner.assert_not_called()

    def test_private_xctestrun_has_exact_env_privacy_and_single_test_contract(self) -> None:
        executor = FakeExecutor(self.paths)
        runner, stdout, stderr = self.make_runner(
            executor,
            base_environment={
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/tester",
                "RUN_COMPUTER_USE_LIVE_E2E": "stale",
                "RUN_OSATLAS_DOORDASH_SIMULATOR_E2E": "unsafe-stale",
                "RUN_OSATLAS_DOORDASH_GUEST_HANDOFF_SIMULATOR_E2E": "unsafe-stale",
                "TEST_RUNNER_RUN_COMPUTER_USE_LIVE_E2E": "stale",
                "TEST_RUNNER_RUN_OSATLAS_DOORDASH_SIMULATOR_E2E": "unsafe-stale",
                "DOORDASH_EXPECTED_TOTAL": "$0.01",
            },
        )

        return_code = runner.run()

        self.assertEqual(return_code, 0, stderr.getvalue())
        self.assertEqual(len(executor.popen_calls), 1)
        arguments, environment = executor.popen_calls[0]
        self.assertFalse(
            any(key.startswith("TEST_RUNNER_RUN_") for key in environment)
        )
        self.assertFalse(any(key.startswith("RUN_") for key in environment))
        self.assertNotIn("DOORDASH_EXPECTED_TOTAL", environment)

        build_calls = [
            call
            for call in executor.run_calls
            if call[0:2] == [str(self.paths.xcodebuild), "build-for-testing"]
        ]
        self.assertEqual(len(build_calls), 1)
        build = build_calls[0]
        build_index = executor.run_calls.index(build)
        self.assertEqual(executor.run_environments[build_index], environment)
        self.assertEqual(
            build[build.index("-configuration") + 1],
            "Release",
        )
        self.assertEqual(
            build[build.index("-parallel-testing-enabled") + 1],
            "NO",
        )
        private_derived_data = pathlib.Path(
            build[build.index("-derivedDataPath") + 1]
        )
        self.assertNotEqual(private_derived_data, self.paths.derived_data)
        self.assertEqual(private_derived_data.name, "DerivedData")
        self.assertTrue(
            private_derived_data.parent.name.startswith(
                runner_module.PRIVATE_RUN_PREFIX
            )
        )

        only_testing = [
            argument for argument in arguments if argument.startswith("-only-testing:")
        ]
        self.assertEqual(
            only_testing,
            [f"-only-testing:{runner_module.TEST_IDENTIFIER}"],
        )
        self.assertEqual(
            arguments[0:2],
            [str(self.paths.xcodebuild), "test-without-building"],
        )
        self.assertNotIn("-project", arguments)
        self.assertNotIn("-scheme", arguments)
        self.assertNotIn("-configuration", arguments)
        self.assertNotIn("-derivedDataPath", arguments)
        self.assertEqual(
            arguments[arguments.index("-parallel-testing-enabled") + 1], "NO"
        )
        self.assertEqual(
            arguments[arguments.index("-collect-test-diagnostics") + 1],
            "never",
        )
        self.assertNotIn("-test-iterations", arguments)

        source_xctestrun = executor.generated_xctestrun_paths[0]
        launched_xctestrun = pathlib.Path(
            arguments[arguments.index("-xctestrun") + 1]
        )
        self.assertEqual(launched_xctestrun.parent, source_xctestrun.parent)
        self.assertNotEqual(launched_xctestrun, source_xctestrun)
        self.assertIn("privacy-safe", launched_xctestrun.name)
        self.assertIsInstance(executor.launched_xctestrun, dict)
        assert isinstance(executor.launched_xctestrun, dict)
        self.assertEqual(
            set(executor.launched_xctestrun),
            {
                "__xctestrun_metadata__",
                runner_module.XCTESTRUN_TARGET_NAME,
            },
        )
        self.assertEqual(executor.launched_xctestrun_mode, 0o600)
        self.assertEqual(executor.private_root_mode, 0o700)
        configuration = executor.launched_xctestrun[
            runner_module.XCTESTRUN_TARGET_NAME
        ]
        self.assertEqual(
            configuration["PreferredScreenCaptureFormat"],
            "screenshots",
        )
        self.assertEqual(configuration["SystemAttachmentLifetime"], "keepNever")
        self.assertEqual(configuration["UserAttachmentLifetime"], "keepAlways")
        self.assertEqual(configuration["DiagnosticCollectionPolicy"], 0)
        xctest_environment = configuration["EnvironmentVariables"]
        self.assertEqual(
            {
                key: value
                for key, value in xctest_environment.items()
                if key.startswith("RUN_")
            },
            runner_module.XCTEST_LIVE_ENVIRONMENT,
        )
        self.assertEqual(xctest_environment["PATH_PRESERVED_BY_XCODE"], "yes")
        self.assertFalse(
            any(
                key.startswith("OSATLAS_DOORDASH_EXPECTED_")
                or key.startswith("DOORDASH_EXPECTED_")
                for key in xctest_environment
            )
        )
        self.assertNotIn(
            "RUN_WRONG_TEST",
            configuration["TestingEnvironmentVariables"],
        )
        self.assertNotIn(
            "DOORDASH_EXPECTED_EMAIL",
            configuration["UITargetAppEnvironmentVariables"],
        )

        final_results = list(self.paths.result_directory.glob("*.xcresult"))
        self.assertEqual(len(final_results), 1)
        self.assertTrue(final_results[0].is_dir())
        self.assertEqual(final_results[0].stat().st_mode & 0o777, 0o700)
        self.assertFalse(
            any(
                path.name.startswith(runner_module.PRIVATE_RUN_PREFIX)
                for path in self.paths.result_directory.iterdir()
            )
        )
        self.assertFalse(launched_xctestrun.exists())
        audit_calls = [
            call
            for call in executor.run_calls
            if call[0:4]
            == [
                str(self.paths.xcrun),
                "xcresulttool",
                "export",
                "attachments",
            ]
        ]
        self.assertEqual(len(audit_calls), 1)
        audit_index = executor.run_calls.index(audit_calls[0])
        self.assertEqual(executor.run_environments[audit_index], environment)
        self.assertIn("15-minute manual sign-in window", runner_module.__doc__ or "")
        self.assertIn("choose Allow yourself", stdout.getvalue())
        self.assertIn("Then tap Let AI continue", stdout.getvalue())
        self.assertIn("You—not automation—sign in", stdout.getvalue())
        self.assertIn("never enters credentials", stdout.getvalue())
        self.assertIn("screen recording is disabled", stdout.getvalue().lower())
        self.assertIn("Privacy-audited result bundle", stdout.getvalue())

    def test_manual_instructions_and_help_explain_the_exact_pixel_gate(self) -> None:
        executor = FakeExecutor(self.paths)
        runner, stdout, stderr = self.make_runner(executor)

        self.assertEqual(runner.run(), 0, stderr.getvalue())
        instructions = stdout.getvalue()
        for phrase in (
            "Safari History entry",
            "Codex/ChatGPT",
            "does not count",
            "click the entry",
            "wait for navigation",
            "close every Safari menu",
            "doordash.com",
            "Continue to Sign In",
            "Email Required",
            "real sign-in form",
            "10-second preflight",
            "privacy-safe evidence",
            "no request is typed or sent",
            "published only after privacy audit",
            "screen recording is disabled",
            "allowlisted JSON evidence",
        ):
            self.assertIn(phrase, instructions)

        help_text = runner_module.build_argument_parser().format_help()
        self.assertIn("doordash.com", help_text)
        self.assertIn("Codex/ChatGPT", help_text)
        self.assertIn("privacy-audited", help_text)

    def test_swift_pixel_gate_precedes_composer_typing_and_send(self) -> None:
        source = runner_module.LIVE_TEST_SOURCE.read_text(encoding="utf-8")
        preflight = source.index("try waitForDoorDashSignedOutPreflight(")
        final_preflight = source.rindex("try waitForDoorDashSignedOutPreflight(")
        type_prompt = source.index("composer.typeText(prompt)")
        send_request = source.index("send.tap()")

        self.assertLess(preflight, type_prompt)
        self.assertLess(type_prompt, final_preflight)
        self.assertLess(final_preflight, send_request)
        self.assertEqual(
            source.count("try waitForDoorDashSignedOutPreflight("),
            2,
        )
        self.assertIn("consecutiveReadySamples >= 2", source)
        self.assertIn("No request was typed or sent.", source)

    def test_swift_disables_ocr_and_screenshots_during_private_login(self) -> None:
        source = runner_module.LIVE_TEST_SOURCE.read_text(encoding="utf-8")
        handoff = source[
            source.index("private func waitForSafeAuthenticationHandoff(") :
            source.index("private func waitForScreenCaptureConsentResume(")
        ]
        self.assertLess(
            handoff.index("if guidance.exists && resume.exists"),
            handoff.index("inspectUnrelatedVisibleContentIfDue("),
        )
        self.assertIn("stopBeforeRecognition", handoff)

        consent_resume = source[
            source.index("private func waitForScreenCaptureConsentResume(") :
            source.index("private func enterManualAuthenticationHandoff(")
        ]
        self.assertLess(
            consent_resume.index("if deliveryGuidance.exists && resume.exists"),
            consent_resume.index("inspectUnrelatedVisibleContentIfDue("),
        )
        self.assertIn("stopBeforeRecognition", consent_resume)

        private_login = source[
            source.index("private func waitForHumanResume(") :
            source.index("private func waitForLocallyValidatedReadOnlyQuote(")
        ]
        self.assertNotIn("recognizeText", private_login)
        self.assertNotIn("assertNoUnrelatedVisibleContent", private_login)
        self.assertNotIn("attachScreenshot", private_login)
        self.assertIn("-collect-test-diagnostics", SCRIPT_PATH.read_text())

    def test_runner_contains_no_ui_or_permission_request_commands(self) -> None:
        executor = FakeExecutor(self.paths)
        runner, _, _ = self.make_runner(executor)
        self.assertEqual(runner.run(), 0)

        all_arguments = [
            argument
            for call in executor.run_calls
            for argument in call
        ] + [
            argument
            for call, _ in executor.popen_calls
            for argument in call
        ]
        self.assertNotIn("--request-permissions", all_arguments)
        self.assertNotIn("open", all_arguments)
        self.assertNotIn("osascript", all_arguments)
        self.assertNotIn("io", all_arguments)
        source = SCRIPT_PATH.read_text(encoding="utf-8")
        for forbidden in (
            "XCUIElement",
            "typeText(",
            ".tap()",
            "CGEvent",
            "osascript",
            "simctl io",
        ):
            self.assertNotIn(forbidden, source)

    def test_release_host_binary_mismatch_fails_before_any_process_launch(self) -> None:
        self.paths.installed_executable.write_bytes(b"not-the-release-host")
        executor = FakeExecutor(self.paths)
        runner, _, _ = self.make_runner(executor)

        with self.assertRaisesRegex(runner_module.RunnerError, "not the current Release"):
            runner.run()

        self.assertEqual(executor.run_calls, [])
        self.assertEqual(executor.popen_calls, [])

    def test_host_must_be_running_from_installed_path_in_listening_mode(self) -> None:
        executor = FakeExecutor(self.paths, host_running=False)
        runner, _, _ = self.make_runner(executor)

        with self.assertRaisesRegex(runner_module.RunnerError, "not running in listening"):
            runner.run()

        self.assertEqual(executor.popen_calls, [])

    def test_host_process_must_have_started_after_release_install(self) -> None:
        executor = FakeExecutor(self.paths, stale_host=True)
        runner, _, _ = self.make_runner(executor)

        with self.assertRaisesRegex(runner_module.RunnerError, "started before"):
            runner.run()

        self.assertEqual(executor.popen_calls, [])

    def test_permission_check_is_read_only_and_fails_closed(self) -> None:
        executor = FakeExecutor(
            self.paths,
            permissions={
                "screenRecording": True,
                "accessibility": False,
                "ok": False,
            },
        )
        runner, _, _ = self.make_runner(executor)

        with self.assertRaisesRegex(runner_module.RunnerError, "will not click or request"):
            runner.run()

        self.assertIn(
            [str(self.paths.installed_executable), "--check-permissions-json"],
            executor.run_calls,
        )
        self.assertFalse(
            any("--request-permissions" in call for call in executor.run_calls)
        )
        self.assertEqual(executor.popen_calls, [])

    def test_project_scheme_and_booted_iphone_air_are_verified(self) -> None:
        executor = FakeExecutor(self.paths, schemes=["RemoteDesktop"])
        runner, _, _ = self.make_runner(executor)
        with self.assertRaisesRegex(runner_module.RunnerError, "not discoverable"):
            runner.run()
        self.assertEqual(executor.popen_calls, [])

        executor = FakeExecutor(self.paths, simulator_state="Shutdown")
        runner, _, _ = self.make_runner(executor)
        with self.assertRaisesRegex(runner_module.RunnerError, "exactly one booted"):
            runner.run()
        self.assertEqual(executor.popen_calls, [])

    def test_explicit_simulator_id_must_match_booted_iphone_air(self) -> None:
        executor = FakeExecutor(self.paths, simulator_state="Shutdown")
        runner, _, _ = self.make_runner(executor)
        with self.assertRaisesRegex(runner_module.RunnerError, "is not booted"):
            runner.run(simulator_id="11111111-2222-3333-4444-555555555555")
        self.assertEqual(executor.popen_calls, [])

    def test_result_bundle_names_are_unique_and_never_overwrite(self) -> None:
        fixed_time = datetime(2026, 7, 14, 12, 0, tzinfo=timezone.utc)
        first = runner_module.unique_result_bundle_path(
            self.paths.result_directory,
            now=fixed_time,
            process_id=42,
            nonce="first",
        )
        second = runner_module.unique_result_bundle_path(
            self.paths.result_directory,
            now=fixed_time,
            process_id=42,
            nonce="second",
        )
        self.assertNotEqual(first, second)
        self.assertEqual(first.suffix, ".xcresult")

        executor = FakeExecutor(self.paths)
        runner, _, _ = self.make_runner(executor)
        with mock.patch.object(
            runner_module,
            "unique_result_bundle_path",
            return_value=first,
        ):
            first.mkdir(parents=True)
            with self.assertRaisesRegex(runner_module.RunnerError, "overwrite"):
                runner.run()
        self.assertEqual(executor.popen_calls, [])

    def test_failed_xcode_run_publishes_only_an_audited_result_bundle(self) -> None:
        executor = FakeExecutor(self.paths, process_return_code=65)
        runner, _, stderr = self.make_runner(executor)

        return_code = runner.run()

        self.assertEqual(return_code, 65)
        self.assertEqual(len(self.published_results()), 1)
        self.assertIsNotNone(executor.quarantined_result_path)
        assert executor.quarantined_result_path is not None
        self.assertFalse(executor.quarantined_result_path.exists())
        self.assert_private_workspace_cleaned()
        self.assertIn("FAILED (exit 65)", stderr.getvalue())
        self.assertIn("Privacy-audited result bundle", stderr.getvalue())

    def test_timeout_is_bounded_and_publishes_only_an_audited_partial_result(self) -> None:
        executor = FakeExecutor(
            self.paths,
            process_return_code=-2,
            time_out_first=True,
        )
        runner, _, stderr = self.make_runner(executor)

        with mock.patch.object(runner_module.os, "killpg") as killpg:
            return_code = runner.run()

        self.assertEqual(return_code, 124)
        killpg.assert_called_once_with(99123, runner_module.signal.SIGINT)
        self.assertIsNotNone(executor.process)
        assert executor.process is not None
        self.assertEqual(executor.process.wait_calls, 2)
        self.assertEqual(
            executor.process.wait_timeouts,
            [runner_module.RUN_TIMEOUT_SECONDS, runner_module.INTERRUPT_GRACE_SECONDS],
        )
        self.assertEqual(runner_module.RUN_TIMEOUT_SECONDS, 40 * 60)
        self.assertEqual(len(self.published_results()), 1)
        self.assert_private_workspace_cleaned()
        self.assertIn("reached 40 minutes", stderr.getvalue())
        self.assertIn("Privacy-audited result bundle", stderr.getvalue())

    def test_allowlisted_json_evidence_is_published(self) -> None:
        filename = FakeExecutor.public_attachment_filename
        executor = FakeExecutor(
            self.paths,
            attachment_manifest=self.manifest_with_attachment(
                name=FakeExecutor.public_attachment_name,
                filename=filename,
            ),
            attachment_payloads={
                filename: FakeExecutor.public_attachment_payload,
            },
        )
        runner, _, stderr = self.make_runner(executor)

        self.assertEqual(runner.run(), 0, stderr.getvalue())

        self.assertEqual(len(self.published_results()), 1)
        self.assert_private_workspace_cleaned()

    def test_screen_recording_attachment_is_deleted_and_never_published(self) -> None:
        filename = "ScreenRecording.mp4"
        executor = FakeExecutor(
            self.paths,
            attachment_manifest=self.manifest_with_attachment(
                name="Screen Recording",
                filename=filename,
            ),
            attachment_payloads={filename: b"synthetic-video"},
        )
        runner, _, _ = self.make_runner(executor)

        with self.assertRaisesRegex(
            runner_module.RunnerError,
            "non-allowlisted XCTest attachment",
        ):
            runner.run()

        self.assertEqual(self.published_results(), [])
        self.assert_private_workspace_cleaned()
        self.assertIsNotNone(executor.quarantined_result_path)
        assert executor.quarantined_result_path is not None
        self.assertFalse(executor.quarantined_result_path.exists())

    def test_ui_snapshot_and_synthesized_event_names_fail_closed(self) -> None:
        for name in ("UI Snapshot", "Synthesized Event"):
            with self.subTest(name=name):
                filename = name.replace(" ", "-") + ".json"
                executor = FakeExecutor(
                    self.paths,
                    attachment_manifest=self.manifest_with_attachment(
                        name=name,
                        filename=filename,
                    ),
                    attachment_payloads={filename: b"{}"},
                )
                runner, _, _ = self.make_runner(executor)

                with self.assertRaisesRegex(
                    runner_module.RunnerError,
                    "non-allowlisted XCTest attachment",
                ):
                    runner.run()

                self.assertEqual(self.published_results(), [])
                self.assert_private_workspace_cleaned()

    def test_allowlisted_name_with_visual_or_invalid_payload_fails_closed(self) -> None:
        valid_filename = FakeExecutor.public_attachment_filename
        cases = (
            ("11111111-2222-3333-4444-555555555555.png", b"synthetic-image", "only allowlisted JSON"),
            (valid_filename, b"not-json", "invalid JSON evidence"),
            (valid_filename, b"[]", "JSON object"),
        )
        for filename, payload, expected_error in cases:
            with self.subTest(filename=filename, payload=payload):
                executor = FakeExecutor(
                    self.paths,
                    attachment_manifest=self.manifest_with_attachment(
                        name=FakeExecutor.public_attachment_name,
                        filename=filename,
                    ),
                    attachment_payloads={filename: payload},
                )
                runner, _, _ = self.make_runner(executor)

                with self.assertRaisesRegex(
                    runner_module.RunnerError,
                    expected_error,
                ):
                    runner.run()

                self.assertEqual(self.published_results(), [])
                self.assert_private_workspace_cleaned()

    def test_oversized_traversal_and_unlisted_export_files_fail_closed(self) -> None:
        valid_filename = FakeExecutor.public_attachment_filename
        cases = (
            (
                self.manifest_with_attachment(
                    name=FakeExecutor.public_attachment_name,
                    filename=valid_filename,
                ),
                {
                    valid_filename: b"{" + b" "
                    * runner_module.MAX_PRIVACY_SAFE_ATTACHMENT_BYTES + b"}",
                },
                "oversized",
            ),
            (
                self.manifest_with_attachment(
                    name=FakeExecutor.public_attachment_name,
                    filename="../" + valid_filename,
                ),
                {valid_filename: b"{}"},
                "outside its export directory",
            ),
            (
                self.manifest_with_attachment(
                    name=FakeExecutor.public_attachment_name,
                    filename=valid_filename,
                ),
                {
                    valid_filename: FakeExecutor.public_attachment_payload,
                    "unlisted.json": b"{}",
                },
                "unlisted or missing",
            ),
        )
        for manifest, payloads, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                executor = FakeExecutor(
                    self.paths,
                    attachment_manifest=manifest,
                    attachment_payloads=payloads,
                )
                runner, _, _ = self.make_runner(executor)

                with self.assertRaisesRegex(
                    runner_module.RunnerError,
                    expected_error,
                ):
                    runner.run()

                self.assertEqual(self.published_results(), [])
                self.assert_private_workspace_cleaned()

    def test_direct_visual_payload_in_xcresult_fails_before_export(self) -> None:
        executor = FakeExecutor(
            self.paths,
            direct_result_payloads={"Data/credential-frame.png": b"pixels"},
        )
        runner, _, _ = self.make_runner(executor)

        with self.assertRaisesRegex(
            runner_module.RunnerError,
            "visual payload stored directly",
        ):
            runner.run()

        self.assertFalse(
            any(
                call[0:4]
                == [
                    str(self.paths.xcrun),
                    "xcresulttool",
                    "export",
                    "attachments",
                ]
                for call in executor.run_calls
            )
        )
        self.assertEqual(self.published_results(), [])
        self.assert_private_workspace_cleaned()

    def test_attachment_export_or_manifest_failure_deletes_quarantine(self) -> None:
        cases = (
            ({"attachment_export_return_code": 1}, "audit quarantined"),
            ({"attachment_manifest": {"unexpected": []}}, "manifest shape"),
            ({"attachment_manifest": [{"attachments": "wrong"}]}, "attachments list"),
        )
        for options, expected_error in cases:
            with self.subTest(options=options):
                executor = FakeExecutor(self.paths, **options)
                runner, _, _ = self.make_runner(executor)

                with self.assertRaisesRegex(
                    runner_module.RunnerError,
                    expected_error,
                ):
                    runner.run()

                self.assertEqual(self.published_results(), [])
                self.assert_private_workspace_cleaned()

    def test_generated_xctestrun_shape_fails_closed_before_ui_launch(self) -> None:
        malformed_shapes = (
            [],
            {
                "__xctestrun_metadata__": {},
                "One": FakeExecutor.default_xctestrun()[
                    runner_module.XCTESTRUN_TARGET_NAME
                ],
                "Two": FakeExecutor.default_xctestrun()[
                    runner_module.XCTESTRUN_TARGET_NAME
                ],
            },
            {
                "__xctestrun_metadata__": {},
                runner_module.XCTESTRUN_TARGET_NAME: {
                    "BlueprintName": runner_module.XCTESTRUN_TARGET_NAME,
                    "IsUITestBundle": False,
                    "EnvironmentVariables": {},
                },
            },
            {
                "__xctestrun_metadata__": {},
                runner_module.XCTESTRUN_TARGET_NAME: {
                    "BlueprintName": "UnexpectedTests",
                    "IsUITestBundle": True,
                    "EnvironmentVariables": {},
                },
            },
        )
        for shape in malformed_shapes:
            with self.subTest(shape=shape):
                executor = FakeExecutor(
                    self.paths,
                    generated_xctestrun=shape,
                )
                runner, _, _ = self.make_runner(executor)

                with self.assertRaises(runner_module.RunnerError):
                    runner.run()

                self.assertEqual(executor.popen_calls, [])
                self.assertEqual(self.published_results(), [])
                self.assert_private_workspace_cleaned()

    def test_missing_multiple_and_unreadable_xctestruns_fail_before_ui_launch(self) -> None:
        cases = (
            ({"generated_xctestrun_count": 0}, "found 0"),
            ({"generated_xctestrun_count": 2}, "found 2"),
            ({"generated_xctestrun": b"not a plist"}, "Could not read"),
        )
        for options, expected_error in cases:
            with self.subTest(options=options):
                executor = FakeExecutor(self.paths, **options)
                runner, _, _ = self.make_runner(executor)

                with self.assertRaisesRegex(
                    runner_module.RunnerError,
                    expected_error,
                ):
                    runner.run()

                self.assertEqual(executor.popen_calls, [])
                self.assertEqual(self.published_results(), [])
                self.assert_private_workspace_cleaned()

    def test_build_failure_cleans_private_workspace_without_launching_ui(self) -> None:
        executor = FakeExecutor(self.paths, build_return_code=65)
        runner, _, _ = self.make_runner(executor)

        with self.assertRaisesRegex(
            runner_module.RunnerError,
            "build the private Release UI-test products",
        ):
            runner.run()

        self.assertEqual(executor.popen_calls, [])
        self.assertEqual(self.published_results(), [])
        self.assert_private_workspace_cleaned()


if __name__ == "__main__":
    unittest.main()
