#!/usr/bin/env python3
"""Run the one continuous, Simulator-visible DoorDash acceptance directly.

This entry point deliberately uses the local ``xcodebuild`` process instead of
an MCP transport that would truncate the 15-minute manual sign-in window. It
only starts the existing, read-only takeover/resume test;
it contains no UI-driving, credential, permission, cart, checkout, or order
automation of its own. Before XCTest types or sends anything, a bounded
Simulator-visible pixel preflight requires the actual ``doordash.com`` page
and real signed-out form twice; a Safari History entry, tab preview, or
Codex/ChatGPT page is not sufficient. Xcode's automatic UI recording is
disabled through a private, per-run xctestrun copy. The result stays in a
private quarantine until an attachment audit proves that it contains no
screenshots, screen recordings, UI snapshots, or other unapproved payloads.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Mapping, Sequence


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEME = "RemoteDesktopLiveE2E"
TEST_IDENTIFIER = (
    "RemoteDesktopLiveE2ETests/"
    "OSAtlasDoorDashTakeoverResumeSimulatorLiveE2ETests/"
    "testRealDoorDashSignInTakeoverResumesToLocallyValidatedQuote"
)
LIVE_TEST_SOURCE = (
    REPO_ROOT
    / "ios/RemoteDesktopLiveE2ETests/OSAtlasDoorDashTakeoverResumeSimulatorLiveE2ETests.swift"
)
XCTEST_LIVE_ENVIRONMENT = {
    "RUN_COMPUTER_USE_LIVE_E2E": "1",
    "RUN_OSATLAS_DOORDASH_TAKEOVER_RESUME_SIMULATOR_E2E": "1",
}
REQUIRED_SIMULATOR_NAME = "iPhone Air"

XCTESTRUN_TARGET_NAME = "RemoteDesktopLiveE2ETests"
RESULT_TEST_IDENTIFIER = (
    "OSAtlasDoorDashTakeoverResumeSimulatorLiveE2ETests/"
    "testRealDoorDashSignInTakeoverResumesToLocallyValidatedQuote()"
)
RESULT_TEST_IDENTIFIER_URL = (
    "test://com.apple.xcode/RemoteDesktop/RemoteDesktopLiveE2ETests/"
    + RESULT_TEST_IDENTIFIER.removesuffix("()")
)
RESULT_TEST_NAME = (
    "testRealDoorDashSignInTakeoverResumesToLocallyValidatedQuote()"
)
PRIVATE_RUN_PREFIX = ".remotedesktop-doordash-live-"
PUBLIC_ATTACHMENT_NAME = "public.json"
PUBLIC_EVIDENCE_KEYS = frozenset({
    "authenticationHandoffObserved",
    "humanResumeObserved",
    "localQuoteStructureValidated",
    "strictVisibilityCompleted",
})
PUBLIC_SUGGESTED_NAME = re.compile(
    r"^public_[0-9]+_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.json$"
)
PUBLIC_EXPORTED_NAME = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.json$"
)
MAX_PRIVACY_SAFE_ATTACHMENT_BYTES = 1024 * 1024
VISUAL_ATTACHMENT_SUFFIXES = frozenset({
    ".avi",
    ".bmp",
    ".gif",
    ".heic",
    ".heif",
    ".jpeg",
    ".jpg",
    ".m4v",
    ".mov",
    ".mp4",
    ".png",
    ".tif",
    ".tiff",
    ".webm",
})
SENSITIVE_ENVIRONMENT_PREFIXES = (
    "RUN_",
    "TEST_RUNNER_RUN_",
    "OSATLAS_DOORDASH_EXPECTED_",
    "DOORDASH_EXPECTED_",
)

# Before any request, XCTest gives the streamed-pixel DoorDash preflight 10
# seconds and requires two consecutive clean samples. It then allows 5 minutes
# for person-handled macOS capture consent, 4 minutes to reach the
# authentication barrier, 15 minutes for the person to sign in and prepare the
# quote, and 5 minutes for resumed validation. Eleven additional minutes cover
# build/launch/cleanup while keeping an unattended invocation strictly bounded.
RUN_TIMEOUT_SECONDS = 40 * 60
INTERRUPT_GRACE_SECONDS = 20
TERMINATE_GRACE_SECONDS = 10


class RunnerError(RuntimeError):
    """A preflight or launch invariant failed before safe completion."""


@dataclass(frozen=True)
class RunnerPaths:
    project: pathlib.Path = REPO_ROOT / "ios/RemoteDesktop.xcodeproj"
    scheme_file: pathlib.Path = (
        REPO_ROOT
        / "ios/RemoteDesktop.xcodeproj/xcshareddata/xcschemes/RemoteDesktopLiveE2E.xcscheme"
    )
    derived_data: pathlib.Path = REPO_ROOT / "ios/build/codex-doordash-live"
    installed_app: pathlib.Path = pathlib.Path(
        "/Applications/RemoteDesktopHost.app"
    )
    release_app: pathlib.Path = (
        REPO_ROOT
        / "host-mac/build/DerivedData/Build/Products/Release/RemoteDesktopHost.app"
    )
    xcodebuild: pathlib.Path = pathlib.Path("/usr/bin/xcodebuild")
    xcrun: pathlib.Path = pathlib.Path("/usr/bin/xcrun")
    ps: pathlib.Path = pathlib.Path("/bin/ps")
    result_directory: pathlib.Path = pathlib.Path(tempfile.gettempdir())

    @property
    def installed_executable(self) -> pathlib.Path:
        return self.installed_app / "Contents/MacOS/RemoteDesktopHost"

    @property
    def release_executable(self) -> pathlib.Path:
        return self.release_app / "Contents/MacOS/RemoteDesktopHost"


class CommandExecutor:
    """Small subprocess seam so contract tests never launch Xcode or UI."""

    def run(
        self,
        arguments: Sequence[str],
        *,
        environment: Mapping[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            list(arguments),
            check=False,
            capture_output=True,
            text=True,
            env=None if environment is None else dict(environment),
        )

    def popen(
        self,
        arguments: Sequence[str],
        *,
        environment: Mapping[str, str],
    ) -> subprocess.Popen[bytes]:
        return subprocess.Popen(
            list(arguments),
            env=dict(environment),
            start_new_session=True,
        )


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sanitized_live_environment(
    base_environment: Mapping[str, str],
) -> dict[str, str]:
    """Return an outer process environment with no live or expected-value keys.

    The two raw live opt-ins exist only in the audited private xctestrun. They
    are never inherited by build-for-testing, xcodebuild, or xcresulttool.
    """

    return {
        key: value
        for key, value in base_environment.items()
        if not _is_sensitive_environment_key(key)
    }


def _is_sensitive_environment_key(key: str) -> bool:
    return (
        key.startswith(SENSITIVE_ENVIRONMENT_PREFIXES)
        or key.startswith("EXPECTED_")
        or "_EXPECTED_" in key
    )


def unique_result_bundle_path(
    directory: pathlib.Path,
    *,
    now: datetime | None = None,
    process_id: int | None = None,
    nonce: str | None = None,
) -> pathlib.Path:
    timestamp = (now or datetime.now(timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
    pid = process_id if process_id is not None else os.getpid()
    suffix = nonce or uuid.uuid4().hex[:12]
    return directory / (
        f"remotedesktop-doordash-takeover-resume-{timestamp}-{pid}-{suffix}.xcresult"
    )


class DoorDashLiveRunner:
    def __init__(
        self,
        *,
        paths: RunnerPaths = RunnerPaths(),
        executor: CommandExecutor | None = None,
        base_environment: Mapping[str, str] | None = None,
        stdout: object = sys.stdout,
        stderr: object = sys.stderr,
    ) -> None:
        self.paths = paths
        self.executor = executor or CommandExecutor()
        self.base_environment = dict(
            os.environ if base_environment is None else base_environment
        )
        self.stdout = stdout
        self.stderr = stderr

    def run(self, *, simulator_id: str | None = None) -> int:
        self._verify_project_and_scheme()
        self._verify_installed_release_host()
        self._verify_host_is_running()
        self._verify_host_permissions()
        self._verify_scheme_is_discoverable()
        selected_simulator = self._select_booted_simulator(simulator_id)

        self.paths.result_directory.mkdir(parents=True, exist_ok=True)
        result_bundle = unique_result_bundle_path(self.paths.result_directory)
        if result_bundle.exists():
            raise RunnerError(
                f"Refusing to overwrite existing result bundle: {result_bundle}"
            )

        environment = sanitized_live_environment(self.base_environment)
        with tempfile.TemporaryDirectory(
            prefix=PRIVATE_RUN_PREFIX,
            dir=self.paths.result_directory,
        ) as private_directory:
            private_root = pathlib.Path(private_directory)
            private_root.chmod(0o700)
            derived_data = private_root / "DerivedData"
            quarantined_result = private_root / "Quarantined.xcresult"

            self._run_checked(
                self._build_for_testing_arguments(
                    selected_simulator,
                    derived_data,
                ),
                "build the private Release UI-test products",
                environment=environment,
            )
            private_xctestrun = self._prepare_private_xctestrun(derived_data)
            try:
                arguments = self._test_without_building_arguments(
                    selected_simulator,
                    private_xctestrun,
                    quarantined_result,
                )
                self._print_manual_instructions(selected_simulator, result_bundle)

                try:
                    process = self.executor.popen(arguments, environment=environment)
                except OSError as error:
                    raise RunnerError(
                        f"Could not start privacy-configured xcodebuild: {error}"
                    ) from error

                try:
                    return_code = process.wait(timeout=RUN_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    print(
                        "\nTIME LIMIT: the direct Xcode run reached 40 minutes; "
                        "interrupting it before auditing the quarantined result.",
                        file=self.stderr,
                    )
                    self._stop_process_group(process, first_signal=signal.SIGINT)
                    return_code = 124
                except KeyboardInterrupt:
                    print(
                        "\nInterrupted by the operator; stopping xcodebuild before "
                        "auditing the quarantined result.",
                        file=self.stderr,
                    )
                    self._stop_process_group(process, first_signal=signal.SIGINT)
                    return_code = 130
            finally:
                self._remove_private_xctestrun(private_xctestrun)

            self._audit_quarantined_result(
                quarantined_result,
                private_root=private_root,
                environment=environment,
                return_code=return_code,
            )
            self._publish_result(quarantined_result, result_bundle)

        self._print_result_outcome(result_bundle, return_code=return_code)
        return return_code

    def _verify_project_and_scheme(self) -> None:
        if not self.paths.project.is_dir():
            raise RunnerError(
                f"Required Xcode project is missing: {self.paths.project}"
            )
        if not self.paths.scheme_file.is_file():
            raise RunnerError(
                f"Required shared scheme is missing: {self.paths.scheme_file}"
            )

        try:
            import xml.etree.ElementTree as element_tree

            root = element_tree.parse(self.paths.scheme_file).getroot()
        except (OSError, element_tree.ParseError) as error:
            raise RunnerError(f"Could not parse the required shared scheme: {error}") from error

        test_action = root.find("TestAction")
        if test_action is None or test_action.get("buildConfiguration") != "Release":
            raise RunnerError(
                f"{SCHEME} must run its TestAction with the Release configuration."
            )
        test_targets = {
            reference.get("BlueprintName")
            for reference in root.findall(
                "./TestAction/Testables/TestableReference/BuildableReference"
            )
        }
        if test_targets != {"RemoteDesktopLiveE2ETests"}:
            raise RunnerError(
                f"{SCHEME} must contain only the RemoteDesktopLiveE2ETests target."
            )

    def _verify_installed_release_host(self) -> None:
        installed = self.paths.installed_executable
        release = self.paths.release_executable
        if not installed.is_file() or not os.access(installed, os.X_OK):
            raise RunnerError(
                "The installed host executable is missing. Install the Release host with "
                "host-mac/scripts/install_host.sh --headless --launch."
            )
        if not release.is_file() or not os.access(release, os.X_OK):
            raise RunnerError(
                "The verified Release build product is missing. Reinstall with "
                "host-mac/scripts/install_host.sh --headless --launch before this live test."
            )

        installed_info = self.paths.installed_app / "Contents/Info.plist"
        try:
            with installed_info.open("rb") as handle:
                bundle_identifier = plistlib.load(handle).get("CFBundleIdentifier")
        except (OSError, plistlib.InvalidFileException) as error:
            raise RunnerError(f"Could not validate the installed host bundle: {error}") from error
        if bundle_identifier != "com.threadmark.remotedesktop.host":
            raise RunnerError(
                f"Unexpected installed host bundle identifier: {bundle_identifier!r}"
            )

        if _sha256(installed) != _sha256(release):
            raise RunnerError(
                "The running app is not the current Release build product. Reinstall with "
                "host-mac/scripts/install_host.sh --headless --launch, then restart it once."
            )

    def _verify_host_is_running(self) -> None:
        completed = self._run_checked(
            [str(self.paths.ps), "-axo", "pid=,lstart=,command="],
            "inspect the running installed host",
        )
        expected = str(self.paths.installed_executable)
        matching: list[tuple[list[str], float]] = []
        for line in completed.stdout.splitlines():
            # macOS `ps lstart` is five stable fields, followed by the full
            # command.  Recording start time closes a subtle installer race:
            # replacing /Applications in place does not replace an already
            # running, older executable image.
            fields = line.strip().split(maxsplit=6)
            if len(fields) != 7 or not fields[0].isdigit():
                continue
            try:
                started_at = datetime.strptime(
                    " ".join(fields[1:6]),
                    "%a %b %d %H:%M:%S %Y",
                ).timestamp()
                command = shlex.split(fields[6])
            except (ValueError, OverflowError):
                continue
            if command and command[0] == expected:
                matching.append((command, started_at))

        listening = [
            (command, started_at)
            for command, started_at in matching
            if "--start-listening" in command
        ]
        if not listening:
            raise RunnerError(
                "The installed Release host is not running in listening mode. Launch it with "
                f"/usr/bin/open -gj {self.paths.installed_app} --args --start-listening."
            )
        installed_mtime = self.paths.installed_executable.stat().st_mtime
        if not any(started_at >= installed_mtime - 1 for _, started_at in listening):
            raise RunnerError(
                "The listening host started before the current Release binary was installed. "
                "Quit that stale process and relaunch the installed host once before testing."
            )

    def _verify_host_permissions(self) -> None:
        completed = self._run_checked(
            [str(self.paths.installed_executable), "--check-permissions-json"],
            "check host permissions without requesting them",
        )
        try:
            permissions = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise RunnerError(
                "The installed host returned invalid permission status JSON."
            ) from error
        required = (
            permissions.get("screenRecording") is True
            and permissions.get("accessibility") is True
            and permissions.get("ok") is True
        )
        if not required:
            raise RunnerError(
                "Screen Recording and Accessibility must already be granted. This runner "
                "will not click or request permissions; approve them yourself before rerunning."
            )

    def _verify_scheme_is_discoverable(self) -> None:
        completed = self._run_checked(
            [
                str(self.paths.xcodebuild),
                "-project",
                str(self.paths.project),
                "-list",
                "-json",
            ],
            "discover the required Xcode scheme",
        )
        try:
            project = json.loads(completed.stdout).get("project", {})
        except json.JSONDecodeError as error:
            raise RunnerError("xcodebuild returned invalid project metadata.") from error
        if SCHEME not in project.get("schemes", []):
            raise RunnerError(
                f"The required {SCHEME} scheme is not discoverable in {self.paths.project}."
            )

    def _select_booted_simulator(self, requested_id: str | None) -> str:
        completed = self._run_checked(
            [str(self.paths.xcrun), "simctl", "list", "devices", "available", "--json"],
            "inspect available Simulators",
        )
        try:
            runtimes = json.loads(completed.stdout).get("devices", {})
        except json.JSONDecodeError as error:
            raise RunnerError("simctl returned invalid Simulator metadata.") from error

        devices = [device for values in runtimes.values() for device in values]
        if requested_id is not None:
            selected = [device for device in devices if device.get("udid") == requested_id]
            if not selected:
                raise RunnerError(f"Requested Simulator does not exist or is unavailable: {requested_id}")
            device = selected[0]
            if device.get("name") != REQUIRED_SIMULATOR_NAME:
                raise RunnerError(
                    f"The live acceptance requires {REQUIRED_SIMULATOR_NAME}, not "
                    f"{device.get('name', 'an unnamed Simulator')}."
                )
            if device.get("state") != "Booted":
                raise RunnerError(
                    f"Requested {REQUIRED_SIMULATOR_NAME} is not booted: {requested_id}"
                )
            return requested_id

        booted = [
            device
            for device in devices
            if device.get("name") == REQUIRED_SIMULATOR_NAME
            and device.get("state") == "Booted"
        ]
        if len(booted) != 1:
            raise RunnerError(
                f"Expected exactly one booted {REQUIRED_SIMULATOR_NAME}; found {len(booted)}. "
                "Boot the intended device or pass --simulator-id explicitly."
            )
        return str(booted[0]["udid"])

    def _build_for_testing_arguments(
        self,
        simulator_id: str,
        derived_data: pathlib.Path,
    ) -> list[str]:
        return [
            str(self.paths.xcodebuild),
            "build-for-testing",
            "-project",
            str(self.paths.project),
            "-scheme",
            SCHEME,
            "-configuration",
            "Release",
            "-destination",
            f"platform=iOS Simulator,id={simulator_id}",
            "-derivedDataPath",
            str(derived_data),
            "-parallel-testing-enabled",
            "NO",
        ]

    def _test_without_building_arguments(
        self,
        simulator_id: str,
        xctestrun: pathlib.Path,
        result_bundle: pathlib.Path,
    ) -> list[str]:
        return [
            str(self.paths.xcodebuild),
            "test-without-building",
            "-xctestrun",
            str(xctestrun),
            "-destination",
            f"platform=iOS Simulator,id={simulator_id}",
            "-resultBundlePath",
            str(result_bundle),
            "-parallel-testing-enabled",
            "NO",
            "-collect-test-diagnostics",
            "never",
            f"-only-testing:{TEST_IDENTIFIER}",
        ]

    def _prepare_private_xctestrun(
        self,
        derived_data: pathlib.Path,
    ) -> pathlib.Path:
        products = derived_data / "Build/Products"
        candidates = sorted(products.glob("*.xctestrun"))
        candidates = [candidate for candidate in candidates if candidate.is_file()]
        if len(candidates) != 1:
            raise RunnerError(
                "The private build must produce exactly one xctestrun; "
                f"found {len(candidates)} in {products}."
            )

        source = candidates[0]
        try:
            with source.open("rb") as handle:
                contents = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException) as error:
            raise RunnerError(
                f"Could not read the generated xctestrun safely: {error}"
            ) from error

        configuration = self._single_ui_test_configuration(contents)
        configuration["PreferredScreenCaptureFormat"] = "screenshots"
        configuration["SystemAttachmentLifetime"] = "keepNever"
        configuration["UserAttachmentLifetime"] = "keepAlways"
        configuration["DiagnosticCollectionPolicy"] = 0
        self._patch_xctestrun_environment(configuration)

        private = source.with_name(
            f"{source.stem}-privacy-safe-{uuid.uuid4().hex[:12]}.xctestrun"
        )
        try:
            descriptor = os.open(
                private,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(descriptor, "wb") as handle:
                plistlib.dump(contents, handle, sort_keys=True)
        except OSError as error:
            raise RunnerError(
                f"Could not create the private privacy-safe xctestrun: {error}"
            ) from error

        self._verify_private_xctestrun(private)
        return private

    def _single_ui_test_configuration(
        self,
        contents: Any,
    ) -> dict[str, Any]:
        if not isinstance(contents, dict):
            raise RunnerError("The generated xctestrun root was not a dictionary.")
        expected_keys = {
            "__xctestrun_metadata__",
            XCTESTRUN_TARGET_NAME,
        }
        if set(contents) != expected_keys:
            raise RunnerError(
                "The generated xctestrun must contain exactly the metadata and "
                f"{XCTESTRUN_TARGET_NAME} top-level keys."
            )
        if not isinstance(contents["__xctestrun_metadata__"], dict):
            raise RunnerError("The generated xctestrun metadata was not a dictionary.")
        configuration = contents[XCTESTRUN_TARGET_NAME]
        if not isinstance(configuration, dict):
            raise RunnerError(
                "The generated xctestrun test configuration was not a dictionary."
            )
        if configuration.get("IsUITestBundle") is not True:
            raise RunnerError("The generated xctestrun was not an iOS UI-test bundle.")
        if configuration.get("BlueprintName") != XCTESTRUN_TARGET_NAME:
            raise RunnerError(
                "The generated xctestrun targeted an unexpected test bundle."
            )
        return configuration

    def _patch_xctestrun_environment(
        self,
        configuration: dict[str, Any],
    ) -> None:
        environment = configuration.get("EnvironmentVariables")
        if not isinstance(environment, dict):
            raise RunnerError(
                "The generated xctestrun omitted its test environment dictionary."
            )
        configuration["EnvironmentVariables"] = {
            key: value
            for key, value in environment.items()
            if isinstance(key, str) and not _is_sensitive_environment_key(key)
        }
        configuration["EnvironmentVariables"].update(XCTEST_LIVE_ENVIRONMENT)

        for key in (
            "TestingEnvironmentVariables",
            "UITargetAppEnvironmentVariables",
        ):
            nested = configuration.get(key)
            if nested is None:
                continue
            if not isinstance(nested, dict):
                raise RunnerError(
                    f"The generated xctestrun had an invalid {key} dictionary."
                )
            configuration[key] = {
                name: value
                for name, value in nested.items()
                if isinstance(name, str)
                and not _is_sensitive_environment_key(name)
            }

    def _verify_private_xctestrun(self, path: pathlib.Path) -> None:
        try:
            with path.open("rb") as handle:
                contents = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException) as error:
            raise RunnerError(
                f"Could not verify the private xctestrun: {error}"
            ) from error
        configuration = self._single_ui_test_configuration(contents)
        expected = {
            "PreferredScreenCaptureFormat": "screenshots",
            "SystemAttachmentLifetime": "keepNever",
            "UserAttachmentLifetime": "keepAlways",
            "DiagnosticCollectionPolicy": 0,
        }
        for key, value in expected.items():
            if configuration.get(key) != value:
                raise RunnerError(
                    f"The private xctestrun did not preserve {key}={value!r}."
                )
        environment = configuration.get("EnvironmentVariables")
        assert isinstance(environment, dict)
        live_environment = {
            key: value
            for key, value in environment.items()
            if isinstance(key, str) and key.startswith("RUN_")
        }
        if live_environment != XCTEST_LIVE_ENVIRONMENT:
            raise RunnerError(
                "The private xctestrun did not contain exactly the two live opt-ins."
            )

    @staticmethod
    def _remove_private_xctestrun(path: pathlib.Path) -> None:
        try:
            path.unlink()
        except FileNotFoundError:
            return
        except OSError as error:
            raise RunnerError(
                f"Could not remove the private xctestrun: {error}"
            ) from error

    def _audit_quarantined_result(
        self,
        result_bundle: pathlib.Path,
        *,
        private_root: pathlib.Path,
        environment: Mapping[str, str],
        return_code: int,
    ) -> None:
        if not result_bundle.is_dir():
            raise RunnerError(
                "Xcode did not create a quarantined result bundle to audit."
            )
        for payload in result_bundle.rglob("*"):
            if payload.is_file() and payload.suffix.lower() in VISUAL_ATTACHMENT_SUFFIXES:
                raise RunnerError(
                    "Privacy audit rejected a visual payload stored directly in the "
                    "quarantined result bundle."
                )

        export_directory = private_root / "AttachmentAudit"
        self._run_checked(
            [
                str(self.paths.xcrun),
                "xcresulttool",
                "export",
                "attachments",
                "--path",
                str(result_bundle),
                "--output-path",
                str(export_directory),
            ],
            "audit quarantined XCTest attachments",
            environment=environment,
        )
        manifest_path = export_directory / "manifest.json"
        try:
            with manifest_path.open("r", encoding="utf-8") as handle:
                manifest = json.load(handle)
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise RunnerError(
                f"Privacy audit could not parse the attachment manifest: {error}"
            ) from error
        if not isinstance(manifest, list):
            raise RunnerError(
                "Privacy audit rejected an unexpected attachment manifest shape."
            )

        if len(manifest) != 1:
            raise RunnerError(
                "Privacy audit requires exactly one selected test in the attachment manifest."
            )

        expected_files = {manifest_path.resolve()}
        validated_attachment_count = 0
        for test_details in manifest:
            if not isinstance(test_details, dict):
                raise RunnerError(
                    "Privacy audit rejected malformed test attachment details."
                )
            attachments = test_details.get("attachments")
            if not isinstance(attachments, list):
                raise RunnerError(
                    "Privacy audit rejected attachment details without an attachments list."
                )
            if test_details.get("testIdentifier") != RESULT_TEST_IDENTIFIER:
                raise RunnerError(
                    "Privacy audit rejected attachment evidence for an unexpected test."
                )
            identifier_url = test_details.get("testIdentifierURL")
            if identifier_url is not None and identifier_url != RESULT_TEST_IDENTIFIER_URL:
                raise RunnerError(
                    "Privacy audit rejected an unexpected test identifier URL."
                )
            for attachment in attachments:
                path = self._validate_exported_attachment(
                    attachment,
                    export_directory=export_directory,
                )
                expected_files.add(path.resolve())
                validated_attachment_count += 1

        if validated_attachment_count > 1:
            raise RunnerError(
                "Privacy audit rejected duplicate public evidence attachments."
            )
        if return_code == 0 and validated_attachment_count != 1:
            raise RunnerError(
                "A passing run must retain exactly one fixed-shape public JSON attachment."
            )

        actual_files = {
            path.resolve()
            for path in export_directory.rglob("*")
            if path.is_file()
        }
        if actual_files != expected_files:
            raise RunnerError(
                "Privacy audit rejected an unlisted or missing exported attachment."
            )

    def _validate_exported_attachment(
        self,
        attachment: Any,
        *,
        export_directory: pathlib.Path,
    ) -> pathlib.Path:
        if not isinstance(attachment, dict):
            raise RunnerError("Privacy audit rejected malformed attachment metadata.")
        filename = attachment.get("exportedFileName")
        name = attachment.get("suggestedHumanReadableName")
        if not isinstance(filename, str) or not filename:
            raise RunnerError("Privacy audit rejected an attachment without a filename.")
        if not isinstance(name, str) or PUBLIC_SUGGESTED_NAME.fullmatch(name) is None:
            raise RunnerError(
                "Privacy audit rejected a non-allowlisted XCTest attachment."
            )
        relative = pathlib.Path(filename)
        if relative.name != filename or relative.is_absolute():
            raise RunnerError(
                "Privacy audit rejected an attachment path outside its export directory."
            )
        if PUBLIC_EXPORTED_NAME.fullmatch(filename) is None:
            raise RunnerError(
                "Privacy audit permits only allowlisted JSON evidence attachments."
            )
        path = export_directory / relative
        if path.is_symlink() or not path.is_file():
            raise RunnerError(
                "Privacy audit could not verify an exported evidence file."
            )
        try:
            data = path.read_bytes()
        except OSError as error:
            raise RunnerError(
                f"Privacy audit could not read exported evidence: {error}"
            ) from error
        if len(data) > MAX_PRIVACY_SAFE_ATTACHMENT_BYTES:
            raise RunnerError(
                "Privacy audit rejected an oversized evidence attachment."
            )
        try:
            payload = json.loads(data.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise RunnerError(
                f"Privacy audit rejected invalid JSON evidence: {error}"
            ) from error
        if not isinstance(payload, dict):
            raise RunnerError(
                "Privacy audit requires each evidence attachment to be a JSON object."
            )
        if set(payload) != PUBLIC_EVIDENCE_KEYS or not all(
            isinstance(value, bool) for value in payload.values()
        ):
            raise RunnerError(
                "Privacy audit rejected public evidence outside the fixed boolean schema."
            )
        if not all(payload.values()):
            raise RunnerError(
                "Privacy audit rejected incomplete public completion evidence."
            )
        return path

    def _publish_result(
        self,
        quarantined_result: pathlib.Path,
        published_result: pathlib.Path,
    ) -> None:
        if published_result.exists():
            raise RunnerError(
                f"Refusing to overwrite existing result bundle: {published_result}"
            )
        try:
            quarantined_result.chmod(0o700)
            quarantined_result.replace(published_result)
        except OSError as error:
            raise RunnerError(
                f"Could not publish the privacy-audited result bundle: {error}"
            ) from error

    def _run_checked(
        self,
        arguments: Sequence[str],
        purpose: str,
        *,
        environment: Mapping[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        try:
            completed = self.executor.run(
                arguments,
                environment=environment,
            )
        except OSError as error:
            raise RunnerError(f"Could not {purpose}: {error}") from error
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip()
            suffix = f": {detail}" if detail else ""
            raise RunnerError(f"Could not {purpose}{suffix}")
        return completed

    def _print_manual_instructions(
        self,
        simulator_id: str,
        result_bundle: pathlib.Path,
    ) -> None:
        print("", file=self.stdout)
        print("CONTINUOUS DOORDASH LIVE ACCEPTANCE", file=self.stdout)
        print(f"Simulator: {REQUIRED_SIMULATOR_NAME} ({simulator_id})", file=self.stdout)
        print(
            f"Result bundle (published only after privacy audit): {result_bundle}",
            file=self.stdout,
        )
        print(f"Bounded direct-Xcode limit: {RUN_TIMEOUT_SECONDS // 60} minutes", file=self.stdout)
        print("", file=self.stdout)
        print("Before the task begins:", file=self.stdout)
        print(
            "  1. Keep the real, signed-out DoorDash sign-in wall frontmost in Safari.",
            file=self.stdout,
        )
        print(
            "     A Safari History entry, tab preview, or Codex/ChatGPT page mentioning "
            "DoorDash does not count.",
            file=self.stdout,
        )
        print(
            "     If using History, click the entry, wait for navigation, and close every "
            "Safari menu.",
            file=self.stdout,
        )
        print(
            "     Visibly confirm doordash.com plus Continue to Sign In and Email Required, "
            "or the sign-in heading and a provider control.",
            file=self.stdout,
        )
        print(
            "     Before typing, the Simulator requires two consecutive streamed-pixel "
            "matches for doordash.com and the real sign-in form. Its 10-second preflight "
            "fails with privacy-safe evidence; no request is typed or sent.",
            file=self.stdout,
        )
        print(
            "  2. If macOS shows a screen-capture permission prompt, choose Allow "
            "yourself; this runner never clicks it. Then tap Let AI continue when shown.",
            file=self.stdout,
        )
        print("At the secure handoff in the Simulator:", file=self.stdout)
        print(
            "  3. You—not automation—sign in through the streamed Mac screen.",
            file=self.stdout,
        )
        print(
            "  4. Open the complete quote showing restaurant, item, subtotal, delivery "
            "fee, service fee, tax, total, and ETA together.",
            file=self.stdout,
        )
        print(
            "  5. Tap Let AI continue yourself. Do not check out or place the order.",
            file=self.stdout,
        )
        print("", file=self.stdout)
        print(
            "Safety: the runner never enters credentials, clicks a permission prompt, "
            "touches DoorDash controls, changes the cart, approves checkout, or places an order.",
            file=self.stdout,
        )
        print(
            "XCTest screen recording is disabled. The private result will be deleted "
            "unless its attachment audit permits only allowlisted JSON evidence.",
            file=self.stdout,
        )
        print(
            "Starting exactly one privacy-configured Release XCTest directly with "
            "/usr/bin/xcodebuild…",
            file=self.stdout,
            flush=True,
        )

    def _stop_process_group(
        self,
        process: subprocess.Popen[bytes],
        *,
        first_signal: signal.Signals,
    ) -> None:
        try:
            os.killpg(process.pid, first_signal)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=INTERRUPT_GRACE_SECONDS)
            return
        except subprocess.TimeoutExpired:
            pass

        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=TERMINATE_GRACE_SECONDS)
            return
        except subprocess.TimeoutExpired:
            pass

        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        process.wait()

    def _print_result_outcome(
        self,
        result_bundle: pathlib.Path,
        *,
        return_code: int,
    ) -> None:
        destination = self.stdout if return_code == 0 else self.stderr
        outcome = "PASSED" if return_code == 0 else f"FAILED (exit {return_code})"
        print(f"\nDoorDash continuous acceptance {outcome}.", file=destination)
        if result_bundle.exists():
            print(
                f"Privacy-audited result bundle: {result_bundle}",
                file=destination,
            )
        else:
            print(
                f"Xcode did not create the requested result bundle path: {result_bundle}",
                file=destination,
            )


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run only the continuous Release Simulator DoorDash takeover/resume XCTest "
            "directly, preserving its 15-minute manual sign-in window. Before typing or "
            "sending, a 10-second streamed-pixel gate requires the actual doordash.com "
            "signed-out form twice; History entries, previews, and Codex/ChatGPT pages "
            "are rejected. Xcode recording is disabled and only a privacy-audited result "
            "bundle can be published."
        )
    )
    parser.add_argument(
        "--allow-visible-ui",
        action="store_true",
        help=(
            "explicitly opt in to the real Simulator-visible DoorDash flow; required. "
            "The loaded doordash.com sign-in form must be visible; a History entry, "
            "preview, or Codex/ChatGPT page is rejected before typing or sending"
        ),
    )
    parser.add_argument(
        "--simulator-id",
        metavar="UDID",
        help=(
            "booted iPhone Air UDID; if omitted, exactly one booted iPhone Air is required"
        ),
    )
    parser.add_argument(
        "--result-directory",
        type=pathlib.Path,
        default=pathlib.Path(tempfile.gettempdir()),
        help=(
            "directory for the unique privacy-audited .xcresult bundle "
            "(default: system temp)"
        ),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_argument_parser()
    arguments = parser.parse_args(argv)
    if not arguments.allow_visible_ui:
        print(
            "Refusing to launch visible live UI without --allow-visible-ui. "
            "No Xcode or Simulator action was started.",
            file=sys.stderr,
        )
        return 2

    paths = RunnerPaths(result_directory=arguments.result_directory)
    runner = DoorDashLiveRunner(paths=paths)
    try:
        return runner.run(simulator_id=arguments.simulator_id)
    except RunnerError as error:
        print(
            f"Live run refused or withheld its quarantined evidence: {error}",
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
