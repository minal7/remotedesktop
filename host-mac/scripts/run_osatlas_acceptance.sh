#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT/host-mac/RemoteDesktopHost.xcodeproj"
SCHEME="RemoteDesktopHost"
MODEL_FLAG="/tmp/com.threadmark.remotedesktop.osatlas-model-e2e-$(id -u)"
LIVE_CONFIG="/tmp/com.threadmark.remotedesktop.osatlas-live-doordash-$(id -u).json"
VERIFY_XCRESULT="$ROOT/host-mac/scripts/verify_xcresult_counts.sh"
INVENTORY_VERIFIER="$ROOT/host-mac/scripts/verify_test_inventory.py"
DETERMINISTIC_INVENTORY="$ROOT/host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json"
RESULT_ROOT=""

run_actual_model=0
run_future_semantic_package=0
run_live_doordash=0
allow_visible_ui=0
configuration="Debug"

usage() {
    /bin/echo "Usage: $0 [--configuration Debug|Release] [--actual-model] [--future-semantic-package] [--live-doordash --allow-visible-ui]"
    /bin/echo ""
    /bin/echo "Default: hidden deterministic OS-Atlas parser, executor, safety, and native-input tests."
    /bin/echo "--actual-model: gate the current installed production package and hidden model components; requires --configuration Release."
    /bin/echo "--future-semantic-package: additionally qualify the V5 Apple/Granite/OS-Atlas composition; requires its published artifact and --configuration Release."
    /bin/echo "--live-doordash: read a prepared, visible DoorDash review page without performing input; requires --configuration Release."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --actual-model)
            run_actual_model=1
            ;;
        --future-semantic-package)
            run_future_semantic_package=1
            run_actual_model=1
            ;;
        --live-doordash)
            run_live_doordash=1
            run_actual_model=1
            ;;
        --allow-visible-ui)
            allow_visible_ui=1
            ;;
        --configuration)
            if [[ $# -lt 2 ]]; then
                /bin/echo "Missing value for --configuration." >&2
                usage >&2
                exit 2
            fi
            configuration="$2"
            shift
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

case "$configuration" in
    Debug|Release)
        ;;
    *)
        /bin/echo "Unsupported configuration: $configuration (expected Debug or Release)." >&2
        exit 2
        ;;
esac

if [[ $run_actual_model -eq 1 && "$configuration" != "Release" ]]; then
    /bin/echo "Actual-model and live acceptance require --configuration Release." >&2
    exit 2
fi

cleanup() {
    /bin/rm -f "$MODEL_FLAG" "$LIVE_CONFIG"
    case "$RESULT_ROOT" in
        /tmp/com.threadmark.remotedesktop.osatlas-acceptance.*)
            if [[ -e "$RESULT_ROOT" ]]; then
                /usr/bin/find "$RESULT_ROOT" -depth -delete
            fi
            ;;
        "")
            ;;
        *)
            /bin/echo "Refusing to remove unexpected acceptance result path: $RESULT_ROOT" >&2
            ;;
    esac
}
trap cleanup EXIT INT TERM
cleanup

reclaimable_memory_bytes() {
    local page_size pages
    page_size="$(/usr/sbin/sysctl -n hw.pagesize)"
    pages="$(/usr/bin/vm_stat | /usr/bin/awk '
        /Pages free:/ || /Pages inactive:/ || /Pages speculative:/ {
            gsub(/\./, "", $3)
            total += $3
        }
        END { printf "%.0f", total }
    ')"
    /bin/echo $((page_size * pages))
}

