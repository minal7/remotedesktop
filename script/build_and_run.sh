#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="RemoteDesktopHost"
SUBSYSTEM="com.threadmark.remotedesktop.host"
SHARED_CONFIGURATION="${REMOTE_DESKTOP_APPLE_CONFIGURATION:-Release}"
HOST_CONFIGURATION="${REMOTE_DESKTOP_HOST_CONFIGURATION:-$SHARED_CONFIGURATION}"
IOS_CONFIGURATION="${REMOTE_DESKTOP_IOS_CONFIGURATION:-$SHARED_CONFIGURATION}"

case "$SHARED_CONFIGURATION" in
  Debug|Release)
    ;;
  *)
    echo "REMOTE_DESKTOP_APPLE_CONFIGURATION must be Debug or Release." >&2
    exit 2
    ;;
esac
if [[ "$HOST_CONFIGURATION" != "$IOS_CONFIGURATION" ]]; then
  echo "Refusing mixed Apple configurations: macOS=$HOST_CONFIGURATION, iOS=$IOS_CONFIGURATION." >&2
  echo "Use Release/Release for final Production CloudKit acceptance or Debug/Debug for diagnostics." >&2
  exit 2
fi
if [[ "$HOST_CONFIGURATION" != "$SHARED_CONFIGURATION" ]]; then
  echo "Refusing a host override that differs from the shared Apple configuration: shared=$SHARED_CONFIGURATION, macOS=$HOST_CONFIGURATION." >&2
  exit 2
fi
CONFIGURATION="$SHARED_CONFIGURATION"
case "$CONFIGURATION" in
  Debug)
    EXPECTED_CLOUDKIT_ENVIRONMENT="Development"
    ;;
  Release)
    EXPECTED_CLOUDKIT_ENVIRONMENT="Production"
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="$ROOT_DIR/host-mac"
DERIVED_DATA_DIR="$HOST_DIR/build/codex-run"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
RUNTIME_BINARY="$APP_BUNDLE/Contents/Resources/ComputerUseRuntime/llama-b9992/llama-server"
INSTALLED_APP_BUNDLE="/Applications/$APP_NAME.app"
INSTALLED_APP_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"
INSTALLED_RUNTIME_BINARY="$INSTALLED_APP_BUNDLE/Contents/Resources/ComputerUseRuntime/llama-b9992/llama-server"
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

# Match canonical executables, never broad process names. The current workspace
# process is stopped before building; the installed same-bundle host stays up
# only until a verified replacement is ready to launch.
terminate_exact_processes "$APP_BINARY" "Remote Desktop Host"
terminate_exact_processes "$RUNTIME_BINARY" "local AI runtime"

(
  cd "$HOST_DIR"
  xcodegen generate
  xcodebuild \
    -project RemoteDesktopHost.xcodeproj \
    -scheme RemoteDesktopHost \
    -configuration "$CONFIGURATION" \
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

verify_cloudkit_configuration() {
  local entitlements
  local actual_environment
  entitlements="$(/usr/bin/mktemp -t remotedesktop-host-entitlements)"
  if ! /usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" \
      >"$entitlements" 2>/dev/null; then
    /bin/rm -f "$entitlements"
    echo "Could not read CloudKit entitlements from $APP_BUNDLE" >&2
    exit 1
  fi
  actual_environment="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.icloud-container-environment' \
    "$entitlements" 2>/dev/null || true)"
  /bin/rm -f "$entitlements"
  if [[ "$actual_environment" != "$EXPECTED_CLOUDKIT_ENVIRONMENT" ]]; then
    echo "Refusing $CONFIGURATION host with CloudKit environment '$actual_environment'; expected $EXPECTED_CLOUDKIT_ENVIRONMENT." >&2
    exit 1
  fi
  if [[ "$CONFIGURATION" == "Release" ]] \
      && /usr/bin/find "$APP_BUNDLE/Contents" -name '*.debug.dylib' -print -quit \
          | /usr/bin/grep -q .; then
    echo "Refusing a Release host that contains a debug dylib: $APP_BUNDLE" >&2
    exit 1
  fi
}

terminate_competing_installed_host() {
  terminate_exact_processes \
    "$INSTALLED_APP_BINARY" \
    "installed Remote Desktop Host"
  terminate_exact_processes \
    "$INSTALLED_RUNTIME_BINARY" \
    "installed local AI runtime"
}

open_app() {
  verify_app_signature
  verify_cloudkit_configuration
  terminate_competing_installed_host
  terminate_exact_processes "$RUNTIME_BINARY" "local AI runtime"
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    verify_app_signature
    verify_cloudkit_configuration
    terminate_competing_installed_host
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
    echo "Set REMOTE_DESKTOP_APPLE_CONFIGURATION=Debug only for a paired Debug/Debug diagnostic run; the default is Release/Release." >&2
    exit 2
    ;;
esac
