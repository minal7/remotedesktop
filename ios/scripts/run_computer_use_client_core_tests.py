#!/usr/bin/env python3
"""Run real, platform-independent client sources on macOS, without Simulator.

This does not qualify SwiftUI, Keychain behavior, transport authentication, or
the phone/host/model flow. Compile and run the iOS app separately for those.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", type=Path, required=True)
    parser.add_argument("--run-label", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", args.run_label):
        parser.error("run-label must contain only letters, digits, underscores and hyphens")
    root = Path(__file__).resolve().parents[2]
    scratch = args.scratch_path.resolve()
    sources = sorted((root / "protocol/Swift").glob("*.swift"))
    # Video quality is the only shared source requiring the WebRTC binary;
    # it is not used by this client task-state and wire-protocol test target.
    sources = [p for p in sources if p.name != "DesktopVideoQuality.swift"]
    sources += [root / "ios/RemoteDesktop/ComputerUse" / name for name in
                ["ComputerUseSessionModel.swift", "ComputerUsePendingPromptStore.swift"]]
    tests = [root / "ios/RemoteDesktopTests/ComputerUseClarificationClientTests.swift"]
    tracked = sources + tests
    hashes = {str(p.relative_to(root)): digest(p) for p in tracked}
    manifest_path = root / "ios/AcceptanceFixtures/computer-use-client-core-tests.json"
    manifest = json.loads(manifest_path.read_text())
    discovered = {"RemoteDesktopTests/ComputerUseClarificationClientTests/" + name
                  for name in re.findall(r"func\s+(test\w+)\s*\(", tests[0].read_text())}
    if (manifest["selectors"] != ["RemoteDesktopTests/ComputerUseClarificationClientTests"]
            or discovered != set(manifest["expectedTests"])
            or len(manifest["expectedTests"]) != len(discovered)):
        parser.error("client test source differs from the reviewed inventory")
    expected = sorted(name.removeprefix("RemoteDesktopTests/") for name in manifest["expectedTests"])
    package = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "RemoteDesktopClientCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "RemoteDesktop", swiftSettings: [.unsafeFlags(["-strict-concurrency=targeted"])]),
    .testTarget(name: "RemoteDesktopTests", dependencies: ["RemoteDesktop"],
        swiftSettings: [.unsafeFlags(["-strict-concurrency=targeted"])])
], swiftLanguageVersions: [.v5])
'''
    package_path = scratch / "Package.swift"
    if package_path.exists() and package_path.read_text() != package:
        parser.error("scratch-path contains a different package; choose a new directory")
    for directory, files in [(scratch / "Sources/RemoteDesktop", sources),
                             (scratch / "Tests/RemoteDesktopTests", tests)]:
        directory.mkdir(parents=True, exist_ok=True)
        for source in files:
            link = directory / source.name
            if link.is_symlink() and link.resolve() == source:
                continue
            if link.exists() or link.is_symlink():
                parser.error(f"scratch source already exists with different contents: {link}")
            link.symlink_to(source)
    package_path.write_text(package)
    log = scratch / f"{args.run_label}.log"
    xml = scratch / f"{args.run_label}.xml"
    report_path = scratch / f"{args.run_label}-results.json"
    if any(p.exists() for p in [log, xml, report_path]):
        parser.error("run-label already exists; use a new label to preserve prior evidence")
    command = ["swift", "test", "--package-path", str(scratch), "--disable-sandbox", "--jobs", "2",
               "--disable-swift-testing", "--parallel", "--num-workers", "1",
               "--filter", "ComputerUseClarificationClientTests", "--xunit-output", str(xml)]
    with log.open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    observed = []
    if xml.exists():
        for case in ET.parse(xml).getroot().iter("testcase"):
            observed.append({"id": case.attrib.get("classname", "").split(".")[-1] + "/"
                             + case.attrib.get("name", "").removesuffix("()"),
                             "passed": all(case.find(tag) is None for tag in ["failure", "error", "skipped"]),
                             "seconds": case.attrib.get("time")})
    unchanged = hashes == {str(p.relative_to(root)): digest(p) for p in tracked}
    passed = (result.returncode == 0 and unchanged and len(observed) == len(expected)
              and sorted(item["id"] for item in observed) == expected
              and all(item["passed"] for item in observed))
    report = {"schemaVersion": 1, "scope": "Actual client state/protocol sources on macOS; no mobile UI or live transport qualification.",
              "passed": passed, "commandExitCode": result.returncode, "sourceUnchangedDuringRun": unchanged,
              "sourceSHA256": hashes, "expectedTests": expected, "observedTests": observed,
              "inventorySnapshot": manifest, "inventorySHA256": digest(manifest_path),
              "command": command, "log": str(log), "xunit": str(xml)}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"{'PASS' if passed else 'FAIL'}: {len(observed)} observed client core tests; report: {report_path}")
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
