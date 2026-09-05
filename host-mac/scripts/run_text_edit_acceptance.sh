#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
test_filter='ComputerUseNativeTextIntegrationTests/testReal(Native|Browser)FieldsReceiveExactVerifiedEdits|ComputerUse(TextEditor|LocalTextGoalPlanner|TextTask|TextStepStore|LiteralPayload|ObservationWorker)Tests'
signed_package=0
if [[ "${1:-}" == "--browser-only" ]]; then
    test_filter='ComputerUseNativeTextIntegrationTests/testRealBrowserFieldsReceiveExactVerifiedEdits'
elif [[ "${1:-}" == "--local-goals-only" ]]; then
    test_filter='ComputerUseNativeTextIntegrationTests/testReal(Native|Browser)NaturalLanguageGoalsAndResume'
elif [[ "${1:-}" == "--local-proposals-only" ]]; then
    test_filter='ComputerUseLocalTextProposalAcceptanceTests/testOptInLocalTextProposalCorpus'
elif [[ "${1:-}" == "--signed-package-only" ]]; then
    signed_package=1
    : "${COMPUTER_USE_SIGNED_PACKAGE_CORPUS:?Supply the frozen regression corpus copied outside Documents}"
    : "${COMPUTER_USE_SIGNED_PACKAGE_REPORT_PREFIX:?Supply a fresh absolute report prefix}"
    : "${COMPUTER_USE_SIGNED_PACKAGE_DERIVED_DATA:?Supply the development-signed Xcode derived-data directory}"
    if [[ -e "$COMPUTER_USE_SIGNED_PACKAGE_REPORT_PREFIX.xcresult" || \
          -e "$COMPUTER_USE_SIGNED_PACKAGE_REPORT_PREFIX.appkit.json" || \
          -e "$COMPUTER_USE_SIGNED_PACKAGE_REPORT_PREFIX.webkit.json" ]]; then
        echo "Refusing to overwrite signed acceptance evidence" >&2
        exit 2
    fi
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--browser-only|--local-goals-only|--local-proposals-only|--signed-package-only]" >&2
    exit 2
fi
fixture_dir="$(mktemp -d /tmp/remotedesktop-text-fixture.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
bundle="$fixture_dir/ComputerUseTextFixture.app"
mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.threadmark.remotedesktop.text-fixture</string>
<key>CFBundleName</key><string>Computer Use Text Fixture</string>
<key>CFBundleExecutable</key><string>ComputerUseTextFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 "$ROOT/host-mac/AcceptanceFixtures/TextEditingFixture.swift" \
    -o "$bundle/Contents/MacOS/ComputerUseTextFixture"
# This local fixture is not a production host or bundled model runtime.
codesign --force --sign - "$bundle"
cd "$ROOT"
if [[ "$signed_package" == 1 ]]; then
    # xcodebuild(1) documents TEST_RUNNER_ forwarding. Only these controlled
    # fixture paths/opt-ins are passed to the signed app; no model endpoint or
    # substitute runtime is injected. Its installer and bundled loader run.
    TEST_RUNNER_RUN_COMPUTER_USE_NATIVE_TEXT_ACCEPTANCE=1 \
    TEST_RUNNER_RUN_SIGNED_NATIVE_PACKAGE_ACCEPTANCE=1 \
    TEST_RUNNER_COMPUTER_USE_TEXT_FIXTURE_EXECUTABLE="$bundle/Contents/MacOS/ComputerUseTextFixture" \
    TEST_RUNNER_COMPUTER_USE_SIGNED_PACKAGE_CORPUS="$COMPUTER_USE_SIGNED_PACKAGE_CORPUS" \
    TEST_RUNNER_COMPUTER_USE_SIGNED_PACKAGE_REPORT_PREFIX="$COMPUTER_USE_SIGNED_PACKAGE_REPORT_PREFIX" \
        xcodebuild test -project host-mac/RemoteDesktopHost.xcodeproj -scheme RemoteDesktopHost \
        -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO \
        -derivedDataPath "$COMPUTER_USE_SIGNED_PACKAGE_DERIVED_DATA" \
        -resultBundlePath "$COMPUTER_USE_SIGNED_PACKAGE_REPORT_PREFIX.xcresult" \
        -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile ENABLE_TESTABILITY=YES \
        '-only-testing:RemoteDesktopHostTests/ComputerUseNativeTextIntegrationTests/testSignedHostNativePackageEditsNativeFields' \
        '-only-testing:RemoteDesktopHostTests/ComputerUseNativeTextIntegrationTests/testSignedHostNativePackageEditsBrowserFields'
    exit $?
fi
result_arguments=(--no-parallel)
if [[ -n "${COMPUTER_USE_TEST_XUNIT_REPORT:-}" ]]; then
    # SwiftPM emits XCTest xUnit results through its worker runner. One worker
    # keeps the real desktop fixtures strictly sequential.
    result_arguments=(--parallel --num-workers 1 --disable-swift-testing --xunit-output "$COMPUTER_USE_TEST_XUNIT_REPORT")
fi
RUN_COMPUTER_USE_NATIVE_TEXT_ACCEPTANCE=1 \
COMPUTER_USE_TEXT_FIXTURE_EXECUTABLE="$bundle/Contents/MacOS/ComputerUseTextFixture" \
    swift test --force-resolved-versions \
    --scratch-path "${COMPUTER_USE_TEST_BUILD_PATH:-$ROOT/.build}" \
    "${result_arguments[@]}" \
    --filter "$test_filter"