wait_for_actual_model_headroom() {
    # Keep a buffer above the production launch gate. Each actual-checkpoint
    # method gets a fresh XCTest process so reclaimed VM/Metal pages from one
    # cold launch cannot turn the next method into a cascade of zero-duration
    # `insufficientAvailableMemory` failures.
    local minimum_bytes=$((8 * 1024 * 1024 * 1024))
    local available_bytes attempt
    for attempt in $(/usr/bin/seq 1 30); do
        available_bytes="$(reclaimable_memory_bytes)"
        if [[ "$available_bytes" -ge "$minimum_bytes" ]]; then
            return 0
        fi
        /bin/sleep 1
    done
    /bin/echo "Actual-model acceptance needs at least 8 GiB of reclaimable memory before a cold launch; found $((available_bytes / 1024 / 1024)) MiB." >&2
    return 1
}

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
RESULT_ROOT="$(/usr/bin/mktemp -d "/tmp/com.threadmark.remotedesktop.osatlas-acceptance.XXXXXX")"
/bin/chmod 700 "$RESULT_ROOT"

# This default gate never opens a fixture, captures the desktop, or posts real
# input. The ComputerUseHostTools screen and event providers are in-memory.
# ENABLE_TESTABILITY is a test-build-only override required by the app-hosted
# suite's `@testable import`; Release still uses its normal optimization,
# Production CloudKit setting, and mandatory real runtime signature.
deterministic_result="$RESULT_ROOT/deterministic.xcresult"
selector_output="$(python3 "$INVENTORY_VERIFIER" \
    --manifest "$DETERMINISTIC_INVENTORY" --source-root "$ROOT" --selectors)"
deterministic_selectors=()
while IFS= read -r selector; do
    deterministic_selectors+=("-only-testing:$selector")
done <<< "$selector_output"
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    -resultBundlePath "$deterministic_result" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    ENABLE_TESTABILITY=YES \
    "${deterministic_selectors[@]}"
python3 "$INVENTORY_VERIFIER" --manifest "$DETERMINISTIC_INVENTORY" \
    --source-root "$ROOT" --result "$deterministic_result"

if [[ $run_actual_model -eq 1 ]]; then
    /usr/bin/install -m 600 /dev/null "$MODEL_FLAG"
    actual_model_tests=(
        testCurrentProductionPackageRoutesNaturalLanguageToGroundedApproval
        testInstalledGrounderCompletesRegularUserMatrixWithApplePlannerUnavailableUsingOnlyClickCarriers
        testInstalledHybridUnderstandsNaturalLanguageAcrossFullActionSurfaceWithoutVisibleUI
        testActualModelNavigatesDeliveryQuoteAndValidatedLocalOCRReturnsExactFactsWithoutVisibleUI
        testActualModelCompletesMultiActionDeliveryQuoteWorkflowWithoutVisibleUI
    )
    if [[ $run_future_semantic_package -eq 1 ]]; then
        actual_model_tests+=(testFinalV5ProductionPackageRoutesThroughAppleGraniteOSAtlasAndHostValidation)
    fi
    for test_name in "${actual_model_tests[@]}"; do
        wait_for_actual_model_headroom
        actual_result="$RESULT_ROOT/actual-$test_name.xcresult"
        xcodebuild test \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration "$configuration" \
            -destination 'platform=macOS' \
            -parallel-testing-enabled NO \
            -resultBundlePath "$actual_result" \
            -disableAutomaticPackageResolution \
            -onlyUsePackageVersionsFromResolvedFile \
            ENABLE_TESTABILITY=YES \
            -only-testing:"RemoteDesktopHostTests/OSAtlasActualModelAcceptanceTests/$test_name"
        /bin/bash "$VERIFY_XCRESULT" \
            "$actual_result" \
            1 \
            "actual OS-Atlas acceptance $test_name"
    done
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
    live_result="$RESULT_ROOT/live-doordash.xcresult"
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$configuration" \
        -destination 'platform=macOS' \
        -resultBundlePath "$live_result" \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        ENABLE_TESTABILITY=YES \
        -only-testing:RemoteDesktopHostTests/OSAtlasLiveDoorDashSmokeTests
    /bin/bash "$VERIFY_XCRESULT" \
        "$live_result" \
        1 \
        "live DoorDash OS-Atlas acceptance"
fi
