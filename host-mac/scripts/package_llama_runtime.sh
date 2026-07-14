#!/usr/bin/env bash
set -euo pipefail

# Xcode executes this as the final target build phase, before it signs the
# enclosing .app. The source payload is repository-local and checksum-pinned;
# this script deliberately contains no network or archive extraction path.

required_variables=(
  SRCROOT
  TARGET_BUILD_DIR
  UNLOCALIZED_RESOURCES_FOLDER_PATH
  EXPANDED_CODE_SIGN_IDENTITY
)
for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Missing required Xcode build variable: $variable" >&2
    exit 65
  fi
done

source_root="$SRCROOT/ThirdPartyRuntime/llama-b9992"
manifest="$source_root/runtime-manifest.json"
verifier="$SRCROOT/scripts/verify_llama_runtime.py"
destination_root="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ComputerUseRuntime/llama-b9992"

/usr/bin/python3 "$verifier" \
  --root "$source_root" \
  --manifest "$manifest"

# Source verification above proves that this closed directory contains only
# the manifest's allowlisted real files and relative symlinks. ditto preserves
# those symlinks; it never follows them into an unexpected path.
/bin/rm -rf "$destination_root"
/bin/mkdir -p "$(/usr/bin/dirname "$destination_root")"
/usr/bin/ditto --noqtn "$source_root" "$destination_root"

/usr/bin/python3 "$verifier" \
  --root "$destination_root" \
  --manifest "$manifest"

signing_identity="$EXPANDED_CODE_SIGN_IDENTITY"
if [[ "$signing_identity" == "-" ]]; then
  echo "A real host signing identity is required for the bundled llama runtime." >&2
  exit 65
fi

# `codesign --verify` can accept a cryptographically intact signature whose
# leaf certificate was later revoked. Prove the actual identity Xcode selected
# with mandatory OCSP before it is applied to any bundled executable.
certificate_probe_dir="$(/usr/bin/mktemp -d /tmp/remotedesktop-runtime-signing.XXXXXX)"
cleanup_certificate_probe() {
  /bin/rm -rf "$certificate_probe_dir"
}
trap cleanup_certificate_probe EXIT
/bin/cp /usr/bin/true "$certificate_probe_dir/signing-probe"
/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp=none \
  "$certificate_probe_dir/signing-probe" >/dev/null 2>&1
(
  cd "$certificate_probe_dir"
  /usr/bin/codesign -d --extract-certificates signing-probe >/dev/null 2>&1
)
if ! /usr/bin/security verify-cert \
  -c "$certificate_probe_dir/codesign0" \
  -p codeSign \
  -R ocsp \
  -R require \
  -q; then
  echo "The selected code-signing certificate is expired, revoked, or untrusted." >&2
  exit 65
fi
/bin/rm -rf "$certificate_probe_dir"
trap - EXIT

signing_name="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:-}}"
timestamp_option="--timestamp=none"
if [[ "$signing_name" == *"Developer ID Application"* ]]; then
  timestamp_option="--timestamp"
fi

# Sign dylibs before the executable that loads them. Symlink aliases are not
# signed separately because they resolve to the already signed real files.
while IFS= read -r runtime_file; do
  /usr/bin/codesign \
    --force \
    --sign "$signing_identity" \
    --options runtime \
    "$timestamp_option" \
    "$runtime_file"
done < <(/usr/bin/find "$destination_root" -maxdepth 1 -type f -name '*.dylib' -print | /usr/bin/sort)

/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --options runtime \
  "$timestamp_option" \
  "$destination_root/llama-server"

/usr/bin/python3 "$verifier" \
  --root "$destination_root" \
  --manifest "$manifest" \
  --signed \
  --expected-team "${DEVELOPMENT_TEAM:-}"
