#!/usr/bin/env bash
set -euo pipefail

configuration="Auto"
expected_source_commit=""
app_bundle=""
expected_team_id="V9AX39SPJD"

usage() {
  cat >&2 <<USAGE
usage: $0 [--configuration Auto|Debug|Release] [--expected-source-commit SHA] /path/to/RemoteDesktopHost.app

Auto preserves the local-development trust policy: a valid Apple Development
bundle may run when it is not quarantined, while Developer ID bundles must be
notarized. Release is a distribution gate and additionally requires the exact
Developer ID team, hardened runtime, secure timestamps, reviewed Production
CloudKit entitlements, no task-debugging or APS entitlement, valid nested
signatures, a stapled notarization ticket, Gatekeeper acceptance, and signed
source-commit metadata.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --configuration." >&2
        usage
        exit 64
      fi
      configuration="$2"
      shift 2
      ;;
    --expected-source-commit)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --expected-source-commit." >&2
        usage
        exit 64
      fi
      expected_source_commit="$(/bin/echo "$2" | /usr/bin/tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 64
      ;;
    *)
      if [[ -n "$app_bundle" ]]; then
        echo "Specify exactly one host app bundle." >&2
        usage
        exit 64
      fi
      app_bundle="$1"
      shift
      ;;
  esac
done

case "$configuration" in
  Auto|Debug|Release)
    ;;
  *)
    echo "Unsupported configuration '$configuration'; expected Auto, Debug, or Release." >&2
    exit 64
    ;;
esac

if [[ -z "$app_bundle" || ! -d "$app_bundle" ]]; then
  usage
  exit 64
fi
if [[ -L "$app_bundle" ]]; then
  echo "Refusing a symlinked host app bundle: $app_bundle" >&2
  exit 64
fi
if [[ "$configuration" == "Release" ]]; then
  if [[ ! "$expected_source_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Release verification requires --expected-source-commit with one full 40-character Git commit." >&2
    exit 64
  fi
elif [[ -n "$expected_source_commit" ]]; then
  echo "--expected-source-commit is supported only with --configuration Release." >&2
  exit 64
fi

app_bundle="$(cd "$(/usr/bin/dirname "$app_bundle")" && /bin/pwd -P)/$(/usr/bin/basename "$app_bundle")"
info_plist="$app_bundle/Contents/Info.plist"
main_executable="$app_bundle/Contents/MacOS/RemoteDesktopHost"
if [[ -L "$info_plist" || ! -f "$info_plist" ]]; then
  echo "Host bundle is missing a physical Info.plist: $info_plist" >&2
  exit 65
fi
if [[ -L "$main_executable" || ! -x "$main_executable" ]]; then
  echo "Host bundle is missing its physical executable: $main_executable" >&2
  exit 65
fi

bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)"
if [[ "$bundle_identifier" != "com.threadmark.remotedesktop.host" ]]; then
  echo "Host bundle has an unexpected bundle identifier: $bundle_identifier" >&2
  exit 65
fi
if [[ "$configuration" == "Release" ]]; then
  artifact_source_commit="$(/usr/bin/plutil \
    -extract RemoteDesktopSourceCommit raw -o - "$info_plist" \
    2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' || true)"
  if [[ "$artifact_source_commit" != "$expected_source_commit" ]]; then
    echo "Release host source provenance mismatch: signed metadata='$artifact_source_commit', expected='$expected_source_commit'." >&2
    exit 65
  fi
fi

signature_details="$(/usr/bin/codesign -dvvv "$app_bundle" 2>&1 || true)"
signature_verification=""
signature_is_valid=0
if [[ "$signature_details" != *"Signature=adhoc"* ]] && \
   signature_verification="$(/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle" 2>&1)"; then
  signature_is_valid=1
fi
if [[ "$signature_details" == *"Signature=adhoc"* ]] || \
   [[ "$signature_is_valid" -ne 1 ]]; then
  [[ -n "$signature_verification" ]] && printf '%s\n' "$signature_verification" >&2
  echo "Host bundle is unsigned, ad-hoc, revoked, or otherwise invalid: $app_bundle" >&2
  exit 66
fi

certificate_dir="$(/usr/bin/mktemp -d /tmp/remotedesktop-signing-certificate.XXXXXX)"
entitlements_file="$(/usr/bin/mktemp /tmp/remotedesktop-host-entitlements.XXXXXX)"
cleanup() {
  case "$certificate_dir" in
    /tmp/remotedesktop-signing-certificate.*)
      if [[ -d "$certificate_dir" ]]; then
        /usr/bin/find -x "$certificate_dir" -depth -delete
      fi
      ;;
  esac
  case "$entitlements_file" in
    /tmp/remotedesktop-host-entitlements.*)
      /bin/rm -f "$entitlements_file"
      ;;
  esac
}
trap cleanup EXIT

if ! (cd "$certificate_dir" && /usr/bin/codesign -d --extract-certificates "$app_bundle" >/dev/null 2>&1) ||
   ! /usr/bin/security verify-cert \
     -c "$certificate_dir/codesign0" \
     -p codeSign \
     -R ocsp \
     -R require \
     -q; then
  echo "Host signing certificate is expired, revoked, or untrusted: $app_bundle" >&2
  exit 67
fi

has_secure_timestamp() {
  local details="$1"
  [[ "$details" == *"Timestamp="* && "$details" != *"Timestamp=none"* ]]
}

