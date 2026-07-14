#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="RemoteDesktopHost"
SUBSYSTEM="com.threadmark.remotedesktop.host"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT_DIR/host-mac"
DERIVED_DATA_DIR="$HOST_DIR/build/codex-run"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
RUNTIME_BINARY="$APP_BUNDLE/Contents/Resources/ComputerUseRuntime/llama-b9992/llama-server"
TRUST_VERIFIER="$HOST_DIR/scripts/verify_host_bundle_trust.sh"

matching_process_ids() {
  local expected_executable="$1"
  /bin/ps -axo pid=,comm= | while read -r process_id executable; do
    if [[ "$executable" == "$expected_executable" ]]; then
      echo "$process_id"
    fi
  done
}

terminate_exact_processes() {
  local executable="$1"
  local label="$2"
  local process_ids
  process_ids="$(matching_process_ids "$executable")"
  [[ -n "$process_ids" ]] || return 0

  while read -r process_id; do
    [[ -n "$process_id" ]] || continue
    /bin/kill -TERM "$process_id" >/dev/null 2>&1 || true
  done <<< "$process_ids"

  # Patched hosts route SIGTERM through AppKit and await model teardown. Older
  # builds may exit immediately, so wait for the owner first and then perform
  # the exact-path runtime cleanup below.
  for _ in {1..40}; do
    [[ -z "$(matching_process_ids "$executable")" ]] && return 0
    /bin/sleep 0.25
  done

  process_ids="$(matching_process_ids "$executable")"
  while read -r process_id; do
    [[ -n "$process_id" ]] || continue
    /bin/kill -KILL "$process_id" >/dev/null 2>&1 || true
  done <<< "$process_ids"

  for _ in {1..20}; do
    [[ -z "$(matching_process_ids "$executable")" ]] && return 0
    /bin/sleep 0.1
  done
  echo "Could not stop the previous $label safely." >&2
  return 1
}

# Match canonical executables, never broad process names. This avoids stopping
# an installed Release host while rebuilding the workspace Debug host and
# removes a model orphan left by an older build or an ungraceful crash.
terminate_exact_processes "$APP_BINARY" "Remote Desktop Host"
terminate_exact_processes "$RUNTIME_BINARY" "local AI runtime"

(
  cd "$HOST_DIR"
  xcodegen generate
  xcodebuild \
    -project RemoteDesktopHost.xcodeproj \
    -scheme RemoteDesktopHost \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build
)

guard_app_exists() {
  if [[ ! -x "$APP_BINARY" ]]; then
    echo "Built app is missing its executable: $APP_BINARY" >&2
    exit 1
  fi
}

verify_app_signature() {
  guard_app_exists
  "$TRUST_VERIFIER" "$APP_BUNDLE"
}

open_app() {
  verify_app_signature
  terminate_exact_processes "$RUNTIME_BINARY" "local AI runtime"
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    verify_app_signature
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact \
      --predicate "subsystem == \"$SUBSYSTEM\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if [[ -n "$(matching_process_ids "$APP_BINARY")" ]]; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not remain running after launch" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
