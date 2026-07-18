#!/usr/bin/env bash
set -euo pipefail

HOST_CONFIGURATION="${1:-Release}"
IOS_CONFIGURATION="${2:-$HOST_CONFIGURATION}"

usage() {
  echo "usage: $0 [Debug|Release] [matching-iOS-configuration]" >&2
}

case "$HOST_CONFIGURATION" in
  Debug|Release) ;;
  *) usage; exit 2 ;;
esac
case "$IOS_CONFIGURATION" in
  Debug|Release) ;;
  *) usage; exit 2 ;;
esac
if [[ "$HOST_CONFIGURATION" != "$IOS_CONFIGURATION" ]]; then
  echo "Refusing mixed Apple configurations: macOS=$HOST_CONFIGURATION, iOS=$IOS_CONFIGURATION." >&2
  echo "Use Release/Release for Production acceptance or Debug/Debug for diagnostics." >&2
  exit 2
fi

case "$HOST_CONFIGURATION" in
  Debug) EXPECTED_ENVIRONMENT="Development" ;;
  Release) EXPECTED_ENVIRONMENT="Production" ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

read_cloudkit_environment() {
  local project="$1"
  local target="$2"
  local configuration="$3"
  local output
  output="$(xcodebuild \
    -project "$project" \
    -target "$target" \
    -configuration "$configuration" \
    -showBuildSettings \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile)"
  /usr/bin/awk -F ' = ' \
    '$1 ~ /^[[:space:]]*ICLOUD_CONTAINER_ENVIRONMENT$/ { print $2; exit }' \
    <<<"$output"
}

HOST_ENVIRONMENT="$(read_cloudkit_environment \
  "$ROOT_DIR/host-mac/RemoteDesktopHost.xcodeproj" \
  RemoteDesktopHost \
  "$HOST_CONFIGURATION")"
IOS_ENVIRONMENT="$(read_cloudkit_environment \
  "$ROOT_DIR/ios/RemoteDesktop.xcodeproj" \
  RemoteDesktop \
  "$IOS_CONFIGURATION")"

if [[ "$HOST_ENVIRONMENT" != "$EXPECTED_ENVIRONMENT" ]]; then
  echo "macOS $HOST_CONFIGURATION resolves CloudKit '$HOST_ENVIRONMENT'; expected $EXPECTED_ENVIRONMENT." >&2
  exit 1
fi
if [[ "$IOS_ENVIRONMENT" != "$EXPECTED_ENVIRONMENT" ]]; then
  echo "iOS $IOS_CONFIGURATION resolves CloudKit '$IOS_ENVIRONMENT'; expected $EXPECTED_ENVIRONMENT." >&2
  exit 1
fi

echo "Verified macOS $HOST_CONFIGURATION + iOS $IOS_CONFIGURATION -> $EXPECTED_ENVIRONMENT CloudKit."
