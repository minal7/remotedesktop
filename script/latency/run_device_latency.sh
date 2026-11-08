#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="${LATENCY_BUILD:-/tmp/remotedesktop-device-latency}"
: "${LATENCY_OUTPUT_DIR:?Set LATENCY_OUTPUT_DIR to a new directory for this device}"
: "${LATENCY_DEVICE:?Set LATENCY_DEVICE to the physical device identifier}"
: "${LATENCY_HOST_REFRESH_HZ:?Set the assumed host display refresh rate in Hz}"
: "${LATENCY_CLIENT_REFRESH_HZ:?Set the assumed client display refresh rate in Hz}"
BUNDLE="${LATENCY_BUNDLE_ID:-com.threadmark.remotedesktop.client}"
SCENARIOS="${LATENCY_SCENARIOS:-A B C}"
RUNS="${LATENCY_RUNS:-1 2 3}"
[[ -n "${RUNS//[[:space:]]/}" ]] || { echo 'LATENCY_RUNS must contain positive integers.' >&2; exit 1; }
for run in $RUNS; do
  [[ "$run" =~ ^[1-9][0-9]*$ ]] || { echo 'LATENCY_RUNS must contain positive integers.' >&2; exit 1; }
done
ineligible=0
probe="" warmup="" safari_document=""
cleanup() {
  if [[ -n "$warmup" ]]; then kill "$warmup" 2>/dev/null || true; wait "$warmup" 2>/dev/null || true; fi
  if [[ -n "$probe" ]]; then kill "$probe" 2>/dev/null || true; wait "$probe" 2>/dev/null || true; fi
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
mkdir -p "$BUILD" "$LATENCY_OUTPUT_DIR"
[[ -z "$(ls -A "$LATENCY_OUTPUT_DIR")" ]] || { echo 'Output directory must be empty.' >&2; exit 1; }
xcrun swiftc -O -swift-version 5 "$ROOT/script/latency/DeviceMarkerProbe.swift" -o "$BUILD/DeviceMarkerProbe"
xcrun swiftc -O -swift-version 5 "$ROOT/script/latency/LocalUnixClock.swift" -o "$BUILD/LocalUnixClock"
python3 "$ROOT/script/latency/device_trace_tools.py" metadata "$LATENCY_HOST_REFRESH_HZ" "$LATENCY_CLIENT_REFRESH_HZ" "$LATENCY_OUTPUT_DIR/metadata.json"
for scenario in $SCENARIOS; do
  case "$scenario" in
    A|B) ;;
    C) ;;
    *) echo "Unknown scenario: $scenario" >&2; exit 1 ;;
  esac
  for run in $RUNS; do
    stem="$LATENCY_OUTPUT_DIR/${scenario}-${run}"
    # Keep synthetic content changing while the connection initializes. A
    # static desktop can otherwise expire before the first clock burst finishes.
    # This contains no counter cells, so it cannot pollute the measured IDs.
    "$BUILD/LocalUnixClock" >"$stem-warmup.log" 2>&1 & warmup=$!
    # Each process creates a fresh session and bounded trace; wait for an actual
    # 50-sample clock estimate rather than assuming launch means connected.
    started="$(python3 -c 'import time; print(time.monotonic())')"
    launch_args=(LatencyProbe LatencyProbeScenario "$scenario")
    if [[ -n "${LATENCY_HOST_ID:-}" ]]; then launch_args+=(LatencyProbeHostID "$LATENCY_HOST_ID"); fi
    xcrun devicectl device process launch --device "$LATENCY_DEVICE" --terminate-existing "$BUNDLE" "${launch_args[@]}" >"$stem-launch.log"
    echo "Waiting for a connected Debug session and clock sync: scenario $scenario run $run" >&2
    ready_dir="$stem-ready"
    ready=0
    for _ in {1..60}; do
      rm -rf "$ready_dir"
      if xcrun devicectl device copy from --device "$LATENCY_DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source 'Library/Application Support/RemoteDesktopHost/Latency' \
        --destination "$ready_dir" >"$stem-ready.log" 2>&1 && \
        python3 "$ROOT/script/latency/device_trace_tools.py" ready "$ready_dir" "$started" >/dev/null && \
        python3 "$ROOT/script/latency/device_trace_tools.py" host-ready "$HOME/Library/Application Support/RemoteDesktopHost/Latency" "$started"; then
        ready=1; break
      fi
      sleep 2
    done
    [[ "$ready" == 1 ]] || { echo "No fresh connected clock within readiness window; inspect $stem-ready.log" >&2; exit 1; }
    kill "$warmup" 2>/dev/null || true
    wait "$warmup" 2>/dev/null || true
    warmup=""
    cp "$LATENCY_OUTPUT_DIR/metadata.json" "$stem-metadata.json"
    # An external controller may own the already-open synthetic Safari window.
    if [[ "$scenario" == B && "${LATENCY_EXTERNAL_SCROLL_FIXTURE:-0}" != 1 ]]; then
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
    export LATENCY_HOST_TRACE="$stem-host.json" LATENCY_SECONDS=60
    "$BUILD/DeviceMarkerProbe" >"$stem-marker.log" 2>&1 & probe=$!
    ready=0
    for _ in {1..100}; do
      if rg -q '^MARKER_READY ' "$stem-marker.log"; then ready=1; break; fi
      if ! kill -0 "$probe" 2>/dev/null; then break; fi
      sleep 0.1
    done
    [[ "$ready" == 1 ]] || { echo "Marker failed to become ready; see $stem-marker.log" >&2; exit 1; }
    if wait "$probe"; then probe=""; else probe=""; echo "Marker probe failed; see $stem-marker.log" >&2; exit 1; fi
    # The last displayed marker still needs to travel through the stream and
    # reach presentedTime before copying the live client trace.
    sleep 3
    if [[ -n "$safari_document" ]]; then
      osascript - "$safari_document" <<'APPLESCRIPT'