verify_release_identity_and_runtime() {
  local code_path="$1"
  local code_label="$2"
  local details

  if ! /usr/bin/codesign --verify --strict --verbose=2 "$code_path" >/dev/null 2>&1; then
    echo "$code_label has an invalid nested code signature: $code_path" >&2
    return 1
  fi
  details="$(/usr/bin/codesign -dvvv "$code_path" 2>&1 || true)"
  if [[ "$details" != *"Authority=Developer ID Application:"* \
        || "$details" != *"TeamIdentifier=$expected_team_id"* ]]; then
    echo "$code_label is not signed by Developer ID Application team $expected_team_id: $code_path" >&2
    return 1
  fi
  if ! /usr/bin/printf '%s\n' "$details" \
      | /usr/bin/grep -Eq \
          'flags=[^[:space:]]*\(([^,]+,)*runtime(,[^,]+)*\)'; then
    echo "$code_label is missing the hardened runtime: $code_path" >&2
    return 1
  fi
  if ! has_secure_timestamp "$details"; then
    echo "$code_label is missing a secure timestamp: $code_path" >&2
    return 1
  fi
}

read_entitlement() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements_file" 2>/dev/null || true
}

has_entitlement() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements_file" >/dev/null 2>&1
}

verify_release_entitlements() {
  local cloudkit_environment container extra_container service extra_service
  if ! /usr/bin/codesign -d --entitlements :- "$app_bundle" \
      >"$entitlements_file" 2>/dev/null \
      || ! /usr/bin/plutil -lint "$entitlements_file" >/dev/null; then
    echo "Could not read the Release host entitlements: $app_bundle" >&2
    return 1
  fi

  if has_entitlement "get-task-allow" \
      || has_entitlement "com.apple.security.get-task-allow"; then
    echo "Release host must not contain a get-task-allow entitlement." >&2
    return 1
  fi
  if has_entitlement "aps-environment" \
      || has_entitlement "com.apple.developer.aps-environment"; then
    echo "Polling-only Release host must not contain an APS entitlement." >&2
    return 1
  fi

  cloudkit_environment="$(read_entitlement com.apple.developer.icloud-container-environment)"
  container="$(read_entitlement com.apple.developer.icloud-container-identifiers:0)"
  extra_container="$(read_entitlement com.apple.developer.icloud-container-identifiers:1)"
  service="$(read_entitlement com.apple.developer.icloud-services:0)"
  extra_service="$(read_entitlement com.apple.developer.icloud-services:1)"
  if [[ "$cloudkit_environment" != "Production" \
        || "$container" != "iCloud.com.threadmark.remotedesktop" \
        || -n "$extra_container" \
        || "$service" != "CloudKit" \
        || -n "$extra_service" ]]; then
    echo "Release host has unreviewed CloudKit entitlements: environment='$cloudkit_environment', container='$container', service='$service'." >&2
    return 1
  fi
  if [[ "$(read_entitlement com.apple.security.automation.apple-events)" != "true" \
        || "$(read_entitlement com.apple.security.device.audio-input)" != "true" ]]; then
    echo "Release host is missing its reviewed Apple Events or audio-input entitlement." >&2
    return 1
  fi
}

if [[ "$configuration" == "Release" ]]; then
  verify_release_identity_and_runtime "$app_bundle" "Release host"
  verify_release_entitlements

  while IFS= read -r -d '' nested_code; do
    if [[ "$nested_code" == "$main_executable" ]] \
        || [[ "$(/usr/bin/file -b "$nested_code")" != *"Mach-O"* ]]; then
      continue
    fi
    verify_release_identity_and_runtime "$nested_code" "Nested Release code"
  done < <(/usr/bin/find "$app_bundle/Contents" -type f -print0)

  stapler_assessment="$(/usr/bin/xcrun stapler validate "$app_bundle" 2>&1)" || {
    printf '%s\n' "$stapler_assessment" >&2
    echo "Release host does not contain a valid stapled notarization ticket: $app_bundle" >&2
    exit 68
  }
  gatekeeper_assessment="$(/usr/sbin/spctl --assess --type execute --verbose=4 "$app_bundle" 2>&1)" || {
    printf '%s\n' "$gatekeeper_assessment" >&2
    echo "Release host is not accepted by Gatekeeper: $app_bundle" >&2
    exit 68
  }
  gatekeeper_assessment_lower="$(/bin/echo "$gatekeeper_assessment" \
    | /usr/bin/tr '[:upper:]' '[:lower:]')"
  if [[ "$gatekeeper_assessment_lower" != *"source=notarized developer id"* ]]; then
    printf '%s\n' "$gatekeeper_assessment" >&2
    echo "Release host Gatekeeper assessment did not prove notarized Developer ID provenance: $app_bundle" >&2
    exit 68
  fi
elif [[ "$signature_details" == *"Authority=Developer ID Application:"* ]]; then
  stapler_assessment="$(/usr/bin/xcrun stapler validate "$app_bundle" 2>&1)" || {
    printf '%s\n' "$stapler_assessment" >&2
    echo "Developer ID host does not contain a valid stapled notarization ticket: $app_bundle" >&2
    exit 68
  }
  gatekeeper_assessment="$(/usr/sbin/spctl --assess --type execute --verbose=2 "$app_bundle" 2>&1)" || {
    printf '%s\n' "$gatekeeper_assessment" >&2
    echo "Developer ID host is not accepted by Gatekeeper: $app_bundle" >&2
    exit 68
  }
elif [[ "$signature_details" == *"Authority=Apple Development:"* ]]; then
  if /usr/bin/xattr -p com.apple.quarantine "$app_bundle" >/dev/null 2>&1; then
    echo "A quarantined Apple Development build cannot be launched safely. Use Xcode or a notarized Developer ID build: $app_bundle" >&2
    exit 69
  fi
else
  echo "Host is not signed with an allowed Apple Development or Developer ID Application identity: $app_bundle" >&2
  exit 70
fi

echo "Verified trusted $configuration host bundle: $app_bundle"
