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
host_artifact=""
expected_source_commit=""

usage() {
  cat <<'USAGE'
Usage:
  install_host.sh [options]

Options:
  --debug                       Build a diagnostic Debug host; pair only with Debug iOS.
  --skip-build                  Install the existing build product.
  --host-artifact APP           Install an absolute, notarized Release .app instead of rebuilding.
  --expected-source-commit SHA  Require APP's signed source revision to match this full Git commit.
  --install-dir /Applications   Explicitly select the supported install directory.
  --launch                      Launch the installed host after installing.
  --start-at-login              Install a per-user LaunchAgent.
  --headless                    Start listening on launch; Apple devices pair automatically.
  --request-permissions         Ask macOS to surface available permission prompts and print status.
  --ssh-permission-report       Explain what plain SSH can and cannot grant.
  --generate-pppc-profile PATH  Generate an MDM PPPC profile for the installed app.
  -h, --help                    Show this help.

For a screenless Debug developer Mac mini, use:
  REMOTE_DESKTOP_APPLE_CONFIGURATION=Debug REMOTE_DESKTOP_HOST_CONFIGURATION=Debug REMOTE_DESKTOP_IOS_CONFIGURATION=Debug \
    ./scripts/install_host.sh --debug --headless --start-at-login --launch --request-permissions --ssh-permission-report

For Release, pass the extracted notarized app and its exact signed source SHA:
  ./scripts/install_host.sh --host-artifact /absolute/path/RemoteDesktopHost.app \
    --expected-source-commit FULL_SHA --headless --start-at-login --launch

Plain SSH cannot grant every required macOS TCC permission. Use
--ssh-permission-report for the exact breakdown.
Final acceptance uses the default Release host with a Release iPhone Air
Simulator; both resolve to Production CloudKit. Release installation requires
--host-artifact and --expected-source-commit. Debug remains a local source build.
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
    --host-artifact)
      host_artifact="${2:?Missing path for --host-artifact}"
      shift 2
      ;;
    --expected-source-commit)
      expected_source_commit="${2:?Missing SHA for --expected-source-commit}"
      shift 2
      ;;
    --install-dir)
      requested_install_dir="${2:?Missing path for --install-dir}"
      if [[ "$requested_install_dir" != "$install_dir" ]]; then
        echo "Refusing noncanonical install directory '$requested_install_dir'; Remote Desktop Host installs only in /Applications." >&2
        exit 64
      fi
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
repository_root="$(cd "$host_dir/.." && pwd)"
derived_data="$host_dir/build/DerivedData"
app_name="RemoteDesktopHost.app"
built_app="$derived_data/Build/Products/$configuration/$app_name"
installed_app="$install_dir/$app_name"
executable="$installed_app/Contents/MacOS/RemoteDesktopHost"
installed_runtime="$installed_app/Contents/Resources/ComputerUseRuntime/llama-b9992/llama-server"
bundle_id="com.threadmark.remotedesktop.host"