on run argv
  tell application "Safari" to close window id (item 1 of argv as integer)
end run
APPLESCRIPT
      safari_document=""
    fi
    trace_dir="$stem-client-files"
    selected=0
    # A live JSONL file can be copied in the middle of an append. Retry the
    # snapshot and selection as a unit; never accept a partial JSON record.
    for _ in 1 2 3; do
      rm -rf "$trace_dir"
      if xcrun devicectl device copy from --device "$LATENCY_DEVICE" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" --source 'Library/Application Support/RemoteDesktopHost/Latency' \
        --destination "$trace_dir" >"$stem-copy.log" 2>&1 && \
        python3 "$ROOT/script/latency/select_device_trace.py" "$stem-host.json" "$trace_dir" "$stem-client.jsonl"; then
        selected=1; break
      fi
      sleep 1
    done
    [[ "$selected" == 1 ]] || { echo "Unable to select a complete client trace; see $stem-copy.log" >&2; exit 1; }
    host_selected=0
    for _ in 1 2 3; do
      if python3 "$ROOT/script/latency/device_trace_tools.py" host "$stem-host.json" "$HOME/Library/Application Support/RemoteDesktopHost/Latency" "$stem-host-telemetry.jsonl"; then
        host_selected=1; break
      fi
      sleep 1
    done
    [[ "$host_selected" == 1 ]] || { echo 'Unable to select complete host telemetry.' >&2; exit 1; }
    python3 "$ROOT/script/latency/summarize_latency.py" --device "$stem-host.json" "$stem-client.jsonl" "$stem-host-telemetry.jsonl" "$stem-metadata.json" >"$stem-summary.json"
    if ! python3 - "$stem-summary.json" <<'PYCHECK'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
if not result['baseline_eligible']:
    print('Run is not baseline eligible: ' + '; '.join(result['baseline_ineligible_reasons']), file=sys.stderr)
    raise SystemExit(1)
PYCHECK
    then ineligible=$((ineligible + 1)); fi
  done
done
if (( ineligible > 0 )); then
  echo "$ineligible run(s) were not baseline eligible; all collected results were retained." >&2
  exit 1
fi
