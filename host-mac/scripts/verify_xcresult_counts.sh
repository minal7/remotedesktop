#!/bin/bash
set -euo pipefail

usage() {
    /bin/echo "Usage: $0 XCRESULT_PATH EXPECTED_TEST_COUNT LABEL" >&2
}

if [[ $# -ne 3 ]]; then
    usage
    exit 2
fi

xcresult_path="$1"
expected_test_count="$2"
label="$3"

if [[ ! "$expected_test_count" =~ ^[1-9][0-9]*$ ]]; then
    /bin/echo "Expected test count must be a positive integer; got: $expected_test_count" >&2
    exit 2
fi
if [[ ! -d "$xcresult_path" ]]; then
    /bin/echo "Missing xcresult bundle for $label: $xcresult_path" >&2
    exit 1
fi

summary_file="$(/usr/bin/mktemp "/tmp/com.threadmark.remotedesktop.xcresult-summary.XXXXXX")"
/bin/chmod 600 "$summary_file"
cleanup() {
    /bin/rm -f "$summary_file"
}
trap cleanup EXIT INT TERM

if ! /usr/bin/xcrun xcresulttool get test-results summary \
    --path "$xcresult_path" > "$summary_file"; then
    /bin/echo "Could not read xcresult summary for $label: $xcresult_path" >&2
    exit 1
fi

summary_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$summary_file"
}

result="$(summary_value result)"
total_tests="$(summary_value totalTestCount)"
passed_tests="$(summary_value passedTests)"
failed_tests="$(summary_value failedTests)"
skipped_tests="$(summary_value skippedTests)"
expected_failures="$(summary_value expectedFailures)"

if [[ "$result" != "Passed" \
    || "$total_tests" != "$expected_test_count" \
    || "$passed_tests" != "$expected_test_count" \
    || "$failed_tests" != "0" \
    || "$skipped_tests" != "0" \
    || "$expected_failures" != "0" ]]; then
    /bin/echo "Strict xcresult verification failed for $label." >&2
    /bin/echo "Expected: result=Passed total=$expected_test_count passed=$expected_test_count failed=0 skipped=0 expectedFailures=0" >&2
    /bin/echo "Observed: result=$result total=$total_tests passed=$passed_tests failed=$failed_tests skipped=$skipped_tests expectedFailures=$expected_failures" >&2
    exit 1
fi

/bin/echo "Verified $label: exactly $passed_tests tests passed with no failures, skips, or expected failures."
