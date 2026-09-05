#!/bin/bash
set -euo pipefail
audit_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$audit_dir/../../.." && pwd)"
scratch_dir="$(mktemp -d /tmp/remotedesktop-policy-probe.XXXXXX)"
trap 'rm -rf "$scratch_dir"' EXIT
xcrun swiftc -swift-version 5 \
  "$repo_dir/host-mac/RemoteDesktopHost/ComputerUse/ComputerUseRuntimeTypes.swift" \
  "$repo_dir/host-mac/RemoteDesktopHost/ComputerUse/ComputerUseActionSafetyPolicy.swift" \
  "$repo_dir/host-mac/RemoteDesktopHost/WireFormat.swift" \
  "$repo_dir/host-mac/RemoteDesktopHost/HostConfig.swift" \
  "$repo_dir/host-mac/RemoteDesktopHost/HIDUsage.swift" \
  "$repo_dir/host-mac/RemoteDesktopHost/InputInjector.swift" \
  "$audit_dir/policy-probe.swift" \
  -o "$scratch_dir/policy-probe"
"$scratch_dir/policy-probe"
