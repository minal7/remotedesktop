#!/usr/bin/env bash
set -euo pipefail

app_bundle="${1:-}"
if [[ -z "$app_bundle" || ! -d "$app_bundle" ]]; then
  echo "usage: $0 /path/to/RemoteDesktopHost.app" >&2
  exit 64
fi
app_bundle="$(cd "$(/usr/bin/dirname "$app_bundle")" && /bin/pwd -P)/$(/usr/bin/basename "$app_bundle")"

main_executable="$app_bundle/Contents/MacOS/RemoteDesktopHost"
if [[ ! -x "$main_executable" ]]; then
  echo "Host bundle is missing its executable: $main_executable" >&2
  exit 65
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
cleanup() {
  /bin/rm -rf "$certificate_dir"
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

if [[ "$signature_details" == *"Authority=Developer ID Application:"* ]]; then
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

echo "Verified trusted host bundle: $app_bundle"