verify_release_artifact_selection() {
  local canonical_parent current_source_commit source_status

  if [[ "$configuration" == "Debug" ]]; then
    if [[ -n "$host_artifact" || -n "$expected_source_commit" ]]; then
      echo "--host-artifact and --expected-source-commit are Release-only; Debug builds locally with Apple Development signing." >&2
      return 1
    fi
    return 0
  fi

  if [[ "$skip_build" -eq 1 ]]; then
    echo "Release --skip-build is disabled; select an explicit prevalidated artifact with --host-artifact." >&2
    return 1
  fi
  if [[ -z "$host_artifact" || -z "$expected_source_commit" ]]; then
    echo "Release installation requires --host-artifact /absolute/path/RemoteDesktopHost.app and --expected-source-commit FULL_SHA." >&2
    return 1
  fi
  if [[ "$host_artifact" != /* ]]; then
    echo "Release --host-artifact must be an absolute path: $host_artifact" >&2
    return 1
  fi
  if [[ -L "$host_artifact" || ! -d "$host_artifact" \
        || "$(/usr/bin/basename "$host_artifact")" != "$app_name" ]]; then
    echo "Release --host-artifact must select a physical $app_name bundle." >&2
    return 1
  fi
  canonical_parent="$(cd "$(/usr/bin/dirname "$host_artifact")" && /bin/pwd -P)"
  built_app="$canonical_parent/$app_name"
  if [[ "$built_app" == "$installed_app" ]]; then
    echo "Release artifact must not be the installed destination itself: $installed_app" >&2
    return 1
  fi

  expected_source_commit="$(/bin/echo "$expected_source_commit" \
    | /usr/bin/tr '[:upper:]' '[:lower:]')"
  if [[ ! "$expected_source_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "--expected-source-commit must be one full 40-character Git commit." >&2
    return 1
  fi

  if /usr/bin/git -C "$repository_root" rev-parse --is-inside-work-tree \
      >/dev/null 2>&1; then
    current_source_commit="$(/usr/bin/git -C "$repository_root" \
      rev-parse --verify HEAD^{commit} 2>/dev/null \
      | /usr/bin/tr '[:upper:]' '[:lower:]')"
    if [[ "$current_source_commit" != "$expected_source_commit" ]]; then
      echo "Release artifact commit $expected_source_commit does not match checkout HEAD $current_source_commit." >&2
      return 1
    fi
    source_status="$(/usr/bin/git -C "$repository_root" status \
      --porcelain=v1 --untracked-files=normal)"
    if [[ -n "$source_status" ]]; then
      echo "Release current-source verification requires a clean checkout at $expected_source_commit." >&2
      return 1
    fi
  fi
}

verify_release_artifact_selection

validate_existing_installed_app() {
  if [[ "$installed_app" != "/Applications/$app_name" ]]; then
    echo "Refusing to inspect an unexpected install target: $installed_app" >&2
    return 1
  fi
  if [[ ! -e "$installed_app" && ! -L "$installed_app" ]]; then
    return 0
  fi

  local info_plist="$installed_app/Contents/Info.plist"
  local installed_executable="$installed_app/Contents/MacOS/RemoteDesktopHost"
  local installed_bundle_id
  if [[ -L "$installed_app" || ! -d "$installed_app" \
        || -L "$info_plist" || ! -f "$info_plist" \
        || -L "$installed_executable" || ! -f "$installed_executable" ]]; then
    echo "Refusing to replace an untrusted object at $installed_app." >&2
    return 1
  fi
  installed_bundle_id="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
  if [[ "$installed_bundle_id" != "$bundle_id" ]]; then
    echo "Refusing to replace $installed_app because its bundle identifier is '$installed_bundle_id'." >&2
    return 1
  fi
}

remove_validated_installed_app() {
  validate_existing_installed_app
  if [[ ! -e "$installed_app" && ! -L "$installed_app" ]]; then
    return 0
  fi
  /usr/bin/find -x "$installed_app" -depth -delete
  if [[ -e "$installed_app" || -L "$installed_app" ]]; then
    echo "Could not remove the validated previous host bundle safely: $installed_app" >&2
    return 1
  fi
}

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

if [[ "$configuration" == "Debug" && "$skip_build" -eq 0 ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    (cd "$host_dir" && xcodegen generate)
  fi

  xcodebuild \
    -project "$host_dir/RemoteDesktopHost.xcodeproj" \
    -scheme RemoteDesktopHost \
    -configuration "$configuration" \
    -derivedDataPath "$derived_data" \
    clean build
fi

if [[ ! -d "$built_app" ]]; then
  echo "Build product not found: $built_app" >&2
  exit 66
fi

trust_arguments=(--configuration "$configuration")
if [[ "$configuration" == "Release" ]]; then
  trust_arguments+=(--expected-source-commit "$expected_source_commit")
fi
"$script_dir/verify_host_bundle_trust.sh" \
  "${trust_arguments[@]}" \
  "$built_app"
verify_cloudkit_configuration
validate_existing_installed_app

built_executable="$built_app/Contents/MacOS/RemoteDesktopHost"
if [[ -L "$built_executable" || ! -x "$built_executable" ]]; then
  echo "Verified host artifact is missing its physical executable: $built_executable" >&2
  exit 66
fi
built_executable_sha256="$(/usr/bin/shasum -a 256 "$built_executable" \
  | /usr/bin/awk '{ print $1 }')"

# The replacement bundle has already passed trust verification. Stop only the
# exact installed executable image and its exact packaged runtime before
# replacing files, so launch can never leave an older same-bundle process alive.
terminate_exact_processes "$executable" "installed Remote Desktop Host"
terminate_exact_processes "$installed_runtime" "installed local AI runtime"

mkdir -p "$install_dir"
remove_validated_installed_app
/usr/bin/ditto "$built_app" "$installed_app"
installed_executable_sha256="$(/usr/bin/shasum -a 256 "$executable" \
  | /usr/bin/awk '{ print $1 }')"
if [[ "$installed_executable_sha256" != "$built_executable_sha256" ]]; then
  echo "Installed host executable hash differs from the verified source artifact." >&2
  exit 74
fi
"$script_dir/verify_host_bundle_trust.sh" \
  "${trust_arguments[@]}" \
  "$installed_app"
echo "Installed $installed_app"

if [[ "$headless" -eq 1 ]]; then
  defaults write "$bundle_id" StartListeningOnLaunch -bool true
  defaults delete "$bundle_id" PairingCodeFile >/dev/null 2>&1 || true
  # The installed host removes the retired fixed file at every production
  # launch through descriptor-pinned, no-follow validation. A path-based shell
  # deletion here could follow a substituted Application Support directory.
  echo "Headless mode enabled. Devices on the same Apple Account pair automatically."
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
