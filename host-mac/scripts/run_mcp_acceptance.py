#!/usr/bin/env python3
"""Hidden runtime acceptance gate for the host-exposed MCP surface.

The runner talks to the pinned mac-control-mcp binary over its real stdio
JSON-RPC transport and issues real tools/call requests. It builds an accessory
AppKit fixture entirely outside every display. A CoreGraphics audit runs
continuously around every operation and fails if a test surface or prompt
enters a display. Safari tab tools are explicitly blocked: the live gate proved
that v0.8.2 activates and mutates Safari's ambient front window instead of a
host-owned isolated context.

The runner never prints tool output, because read tools can contain private
on-device data. All mutations are limited to temporary fixture state and
the exact prior frontmost application is restored.

The embedded remote_desktop_mail transport is covered by the signed-host
XCTest suite and the live Mail acceptance flow; this runner records it in the
matrix but deliberately cannot impersonate that signed in-process server.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE_SOURCE = REPO_ROOT / "host-mac/AcceptanceFixtures/MCPAcceptanceFixture.swift"
WINDOW_AUDIT_SOURCE = (
    REPO_ROOT / "host-mac/AcceptanceFixtures/MCPAcceptanceWindowAudit.swift"
)
FRONTMOST_RESTORER_SOURCE = (
    REPO_ROOT / "host-mac/AcceptanceFixtures/MCPAcceptanceFrontmostRestorer.swift"
)
POLICY_SOURCE = REPO_ROOT / "host-mac/RemoteDesktopHost/ComputerUse/MCPToolSafetyPolicy.swift"
PINNED_ADVERTISED_TOOL_COUNT = 143
PINNED_HELPER_SHA256 = (
    "402729cbf8179783466f4ba2ca1d1a2bf8ffb19cd7dee330963392afae9f4302"
)
FIXTURE_APP_NAME = "Remote Desktop MCP Test Fixture"
FIXTURE_WINDOW_TITLE = "Remote Desktop MCP Test Fixture"
COMPONENT_INPUT_TITLE = "Delivery note"
COMPONENT_STATUS_TITLE = "Test status"
COMPONENT_ACTION_BUTTON = "Save delivery note"
COMPONENT_CLICK_BUTTON = "Add utensils"
REQUIRED_WORKFLOWS = {"delivery_quote", "day_trip_plan"}
LSAPPINFO = pathlib.Path("/usr/bin/lsappinfo")

READ_ONLY_TOOLS = {
    "ax_snapshot_capture", "ax_snapshot_diff", "ax_tree_augmented",
    "contacts_search", "find_element", "find_elements", "focused_app",
    "get_element_attributes", "get_ui_tree", "list_apps", "list_elements",
    "list_menu_titles", "list_shortcuts", "list_windows", "permissions_status",
    "probe_ax_tree", "query_elements", "read_value", "reminders_list",
    "wait_for_ax_notification", "wait_for_element",
    "wait_for_window_state_change",
}
REVERSIBLE_TOOLS = {"focus_window"}
APPROVAL_TOOLS = {
    "click", "click_menu_path", "perform_element_action", "press_key",
    "remote_desktop_mail",
    "set_element_attribute", "type_text",
}
HOST_EXPOSED_TOOLS = READ_ONLY_TOOLS | REVERSIBLE_TOOLS | APPROVAL_TOOLS
SIDECAR_EXPOSED_TOOLS = HOST_EXPOSED_TOOLS - {"remote_desktop_mail"}
ACCEPTANCE_BLOCKED_TOOL_REASONS = {
    "browser_close_tab": "pinned helper activates Safari and can close a real tab in the ambient front window",
    "browser_dom_tree": "fails unless Safari's developer-only JavaScript from Apple Events setting is enabled",
    "browser_get_active_tab": "reads Safari's ambient front window rather than a host-owned isolated browser context",
    "browser_iframes": "fails unless Safari's developer-only JavaScript from Apple Events setting is enabled",
    "browser_list_tabs": "inventories unrelated user tabs and has no host-owned isolated browser context",
    "browser_navigate": "pinned helper can navigate Safari's ambient front window instead of host-owned state",
    "browser_new_tab": "live gate proved pinned helper activates Safari's ambient front window and can displace a real user tab",
    "browser_visible_text": "fails unless Safari's developer-only JavaScript from Apple Events setting is enabled",
    "calendar_create_event": "helper Calendar permission and isolated mutation fixture are not verified",
    "calendar_list_events": "signed helper is denied Calendar access on the default setup",
    "reminders_create": "no isolated Reminders mutation fixture with deterministic cleanup exists",
    "run_shortcut": "macOS has no local CLI for creating an isolated temporary Shortcut",
    "scroll_to_element": "pinned helper scrolls at the ambient pointer and accepts offscreen AX matches without scrolling",
}
TOOL_POSTCONDITIONS = {
    "ax_snapshot_capture": "returns a named snapshot ID for the isolated AppKit tree",
    "ax_snapshot_diff": "diffs two fixture snapshots after a known text-field change",
    "ax_tree_augmented": "returns a non-error AX/OCR view of the isolated fixture",
    "click": "changes the fixture status label through a real AX click",
    "click_menu_path": "changes fixture state through Test Actions > Save for Later",
    "contacts_search": "returns the successful contacts-list shape for a no-match sentinel without logging data",
    "find_element": "returns the exact fixture PID, role, title, geometry, and correlated cached-tree ID",
    "find_elements": "returns the fixture's bounded button matches",
    "focus_window": "focuses the offscreen fixture, verifies it, and restores the prior app",
    "focused_app": "returns fixture metadata during bounded focus before restoration",
    "get_element_attributes": "reads role/title/enabled attributes from a cached fixture ID",
    "get_ui_tree": "returns the fixture tree and stable IDs used by follow-up calls",
    "list_apps": "returns a non-error bounded running-application list",
    "list_elements": "returns actionable elements from only the fixture PID",
    "list_menu_titles": "returns menu titles from only the fixture PID",
    "list_shortcuts": "returns a consistent successful names/count shape without logging names or running one",
    "list_windows": "returns windows scoped to only the fixture PID",
    "perform_element_action": "AXPress changes the fixture status label",
    "permissions_status": "reports the signed helper's live Accessibility state",
    "press_key": "the isolated fixture observes the exact Command-A key equivalent",
    "probe_ax_tree": "reports a usable AX tree for the isolated fixture PID",
    "query_elements": "regex query returns fixture elements without scanning another PID",
    "read_value": "reads the exact isolated fixture field/status value",
    "reminders_list": "returns a bounded successful reminder-summary shape without logging data",
    "remote_desktop_mail": "signed-host ledger proves one visible draft and one .invalid send completed",
    "set_element_attribute": "sets AXValue on the fixture and read_value observes it",
    "type_text": "AX typing replaces the focused fixture field with the exact marker",
    "wait_for_ax_notification": "observes the fixture's signaled AXValueChanged event",
    "wait_for_element": "observes the fixture's known button before timeout",
    "wait_for_window_state_change": "observes the fixture's signaled window creation",
}


@dataclass
class ToolResult:
    name: str
    status: str
    detail: str
    risk: str = field(init=False)

    def __post_init__(self) -> None:
        if self.name in READ_ONLY_TOOLS:
            self.risk = "readOnly"
        elif self.name in REVERSIBLE_TOOLS:
            self.risk = "reversible"
        elif self.name in APPROVAL_TOOLS:
            self.risk = "approvalRequired"
        else:
            self.risk = "blocked"


@dataclass
class WorkflowResult:
    name: str
    status: str
    detail: str
    mcp_steps: int


class MCPProtocolError(RuntimeError):
    pass


class UserVisibleArtifactError(MCPProtocolError):
    """A new window or prompt crossed the native visibility boundary."""


class MCPClient:
    def __init__(self, binary: pathlib.Path, state_dir: pathlib.Path) -> None:
        environment = {
            "HOME": str(pathlib.Path.home()),
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": tempfile.gettempdir(),
            "MAC_CONTROL_MCP_HOME": str(state_dir),
            "MAC_CONTROL_MCP_ENFORCE_TIERS": "0",
        }
        self.process = subprocess.Popen(
            [str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1, env=environment)
        self._responses: queue.Queue[dict[str, Any]] = queue.Queue()
        self._reader = threading.Thread(target=self._read_responses, daemon=True)
        self._reader.start()
        self._next_id = 0

    def _read_responses(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "id" in value:
                self._responses.put(value)
        self._responses.put({
            "_transport_error": "mac-control-mcp transport closed unexpectedly",
        })

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def request(
        self, method: str, params: dict[str, Any], timeout: float = 30.0
    ) -> dict[str, Any]:
        self._next_id += 1
        request_id = self._next_id
        self._write({
            "jsonrpc": "2.0", "id": request_id,
            "method": method, "params": params,
        })
        deadline = time.monotonic() + timeout
        deferred: list[dict[str, Any]] = []
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise MCPProtocolError(f"{method} timed out")
                try:
                    response = self._responses.get(timeout=remaining)
                except queue.Empty as error:
                    raise MCPProtocolError(f"{method} timed out") from error
                if "_transport_error" in response:
                    raise MCPProtocolError(str(response["_transport_error"]))
                if response.get("id") == request_id:
                    if "error" in response:
                        raise MCPProtocolError(
                            f"{method} JSON-RPC error {response['error'].get('code')}")
                    return response.get("result", {})
                deferred.append(response)
        finally:
            for response in deferred:
                self._responses.put(response)

    def _write(self, value: dict[str, Any]) -> None:
        if self.process.poll() is not None:
            raise MCPProtocolError("mac-control-mcp exited unexpectedly")
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(value, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def initialize(self) -> dict[str, Any]:
        result = self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "RemoteDesktopMCPAcceptance", "version": "1.0"},
        })
        self.notify("notifications/initialized", {})
        return result

    def list_tools(self) -> list[dict[str, Any]]:
        return self.request("tools/list", {}).get("tools", [])

    def call(self, name: str, arguments: dict[str, Any], timeout: float = 30.0) -> dict[str, Any]:
        return self.request(
            "tools/call", {"name": name, "arguments": arguments}, timeout=timeout)

    def abort(self, reason: str) -> None:
        self._responses.put({"_transport_error": reason})
        if self.process.poll() is None:
            self.process.terminate()

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)


class AcceptanceRunner:
    def __init__(
        self,
        binary: pathlib.Path,
        verbose: bool = False,
    ) -> None:
        self.binary = binary
        digest = hashlib.sha256()
        with self.binary.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != PINNED_HELPER_SHA256:
            raise MCPProtocolError("The helper binary hash does not match pinned v0.8.2")
        self.prior_frontmost_pid = self._frontmost_pid()
        if self.prior_frontmost_pid is None:
            raise MCPProtocolError("Could not identify the prior frontmost application")
        self.temporary = pathlib.Path(tempfile.mkdtemp(prefix="remote-desktop-mcp-e2e-"))
        # The helper is deliberately not launched here. run() first compiles
        # the native window audit, captures the visible-window baseline, and
        # starts the bootstrap watchdog. This prevents a launch/init/list
        # prompt from being absorbed into a later baseline.
        self.client: MCPClient | None = None
        self.verbose = verbose
        self.fixture_process: subprocess.Popen[str] | None = None
        self.fixture_pid: int | None = None
        self.window_audit_binary: pathlib.Path | None = None
        self.frontmost_restorer_binary: pathlib.Path | None = None
        self.fixture_executable: pathlib.Path | None = None
        self.visibility_baseline: set[int] = set()
        self.native_visible_feedback: dict[str, dict[int, dict[str, Any]]] = {}
        self.results: dict[str, ToolResult] = {}
        self.workflow_results: dict[str, WorkflowResult] = {}
        self._active_workflow_steps = 0
        self.semantic_evidence: set[str] = set()
        self.tool_schemas: dict[str, dict[str, Any]] = {}
        self.advertised_tool_count = 0
        self.advertised_tools: list[dict[str, Any]] = []
        self.advertised_tool_names: list[str] = []
        self.policy_blocked_advertised_tool_names: list[str] = []

    def run(self) -> list[ToolResult]:
        if set(TOOL_POSTCONDITIONS) != HOST_EXPOSED_TOOLS:
            raise MCPProtocolError("The acceptance postcondition matrix does not match the host exposure set")
        source = POLICY_SOURCE.read_text()
        source_allowed: set[str] = set()
        for set_name in ("readOnlyTools", "reversibleTools", "approvalRequiredTools"):
            match = re.search(
                rf"static let {set_name}: Set<String> = \[(.*?)\n    \]",
                source, re.DOTALL)
            if match is None:
                raise MCPProtocolError(f"Could not inspect host policy set {set_name}")
            source_allowed.update(re.findall(
                r'^\s*"([^"]+)",?$', match.group(1), re.MULTILINE))
        if source_allowed != HOST_EXPOSED_TOOLS:
            raise MCPProtocolError("The checked-in host allowlist drifted from the acceptance matrix")
        self._build_visibility_guard()
        self._initialize_sidecar_and_launch_fixture()

        self._run_fixture_cases()
        self._run_everyday_workflows()
        self._run_private_read_cases()
        self._verify_mail_live_evidence()
        for name, detail in ACCEPTANCE_BLOCKED_TOOL_REASONS.items():
            self.results[name] = ToolResult(name, "BLOCKED_AFTER_E2E", detail)
        for name in sorted(HOST_EXPOSED_TOOLS):
            self.results.setdefault(name, ToolResult(
                name, "MISSING", "No end-to-end acceptance case is defined"))
        for name in sorted(HOST_EXPOSED_TOOLS - self.semantic_evidence):
            self.results[name] = ToolResult(
                name, "FAIL", "No semantic postcondition evidence was recorded")
        return [self.results[name] for name in sorted(self.results)]

    def _initialize_sidecar_and_launch_fixture(self) -> None:
        """Guard helper launch, handshake, inventory, and fixture launch."""
        watchdog = self._start_visibility_watchdog(trigger_tool="MCP bootstrap")
        startup_failure: BaseException | None = None
        try:
            if watchdog[2]:
                raise watchdog[2][0]
            self.client = MCPClient(self.binary, self.temporary / "mcp-state")
            if watchdog[2]:
                self.client.abort(
                    "Native bootstrap watchdog aborted mac-control-mcp")
                raise watchdog[2][0]
            # Close the small process-construction race synchronously before
            # sending initialize or tools/list.
            self._assert_test_windows_hidden(trigger_tool="MCP launch")
            initialization = self.client.initialize()
            self._assert_test_windows_hidden(trigger_tool="MCP initialize")
            self._validate_initialization_and_inventory(initialization)
            self._launch_fixture()
        except BaseException as error:
            startup_failure = error
        finally:
            visibility_failures = self._stop_visibility_watchdog(watchdog)
            try:
                self._restore_frontmost_application()
                fixture_expected = (
                    self.fixture_process is not None
                    and self.fixture_process.poll() is None
                )
                self._assert_test_windows_hidden(
                    require_fixture_window=fixture_expected,
                    trigger_tool="MCP bootstrap",
                )
            except BaseException as error:
                visibility_failures.append(error)
        if visibility_failures:
            failure = visibility_failures[0]
            if isinstance(failure, UserVisibleArtifactError):
                raise failure
            raise UserVisibleArtifactError(
                "Native bootstrap watchdog could not prove hidden launch/init/list"
            ) from failure
        if startup_failure is not None:
            raise startup_failure

    def _validate_initialization_and_inventory(
        self,
        initialization: dict[str, Any],
    ) -> None:
        server = initialization.get("serverInfo", {})
        if (server.get("name"), server.get("version"), initialization.get("protocolVersion")) != (
            "mac-control-mcp", "0.8.2", "2024-11-05"
        ):
            raise MCPProtocolError("The helper identity does not match the pinned release")

        if self.client is None:
            raise MCPProtocolError("The MCP helper was not launched")
        advertised = self.client.list_tools()
        self._assert_test_windows_hidden(trigger_tool="MCP tools/list")
        advertised_names = [tool["name"] for tool in advertised]
        if len(advertised_names) != len(set(advertised_names)):
            raise MCPProtocolError("The pinned helper advertised duplicate tool names")
        if len(advertised_names) != PINNED_ADVERTISED_TOOL_COUNT:
            raise MCPProtocolError(
                f"Pinned v0.8.2 advertised {len(advertised_names)} tools; expected "
                f"{PINNED_ADVERTISED_TOOL_COUNT}")
        self.advertised_tool_count = len(advertised_names)
        # Preserve every descriptor returned by tools/list for audit evidence.
        # Sort by the unique tool name so serialized reports remain byte-stable
        # even if the helper changes only the order of its response.
        self.advertised_tools = sorted(advertised, key=lambda tool: tool["name"])
        self.advertised_tool_names = [
            tool["name"] for tool in self.advertised_tools
        ]
        self.policy_blocked_advertised_tool_names = sorted(
            set(self.advertised_tool_names) - SIDECAR_EXPOSED_TOOLS
        )
        self.tool_schemas = {tool["name"]: tool.get("inputSchema", {}) for tool in advertised}
        missing = SIDECAR_EXPOSED_TOOLS - self.tool_schemas.keys()
        if missing:
            raise MCPProtocolError("Host allowlist contains unadvertised tools: " + ", ".join(sorted(missing)))
        expected_blocked_count = len(advertised_names) - len(SIDECAR_EXPOSED_TOOLS)
        if len(self.policy_blocked_advertised_tool_names) != expected_blocked_count:
            raise MCPProtocolError(
                "The advertised policy-blocked inventory does not match its count")
        for name in sorted(SIDECAR_EXPOSED_TOOLS):
            schema = self.tool_schemas[name]
            properties = schema.get("properties") if isinstance(schema, dict) else None
            required = schema.get("required", []) if isinstance(schema, dict) else None
            additional = (
                schema.get("additionalProperties") if isinstance(schema, dict) else None)
            if (not isinstance(schema, dict)
                    or schema.get("type") != "object"
                    or not isinstance(properties, dict)
                    or any(not isinstance(key, str) or not isinstance(value, dict)
                           for key, value in properties.items())
                    or not isinstance(required, list)
                    or any(not isinstance(key, str) or key not in properties
                           for key in required)
                    or len(required) != len(set(required))
                    or (additional is not None
                        and not isinstance(additional, (bool, dict)))):
                raise MCPProtocolError(
                    f"Pinned helper advertised an invalid object schema for {name}")

    def _build_visibility_guard(self) -> None:
        executable = self.temporary / "MCPAcceptanceFixture.app/Contents/MacOS/MCPAcceptanceFixture"
        self.fixture_executable = executable
        self.window_audit_binary = self.temporary / "MCPAcceptanceWindowAudit"
        self.frontmost_restorer_binary = self.temporary / "MCPAcceptanceFrontmostRestorer"
        executable.parent.mkdir(parents=True)
        subprocess.run([
            "xcrun", "swiftc", str(FIXTURE_SOURCE), "-o", str(executable),
            "-framework", "AppKit",
        ], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([
            "xcrun", "swiftc", str(WINDOW_AUDIT_SOURCE),
            "-o", str(self.window_audit_binary), "-framework", "CoreGraphics",
        ], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([
            "xcrun", "swiftc", str(FRONTMOST_RESTORER_SOURCE),
            "-o", str(self.frontmost_restorer_binary), "-framework", "AppKit",
        ], check=True, stdout=subprocess.DEVNULL)
        info = {
            "CFBundleExecutable": "MCPAcceptanceFixture",
            "CFBundleIdentifier": "com.threadmark.remotedesktop.mcp-acceptance-fixture",
            "CFBundleDisplayName": FIXTURE_APP_NAME,
            "CFBundleName": FIXTURE_APP_NAME,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "15.0",
            "LSUIElement": True,
            "NSPrincipalClass": "NSApplication",
        }
        with (executable.parents[1] / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        # This is the only baseline capture for the run. It deliberately
        # precedes MCPClient construction/Popen, initialize, and tools/list.
        self.visibility_baseline = self._snapshot_visible_window_ids()

    def _launch_fixture(self) -> None:
        executable = self.fixture_executable
        if executable is None:
            raise MCPProtocolError("The native visibility guard was not built")
        self.fixture_process = subprocess.Popen(
            [str(executable)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        self.fixture_pid = self.fixture_process.pid
        time.sleep(1.0)
        if self.fixture_process.poll() is not None:
            raise RuntimeError("The AppKit MCP acceptance fixture did not launch")
        self._restore_frontmost_application()
        self._assert_test_windows_hidden(require_fixture_window=True)

    @staticmethod
    def _frontmost_pid() -> int | None:
        completed = subprocess.run(
            [str(LSAPPINFO), "front"],
            check=False,
            capture_output=True,
            text=True,
        )
        asn = re.search(r"ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+:", completed.stdout)
        if completed.returncode != 0 or asn is None:
            return None
        info = subprocess.run(
            [str(LSAPPINFO), "info", "-only", "pid", asn.group(0)],
            check=False,
            capture_output=True,
            text=True,
        )
        pid = re.search(r"=\s*(\d+)", info.stdout)
        return int(pid.group(1)) if info.returncode == 0 and pid else None

    def _restore_frontmost_application(self) -> None:
        if self.frontmost_restorer_binary is None:
            return
        for _ in range(8):
            completed = subprocess.run(
                [str(self.frontmost_restorer_binary), str(self.prior_frontmost_pid)],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            time.sleep(0.05)
            if completed.returncode == 0 and self._frontmost_pid() == self.prior_frontmost_pid:
                return
        raise MCPProtocolError("Could not restore the prior frontmost application")

    def _assert_test_windows_hidden(
        self,
        *,
        require_fixture_window: bool = False,
        allow_capture_status_indicator: bool = False,
        trigger_tool: str | None = None,
    ) -> dict[str, Any]:
        if self.window_audit_binary is None:
            raise MCPProtocolError("The CoreGraphics window audit is unavailable")
        pids = [pid for pid in (self.fixture_pid,) if isinstance(pid, int)]
        arguments = [str(self.window_audit_binary)]
        for pid in pids:
            arguments.extend(["--pid", str(pid)])
        if allow_capture_status_indicator:
            arguments.append("--allow-capture-status-indicator")
        for window_id in sorted(self.visibility_baseline):
            arguments.extend(["--baseline-window-id", str(window_id)])
        completed = subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
        )
        try:
            report = json.loads(completed.stdout)
        except (TypeError, ValueError) as error:
            raise MCPProtocolError("CoreGraphics window audit returned invalid data") from error
        if completed.returncode != 0:
            owners = report.get("unexpectedVisibleOwnerPIDs", [])
            windows = report.get("unexpectedVisibleWindows", [])
            raise UserVisibleArtifactError(
                "A test fixture or prompt appeared on an active display"
                + (f" during {trigger_tool}" if trigger_tool else "")
                + (f" (owner PIDs: {owners})" if owners else "")
                + (f" evidence={json.dumps(windows, sort_keys=True)}"
                   if windows else ""))
        allowed_indicators = report.get("allowedCaptureStatusIndicators", [])
        if (not isinstance(allowed_indicators, list)
                or len(allowed_indicators) > 2
                or any(not self._is_expected_capture_status_indicator(item)
                       for item in allowed_indicators)):
            raise UserVisibleArtifactError(
                "Native capture status indicator evidence was outside the exact allowance")
        if (allowed_indicators
                and (not allow_capture_status_indicator
                     or trigger_tool != "ax_tree_augmented")):
            raise UserVisibleArtifactError(
                "A capture status indicator appeared outside ax_tree_augmented")
        if allowed_indicators:
            observed = self.native_visible_feedback.setdefault(
                "ax_tree_augmented", {})
            observed.update({item["id"]: dict(item) for item in allowed_indicators})
        required_count = int(require_fixture_window)
        if report.get("matchedWindowCount", 0) < required_count:
            raise MCPProtocolError("CoreGraphics could not find the expected offscreen window")
        if (report.get("onDisplayWindowCount") != 0
                or report.get("onScreenListWindowCount") != 0
                or report.get("unexpectedVisibleWindowCount") != 0):
            raise UserVisibleArtifactError(
                "A test fixture or prompt appeared on an active display")
        return report

    @staticmethod
    def _is_expected_capture_status_indicator(item: Any) -> bool:
        if not isinstance(item, dict):
            return False
        numeric = ("x", "y", "width", "height")
        if any(not isinstance(item.get(key), (int, float)) for key in numeric):
            return False
        width = float(item["width"])
        height = float(item["height"])
        return (
            item.get("ownerName") == "Window Server"
            and item.get("windowName") == "StatusIndicator"
            and item.get("layer") == 2_147_483_630
            and 0 < width <= 32
            and 0 < height <= 32
            and item.get("topMenuBarContained") is True
        )

    def _snapshot_visible_window_ids(self) -> set[int]:
        if self.window_audit_binary is None:
            raise MCPProtocolError("The CoreGraphics window audit is unavailable")
        completed = subprocess.run(
            [str(self.window_audit_binary), "--snapshot-visible-window-ids"],
            check=False,
            capture_output=True,
            text=True,
        )
        try:
            report = json.loads(completed.stdout)
            ids = report.get("visibleWindowIDs")
        except (TypeError, ValueError) as error:
            raise MCPProtocolError("CoreGraphics baseline returned invalid data") from error
        if (completed.returncode != 0
                or not isinstance(ids, list)
                or any(not isinstance(item, int) for item in ids)):
            raise MCPProtocolError("CoreGraphics baseline returned invalid data")
        return set(ids)

    def _start_visibility_watchdog(
        self,
        *,
        allow_capture_status_indicator: bool = False,
        trigger_tool: str | None = None,
    ) -> tuple[threading.Event, threading.Thread, list[BaseException]]:
        stop_monitor = threading.Event()
        first_audit_finished = threading.Event()
        visibility_failure: list[BaseException] = []

        def monitor_visibility() -> None:
            while not stop_monitor.is_set():
                try:
                    self._assert_test_windows_hidden(
                        allow_capture_status_indicator=allow_capture_status_indicator,
                        trigger_tool=trigger_tool,
                    )
                except BaseException as error:
                    visibility_failure.append(error)
                    if self.client is not None:
                        self.client.abort(
                            "Native visibility watchdog aborted mac-control-mcp")
                    first_audit_finished.set()
                    return
                first_audit_finished.set()
                if stop_monitor.wait(0.02):
                    return

        monitor = threading.Thread(target=monitor_visibility, daemon=True)
        monitor.start()
        if not first_audit_finished.wait(timeout=2.0):
            stop_monitor.set()
            monitor.join(timeout=1.0)
            raise MCPProtocolError(
                "Native visibility watchdog could not complete its initial audit")
        return stop_monitor, monitor, visibility_failure

    @staticmethod
    def _stop_visibility_watchdog(
        watchdog: tuple[threading.Event, threading.Thread, list[BaseException]],
    ) -> list[BaseException]:
        stop_monitor, monitor, visibility_failure = watchdog
        stop_monitor.set()
        monitor.join(timeout=1.0)
        return visibility_failure

    def _wait_for_capture_status_indicator_fade(
        self,
        *,
        trigger_tool: str,
        timeout: float = 15.0,
    ) -> None:
        deadline = time.monotonic() + timeout
        while True:
            report = self._assert_test_windows_hidden(
                allow_capture_status_indicator=True,
                trigger_tool=trigger_tool,
            )
            if not report.get("allowedCaptureStatusIndicators"):
                return
            if time.monotonic() >= deadline:
                raise UserVisibleArtifactError(
                    "Native screen-capture privacy indicators did not fade in time")
            time.sleep(0.05)

    def _invoke_tool(
        self,
        name: str,
        arguments: dict[str, Any],
        *,
        timeout: float = 30.0,
        preserve_frontmost: bool = False,
    ) -> dict[str, Any]:
        if self.client is None:
            raise MCPProtocolError("The MCP helper was not launched")
        allow_capture_status_indicator = name == "ax_tree_augmented"
        watchdog = self._start_visibility_watchdog(
            allow_capture_status_indicator=allow_capture_status_indicator,
            trigger_tool=name,
        )
        result: dict[str, Any] | None = None
        call_failure: BaseException | None = None
        try:
            result = self.client.call(name, arguments, timeout=timeout)
        except BaseException as error:
            call_failure = error
        finally:
            visibility_failure = self._stop_visibility_watchdog(watchdog)
            if not preserve_frontmost:
                self._restore_frontmost_application()
            self._assert_test_windows_hidden(
                allow_capture_status_indicator=allow_capture_status_indicator,
                trigger_tool=name,
            )
        if visibility_failure:
            failure = visibility_failure[0]
            if isinstance(failure, UserVisibleArtifactError):
                raise failure
            raise UserVisibleArtifactError(
                "Native visibility watchdog could not prove hidden operation") from failure
        if allow_capture_status_indicator:
            self._wait_for_capture_status_indicator_fade(trigger_tool=name)
        if call_failure is not None:
            raise call_failure
        assert result is not None
        return result

    @staticmethod
    def _content_text(result: dict[str, Any]) -> str:
        return "\n".join(
            item.get("text", "") for item in result.get("content", [])
            if isinstance(item, dict) and item.get("type") == "text")

    @classmethod
    def _content_json(cls, result: dict[str, Any]) -> Any:
        text = cls._content_text(result).strip()
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return None

    @staticmethod
    def _structured(result: dict[str, Any] | None) -> Any:
        if not isinstance(result, dict):
            return None
        value = result.get("structuredContent")
        if isinstance(value, dict) and set(value).issuperset({"ok", "result"}):
            return value.get("result")
        return value

    @classmethod
    def _structured_dict(cls, result: dict[str, Any] | None) -> dict[str, Any] | None:
        value = cls._structured(result)
        return value if isinstance(value, dict) else None

    @classmethod
    def _matches_fields(
        cls, result: dict[str, Any] | None, expected: dict[str, Any]
    ) -> bool:
        value = cls._structured_dict(result)
        return value is not None and all(value.get(key) == item for key, item in expected.items())

    @classmethod
    def _matches_fixture_element(
        cls,
        result: dict[str, Any] | None,
        *,
        pid: int,
        role: str,
        title: str,
        expected_node: dict[str, Any] | None = None,
    ) -> bool:
        value = cls._structured_dict(result)
        element = value.get("element") if value else None
        if not isinstance(element, dict):
            return False
        if value.get("ok") is not True or value.get("pid") != pid:
            return False
        if element.get("role") != role or element.get("title") != title:
            return False
        position = element.get("position")
        size = element.get("size")
        if not isinstance(position, dict) or not isinstance(size, dict):
            return False
        if not all(isinstance(position.get(key), (int, float)) for key in ("x", "y")):
            return False
        if not all(isinstance(size.get(key), (int, float)) and size[key] > 0
                   for key in ("width", "height")):
            return False
        if expected_node is None or not isinstance(expected_node.get("id"), str):
            return expected_node is None
        return (position == expected_node.get("position")
                and size == expected_node.get("size"))

    @classmethod
    def _private_list_shape(
        cls,
        result: dict[str, Any] | None,
        *,
        list_key: str,
        item_shape: dict[str, type],
        maximum_count: int | None = None,
    ) -> bool:
        value = cls._structured_dict(result)
        items = value.get(list_key) if value else None
        if value is None or value.get("ok") is not True or not isinstance(items, list):
            return False
        if maximum_count is not None and len(items) > maximum_count:
            return False
        return all(
            isinstance(item, dict)
            and all(isinstance(item.get(key), expected_type)
                    for key, expected_type in item_shape.items())
            for item in items)

    @classmethod
    def _collection_contains(
        cls,
        result: dict[str, Any] | None,
        *,
        collection: str,
        expected: dict[str, Any],
        pid: int | None = None,
        require_id: bool = False,
    ) -> bool:
        value = cls._structured_dict(result)
        items = value.get(collection) if value else None
        if value is None or value.get("ok") is not True or not isinstance(items, list):
            return False
        if pid is not None and value.get("pid") != pid:
            return False
        return any(
            isinstance(item, dict)
            and all(item.get(key) == expected_value
                    for key, expected_value in expected.items())
            and (not require_id or isinstance(item.get("id"), str))
            for item in items)

    @classmethod
    def _structured_contains(cls, result: dict[str, Any], needle: str) -> bool:
        try:
            return needle in json.dumps(cls._structured(result), sort_keys=True)
        except (TypeError, ValueError):
            return False

    def _call_ok(
        self, name: str, arguments: dict[str, Any],
        postcondition: Callable[[dict[str, Any]], bool],
        timeout: float = 30.0,
        *,
        preserve_frontmost: bool = False,
    ) -> dict[str, Any]:
        try:
            result = self._invoke_tool(
                name,
                arguments,
                timeout=timeout,
                preserve_frontmost=preserve_frontmost,
            )
            if result.get("isError") is True:
                raise MCPProtocolError("tool returned isError=true")
            if not postcondition(result):
                raise MCPProtocolError("postcondition failed")
        except Exception as error:
            self.results[name] = ToolResult(name, "FAIL", str(error)[:180])
            if self.verbose:
                print(f"FAIL {name}: {error}", flush=True)
            raise
        self.semantic_evidence.add(name)
        prior = self.results.get(name)
        if prior is None or prior.status != "FAIL":
            self.results[name] = ToolResult(name, "PASS", TOOL_POSTCONDITIONS[name])
        if self.verbose:
            print(f"PASS {name}", flush=True)
        return result

    def _call_recording_failure(
        self, name: str, arguments: dict[str, Any],
        postcondition: Callable[[dict[str, Any]], bool],
        timeout: float = 30.0,
        *,
        preserve_frontmost: bool = False,
    ) -> dict[str, Any] | None:
        try:
            return self._call_ok(
                name,
                arguments,
                postcondition=postcondition,
                timeout=timeout,
                preserve_frontmost=preserve_frontmost,
            )
        except UserVisibleArtifactError:
            raise
        except Exception:
            return None

    def _fail_semantic(self, name: str, detail: str) -> None:
        self.results[name] = ToolResult(name, "FAIL", detail)

    def _extract_snapshot_id(self, result: dict[str, Any]) -> str | None:
        value = self._structured(result)
        if value is None:
            value = self._content_json(result)
        if isinstance(value, dict):
            for key in ("snapshot_id", "snapshotID", "id", "snapshotId"):
                if isinstance(value.get(key), str):
                    return value[key]
        return None

    def _tree_element_id(
        self, result: dict[str, Any] | None, title: str, role: str
    ) -> str | None:
        node = self._tree_node(result, title, role)
        return node.get("id") if node is not None else None

    def _tree_node(
        self, result: dict[str, Any] | None, title: str | None, role: str
    ) -> dict[str, Any] | None:
        value = self._structured(result)
        if not isinstance(value, dict):
            return None
        for node in value.get("nodes", []):
            if (isinstance(node, dict) and node.get("title") == title
                    and node.get("role") == role and isinstance(node.get("id"), str)):
                return node
        return None

    def _read_fixture_value(self, title: str, role: str) -> str:
        assert self.fixture_pid is not None
        result = self._invoke_tool("read_value", {
            "pid": self.fixture_pid, "role": role, "title": title,
        })
        if result.get("isError") is True:
            raise MCPProtocolError("fixture read_value returned isError=true")
        value = self._structured_dict(result)
        if (value is not None and value.get("ok") is True
                and value.get("pid") == self.fixture_pid
                and value.get("role") == role and value.get("title") == title
                and value.get("value") is not None):
            return str(value["value"])
        raise MCPProtocolError("fixture read_value response did not match the requested control")

    def _verify_fixture_value(
        self,
        tool_name: str,
        title: str,
        role: str,
        expected: str,
        timeout: float = 1.5,
    ) -> bool:
        deadline = time.monotonic() + timeout
        read_succeeded = False
        last_observed: str | None = None
        while True:
            try:
                observed = self._read_fixture_value(title, role)
                read_succeeded = True
                last_observed = observed
                if observed == expected:
                    return True
            except Exception:
                pass
            if time.monotonic() >= deadline:
                detail = (
                    f"Isolated fixture expected {expected!r} but observed "
                    f"{last_observed!r}"
                    if read_succeeded else
                    "Could not read the isolated fixture postcondition"
                )
                self._fail_semantic(tool_name, detail)
                return False
            time.sleep(0.05)

    def _run_fixture_cases(self) -> None:
        assert self.fixture_pid is not None
        pid = self.fixture_pid

        self._call_recording_failure(
            "permissions_status", {},
            postcondition=lambda result: self._matches_fields(result, {
                "ok": True, "accessibility": "granted",
            }))
        self._call_recording_failure(
            "list_apps", {},
            postcondition=lambda result: (
                (value := self._structured_dict(result)) is not None
                and value.get("ok") is True
                and isinstance(value.get("apps"), list)
                and 0 < len(value["apps"]) <= 500
                and all(
                    isinstance(app, dict)
                    and isinstance(app.get("pid"), int)
                    and isinstance(app.get("name"), str)
                    for app in value["apps"])))
        windows = self._call_recording_failure(
            "list_windows", {"pid": pid},
            postcondition=lambda result: self._collection_contains(
                result,
                collection="windows",
                pid=pid,
                expected={
                    "pid": pid,
                    "index": 0,
                    "title": FIXTURE_WINDOW_TITLE,
                }))
        if windows is not None:
            focused_window = self._call_recording_failure(
                "focus_window", {"pid": pid, "index": 0},
                postcondition=lambda result: self._matches_fields(result, {
                    "ok": True, "pid": pid, "index": 0,
                }),
                preserve_frontmost=True)
            time.sleep(0.25)
            focused_app = self._call_recording_failure(
                "focused_app", {},
                postcondition=lambda result: (
                    (value := self._structured_dict(result)) is not None
                    and value.get("ok") is True
                    and isinstance(value.get("app"), dict)
                    and value["app"].get("pid") == pid
                    and value["app"].get("name") == FIXTURE_APP_NAME
                    and value["app"].get("bundleIdentifier")
                        == "com.threadmark.remotedesktop.mcp-acceptance-fixture"
                    and value["app"].get("isActive") is True))
            if focused_window is not None and focused_app is None:
                self._fail_semantic(
                    "focus_window", "Fixture was not the verified frontmost application")
        else:
            for name in ("focus_window", "focused_app"):
                self._fail_semantic(name, "Fixture window inventory was unavailable")
        self._call_recording_failure(
            "list_menu_titles", {"pid": pid},
            postcondition=lambda result: (
                (value := self._structured_dict(result)) is not None
                and value.get("ok") is True and value.get("pid") == pid
                and isinstance(value.get("titles"), list)
                and "Test Actions" in value["titles"]))
        self._call_recording_failure(
            "probe_ax_tree", {"pid": pid},
            postcondition=lambda result: (
                self._matches_fields(result, {
                    "ok": True, "pid": pid, "has_ax_tree": True,
                })
                and isinstance(self._structured_dict(result).get("window_count"), int)
                and self._structured_dict(result)["window_count"] >= 1))
        tree = self._call_recording_failure(
            "get_ui_tree", {"pid": pid, "max_depth": 12},
            postcondition=lambda result: (
                self._matches_fields(result, {"ok": True, "pid": pid})
                and self._tree_element_id(
                    result, COMPONENT_ACTION_BUTTON, "AXButton") is not None
                and self._tree_element_id(
                    result, COMPONENT_INPUT_TITLE, "AXTextField") is not None))
        self._call_recording_failure(
            "list_elements", {"pid": pid, "max_depth": 12},
            postcondition=lambda result: self._collection_contains(
                result,
                collection="elements",
                pid=pid,
                expected={"role": "AXButton", "title": COMPONENT_CLICK_BUTTON}))

        action_node = self._tree_node(tree, COMPONENT_ACTION_BUTTON, "AXButton")
        self._call_recording_failure(
            "find_element", {
                "pid": pid, "role": "AXButton", "title": COMPONENT_ACTION_BUTTON,
            },
            postcondition=lambda result: self._matches_fixture_element(
                result,
                pid=pid,
                role="AXButton",
                title=COMPONENT_ACTION_BUTTON,
                expected_node=action_node))
        self._call_recording_failure(
            "find_elements", {"pid": pid, "role": "AXButton"},
            postcondition=lambda result: self._collection_contains(
                result,
                collection="elements",
                pid=pid,
                expected={"role": "AXButton", "title": COMPONENT_ACTION_BUTTON},
                require_id=True))
        self._call_recording_failure(
            "query_elements", {
                "pid": pid, "title_regex": "delivery", "limit": 20,
            },
            postcondition=lambda result: self._collection_contains(
                result,
                collection="elements",
                pid=pid,
                expected={"role": "AXButton", "title": COMPONENT_ACTION_BUTTON},
                require_id=True))
        self._call_recording_failure(
            "wait_for_element", {
                "pid": pid, "role": "AXButton", "title": COMPONENT_ACTION_BUTTON,
                "timeout_seconds": 3,
            },
            postcondition=lambda result: (
                self._matches_fields(result, {
                    "ok": True,
                    "role": "AXButton",
                    "title": COMPONENT_ACTION_BUTTON,
                })
                and isinstance(
                    self._structured_dict(result).get("element_id"), str)
                and isinstance(self._structured_dict(result).get("attempts"), int)
                and self._structured_dict(result)["attempts"] >= 1))
        self._call_recording_failure(
            "read_value", {
                "pid": pid, "role": "AXTextField", "title": COMPONENT_INPUT_TITLE,
            },
            postcondition=lambda result: self._matches_fields(result, {
                "ok": True,
                "pid": pid,
                "role": "AXTextField",
                "title": COMPONENT_INPUT_TITLE,
                "value": "Ring the doorbell",
            }))

        action_id = self._tree_element_id(tree, COMPONENT_ACTION_BUTTON, "AXButton")
        if action_id:
            self._call_recording_failure(
                "get_element_attributes", {
                    "element_id": action_id,
                    "names": ["AXRole", "AXTitle", "AXEnabled"],
                },
                postcondition=lambda result: (
                    self._matches_fields(result, {
                        "ok": True, "element_id": action_id, "unavailable": [],
                    })
                    and self._structured_dict(result).get("values") == {
                        "AXRole": "AXButton",
                        "AXTitle": COMPONENT_ACTION_BUTTON,
                        "AXEnabled": "1",
                    }))
            performed = self._call_recording_failure(
                "perform_element_action", {
                    "element_id": action_id, "action": "AXPress",
                },
                postcondition=lambda result: self._matches_fields(result, {
                    "ok": True,
                    "element_id": action_id,
                    "action": "AXPress",
                    "strategy": "ax",
                    "ax_status": 0,
                }))
            if performed is not None:
                self._verify_fixture_value(
                    "perform_element_action",
                    COMPONENT_STATUS_TITLE, "AXStaticText", "Delivery note saved")
        else:
            for name in ("get_element_attributes", "perform_element_action"):
                self._fail_semantic(name, "Fixture element ID was unavailable")

        input_id = self._tree_element_id(tree, COMPONENT_INPUT_TITLE, "AXTextField")
        if input_id:
            changed = self._call_recording_failure(
                "set_element_attribute", {
                    "element_id": input_id,
                    "name": "AXValue",
                    "value": "Please knock once",
                },
                postcondition=lambda result: self._matches_fields(result, {
                    "ok": True,
                    "element_id": input_id,
                    "name": "AXValue",
                    "ax_status": 0,
                }))
            if changed is not None:
                self._verify_fixture_value(
                    "set_element_attribute",
                    COMPONENT_INPUT_TITLE, "AXTextField", "Please knock once")
        else:
            self._fail_semantic(
                "set_element_attribute", "Fixture input element ID was unavailable")

        if input_id:
            prerequisite = self._invoke_tool("set_element_attribute", {
                "element_id": input_id,
                "name": "AXValue",
                "value": "Please leave by gate",
            })
            if (prerequisite.get("isError") is True
                    or not self._matches_fields(prerequisite, {
                        "ok": True, "element_id": input_id,
                        "name": "AXValue", "ax_status": 0,
                    })):
                for name in ("press_key", "type_text"):
                    self._fail_semantic(name, "Could not prepare the isolated input field")
        focus_again = self._invoke_tool(
            "focus_window",
            {"pid": pid, "index": 0},
            preserve_frontmost=True,
        )
        focus_ok = (
            focus_again.get("isError") is not True
            and self._matches_fields(focus_again, {
                "ok": True, "pid": pid, "index": 0,
            })
        )
        pressed = None
        if not focus_ok:
            for name in ("press_key", "type_text"):
                self._fail_semantic(name, "Could not focus the isolated fixture")
            self._restore_frontmost_application()
        else:
            time.sleep(0.25)
            pressed = self._call_recording_failure(
                "press_key", {"key": "a", "modifiers": ["command"]},
                postcondition=lambda result: self._matches_fields(result, {
                    "ok": True,
                    "key": "a",
                    "key_code": 0,
                    "modifiers": ["command"],
                }),
                preserve_frontmost=True)
        time.sleep(0.25)
        if pressed is not None:
            self._verify_fixture_value(
                "press_key",
                COMPONENT_STATUS_TITLE, "AXStaticText", "Delivery note selected")
        typing_focus = self._invoke_tool(
            "focus_window",
            {"pid": pid, "index": 0},
            preserve_frontmost=True,
        )
        typing_focus_ok = (
            typing_focus.get("isError") is not True
            and self._matches_fields(typing_focus, {
                "ok": True, "pid": pid, "index": 0,
            })
        )
        typed = None
        if not typing_focus_ok:
            self._fail_semantic("type_text", "Could not focus the isolated fixture")
            self._restore_frontmost_application()
        else:
            typed = self._call_recording_failure(
                "type_text", {"text": "No-contact delivery", "strategy": "ax"},
                postcondition=lambda result: self._matches_fields(result, {
                    "ok": True,
                    "requested_strategy": "ax",
                    "strategy": "ax_set_value",
                    "text_length": len("No-contact delivery"),
                }))
        time.sleep(0.25)
        if typed is not None:
            self._verify_fixture_value(
                "type_text", COMPONENT_INPUT_TITLE, "AXTextField", "No-contact delivery")

        clicked = self._call_recording_failure(
            "click", {
                "pid": pid, "role": "AXButton", "title": COMPONENT_CLICK_BUTTON,
            },
            postcondition=lambda result: self._matches_fields(result, {
                "ok": True,
                "pid": pid,
                "role": "AXButton",
                "title": COMPONENT_CLICK_BUTTON,
            }))
        if clicked is not None:
            self._verify_fixture_value(
                "click", COMPONENT_STATUS_TITLE, "AXStaticText", "Utensils added")

        menu_path = ["Test Actions", "Save for Later"]
        menu = self._call_recording_failure(
            "click_menu_path", {"pid": pid, "path": menu_path},
            postcondition=lambda result: self._matches_fields(result, {
                "ok": True,
                "pid": pid,
                "requested_path": menu_path,
                "clicked_path": menu_path,
                "missing_segment": None,
            }))
        time.sleep(0.25)
        if menu is not None:
            self._verify_fixture_value(
                "click_menu_path",
                COMPONENT_STATUS_TITLE, "AXStaticText", "Saved for later")

        self._call_recording_failure(
            "ax_tree_augmented", {
                "pid": pid, "max_depth": 12, "max_nodes": 300,
            },
            postcondition=lambda result: (
                self._matches_fields(result, {"ok": True, "pid": pid})
                and self._structured_contains(result, COMPONENT_ACTION_BUTTON)),
            timeout=60)

        if input_id:
            self._invoke_tool("set_element_attribute", {
                "element_id": input_id,
                "name": "AXValue",
                "value": "Call on arrival",
            })
        snapshot_postcondition = lambda result: (
            self._matches_fields(result, {"pid": pid})
            and isinstance(self._extract_snapshot_id(result), str)
            and isinstance(self._structured_dict(result).get("nodeCount"), int)
            and self._structured_dict(result)["nodeCount"] > 0)
        first = self._call_recording_failure(
            "ax_snapshot_capture", {"pid": pid, "max_depth": 12},
            postcondition=snapshot_postcondition)
        if input_id:
            self._invoke_tool("set_element_attribute", {
                "element_id": input_id,
                "name": "AXValue",
                "value": "Text on arrival",
            })
        second = self._call_recording_failure(
            "ax_snapshot_capture", {"pid": pid, "max_depth": 12},
            postcondition=snapshot_postcondition)
        first_id = self._extract_snapshot_id(first) if first else None
        second_id = self._extract_snapshot_id(second) if second else None
        if first_id and second_id and first_id != second_id:
            expected_change = "Call on arrival → Text on arrival"
            self._call_recording_failure(
                "ax_snapshot_diff", {"from": first_id, "to": second_id},
                postcondition=lambda result: (
                    (value := self._structured_dict(result)) is not None
                    and value.get("ok") is True
                    and isinstance(value.get("diff"), dict)
                    and value["diff"].get("fromSnapshotID") == first_id
                    and value["diff"].get("toSnapshotID") == second_id
                    and any(
                        isinstance(change, dict)
                        and change.get("role") == "AXTextField"
                        and change.get("title") == COMPONENT_INPUT_TITLE
                        and isinstance(change.get("changes"), dict)
                        and change["changes"].get("value") == expected_change
                        for change in value["diff"].get("changed", []))))
        else:
            self._fail_semantic(
                "ax_snapshot_diff", "Two distinct fixture snapshot IDs were unavailable")

        value_signal = threading.Timer(0.5, lambda: os.kill(pid, signal.SIGUSR2))
        value_signal.start()
        try:
            notification = self._call_recording_failure(
                "wait_for_ax_notification", {
                    "pid": pid,
                    "notification": "AXValueChanged",
                    "timeout_seconds": 3,
                },
                postcondition=lambda result: (
                    self._matches_fields(result, {
                        "ok": True,
                        "status": "fired",
                        "notification": "AXValueChanged",
                    })
                    and isinstance(
                        self._structured_dict(result).get("elapsed_seconds"),
                        (int, float))
                    and 0 <= self._structured_dict(result)["elapsed_seconds"] < 3),
                timeout=5)
        finally:
            value_signal.cancel()
        if notification is not None:
            self._verify_fixture_value(
                "wait_for_ax_notification",
                COMPONENT_INPUT_TITLE, "AXTextField", "Leave at front desk")

        window_signal = threading.Timer(0.5, lambda: os.kill(pid, signal.SIGUSR1))
        window_signal.start()
        try:
            window_change = self._call_recording_failure(
                "wait_for_window_state_change", {
                    "pid": pid, "change": "created", "timeout_seconds": 3,
                },
                postcondition=lambda result: (
                    self._matches_fields(result, {
                        "ok": True,
                        "status": "fired",
                        "change": "created",
                        "notification": "AXWindowCreated",
                    })
                    and isinstance(
                        self._structured_dict(result).get("elapsed_seconds"),
                        (int, float))
                    and 0 <= self._structured_dict(result)["elapsed_seconds"] < 3),
                timeout=5)
        finally:
            window_signal.cancel()
        if window_change is not None:
            observed_windows = self._invoke_tool("list_windows", {"pid": pid})
            if (observed_windows.get("isError") is True
                    or not self._collection_contains(
                        observed_windows,
                        collection="windows",
                        pid=pid,
                        expected={
                            "pid": pid,
                            "title": "Trip Reminder",
                        })):
                self._fail_semantic(
                    "wait_for_window_state_change",
                    "The signaled fixture window was not observed")

    def _workflow_call(
        self,
        name: str,
        arguments: dict[str, Any],
        postcondition: Callable[[dict[str, Any]], bool],
        *,
        timeout: float = 30.0,
    ) -> dict[str, Any]:
        self._active_workflow_steps += 1
        result = self._invoke_tool(name, arguments, timeout=timeout)
        if result.get("isError") is True or not postcondition(result):
            raise MCPProtocolError(f"{name} did not satisfy the workflow postcondition")
        return result

    def _workflow_read(self, title: str) -> str:
        self._active_workflow_steps += 1
        return self._read_fixture_value(title, "AXStaticText")

    def _record_workflow(
        self,
        name: str,
        pass_detail: str,
        operation: Callable[[], None],
    ) -> None:
        self._active_workflow_steps = 0
        try:
            operation()
        except Exception as error:
            self.workflow_results[name] = WorkflowResult(
                name=name,
                status="FAIL",
                detail=str(error)[:180],
                mcp_steps=self._active_workflow_steps,
            )
            if self.verbose:
                print(f"FAIL workflow {name}: {error}", flush=True)
            return
        self.workflow_results[name] = WorkflowResult(
            name=name,
            status="PASS",
            detail=pass_detail,
            mcp_steps=self._active_workflow_steps,
        )
        if self.verbose:
            print(f"PASS workflow {name}", flush=True)

    def _set_workflow_fields(
        self,
        tree: dict[str, Any],
        values: dict[str, str],
    ) -> None:
        for title, value in values.items():
            element_id = self._tree_element_id(tree, title, "AXTextField")
            if element_id is None:
                raise MCPProtocolError(f"workflow field is unavailable: {title}")
            self._workflow_call(
                "set_element_attribute",
                {"element_id": element_id, "name": "AXValue", "value": value},
                postcondition=lambda result, element_id=element_id: self._matches_fields(
                    result,
                    {
                        "ok": True,
                        "element_id": element_id,
                        "name": "AXValue",
                        "ax_status": 0,
                    },
                ),
            )

    def _workflow_tree(self, required_titles: set[str]) -> dict[str, Any]:
        assert self.fixture_pid is not None
        tree = self._workflow_call(
            "get_ui_tree",
            {"pid": self.fixture_pid, "max_depth": 12},
            postcondition=lambda result: (
                self._matches_fields(result, {"ok": True, "pid": self.fixture_pid})
                and all(
                    self._tree_element_id(result, title, "AXTextField") is not None
                    for title in required_titles
                )
            ),
        )
        return tree

    def _run_everyday_workflows(self) -> None:
        self._record_workflow(
            "delivery_quote",
            "2 Margherita pizzas: $36.00 subtotal + $6.69 fees + $3.15 tax = $45.84",
            self._run_delivery_quote_workflow,
        )
        self._record_workflow(
            "day_trip_plan",
            "Civic Center to Ocean Beach via N Judah, arriving 9:52 AM in 37 min",
            self._run_day_trip_workflow,
        )

    def _run_delivery_quote_workflow(self) -> None:
        assert self.fixture_pid is not None
        tree = self._workflow_tree({
            "Delivery item", "Delivery quantity", "Delivery address",
        })
        self._set_workflow_fields(tree, {
            "Delivery item": "Margherita pizza",
            "Delivery quantity": "2",
            "Delivery address": "200 Market Street",
        })
        self._workflow_call(
            "click",
            {
                "pid": self.fixture_pid,
                "role": "AXButton",
                "title": "Get delivery quote",
            },
            postcondition=lambda result: self._matches_fields(result, {
                "ok": True,
                "pid": self.fixture_pid,
                "role": "AXButton",
                "title": "Get delivery quote",
            }),
        )
        expected = {
            "Quoted item": "2 × Margherita pizza",
            "Delivery subtotal": "$36.00",
            "Delivery fees": "$6.69",
            "Delivery tax": "$3.15",
            "Delivery total": "$45.84",
        }
        observed = {title: self._workflow_read(title) for title in expected}
        if observed != expected:
            raise MCPProtocolError(
                "delivery quote did not return the exact item/subtotal/fees/tax/total")

    def _run_day_trip_workflow(self) -> None:
        tree = self._workflow_tree({
            "Trip start", "Trip destination", "Trip departure",
        })
        self._set_workflow_fields(tree, {
            "Trip start": "Civic Center",
            "Trip destination": "Ocean Beach",
            "Trip departure": "9:15 AM",
        })
        button_id = self._tree_element_id(tree, "Plan day trip", "AXButton")
        if button_id is None:
            raise MCPProtocolError("day-trip workflow button is unavailable")
        self._workflow_call(
            "perform_element_action",
            {"element_id": button_id, "action": "AXPress"},
            postcondition=lambda result: self._matches_fields(result, {
                "ok": True,
                "element_id": button_id,
                "action": "AXPress",
                "strategy": "ax",
                "ax_status": 0,
            }),
        )
        expected = {
            "Trip route": "Civic Center → Ocean Beach",
            "Trip itinerary": "N Judah • 32 min, then walk 5 min",
            "Trip arrival": "9:52 AM",
            "Trip duration": "37 min",
        }
        observed = {title: self._workflow_read(title) for title in expected}
        if observed != expected:
            raise MCPProtocolError(
                "day-trip workflow did not return the exact route/arrival/duration")

    def _run_private_read_cases(self) -> None:
        # Results are deliberately discarded and never written to the report.
        self._call_recording_failure(
            "contacts_search", {
                "query": "__REMOTE_DESKTOP_ACCEPTANCE_6B73DC9E__", "limit": 1,
            },
            postcondition=lambda result: self._private_list_shape(
                result,
                list_key="contacts",
                item_shape={"name": str, "phones": list, "emails": list},
                maximum_count=0))
        self._call_recording_failure(
            "reminders_list", {"include_completed": False, "limit": 1},
            postcondition=lambda result: self._private_list_shape(
                result,
                list_key="reminders",
                item_shape={"title": str, "completed": bool, "list": str},
                maximum_count=1))
        self._call_recording_failure(
            "list_shortcuts", {},
            postcondition=lambda result: (
                (value := self._structured_dict(result)) is not None
                and value.get("ok") is True
                and isinstance(value.get("names"), list)
                and all(isinstance(name, str) for name in value["names"])
                and isinstance(value.get("count"), int)
                and value["count"] == len(value["names"])))

    def _verify_mail_live_evidence(self) -> None:
        ledger = pathlib.Path.home() / (
            "Library/Application Support/Remote Desktop Host/Computer Use Model/MCP/"
            "mutation-ledger.json")
        expected = {
            "Email draft opened visibly in Mail for review.",
            "Mail accepted the approved email for sending.",
        }
        try:
            snapshot = json.loads(ledger.read_text())
            observed = {
                entry.get("result", {}).get("text")
                for entry in snapshot.get("entries", {}).values()
                if entry.get("serverID") == "com.threadmark.remotedesktop.host.mail-mcp"
                and entry.get("toolName") == "remote_desktop_mail"
                and entry.get("status") == "completed"
                and entry.get("result", {}).get("isError") is False
            }
        except (OSError, ValueError, TypeError):
            observed = set()
        if expected.issubset(observed):
            self.semantic_evidence.add("remote_desktop_mail")
            self.results["remote_desktop_mail"] = ToolResult(
                "remote_desktop_mail", "PASS",
                TOOL_POSTCONDITIONS["remote_desktop_mail"])
        else:
            self.results["remote_desktop_mail"] = ToolResult(
                "remote_desktop_mail", "FAIL",
                "live signed-host draft and .invalid send evidence is incomplete")

    def close(self) -> None:
        failure: Exception | None = None
        if self.client is not None:
            self.client.close()
            self.client = None
        if self.fixture_process is not None and self.fixture_process.poll() is None:
            self.fixture_process.terminate()
            try:
                self.fixture_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.fixture_process.kill()
                self.fixture_process.wait(timeout=2)
        self.fixture_process = None
        self.fixture_pid = None
        try:
            self._restore_frontmost_application()
        except Exception as error:
            failure = failure or error
        finally:
            shutil.rmtree(self.temporary, ignore_errors=True)
        if failure is not None:
            raise failure


def default_binary() -> pathlib.Path:
    return pathlib.Path.home() / (
        "Library/Application Support/Remote Desktop Host/Computer Use Model/MCP/"
        "mac-control-mcp/Versions/0.8.2/MacControlMCP.app/Contents/MacOS/MacControlMCP")


def _status_counts(rows: list[ToolResult] | list[WorkflowResult]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for row in rows:
        counts[row.status] = counts.get(row.status, 0) + 1
    return counts


def build_report(
    runner: AcceptanceRunner,
    rows: list[ToolResult],
) -> dict[str, Any]:
    workflows = [
        runner.workflow_results[name] for name in sorted(runner.workflow_results)
    ]
    return {
        "component_tool_coverage": {
            "counts": _status_counts(rows),
            "inventory": {
                "pinned_sidecar_advertised": runner.advertised_tool_count,
                "pinned_sidecar_tools_list": {
                    "count": len(runner.advertised_tools),
                    "tools": runner.advertised_tools,
                },
                "pinned_sidecar_advertised_tool_names": (
                    runner.advertised_tool_names
                ),
                "sidecar_exposed": len(SIDECAR_EXPOSED_TOOLS),
                "sidecar_policy_blocked": (
                    runner.advertised_tool_count - len(SIDECAR_EXPOSED_TOOLS)
                ),
                "sidecar_policy_blocked_tool_names": (
                    runner.policy_blocked_advertised_tool_names
                ),
                "embedded_exposed": 1,
                "host_exposed_operations": len(HOST_EXPOSED_TOOLS),
            },
            "tools": [row.__dict__ for row in rows],
            "runtime": (
                "real pinned stdio JSON-RPC tools/call; accessory AppKit windows "
                "stay outside every display; Safari tab tools are policy-blocked "
                "after the live gate proved ambient-front-window targeting; a 20 ms "
                "native CGWindowList watchdog rejects every new visible window or prompt "
                "except the exact bounded macOS screen-capture privacy indicator "
                "during ax_tree_augmented, which must fade before the next call"
            ),
            "native_visible_feedback": [
                {
                    "tool": tool,
                    "surfaceCount": len(evidence),
                    "surfaces": [
                        evidence[window_id] for window_id in sorted(evidence)
                    ],
                }
                for tool, evidence in sorted(runner.native_visible_feedback.items())
            ],
            "blocked_browser_defect": {
                name: ACCEPTANCE_BLOCKED_TOOL_REASONS[name]
                for name in (
                    "browser_close_tab", "browser_get_active_tab",
                    "browser_list_tabs", "browser_navigate", "browser_new_tab",
                )
            },
        },
        "everyday_workflows": {
            "counts": _status_counts(workflows),
            "results": [workflow.__dict__ for workflow in workflows],
        },
    }


def acceptance_exit_code(runner: AcceptanceRunner) -> int:
    components_passed = all(
        runner.results.get(name) is not None
        and runner.results[name].status == "PASS"
        for name in HOST_EXPOSED_TOOLS
    )
    workflows_passed = REQUIRED_WORKFLOWS.issubset(runner.workflow_results) and all(
        runner.workflow_results[name].status == "PASS"
        for name in REQUIRED_WORKFLOWS
    ) and all(
        workflow.status == "PASS"
        for workflow in runner.workflow_results.values()
    )
    return 0 if components_passed and workflows_passed else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run the pinned MCP tools/call matrix with isolated offscreen fixtures "
            "and a CoreGraphics visibility audit."
        )
    )
    parser.add_argument("--binary", type=pathlib.Path, default=default_binary())
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument(
        "--allow-visible-ui",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args(argv)
    if args.allow_visible_ui:
        parser.error(
            "visible MCP acceptance UI is not supported; this gate is always hidden")
    if not args.binary.is_file():
        parser.error(f"pinned helper is missing: {args.binary}")

    runner = AcceptanceRunner(
        args.binary,
        args.verbose,
    )
    try:
        rows = runner.run()
    finally:
        runner.close()

    report = build_report(runner, rows)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print("component tool coverage")
        for row in rows:
            print(f"{row.status:22} {row.risk:18} {row.name:34} {row.detail}")
        component_counts = report["component_tool_coverage"]["counts"]
        print(
            "component summary "
            + " ".join(
                f"{key}={value}" for key, value in sorted(component_counts.items())
            )
            + f" advertised={runner.advertised_tool_count}"
            + f" exposed={len(HOST_EXPOSED_TOOLS)}"
            + f" policy_blocked={runner.advertised_tool_count - len(SIDECAR_EXPOSED_TOOLS)}"
        )
        print("everyday workflows")
        workflows = [
            runner.workflow_results[name] for name in sorted(runner.workflow_results)
        ]
        for workflow in workflows:
            print(
                f"{workflow.status:22} {'workflow':18} {workflow.name:34} "
                f"steps={workflow.mcp_steps} {workflow.detail}")
        workflow_counts = report["everyday_workflows"]["counts"]
        print(
            "workflow summary "
            + " ".join(
                f"{key}={value}" for key, value in sorted(workflow_counts.items())
            )
        )

    return acceptance_exit_code(runner)


if __name__ == "__main__":
    sys.exit(main())
