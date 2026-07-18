#!/usr/bin/env bash
set -euo pipefail

configuration="Release"
install_dir="/Applications"
skip_build=0
launch=0
start_at_login=0
headless=0
request_permissions=0
ssh_permission_report=0
pppc_profile_path=""

usage() {
  cat <<'USAGE'
Usage:
  install_host.sh [options]

Options:
  --debug                       Build a diagnostic Debug host; pair only with Debug iOS.
  --skip-build                  Install the existing build product.
  --install-dir PATH            Install directory. Default: /Applications.
  --launch                      Launch the installed host after installing.
  --start-at-login              Install a per-user LaunchAgent.
  --headless                    Start listening on launch and write the pairing code to a file.
  --request-permissions         Ask macOS to surface available permission prompts and print status.
  --ssh-permission-report       Explain what plain SSH can and cannot grant.
  --generate-pppc-profile PATH  Generate an MDM PPPC profile for the installed app.
  -h, --help                    Show this help.

For a screenless developer Mac mini, use:
  ./scripts/install_host.sh --headless --start-at-login --launch --request-permissions --ssh-permission-report

Plain SSH cannot grant every required macOS TCC permission. Use
--ssh-permission-report for the exact breakdown.
Final acceptance uses the default Release host with a Release iPhone Air
Simulator; both resolve to Production CloudKit.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      configuration="Debug"
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --install-dir)
      install_dir="${2:?Missing path for --install-dir}"
      shift 2
      ;;
    --launch)
      launch=1
      shift
      ;;
    --start-at-login)
      start_at_login=1
      shift
      ;;
    --headless)
      headless=1
      shift
      ;;
    --request-permissions)
      request_permissions=1
      shift
      ;;
    --ssh-permission-report)
      ssh_permission_report=1
      shift
      ;;
    --generate-pppc-profile)
      pppc_profile_path="${2:?Missing path for --generate-pppc-profile}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

shared_configuration="${REMOTE_DESKTOP_APPLE_CONFIGURATION:-$configuration}"
declared_host_configuration="${REMOTE_DESKTOP_HOST_CONFIGURATION:-$shared_configuration}"
declared_ios_configuration="${REMOTE_DESKTOP_IOS_CONFIGURATION:-$shared_configuration}"
if [[ "$configuration" != "$shared_configuration" \
      || "$configuration" != "$declared_host_configuration" \
      || "$configuration" != "$declared_ios_configuration" ]]; then
  echo "Refusing mixed Apple configurations: installer=$configuration, shared=$shared_configuration, macOS=$declared_host_configuration, iOS=$declared_ios_configuration." >&2
  echo "Use Release/Release for Production acceptance or Debug/Debug for diagnostics." >&2
  exit 2
fi
case "$configuration" in
  Debug) expected_cloudkit_environment="Development" ;;
  Release) expected_cloudkit_environment="Production" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host_dir="$(cd "$script_dir/.." && pwd)"
derived_data="$host_dir/build/DerivedData"
app_name="RemoteDesktopHost.app"
built_app="$derived_data/Build/Products/$configuration/$app_name"
installed_app="$install_dir/$app_name"
executable="$installed_app/Contents/MacOS/RemoteDesktopHost"
installed_runtime="$installed_app/Contents/Resources/ComputerUseRuntime/llama-b9992/llama-server"
bundle_id="com.threadmark.remotedesktop.host"
pairing_code_file="$HOME/Library/Application Support/RemoteDesktopHost/pairing-code.txt"

matching_process_ids() {
  local expected_executable="$1"
  /bin/ps -axo pid=,comm= | while read -r process_id process_executable; do
    if [[ "$process_executable" == "$expected_executable" ]]; then
      echo "$process_id"
    fi
  done
}

terminate_exact_processes() {
  local process_executable="$1"
  local label="$2"
  local process_ids
  process_ids="$(matching_process_ids "$process_executable")"
  [[ -n "$process_ids" ]] || return 0

  while read -r process_id; do
    [[ -n "$process_id" ]] || continue
    /bin/kill -TERM "$process_id" >/dev/null 2>&1 || true
  done <<< "$process_ids"

  for _ in {1..40}; do
    [[ -z "$(matching_process_ids "$process_executable")" ]] && return 0
    /bin/sleep 0.25
  done

  process_ids="$(matching_process_ids "$process_executable")"
  while read -r process_id; do
    [[ -n "$process_id" ]] || continue
    /bin/kill -KILL "$process_id" >/dev/null 2>&1 || true
  done <<< "$process_ids"
  for _ in {1..20}; do
    [[ -z "$(matching_process_ids "$process_executable")" ]] && return 0
    /bin/sleep 0.1
  done
  echo "Could not stop the previous $label safely." >&2
  return 1
}

