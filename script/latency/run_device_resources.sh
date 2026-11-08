#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${LATENCY_OUTPUT_DIR:?Set LATENCY_OUTPUT_DIR to a new empty directory}"
: "${LATENCY_DEVICE:?Set LATENCY_DEVICE to the physical device identifier}"
BUNDLE="${LATENCY_BUNDLE_ID:-com.threadmark.remotedesktop.client}"
duration=600
safari_document=""
cleanup() {
  if [[ -n "$safari_document" ]]; then
    osascript - "$safari_document" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  tell application "Safari" to close window id (item 1 of argv as integer)
end run
APPLESCRIPT
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$LATENCY_OUTPUT_DIR"
[[ -z "$(ls -A "$LATENCY_OUTPUT_DIR")" ]] || { echo 'Output directory must be empty.' >&2; exit 1; }
# An external controller may own the already-open synthetic Safari window.
if [[ "${LATENCY_EXTERNAL_SCROLL_FIXTURE:-0}" != 1 ]]; then
  fixture_url="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).as_uri())' "$ROOT/script/latency/SyntheticScroll.html")"
  safari_document="$(osascript - "$fixture_url" <<'APPLESCRIPT'
on run argv
  set fixtureURL to item 1 of argv
  tell application "Safari"
    set probeDoc to make new document with properties {URL:fixtureURL}
    activate
    return id of front window
  end tell
end run
APPLESCRIPT
)"
fi
started="$(python3 -c 'import time; print(time.monotonic())')"
launch_args=(LatencyProbe LatencyProbeResourcesOnly)
if [[ -n "${LATENCY_HOST_ID:-}" ]]; then launch_args+=(LatencyProbeHostID "$LATENCY_HOST_ID"); fi
xcrun devicectl device process launch --device "$LATENCY_DEVICE" --terminate-existing "$BUNDLE" "${launch_args[@]}" >"$LATENCY_OUTPUT_DIR/launch.log"
echo 'Waiting for a connected Debug session and clock sync; the host must also have both resource-probe launch arguments.' >&2
ready=0
for _ in {1..60}; do
  rm -rf "$LATENCY_OUTPUT_DIR/ready"
  if xcrun devicectl device copy from --device "$LATENCY_DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source 'Library/Application Support/RemoteDesktopHost/Latency' \
    --destination "$LATENCY_OUTPUT_DIR/ready" >"$LATENCY_OUTPUT_DIR/ready.log" 2>&1 && \
    python3 "$ROOT/script/latency/device_trace_tools.py" ready "$LATENCY_OUTPUT_DIR/ready" "$started" >/dev/null && \
    python3 "$ROOT/script/latency/device_trace_tools.py" resource-host-ready "$HOME/Library/Application Support/RemoteDesktopHost/Latency" "$started"; then
    ready=1; break
  fi
  sleep 2
done
[[ "$ready" == 1 ]] || { echo 'No fresh connected clock and host statistics; inspect ready.log' >&2; exit 1; }
start="$(python3 -c 'import time; print(time.monotonic())')"
sleep "$duration"
end="$(python3 -c 'import time; print(time.monotonic())')"
sleep 3
selected=0
for _ in 1 2 3; do
  rm -rf "$LATENCY_OUTPUT_DIR/client-files"
  if xcrun devicectl device copy from --device "$LATENCY_DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source 'Library/Application Support/RemoteDesktopHost/Latency' \
    --destination "$LATENCY_OUTPUT_DIR/client-files" >"$LATENCY_OUTPUT_DIR/copy.log" 2>&1 && \
    python3 "$ROOT/script/latency/resource_run.py" "$HOME/Library/Application Support/RemoteDesktopHost/Latency" \
    "$LATENCY_OUTPUT_DIR/client-files" "$start" "$end" "$duration" "$LATENCY_OUTPUT_DIR"; then
    selected=1; break
  fi
  sleep 1
done
[[ "$selected" == 1 ]] || { echo 'Unable to select complete resource-only traces; inspect copy.log.' >&2; exit 1; }
echo "Resource summary: $LATENCY_OUTPUT_DIR/resource-summary.json"
