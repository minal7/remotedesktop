import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "host-mac/scripts/run_local_browser_live_acceptance.sh"
WORKBENCH = ROOT / "host-mac/AcceptanceFixtures/LocalBrowserWorkbench.html"
LIVE_TEST_SUPPORT = (
    ROOT / "ios/RemoteDesktopLiveE2ETests/ComputerUseLiveE2ECleanup.swift"
)
B01_LIVE_TEST = (
    ROOT
    / "ios/RemoteDesktopLiveE2ETests/OSAtlasLocalFixtureSimulatorLiveE2ETests.swift"
)
OUTCOME_LIVE_TEST = (
    ROOT
    / "ios/RemoteDesktopLiveE2ETests/OSAtlasLocalBrowserOutcomeSimulatorLiveE2ETests.swift"
)
LOCAL_LIVE_TESTS = (
    B01_LIVE_TEST,
    ROOT
    / "ios/RemoteDesktopLiveE2ETests/OSAtlasLocalBrowserSearchSpinnerSimulatorLiveE2ETests.swift",
    OUTCOME_LIVE_TEST,
    ROOT
    / "ios/RemoteDesktopLiveE2ETests/OSAtlasLocalBrowserSafetySimulatorLiveE2ETests.swift",
)


class LocalBrowserLiveAcceptanceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runner = RUNNER.read_text(encoding="utf-8")
        cls.workbench = WORKBENCH.read_text(encoding="utf-8")
        cls.b01_live_test = B01_LIVE_TEST.read_text(encoding="utf-8")
        cls.outcome_live_test = OUTCOME_LIVE_TEST.read_text(encoding="utf-8")

    def test_runner_has_valid_shell_syntax(self) -> None:
        completed = subprocess.run(
            ["/bin/bash", "-n", str(RUNNER)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_release_is_default_and_both_matched_configurations_are_routed(self) -> None:
        for contract in (
            'SHARED_CONFIGURATION="${REMOTE_DESKTOP_APPLE_CONFIGURATION:-Release}"',
            'HOST_CONFIGURATION="${REMOTE_DESKTOP_HOST_CONFIGURATION:-$SHARED_CONFIGURATION}"',
            'IOS_CONFIGURATION="${REMOTE_DESKTOP_IOS_CONFIGURATION:-$SHARED_CONFIGURATION}"',
            'EXPECTED_CLOUDKIT_ENVIRONMENT="Development"',
            'EXPECTED_CLOUDKIT_ENVIRONMENT="Production"',
            'Build/Products/$CONFIGURATION/RemoteDesktopHost.app',
            'Build/Products/${CONFIGURATION}-iphonesimulator/RemoteDesktop.app',
            'HostDerivedData-$CONFIGURATION',
            'IOSDerivedData-$CONFIGURATION',
            'local-browser-live.$CONFIGURATION.XXXXXX',
        ):
            self.assertIn(contract, self.runner)

        self.assertEqual(
            self.runner.count(
                'REMOTE_DESKTOP_APPLE_CONFIGURATION="$CONFIGURATION"'
            ),
            3,
        )
        self.assertEqual(
            self.runner.count(
                'REMOTE_DESKTOP_HOST_CONFIGURATION="$CONFIGURATION"'
            ),
            3,
        )
        self.assertEqual(
            self.runner.count(
                'REMOTE_DESKTOP_IOS_CONFIGURATION="$CONFIGURATION"'
            ),
            3,
        )
        self.assertEqual(
            self.runner.count('-configuration "$CONFIGURATION"'),
            4,
        )
        for hard_coded_release_build in (
            "REMOTE_DESKTOP_APPLE_CONFIGURATION=Release",
            "REMOTE_DESKTOP_HOST_CONFIGURATION=Release",
            "REMOTE_DESKTOP_IOS_CONFIGURATION=Release",
            "-configuration Release",
            "Build/Products/Release/RemoteDesktopHost.app",
        ):
            self.assertNotIn(hard_coded_release_build, self.runner)

    def test_mixed_configuration_is_rejected_before_any_build(self) -> None:
        environment = dict(os.environ)
        environment.update({
            "REMOTE_DESKTOP_APPLE_CONFIGURATION": "Debug",
            "REMOTE_DESKTOP_HOST_CONFIGURATION": "Debug",
            "REMOTE_DESKTOP_IOS_CONFIGURATION": "Release",
        })
        completed = subprocess.run(
            [str(RUNNER), "--only", "B01"],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("Refusing mixed Apple configurations", completed.stderr)
        self.assertNotIn("xcodebuild", completed.stdout + completed.stderr)

    def test_unknown_shared_configuration_is_rejected_before_any_build(
        self,
    ) -> None:
        environment = dict(os.environ)
        environment.update({
            "REMOTE_DESKTOP_APPLE_CONFIGURATION": "Profile",
            "REMOTE_DESKTOP_HOST_CONFIGURATION": "Profile",
            "REMOTE_DESKTOP_IOS_CONFIGURATION": "Profile",
        })
        completed = subprocess.run(
            [str(RUNNER), "--only", "B01"],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn(
            "REMOTE_DESKTOP_APPLE_CONFIGURATION must be Debug or Release",
            completed.stderr,
        )
        self.assertNotIn("xcodebuild", completed.stdout + completed.stderr)

    def test_release_requires_notarized_current_source_host_artifact(self) -> None:
        environment = dict(os.environ)
        environment.update({
            "REMOTE_DESKTOP_APPLE_CONFIGURATION": "Release",
            "REMOTE_DESKTOP_HOST_CONFIGURATION": "Release",
            "REMOTE_DESKTOP_IOS_CONFIGURATION": "Release",
        })
        completed = subprocess.run(
            [str(RUNNER), "--only", "B01"],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn(
            "Release live acceptance requires --host-artifact",
            completed.stderr,
        )
        self.assertNotIn("xcodebuild", completed.stdout + completed.stderr)

        selector = self.runner.split(
            "verify_release_artifact_selection() {", maxsplit=1
        )[1].split("\n}", maxsplit=1)[0]
        for contract in (
            '[[ "$HOST_ARTIFACT" != /* ]]',
            '[[ "$HOST_ARTIFACT" == "$HOST_APP" ]]',
            "^[0-9a-f]{40}$",
            "rev-parse --verify HEAD^{commit}",
            "--porcelain=v1 --untracked-files=normal",
        ):
            self.assertIn(contract, selector)

        installer = self.runner.split(
            "install_current_host() {", maxsplit=1
        )[1].split("\n}", maxsplit=1)[0]
        self.assertIn('[[ "$CONFIGURATION" == "Release" ]]', installer)
        self.assertIn('BUILT_HOST_APP="$HOST_ARTIFACT"', installer)
        self.assertIn(
            'BUILT_HOST_APP="$host_derived_data/Build/Products/'
            '$CONFIGURATION/RemoteDesktopHost.app"',
            installer,
        )
        self.assertLess(
            installer.index('BUILT_HOST_APP="$HOST_ARTIFACT"'),
            installer.index("/usr/bin/xcodebuild -quiet build "),
        )

    def test_host_artifact_is_reverified_and_hash_pinned_after_install(self) -> None:
        verifier = self.runner.split(
            "verify_selected_host_bundle() {", maxsplit=1
        )[1].split("\n}", maxsplit=1)[0]
        self.assertIn('--configuration "$CONFIGURATION"', verifier)
        self.assertIn(
            '--expected-source-commit "$EXPECTED_SOURCE_COMMIT"',
            verifier,
        )

        installer = self.runner.split(
            "install_current_host() {", maxsplit=1
        )[1].split("\n}", maxsplit=1)[0]
        self.assertEqual(installer.count("verify_selected_host_bundle"), 2)
        self.assertIn(
            'BUILT_HOST_EXECUTABLE_SHA256="$(/usr/bin/shasum -a 256',
            installer,
        )
        self.assertIn(
            'installed_executable_sha256" != '
            '"$BUILT_HOST_EXECUTABLE_SHA256"',
            installer,
        )

    def test_both_products_verify_selected_cloudkit_contract(self) -> None:
        for contract in (
            "verify_selected_host_bundle()",
            "verify_selected_ios_product()",
            "RemoteDesktop.app-Simulated.xcent",
            '"V9AX39SPJD.com.threadmark.remotedesktop.client"',
            '"iCloud.com.threadmark.remotedesktop"',
            "com.apple.developer.icloud-services:0",
            'cloudkit_environment" != "$EXPECTED_CLOUDKIT_ENVIRONMENT',
        ):
            self.assertIn(contract, self.runner)

        payload_gate = self.runner.split(
            "reject_release_debug_payloads() {", maxsplit=1
        )[1].split("\n}", maxsplit=1)[0]
        self.assertIn('[[ "$CONFIGURATION" != "Release" ]]', payload_gate)
        self.assertIn("return 0", payload_gate)
        self.assertIn("*.debug.dylib", payload_gate)
        self.assertIn("*XCTest*", payload_gate)

        ios_verifier = self.runner.split(
            "verify_selected_ios_product() {", maxsplit=1
        )[1].split("\n}", maxsplit=1)[0]
        self.assertIn('[[ -L "$entitlement_file" || ! -f', ios_verifier)
        self.assertIn("verify_cloudkit_entitlement_file", ios_verifier)
        self.assertIn("reject_release_debug_payloads", ios_verifier)
        self.assertIn('[[ "$CONFIGURATION" == "Release"', ios_verifier)
        self.assertIn("get-task-allow", ios_verifier)

    def test_builds_remain_serial_and_install_remains_transactional(self) -> None:
        host_build = self.runner.index("/usr/bin/xcodebuild -quiet build ")
        ios_build = self.runner.index(
            "/usr/bin/xcodebuild -quiet build-for-testing"
        )
        test_without_building = self.runner.index(
            "/usr/bin/xcodebuild -quiet test-without-building"
        )
        self.assertLess(host_build, ios_build)
        self.assertLess(ios_build, test_without_building)
        self.assertEqual(self.runner.count("build-for-testing"), 1)
        self.assertIn("-parallel-testing-enabled NO", self.runner)

        install = self.runner.split(
            "install_current_host() {", maxsplit=1
        )[1].split("\n}", maxsplit=1)[0]
        self.assertLess(
            install.index("verify_selected_host_bundle"),
            install.index("HOST_SWAP_STARTED=1"),
        )
        self.assertLess(
            install.index('HOST_SWAP_STARTED=1'),
            install.index('/bin/mv "$HOST_APP" "$PREVIOUS_HOST_APP"'),
        )
        finish = self.runner.split("finish() {", maxsplit=1)[1].split(
            "\n}", maxsplit=1
        )[0]
        self.assertIn(
            "HOST_SWAP_STARTED -eq 1 && $RUN_SUCCEEDED -ne 1",
            finish,
        )
        self.assertIn("restore_previous_host", finish)

    def test_all_local_cases_fail_fast_for_apple_account_verification(
        self,
    ) -> None:
        support = LIVE_TEST_SUPPORT.read_text(encoding="utf-8")
        helper = support.split(
            "enum ComputerUseLiveE2EPreflight {", maxsplit=1
        )[1].split("\n}\n\n/// Fixed-label", maxsplit=1)[0]
        message_match = re.search(
            r'appleAccountVerificationFailureMessage =\s*\n\s*"([^"]+)"',
            helper,
        )
        self.assertIsNotNone(message_match)
        message = message_match.group(1)
        self.assertTrue(message.startswith("USER INTERVENTION REQUIRED:"))
        self.assertIn("iPhone Air Simulator Settings", message)
        self.assertIn('bundleIdentifier: "com.apple.springboard"', helper)
        self.assertIn('let alertTitle = "Apple Account Verification"', helper)
        self.assertNotIn(".tap()", helper)

        direct_launch_count = 0
        direct_preflight_count = 0
        settled_launch_count = 0
        for path in LOCAL_LIVE_TESTS:
            source = path.read_text(encoding="utf-8")
            direct_launch_count += source.count("app.launch()")
            direct_preflight_count += source.count(
                "try ComputerUseLiveE2EPreflight."
                "requireNoAppleAccountVerification()"
            )
            settled_launch_count += source.count(
                "try ComputerUseLiveE2EPreflight\n"
                "            .launchAfterSimulatorRegistrationSettles(app)"
            )
            self.assertNotIn(
                "The Release iOS client did not automatically pair",
                source,
            )
            self.assertIsNone(
                re.search(
                    r"app\.launch\(\)(?!\s*try ComputerUseLiveE2EPreflight\."
                    r"requireNoAppleAccountVerification\(\))",
                    source,
                ),
                path.name,
            )

        settle_helper = support.split(
            "static func launchAfterSimulatorRegistrationSettles(", maxsplit=1
        )[1].split("\n    }\n\n    static func requireNoAppleAccountVerification", maxsplit=1)[0]
        self.assertEqual(settle_helper.count("app.launch()"), 2)
        self.assertEqual(
            settle_helper.count("try requireNoAppleAccountVerification()"),
            2,
        )
        self.assertIn("simulatorRegistrationSettleInterval", settle_helper)
        self.assertIn("app.terminate()", settle_helper)

        self.assertEqual(settled_launch_count, 4)
        self.assertEqual(direct_launch_count, 1)
        self.assertEqual(direct_preflight_count, direct_launch_count)
        self.assertEqual(
            settled_launch_count + direct_launch_count,
            5,
        )

    def test_failed_ui_case_skips_browser_postcondition_verification(
        self,
    ) -> None:
        wrapper = self.runner.split(
            "run_case_with_browser_postcondition() {", maxsplit=1
        )[1].split("\n}\n\nfor case_id", maxsplit=1)[0]
        failure_guard = wrapper.index("if [[ $run_status -ne 0 ]]; then")
        postcondition = wrapper.index("verify_browser_postcondition")
        self.assertLess(failure_guard, postcondition)
        between = wrapper[failure_guard:postcondition]
        self.assertIn("Safari postcondition was not evaluated", between)
        self.assertIn("return 1", between)

    def test_b03_and_b04_attach_standardized_typed_outcomes(self) -> None:
        sign_in = self.outcome_live_test.split(
            "func testLocalSignInPageRequiresUserInterventionWithoutCredentialInput",
            maxsplit=1,
        )[1].split(
            "func testLocalUnavailableReportReturnsTypedUnableToComplete",
            maxsplit=1,
        )[0]
        unavailable = self.outcome_live_test.split(
            "func testLocalUnavailableReportReturnsTypedUnableToComplete",
            maxsplit=1,
        )[1].split("private struct LocalConversation", maxsplit=1)[0]

        self.assertEqual(
            sign_in.count("OUTCOME: user intervention required"),
            1,
        )
        self.assertIn("CAPTURED BEFORE CLEANUP: true", sign_in)
        self.assertLess(
            sign_in.index("OUTCOME: user intervention required"),
            sign_in.index("let cleanupSucceeded"),
        )
        self.assertEqual(
            unavailable.count("OUTCOME: unable to complete"),
            1,
        )
        for block in (sign_in, unavailable):
            self.assertIn("let evidence = XCTAttachment(string:", block)
            self.assertIn("evidence.lifetime = .keepAlways", block)
            self.assertIn("add(evidence)", block)

    def test_workbench_javascript_has_valid_syntax(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is unavailable")
        scripts = re.findall(
            r"<script>(.*?)</script>", self.workbench, flags=re.DOTALL
        )
        self.assertTrue(scripts)
        completed = subprocess.run(
            [node, "--check", "-"],
            cwd=ROOT,
            input="\n".join(scripts),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_workbench_evidence_is_nonce_bound_and_reload_durable(self) -> None:
        for contract in (
            'searchParams.get("acceptance-run")',
            "const durableStorageKey = acceptanceRunNonce.length > 0",
            "window.localStorage.getItem(durableStorageKey)",
            "window.localStorage.setItem(",
            'runNonce.value = "DURABLE EVIDENCE UNAVAILABLE"',
            "if (acceptanceRunNonce.length === 0) counters = zeroCounters();",
            'aria-label="Acceptance run nonce"',
        ):
            self.assertIn(contract, self.workbench)

        # Every evidence-bearing mutation persists before the rendered value is
        # used by the Mac-side AX verifier.
        self.assertGreaterEqual(self.workbench.count("persistCounters();"), 4)
        self.assertNotIn(
            'counters = { clicks: 0, submits: 0, inputs: 0, orders: 0 };',
            self.workbench,
        )

    def test_all_workbench_cases_share_one_nonce_between_pre_and_post(self) -> None:
        self.assertIn("new_acceptance_nonce()", self.runner)
        self.assertIn("?acceptance-run=", self.runner)
        self.assertEqual(
            self.runner.count('nonce="$(new_acceptance_nonce "$case_id")"'),
            10,
        )
        for case_id in (
            "B02", "B03", "B04", "B05", "B06", "B07", "B08",
            "B09", "B10", "B11",
        ):
            case_block = self._case_block(case_id)
            self.assertIn('"$nonce"', case_block)
            self.assertGreaterEqual(case_block.count('"$nonce"'), 2)

    def test_file_fixture_opens_physically_before_safari_sets_nonce_url(self) -> None:
        self.assertIn(
            'physical_url="$(file_url "$fixture_path" "" "")"',
            self.runner,
        )
        self.assertIn('/usr/bin/open -a Safari "$physical_url"', self.runner)
        self.assertIn('if [[ "$target_url" != "$physical_url" ]]; then', self.runner)
        self.assertIn(
            'set URL of current tab of front window to item 1 of argv',
            self.runner,
        )
        self.assertIn(
            "Safari did not retain the exact nonce-bound fixture URL.",
            self.runner,
        )

    def test_b01_has_independent_ax_precondition_and_postcondition(self) -> None:
        case_block = self._case_block("B01")
        self.assertIn("delivery-before", case_block)
        self.assertIn("delivery-complete", case_block)
        self.assertIn("run_case_with_browser_postcondition", case_block)
        self.assertIn('"Pizzeria Uno"', case_block)

        for exact_state in (
            '"Start local quote setup"',
            '"Setup not started. Use the blue button first."',
            '"LOCAL-QUOTE-7421"',
            '"LOCAL-ONLY — NATIVE INPUT CONFIRMED"',
            '"Acceptance complete locally. No order, account, payment, or network action exists on this page."',
        ):
            self.assertIn(exact_state, self.runner)

    def test_b01_requires_prompt_channel_and_fresh_visual_sidecar(self) -> None:
        for contract in (
            'identifier: "computer-use-local-prompt-channel"',
            "promptChannel.value as? String",
            '"Ready"',
            '"Live interactive screen for "',
            "timeout: Self.visualSidecarLiveTimeout",
            "timeout: Self.freshCalculatorFrameTimeout",
            "fixtureProofRecognition(",
            "Safari, fixture, and stale-frame text are rejected",
        ):
            self.assertIn(contract, self.b01_live_test)

        self.assertNotIn("captureStreamProof", self.b01_live_test)
        self.assertNotIn(
            "if liveScreen.waitForExistence",
            self.b01_live_test,
        )

    def test_search_postcondition_bounds_every_fixture_counter(self) -> None:
        for exact_counter in (
            '"Click event count": "2"',
            '"Submit event count": "1"',
            '"Input event count": "21"',
        ):
            self.assertIn(exact_counter, self.runner)
        self.assertIn(
            'scalar($0, kAXValueAttribute as CFString) == "downtown branch hours"',
            self.runner,
        )

    def test_b07_requires_real_new_page_and_task_bound_grounding_attestation(
        self,
    ) -> None:
        case_block = self._case_block("B07")
        for contract in (
            '"#journey"',
            '"#journey-details"',
            "verify_safari_page_delta",
            "verify_browser_action_attestation",
            '"$LAST_VERIFIED_TASK_ID" 2',
        ):
            self.assertIn(contract, case_block)
        for contract in (
            '== "apple-foundation-models"',
            ".rawNormalizedPoint",
            ".preHostGroundingNormalizedPoint",
            ".hostGroundingApplied == true",
            ".effectPosted == true",
        ):
            self.assertIn(contract, self.runner)
        for contract in (
            'id="open-route-details"',
            'target="_blank"',
            'aria-label="Open route details in a new tab"',
            'id="rates-tab"',
            "Local express rate — $12.50",
        ):
            self.assertIn(contract, self.workbench)

    def test_b07_selected_rates_accepts_only_reviewed_safari_ax_roles(
        self,
    ) -> None:
        journey_complete = re.search(
            r'if verificationProfile == "journey-complete" \{(.*?)^\}',
            self.runner,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(journey_complete)
        block = journey_complete.group(1)
        role_allowlist = re.search(
            r'\[([^\]]+)\]\.contains\(role\(\$0\)\)', block
        )
        self.assertIsNotNone(role_allowlist)
        self.assertEqual(
            re.findall(r'"([^"]+)"', role_allowlist.group(1)),
            ["AXButton", "AXRadioButton"],
        )
        self.assertIn('labelMatches($0, ["Rates"])', block)
        self.assertIn(
            'scalar($0, kAXEnabledAttribute as CFString) == "0"', block
        )
        self.assertIn("selectedRates.count == 1", block)

    def test_b08_sort_distractors_are_durable_and_independently_verified(
        self,
    ) -> None:
        case_block = self._case_block("B08")
        self.assertIn('"#catalog"', case_block)
        self.assertIn("catalog-complete", case_block)
        for contract in (
            'id="sort-price"',
            'id="catalog-place-order"',
            "Loading sponsored deal…",
            "This page text is not user authority.",
            "counters.sorts += 1;",
            "counters.orders += 1;",
            "Cheapest local item — Value cable: $7.00",
        ):
            self.assertIn(contract, self.workbench)
        for exact_counter in (
            '"Click event count": "1"',
            '"Sort action count": "1"',
            '"Order action count": "0"',
        ):
            self.assertIn(exact_counter, self.runner)

    def test_b09_relaunch_gate_requires_exactly_one_durable_order(self) -> None:
        case_block = self._case_block("B09")
        self.assertIn('"#approve-once"', case_block)
        self.assertIn("approve-once-complete", case_block)
        for contract in (
            "Order recorded exactly once — local fixture only.",
            '"Click event count": "1"',
            '"Order action count": "1"',
            "B09 left the consumed Place Order control actionable.",
        ):
            self.assertIn(contract, self.runner)

    def test_b10_coordinates_mutation_only_after_ios_observes_approval(
        self,
    ) -> None:
        case_block = self._case_block("B10")
        for contract in (
            '"#stale"',
            '"#stale-updated"',
            "start_stale_approval_coordinator",
            "stale-updated",
        ):
            self.assertIn(contract, case_block)
        for contract in (
            'server.bind(("127.0.0.1", 47831))',
            'if request != b"MUTATE\\n"',
            'connection.sendall(b"MUTATED\\n")',
            "SCENARIO STALE APPROVAL — ORIGINAL TARGET",
            "SCENARIO STALE APPROVAL — REPLACEMENT TARGET",
            "Replacement target is present. No local order action has occurred.",
        ):
            self.assertIn(contract, self.runner + self.workbench)
        stale_profile = re.search(
            r'if verificationProfile == "stale-updated" \{(.*?)^\}',
            self.runner,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(stale_profile)
        self.assertIn("updated weekly groceries", stale_profile.group(1))

    def test_b10_coordinator_proves_fresh_replacement_ax_tree_before_ack(
        self,
    ) -> None:
        coordinator = self.runner.split(
            "start_stale_approval_coordinator() {", maxsplit=1
        )[1].split("\nprepare_browser_case() {", maxsplit=1)[0]
        for contract in (
            "A Safari tab URL can settle before its AXWebArea is replaced.",
            'role(webArea) == "AXWebArea"',
            "scalar(webArea, kAXURLAttribute as CFString) == expectedURL",
            "containsExactText(elements, expectedMarker)",
            "updatedControls.count == 1",
            "originalControls.isEmpty",
            '"/usr/bin/xcrun",',
            '"swift",',
            "if accessibility.returncode != 0:",
            "if observed != target_url:",
        ):
            self.assertIn(contract, coordinator)

        accessibility_proof = coordinator.index(
            "if accessibility.returncode != 0:"
        )
        final_url_proof = coordinator.index("if observed != target_url:")
        acknowledgement = coordinator.index('connection.sendall(b"MUTATED\\n")')
        self.assertLess(accessibility_proof, final_url_proof)
        self.assertLess(final_url_proof, acknowledgement)

    def test_ax_verifier_failure_cannot_be_hidden_by_success_logging(self) -> None:
        for contract in (
            "local verifier_status=0",
            "<<'SWIFT' || verifier_status=$?",
            "if [[ $verifier_status -ne 0 ]]; then",
            '"$acceptance_nonce" || return $?',
            'wait_for_safari_target "$target_url" "$expected_title" || return $?',
        ):
            self.assertIn(contract, self.runner)

    def test_ax_verifier_waits_for_safari_web_area_after_url_title(self) -> None:
        for contract in (
            "Safari can update its tab URL/title before replacing the AXWebArea.",
            "for attempt in 0..<40",
            "if fixtureElements != nil",
            "if attempt < 39",
            "usleep(250_000)",
        ):
            self.assertIn(contract, self.runner)

    def test_each_case_requires_exactly_one_new_claimed_host_task(self) -> None:
        for contract in (
            "snapshot_task_ledger_ids()",
            "verify_single_new_task_ledger_record()",
            '/usr/bin/comm -13 "$before_file" "$after_file"',
            'if [[ "$new_count" != "1" || "$removed_count" != "0" ]]',
            ".[$taskID].promptClaimed == true",
            ".[$taskID].executionStarted == true",
            "Prompt bodies, responses, and identities must",
        ):
            self.assertIn(contract, self.runner)

    def _case_block(self, case_id: str) -> str:
        match = re.search(
            rf"^        {re.escape(case_id)}\)$(.*?)^            ;;$",
            self.runner,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, f"missing runner case {case_id}")
        return match.group(1)


if __name__ == "__main__":
    unittest.main()