verify_cloudkit_configuration() {
  local entitlements
  local actual_environment
  local actual_container
  local extra_container
  local actual_service
  local extra_service
  entitlements="$(/usr/bin/mktemp -t remotedesktop-install-entitlements)"
  if ! /usr/bin/codesign -d --entitlements :- "$built_app" \
      >"$entitlements" 2>/dev/null; then
    /bin/rm -f "$entitlements"
    echo "Could not read CloudKit entitlements from $built_app" >&2
    return 1
  fi

  actual_environment="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.icloud-container-environment' \
    "$entitlements" 2>/dev/null || true)"
  actual_container="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.icloud-container-identifiers:0' \
    "$entitlements" 2>/dev/null || true)"
  extra_container="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.icloud-container-identifiers:1' \
    "$entitlements" 2>/dev/null || true)"
  actual_service="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.icloud-services:0' \
    "$entitlements" 2>/dev/null || true)"
  extra_service="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.developer.icloud-services:1' \
    "$entitlements" 2>/dev/null || true)"
  /bin/rm -f "$entitlements"

  if [[ "$actual_environment" != "$expected_cloudkit_environment" \
        || "$actual_container" != "iCloud.com.threadmark.remotedesktop" \
        || -n "$extra_container" \
        || "$actual_service" != "CloudKit" \
        || -n "$extra_service" ]]; then
    echo "Refusing $configuration host with unreviewed CloudKit entitlements: environment='$actual_environment', container='$actual_container', service='$actual_service'." >&2
    return 1
  fi
  if [[ "$configuration" == "Release" ]] \
      && /usr/bin/find "$built_app/Contents" -type f \
          \( -name '*.debug.dylib' -o -name '*XCTest*' \) \
          -print -quit | /usr/bin/grep -q .; then
    echo "Refusing a Release host that contains a Debug/XCTest payload: $built_app" >&2
    return 1
  fi
}

if [[ "$skip_build" -eq 0 ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    (cd "$host_dir" && xcodegen generate)
  fi

  xcodebuild \
    -project "$host_dir/RemoteDesktopHost.xcodeproj" \
    -scheme RemoteDesktopHost \
    -configuration "$configuration" \
    -derivedDataPath "$derived_data" \
    build
fi

if [[ ! -d "$built_app" ]]; then
  echo "Build product not found: $built_app" >&2
  exit 66
fi

"$script_dir/verify_host_bundle_trust.sh" "$built_app"
verify_cloudkit_configuration

# The replacement bundle has already passed trust verification. Stop only the
# exact installed executable image and its exact packaged runtime before
# replacing files, so launch can never leave an older same-bundle process alive.
terminate_exact_processes "$executable" "installed Remote Desktop Host"
terminate_exact_processes "$installed_runtime" "installed local AI runtime"

mkdir -p "$install_dir"
if [[ -d "$installed_app" ]]; then
  rm -rf "$installed_app"
fi
/usr/bin/ditto "$built_app" "$installed_app"
echo "Installed $installed_app"

if [[ "$headless" -eq 1 ]]; then
  defaults write "$bundle_id" StartListeningOnLaunch -bool true
  defaults write "$bundle_id" PairingCodeFile "$pairing_code_file"
  mkdir -p "$(dirname "$pairing_code_file")"
  echo "Headless mode enabled. Pairing code file: $pairing_code_file"
fi

if [[ -n "$pppc_profile_path" ]]; then
  "$script_dir/generate_pppc_profile.sh" "$installed_app" "$pppc_profile_path"
fi

if [[ "$ssh_permission_report" -eq 1 ]]; then
  "$executable" --ssh-permission-report || true
fi

if [[ "$start_at_login" -eq 1 ]]; then
  launch_agents_dir="$HOME/Library/LaunchAgents"
  launch_agent="$launch_agents_dir/$bundle_id.plist"
  mkdir -p "$launch_agents_dir"
  program_args="<string>$executable</string>"
  if [[ "$headless" -eq 1 ]]; then
    program_args="$program_args
    <string>--start-listening</string>"
  fi

  cat > "$launch_agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$bundle_id</string>
  <key>ProgramArguments</key>
  <array>
    $program_args
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/RemoteDesktopHost.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/RemoteDesktopHost.err.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$launch_agent" >/dev/null
  launchctl bootout "gui/$(id -u)" "$launch_agent" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$launch_agent"
  echo "Installed LaunchAgent $launch_agent"
fi

if [[ "$request_permissions" -eq 1 ]]; then
  set +e
  "$executable" --request-permissions
  permission_status=$?
  set -e
  if [[ "$permission_status" -ne 0 ]]; then
    echo "Permission status is incomplete. For managed Macs, deploy the PPPC profile through MDM." >&2
  fi
fi

if [[ "$launch" -eq 1 ]]; then
  if [[ "$headless" -eq 1 ]]; then
    /usr/bin/open -gj "$installed_app" --args --start-listening
  else
    /usr/bin/open -gj "$installed_app"
  fi
  echo "Launched $installed_app"
fi

echo "Check permissions with:"
echo "  '$executable' --check-permissions"
echo "Check what plain SSH can grant with:"
echo "  '$executable' --ssh-permission-report"
if [[ "$headless" -eq 1 ]]; then
  echo "Read the active pairing code with:"
  echo "  cat '$pairing_code_file'"
fi
