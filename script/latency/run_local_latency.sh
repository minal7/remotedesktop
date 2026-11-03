#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LATENCY_BUILD="${LATENCY_BUILD:-/tmp/remotedesktop-latency-probe}"
: "${DEVELOPER_DIR:=$(xcode-select -p)}"
export DEVELOPER_DIR
if [[ -z "${WEBRTC_FRAMEWORK_DIR:-}" ]]; then
  WEBRTC_FRAMEWORK_DIR="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/macos-arm64_x86_64/LiveKitWebRTC.framework' -type d -print -quit)"
  WEBRTC_FRAMEWORK_DIR="$(dirname "$WEBRTC_FRAMEWORK_DIR")"
fi
[[ -f "$WEBRTC_FRAMEWORK_DIR/LiveKitWebRTC.framework/Headers/RTCPeerConnection.h" ]] || { echo "Set WEBRTC_FRAMEWORK_DIR to the cached macOS WebRTC artifact's parent directory." >&2; exit 1; }
python3 - "$ROOT" "$WEBRTC_FRAMEWORK_DIR" <<'PYVERSION'
import json, sys
from pathlib import Path
root, framework_parent = map(Path, sys.argv[1:])
resolved = json.loads((root / 'host-mac/RemoteDesktopHost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
pin = next(p['state'] for p in resolved['pins'] if p['identity'] == 'webrtc-xcframework')
source_packages = next((p for p in framework_parent.parents if p.name == 'SourcePackages'), None)
if source_packages is None:
    raise SystemExit('Framework must come from a versioned SourcePackages cache.')
state = json.loads((source_packages / 'workspace-state.json').read_text())['object']
dep = next(d['state']['checkoutState'] for d in state['dependencies'] if d['packageRef']['identity'] == 'webrtc-xcframework')
if dep['revision'] != pin['revision']:
    raise SystemExit(f"Cached WebRTC revision differs from project pin: {dep} vs {pin}")
print(f"Using project-pinned WebRTC {pin['version']}")
PYVERSION
export LATENCY_OUTPUT="${LATENCY_OUTPUT:-$LATENCY_BUILD/results-$(date -u +%Y%m%dT%H%M%SZ).json}"
[[ ! -e "$LATENCY_OUTPUT" ]] || { echo "Output already exists; choose a new LATENCY_OUTPUT." >&2; exit 1; }
APP="$LATENCY_BUILD/LocalLatencyProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
ln -sfn "$WEBRTC_FRAMEWORK_DIR/LiveKitWebRTC.framework" "$APP/Contents/Frameworks/LiveKitWebRTC.framework"
cp "$ROOT/script/latency/LocalLatencyProbe.swift" "$LATENCY_BUILD/main.swift"
xcrun swiftc -O -swift-version 5 -F "$WEBRTC_FRAMEWORK_DIR" -framework LiveKitWebRTC \
  -Xlinker -rpath -Xlinker "$WEBRTC_FRAMEWORK_DIR" \
  "$ROOT/host-mac/RemoteDesktopHost/WebRTCAliases.swift" \
  "$ROOT/host-mac/RemoteDesktopHost/WireFormat.swift" \
  "$ROOT/host-mac/RemoteDesktopHost/HostConfig.swift" \
  "$ROOT/protocol/Swift/DesktopVideoQuality.swift" \
  "$ROOT/protocol/Swift/DirectInputSessionProtocol.swift" \
  "$ROOT/host-mac/RemoteDesktopHost/HostRuntimeContext.swift" \
  "$ROOT/host-mac/RemoteDesktopHost/ScreenCapture.swift" \
  "$LATENCY_BUILD/main.swift" -o "$APP/Contents/MacOS/LocalLatencyProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.threadmark.remotedesktop.latencyprobe</string><key>CFBundleName</key><string>Local Latency Probe</string><key>CFBundleExecutable</key><string>LocalLatencyProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
[[ "${LATENCY_BUILD_ONLY:-0}" != "1" ]] || exit 0
# Run the diagnostic bundle under the invoking terminal's existing Screen Recording
# permission. This does not grant or alter TCC permissions; the probe fails closed.
export LATENCY_SECONDS="${LATENCY_SECONDS:-60}"
"$APP/Contents/MacOS/LocalLatencyProbe" "$@" > "$LATENCY_BUILD/run.log" 2> "$LATENCY_BUILD/run.err"
cat "$LATENCY_BUILD/run.log"
python3 - "$LATENCY_OUTPUT" <<'PYVERIFY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    raise SystemExit("No latency result was produced; inspect run.log and run.err.")
d = json.loads(p.read_text())
if d['source_marker_count'] < 10 or d['viewer_marker_count'] != d['source_marker_count']:
    raise SystemExit("Incomplete marker coverage; result requires investigation.")
PYVERIFY
