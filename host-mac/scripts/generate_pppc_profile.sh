#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  generate_pppc_profile.sh /Applications/RemoteDesktopHost.app ./RemoteDesktopHost.pppc.mobileconfig

Generates a Privacy Preferences Policy Control payload for MDM deployment.
Apple allows Accessibility/PostEvent to be allowed by PPPC. ScreenCapture and
Microphone cannot be silently granted by a local script; ScreenCapture is set to
AllowStandardUserToSetSystemService so a managed standard user may approve it.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 64
fi

app_path="$1"
output_path="$2"

if [[ ! -d "$app_path" ]]; then
  echo "App not found: $app_path" >&2
  exit 66
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
requirement="$(codesign -dr - "$app_path" 2>&1 | sed -n 's/^designated => //p')"

if [[ -z "$bundle_id" || -z "$requirement" ]]; then
  echo "Could not read bundle id or code requirement from $app_path" >&2
  exit 65
fi

xml_escape() {
  /usr/bin/python3 -c 'import html,sys; print(html.escape(sys.stdin.read().strip(), quote=True))'
}

escaped_bundle_id="$(printf '%s' "$bundle_id" | xml_escape)"
escaped_requirement="$(printf '%s' "$requirement" | xml_escape)"
profile_uuid="$(uuidgen)"
payload_uuid="$(uuidgen)"
profile_identifier="com.threadmark.remotedesktop.host.pppc.$profile_uuid"
payload_identifier="$profile_identifier.tcc"

mkdir -p "$(dirname "$output_path")"

cat > "$output_path" <<PROFILE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadDescription</key>
      <string>Remote Desktop Host privacy preferences</string>
      <key>PayloadDisplayName</key>
      <string>Remote Desktop Host PPPC</string>
      <key>PayloadIdentifier</key>
      <string>$payload_identifier</string>
      <key>PayloadOrganization</key>
      <string>Threadmark</string>
      <key>PayloadType</key>
      <string>com.apple.TCC.configuration-profile-policy</string>
      <key>PayloadUUID</key>
      <string>$payload_uuid</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Services</key>
      <dict>
        <key>Accessibility</key>
        <array>
          <dict>
            <key>Allowed</key>
            <true/>
            <key>CodeRequirement</key>
            <string>$escaped_requirement</string>
            <key>Comment</key>
            <string>Allows Remote Desktop Host to drive Accessibility APIs.</string>
            <key>Identifier</key>
            <string>$escaped_bundle_id</string>
            <key>IdentifierType</key>
            <string>bundleID</string>
          </dict>
        </array>
        <key>PostEvent</key>
        <array>
          <dict>
            <key>Allowed</key>
            <true/>
            <key>CodeRequirement</key>
            <string>$escaped_requirement</string>
            <key>Comment</key>
            <string>Allows Remote Desktop Host to post CoreGraphics input events.</string>
            <key>Identifier</key>
            <string>$escaped_bundle_id</string>
            <key>IdentifierType</key>
            <string>bundleID</string>
          </dict>
        </array>
        <key>ScreenCapture</key>
        <array>
          <dict>
            <key>Authorization</key>
            <string>AllowStandardUserToSetSystemService</string>
            <key>CodeRequirement</key>
            <string>$escaped_requirement</string>
            <key>Comment</key>
            <string>Lets a managed standard user approve Screen Recording for Remote Desktop Host.</string>
            <key>Identifier</key>
            <string>$escaped_bundle_id</string>
            <key>IdentifierType</key>
            <string>bundleID</string>
          </dict>
        </array>
      </dict>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>Deploy through user-approved MDM. Local scripts cannot silently grant Screen Recording or Microphone.</string>
  <key>PayloadDisplayName</key>
  <string>Remote Desktop Host Privacy Preferences</string>
  <key>PayloadIdentifier</key>
  <string>$profile_identifier</string>
  <key>PayloadOrganization</key>
  <string>Threadmark</string>
  <key>PayloadScope</key>
  <string>System</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$profile_uuid</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
PROFILE

plutil -lint "$output_path" >/dev/null
echo "Wrote $output_path"
echo "Deploy this profile through user-approved MDM before first launch."
