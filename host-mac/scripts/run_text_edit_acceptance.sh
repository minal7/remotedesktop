#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_dir="$(mktemp -d /tmp/remotedesktop-text-fixture.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
bundle="$fixture_dir/ComputerUseTextFixture.app"
mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.threadmark.remotedesktop.text-fixture</string>
<key>CFBundleName</key><string>Computer Use Text Fixture</string>
<key>CFBundleExecutable</key><string>ComputerUseTextFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 "$ROOT/host-mac/AcceptanceFixtures/TextEditingFixture.swift" \
    -o "$bundle/Contents/MacOS/ComputerUseTextFixture"
# This local fixture is not a production host or bundled model runtime.
codesign --force --sign - "$bundle"
cd "$ROOT"
RUN_COMPUTER_USE_NATIVE_TEXT_ACCEPTANCE=1 \
COMPUTER_USE_TEXT_FIXTURE_EXECUTABLE="$bundle/Contents/MacOS/ComputerUseTextFixture" \
    swift test --force-resolved-versions \
    --scratch-path "${COMPUTER_USE_TEST_BUILD_PATH:-$ROOT/.build}" \
    --filter 'ComputerUse(NativeTextIntegration|TextEditor|LiteralPayload|ObservationWorker)Tests'
