#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import inspect
import io
import pathlib
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "run_mcp_acceptance.py"
spec = importlib.util.spec_from_file_location("run_mcp_acceptance", SCRIPT_PATH)
assert spec is not None and spec.loader is not None
acceptance = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = acceptance
spec.loader.exec_module(acceptance)


class MCPAcceptanceRunnerTests(unittest.TestCase):
    def test_hash_mismatch_cannot_launch_the_mcp_process(self) -> None:
        with mock.patch.object(acceptance, "MCPClient") as client:
            with self.assertRaisesRegex(
                acceptance.MCPProtocolError, "hash does not match"):
                acceptance.AcceptanceRunner(pathlib.Path(__file__))
        client.assert_not_called()

    def test_valid_constructor_does_not_launch_mcp_before_visibility_guard(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binary = root / "MacControlMCP"
            binary.write_bytes(b"pinned-test-helper")
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()

            with (
                mock.patch.object(acceptance, "PINNED_HELPER_SHA256", digest),
                mock.patch.object(
                    acceptance.AcceptanceRunner, "_frontmost_pid", return_value=42),
                mock.patch.object(acceptance, "MCPClient") as client,
            ):
                runner = acceptance.AcceptanceRunner(binary)

            self.addCleanup(shutil.rmtree, runner.temporary, True)
            client.assert_not_called()

    def test_visibility_guard_precedes_mcp_transport_and_handshake(self) -> None:
        events: list[str] = []

        class RecordingClient:
            def __init__(self, binary: pathlib.Path, state_dir: pathlib.Path) -> None:
                del binary, state_dir
                events.append("mcp_launch")

            def initialize(self) -> dict[str, object]:
                events.append("initialize")
                return {
                    "serverInfo": {"name": "mac-control-mcp", "version": "0.8.2"},
                    "protocolVersion": "2024-11-05",
                }

            def list_tools(self) -> list[dict[str, object]]:
                events.append("list_tools")
                schema = {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": False,
                }
                tools = [
                    {"name": name, "inputSchema": schema}
                    for name in sorted(acceptance.SIDECAR_EXPOSED_TOOLS)
                ]
                tools.extend(
                    {"name": f"unexposed_test_tool_{index}", "inputSchema": schema}
                    for index in range(
                        acceptance.PINNED_ADVERTISED_TOOL_COUNT - len(tools))
                )
                return tools

            def abort(self, reason: str) -> None:
                del reason

            def close(self) -> None:
                pass

        class FixtureProcess:
            pid = 99123

            @staticmethod
            def poll() -> None:
                return None

            @staticmethod
            def terminate() -> None:
                pass

            @staticmethod
            def wait(timeout: float | None = None) -> int:
                del timeout
                return 0

            @staticmethod
            def kill() -> None:
                pass

        def run_without_compiling(arguments: list[str], **kwargs: object) -> object:
            del kwargs
            if str(acceptance.WINDOW_AUDIT_SOURCE) in arguments:
                events.append("audit_compile")
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        def snapshot_baseline(_runner: object) -> set[int]:
            events.append("baseline_snapshot")
            return {11, 12}

        def start_watchdog(
            _runner: object, **kwargs: object
        ) -> tuple[object, object, list[BaseException]]:
            del kwargs
            events.append("watchdog_start")
            return object(), object(), []

        def stop_watchdog(
            watchdog: tuple[object, object, list[BaseException]],
        ) -> list[BaseException]:
            events.append("watchdog_stop")
            return watchdog[2]

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binary = root / "MacControlMCP"
            binary.write_bytes(b"pinned-test-helper")
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()

            with (
                mock.patch.object(acceptance, "PINNED_HELPER_SHA256", digest),
                mock.patch.object(acceptance, "MCPClient", RecordingClient),
                mock.patch.object(
                    acceptance.AcceptanceRunner, "_frontmost_pid", return_value=42),
                mock.patch.object(acceptance.subprocess, "run", side_effect=run_without_compiling),
                mock.patch.object(
                    acceptance.subprocess, "Popen", return_value=FixtureProcess()),
                mock.patch.object(acceptance.time, "sleep"),
                mock.patch.object(
                    acceptance.AcceptanceRunner,
                    "_snapshot_visible_window_ids",
                    snapshot_baseline,
                ),
                mock.patch.object(
                    acceptance.AcceptanceRunner,
                    "_start_visibility_watchdog",
                    start_watchdog,
                ),
                mock.patch.object(
                    acceptance.AcceptanceRunner,
                    "_stop_visibility_watchdog",
                    side_effect=stop_watchdog,
                ),
                mock.patch.object(
                    acceptance.AcceptanceRunner,
                    "_restore_frontmost_application",
                ),
                mock.patch.object(
                    acceptance.AcceptanceRunner,
                    "_assert_test_windows_hidden",
                    return_value={},
                ),
                mock.patch.object(acceptance.AcceptanceRunner, "_run_fixture_cases"),
                mock.patch.object(acceptance.AcceptanceRunner, "_run_everyday_workflows"),
                mock.patch.object(acceptance.AcceptanceRunner, "_run_private_read_cases"),
                mock.patch.object(acceptance.AcceptanceRunner, "_verify_mail_live_evidence"),
            ):
                runner = acceptance.AcceptanceRunner(binary)
                self.addCleanup(shutil.rmtree, runner.temporary, True)
                runner.run()

        expected = [
            "audit_compile",
            "baseline_snapshot",
            "watchdog_start",
            "mcp_launch",
            "initialize",
            "list_tools",
            "watchdog_stop",
        ]
        for event in expected:
            self.assertIn(event, events)
        self.assertEqual(
            [event for event in events if event in expected],
            expected,
            msg=f"unsafe MCP lifecycle ordering: {events}",
        )
        self.assertEqual(len(runner.advertised_tools), 143)
        self.assertEqual(
            runner.advertised_tool_names,
            sorted(runner.advertised_tool_names),
        )
        self.assertEqual(
            runner.policy_blocked_advertised_tool_names,
            sorted(
                set(runner.advertised_tool_names)
                - acceptance.SIDECAR_EXPOSED_TOOLS
            ),
        )
        self.assertEqual(len(runner.policy_blocked_advertised_tool_names), 114)

    def test_bootstrap_watchdog_preserves_pre_client_visibility_failure(self) -> None:
        runner = acceptance.AcceptanceRunner.__new__(acceptance.AcceptanceRunner)
        runner.client = None
        expected = acceptance.UserVisibleArtifactError("bootstrap surface")
        runner._assert_test_windows_hidden = mock.Mock(side_effect=expected)

        watchdog = runner._start_visibility_watchdog(trigger_tool="MCP bootstrap")
        failures = runner._stop_visibility_watchdog(watchdog)

        self.assertEqual(failures, [expected])
        self.assertIsNone(runner.client)

    def test_mcp_client_call_issues_a_real_tools_call_request(self) -> None:
        client = acceptance.MCPClient.__new__(acceptance.MCPClient)
        client.request = mock.Mock(return_value={"isError": False})

        result = client.call("focused_app", {"include_icon": False}, timeout=9)

        self.assertEqual(result, {"isError": False})
        client.request.assert_called_once_with(
            "tools/call",
            {"name": "focused_app", "arguments": {"include_icon": False}},
            timeout=9,
        )

    def test_every_exposed_operation_has_semantic_runtime_evidence(self) -> None:
        self.assertEqual(set(acceptance.TOOL_POSTCONDITIONS), acceptance.HOST_EXPOSED_TOOLS)
        self.assertEqual(len(acceptance.SIDECAR_EXPOSED_TOOLS), 29)
        self.assertEqual(len(acceptance.HOST_EXPOSED_TOOLS), 30)
        self.assertEqual(
            acceptance.SIDECAR_EXPOSED_TOOLS,
            acceptance.HOST_EXPOSED_TOOLS - {"remote_desktop_mail"},
        )

    def test_fixture_is_accessory_offscreen_and_has_no_planner_artifact(self) -> None:
        fixture = acceptance.FIXTURE_SOURCE.read_text()
        runner = SCRIPT_PATH.read_text()

        self.assertIn("application.setActivationPolicy(.accessory)", fixture)
        self.assertIn("private final class OffscreenWindow", fixture)
        self.assertIn("displays.allSatisfy { !$0.intersects(frame) }", fixture)
        self.assertIn('"LSUIElement": True', runner)
        self.assertNotIn("Everyday Planner", fixture + runner)
        self.assertNotIn('"Planner"', fixture + runner)

    def test_native_audit_keeps_prompt_detection_strict(self) -> None:
        source = acceptance.WINDOW_AUDIT_SOURCE.read_text()

        self.assertIn("CGGetActiveDisplayList", source)
        self.assertIn("optionOnScreenOnly", source)
        self.assertIn("--baseline-window-id", source)
        self.assertIn("|| !baselineWindowIDs.isEmpty", source)
        self.assertIn("unexpectedVisibleWindowIDs", source)
        self.assertNotIn("--allow-minimized-window-id", source)
        self.assertIn("activeDisplays: [DisplayGeometry]", source)
        self.assertIn("visibleWindowGeometry: [WindowGeometry]", source)

    def test_ambient_safari_tools_are_blocked_with_no_automation_code(self) -> None:
        browser_tools = {
            "browser_new_tab",
            "browser_get_active_tab",
            "browser_list_tabs",
            "browser_navigate",
            "browser_close_tab",
        }
        self.assertTrue(browser_tools.isdisjoint(acceptance.HOST_EXPOSED_TOOLS))
        self.assertTrue(browser_tools.isdisjoint(acceptance.TOOL_POSTCONDITIONS))
        self.assertTrue(browser_tools.issubset(
            acceptance.ACCEPTANCE_BLOCKED_TOOL_REASONS))
        for tool in browser_tools:
            self.assertTrue(acceptance.ACCEPTANCE_BLOCKED_TOOL_REASONS[tool])
        source = SCRIPT_PATH.read_text()
        for forbidden in (
            'tell application "Safari"',
            "/usr/bin/osascript",
            "_run_osascript",
            "_safari_snapshot",
            "_start_isolated_safari_window",
            "_stop_isolated_safari_window",
            "_run_browser_cases",
            "_start_http_fixture",
            "--allow-minimized-window-id",
        ):
            self.assertNotIn(forbidden, source)
        run_source = inspect.getsource(acceptance.AcceptanceRunner.run)
        invoke_source = inspect.getsource(acceptance.AcceptanceRunner._invoke_tool)
        for tool in browser_tools:
            self.assertNotIn(tool, run_source)
            self.assertNotIn(tool, invoke_source)

    def test_capture_indicator_allowance_is_exact_and_menu_bar_bounded(self) -> None:
        valid = {
            "id": 7,
            "ownerPID": 468,
            "ownerName": "Window Server",
            "windowName": "StatusIndicator",
            "layer": 2_147_483_630,
            "x": 1540,
            "y": 2,
            "width": 28,
            "height": 29,
            "topMenuBarContained": True,
        }
        self.assertTrue(acceptance.AcceptanceRunner._is_expected_capture_status_indicator(valid))
        for key, invalid in (
            ("ownerName", "Safari"),
            ("windowName", "Permission Prompt"),
            ("layer", 0),
            ("width", 33),
            ("height", 33),
            ("width", 0),
            ("topMenuBarContained", False),
        ):
            evidence = {**valid, key: invalid}
            self.assertFalse(
                acceptance.AcceptanceRunner._is_expected_capture_status_indicator(evidence),
                msg=f"unexpectedly allowed {key}={invalid!r}",
            )
        audit_source = acceptance.WINDOW_AUDIT_SOURCE.read_text()
        self.assertIn("isContainedInActiveDisplayMenuBar(frame)", audit_source)
        self.assertIn("eligibleCaptureStatusIndicators.prefix(2)", audit_source)
        invoke_source = inspect.getsource(acceptance.AcceptanceRunner._invoke_tool)
        self.assertIn('name == "ax_tree_augmented"', invoke_source)
        self.assertIn("_wait_for_capture_status_indicator_fade", invoke_source)

    def test_more_than_two_capture_indicators_is_fatal(self) -> None:
        runner = acceptance.AcceptanceRunner.__new__(acceptance.AcceptanceRunner)
        runner.window_audit_binary = pathlib.Path("/tmp/audit")
        runner.fixture_pid = None
        runner.visibility_baseline = set()
        runner.native_visible_feedback = {}
        evidence = {
            "id": 7,
            "ownerPID": 468,
            "ownerName": "Window Server",
            "windowName": "StatusIndicator",
            "layer": 2_147_483_630,
            "x": 1540,
            "y": 2,
            "width": 28,
            "height": 29,
            "topMenuBarContained": True,
        }
        report = {
            "matchedWindowCount": 0,
            "onDisplayWindowCount": 0,
            "onScreenListWindowCount": 0,
            "unexpectedVisibleWindowCount": 0,
            "allowedCaptureStatusIndicators": [
                {**evidence, "id": item} for item in (7, 8, 9)
            ],
        }
        completed = types.SimpleNamespace(
            returncode=0, stdout=__import__("json").dumps(report))
        with mock.patch.object(acceptance.subprocess, "run", return_value=completed):
            with self.assertRaises(acceptance.UserVisibleArtifactError):
                runner._assert_test_windows_hidden(
                    allow_capture_status_indicator=True,
                    trigger_tool="ax_tree_augmented",
                )

    def test_report_describes_real_hidden_runtime_and_workflows(self) -> None:
        advertised_tools = [
            {
                "name": "alpha",
                "description": "First tool",
                "inputSchema": {
                    "type": "object",
                    "properties": {"value": {"type": "string"}},
                },
            },
            {
                "name": "zeta",
                "description": "Last tool",
                "inputSchema": {"type": "object", "properties": {}},
            },
        ]
        runner = types.SimpleNamespace(
            advertised_tool_count=143,
            advertised_tools=advertised_tools,
            advertised_tool_names=["alpha", "zeta"],
            policy_blocked_advertised_tool_names=["zeta"],
            native_visible_feedback={},
            workflow_results={
                "delivery_quote": acceptance.WorkflowResult(
                    "delivery_quote", "PASS", "verified", 9),
                "day_trip_plan": acceptance.WorkflowResult(
                    "day_trip_plan", "PASS", "verified", 9),
            },
        )
        rows = [acceptance.ToolResult("focused_app", "PASS", "verified")]

        report = acceptance.build_report(runner, rows)

        self.assertEqual(set(report), {"component_tool_coverage", "everyday_workflows"})
        runtime = report["component_tool_coverage"]["runtime"]
        self.assertIn("real pinned stdio JSON-RPC tools/call", runtime)
        self.assertIn("Safari tab tools are policy-blocked", runtime)
        inventory = report["component_tool_coverage"]["inventory"]
        self.assertEqual(
            inventory["pinned_sidecar_tools_list"],
            {"count": 2, "tools": advertised_tools},
        )
        self.assertEqual(
            inventory["pinned_sidecar_advertised_tool_names"],
            ["alpha", "zeta"],
        )
        self.assertEqual(
            inventory["sidecar_policy_blocked_tool_names"],
            ["zeta"],
        )
        self.assertEqual(
            set(report["component_tool_coverage"]["blocked_browser_defect"]),
            {
                "browser_close_tab", "browser_get_active_tab",
                "browser_list_tabs", "browser_navigate", "browser_new_tab",
            })
        self.assertEqual(report["everyday_workflows"]["counts"], {"PASS": 2})

    def test_deprecated_visible_fixture_flag_is_rejected(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(acceptance, "AcceptanceRunner") as runner:
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as raised:
                    acceptance.main(["--allow-visible-ui"])
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("always hidden", stderr.getvalue())
        runner.assert_not_called()

    def test_help_describes_offscreen_tools_call_gate(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            with self.assertRaises(SystemExit) as raised:
                acceptance.main(["--help"])
        self.assertEqual(raised.exception.code, 0)
        self.assertNotIn("allow-visible-ui", stdout.getvalue())
        self.assertIn("tools/call matrix", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
