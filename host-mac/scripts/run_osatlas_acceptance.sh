#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT/host-mac/RemoteDesktopHost.xcodeproj"
SCHEME="RemoteDesktopHost"
INVENTORY_VERIFIER="$ROOT/host-mac/scripts/verify_test_inventory.py"
DETERMINISTIC_INVENTORY="$ROOT/host-mac/AcceptanceFixtures/osatlas-deterministic-tests.json"
configuration="Debug"

usage() {
    /bin/echo "Usage: $0 [--configuration Debug|Release]"
    /bin/echo "Runs the hidden deterministic OS-Atlas compatibility tests selected by the checked-in inventory."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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

cd "$ROOT"
result_root="$(/usr/bin/mktemp -d "/tmp/com.threadmark.remotedesktop.osatlas-acceptance.XXXXXX")"
/bin/chmod 700 "$result_root"
deterministic_result="$result_root/deterministic.xcresult"
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
/bin/echo "Deterministic acceptance results retained at: $result_root" >&2
