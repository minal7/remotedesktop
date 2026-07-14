#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT/host-mac/RemoteDesktopHost.xcodeproj"
SCHEME="RemoteDesktopHost"
MODEL_FLAG="/tmp/com.threadmark.remotedesktop.osatlas-model-e2e-$(id -u)"
LIVE_CONFIG="/tmp/com.threadmark.remotedesktop.osatlas-live-doordash-$(id -u).json"

run_actual_model=0
run_live_doordash=0
allow_visible_ui=0

usage() {
    /bin/echo "Usage: $0 [--actual-model] [--live-doordash --allow-visible-ui]"
    /bin/echo ""
    /bin/echo "Default: hidden deterministic OS-Atlas parser, executor, safety, and native-input tests."
    /bin/echo "--actual-model: additionally load the installed OS-Atlas Pro checkpoint against hidden virtual screens."
    /bin/echo "--live-doordash: read a prepared, visible DoorDash review page without performing input."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --actual-model)
            run_actual_model=1
            ;;
        --live-doordash)
            run_live_doordash=1
            run_actual_model=1
            ;;
        --allow-visible-ui)
            allow_visible_ui=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            /bin/echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

cleanup() {
    /bin/rm -f "$MODEL_FLAG" "$LIVE_CONFIG"
}
trap cleanup EXIT INT TERM
cleanup

if [[ $run_live_doordash -eq 1 ]]; then
    if [[ $allow_visible_ui -ne 1 ]]; then
        /bin/echo "Refusing live DoorDash capture without --allow-visible-ui." >&2
        exit 2
    fi
    : "${DOORDASH_EXPECTED_ITEM:?Set DOORDASH_EXPECTED_ITEM to the exact visible item.}"
    : "${DOORDASH_EXPECTED_TOTAL:?Set DOORDASH_EXPECTED_TOTAL to the exact visible delivered total.}"
    : "${DOORDASH_EXPECTED_ETA:?Set DOORDASH_EXPECTED_ETA to the exact visible ETA.}"
fi

cd "$ROOT"

# This default gate never opens a fixture, captures the desktop, or posts real
# input. The ComputerUseHostTools screen and event providers are in-memory.
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -only-testing:RemoteDesktopHostTests/OSAtlasComputerUseExecutorTests \
    -only-testing:RemoteDesktopHostTests/OSAtlasLlamaRuntimeTests/testCompletionRequestIsAuthenticatedLoopbackOnlyAndDeterministic \
    -only-testing:RemoteDesktopHostTests/OSAtlasLlamaRuntimeTests/testLaunchArgumentsPinLoopbackAuthNoLogsAndInferenceBudget \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_visualOpenAppUsesValidatedNativeApplicationOpener \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_visualOpenAppRejectsPathsAndPausedAutomationBeforeOpening \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_virtualScreenAndAccessibilityContextKeepModelTestsOffTheDesktop \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_computerUseDoubleClickCarriesNativeClickCount \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_computerUseRightClickPostsNativeRightButtonPair \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_computerUseMiddleClickPostsNativeOtherButtonPair \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_computerUseEnterPostsReturnKeyDownAndUp \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_computerUseCommandShiftHotkeyPostsSKeyWithModifiers \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_computerUseScrollPostsRequestedDeltaExactlyOnce \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_computerUseTextPreservesEmojiAndSupplementaryUnicode \
    -only-testing:RemoteDesktopHostTests/ComputerUseTests/test_computerUseDragInterpolatesHeldPointerPath

if [[ $run_actual_model -eq 1 ]]; then
    /usr/bin/install -m 600 /dev/null "$MODEL_FLAG"
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination 'platform=macOS' \
        -only-testing:RemoteDesktopHostTests/OSAtlasActualModelAcceptanceTests
fi

if [[ $run_live_doordash -eq 1 ]]; then
    # The expected item/total/ETA are user-provided task data. Create the
    # config owner-only before writing any value so there is never a wider
    # permission window between plutil writes and the final test launch.
    /usr/bin/install -m 600 /dev/null "$LIVE_CONFIG"
    /usr/bin/plutil -create json "$LIVE_CONFIG"
    /usr/bin/plutil -insert expectedItem -string "$DOORDASH_EXPECTED_ITEM" "$LIVE_CONFIG"
    /usr/bin/plutil -insert expectedTotal -string "$DOORDASH_EXPECTED_TOTAL" "$LIVE_CONFIG"
    /usr/bin/plutil -insert expectedETA -string "$DOORDASH_EXPECTED_ETA" "$LIVE_CONFIG"
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination 'platform=macOS' \
        -only-testing:RemoteDesktopHostTests/OSAtlasLiveDoorDashSmokeTests
fi
