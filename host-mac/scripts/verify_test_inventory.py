#!/usr/bin/env python3
"""Validate a reviewed XCTest inventory against source and executed identifiers.

Counts alone accept the wrong tests and stale counts reject newly added tests.
The checked-in manifest records selectors and the exact expected identifiers.
Source validation is an early drift check; xcresult remains execution evidence.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess


class InventoryError(ValueError):
    pass


def load_manifest(path: Path) -> dict:
    value = json.loads(path.read_text())
    for key in ("selectors", "expectedTests"):
        entries = value.get(key)
        if not isinstance(entries, list) or not entries or not all(
            isinstance(entry, str) and re.fullmatch(
                r"[A-Za-z_]\w*/[A-Za-z_]\w*(?:/test\w+)?", entry
            ) for entry in entries
        ) or len(entries) != len(set(entries)):
            raise InventoryError(f"Invalid or duplicate {key}")
    if any(entry.count("/") != 2 for entry in value["expectedTests"]):
        raise InventoryError("Expected tests must be complete target/class/method identifiers")
    return value


def selected_source_tests(manifest: dict, root: Path, *,
                          source_directory: Path = Path("host-mac/RemoteDesktopHostTests"),
                          target: str = "RemoteDesktopHostTests") -> set[str]:
    if not re.fullmatch(r"[A-Za-z_]\w*", target):
        raise InventoryError("Invalid XCTest target name")
    discovered: set[str] = set()
    for source in sorted((root / source_directory).glob("*.swift")):
        text = source.read_text()
        # XCTest methods in this target are ordinary, zero-argument Swift
        # methods, indented inside top-level XCTestCase classes. Do not use this
        # source check as a replacement for XCTest runtime discovery/results.
        boundaries = list(re.finditer(
            r"^(?:(?:private|final|public|internal)\s+)*(?:class|struct|enum|actor)\s+\w+[^\n]*", text, re.M))
        for index, boundary in enumerate(boundaries):
            match = re.search(r"class\s+(\w+)\s*:\s*XCTestCase\b", boundary.group())
            if not match:
                continue
            end = boundaries[index + 1].start() if index + 1 < len(boundaries) else len(text)
            for method in re.findall(r"^    func (test\w+)\s*\(\s*\)", text[boundary.end():end], re.M):
                identifier = f"{target}/{match.group(1)}/{method}"
                if identifier in discovered:
                    raise InventoryError(f"Duplicate source test: {identifier}")
                discovered.add(identifier)
    selected: set[str] = set()
    for selector in manifest["selectors"]:
        matches = {test for test in discovered if test == selector or test.startswith(selector + "/")}
        if not matches:
            raise InventoryError(f"Selector matches no source tests: {selector}")
        selected.update(matches)
    return selected


def compare(expected: set[str], observed: set[str], label: str) -> None:
    missing, unexpected = expected - observed, observed - expected
    if missing or unexpected:
        raise InventoryError(
            f"{label} inventory drift. Missing: {sorted(missing)}; unexpected: {sorted(unexpected)}")


def executed_tests(report: dict) -> dict[str, str]:
    found: dict[str, str] = {}

    def visit(node: dict, bundle: str | None = None) -> None:
        if node.get("nodeType") in {"Unit test bundle", "UI test bundle"}:
            bundle = node["name"].removesuffix(".xctest")
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier", "").removesuffix("()")
            if not bundle or not identifier:
                raise InventoryError("Test case lacks bundle or identifier")
            if identifier.startswith(bundle + "."):
                identifier = identifier[len(bundle) + 1:]
            if not identifier.startswith(bundle + "/"):
                identifier = bundle + "/" + identifier
            if not re.fullmatch(r"[A-Za-z_]\w*/[A-Za-z_]\w*/test\w+", identifier):
                raise InventoryError(f"Unrecognized test identifier: {identifier}")
            if identifier in found:
                raise InventoryError(f"Duplicate executed test: {identifier}")
            found[identifier] = node.get("result", "unknown")
        for child in node.get("children", []):
            visit(child, bundle)

    for node in report.get("testNodes", []):
        visit(node)
    return found


def verify_result(manifest: dict, summary: dict, report: dict) -> None:
    expected = set(manifest["expectedTests"])
    executed = executed_tests(report)
    compare(expected, set(executed), "Executed")
    nonpassing = {key: result for key, result in executed.items() if result != "Passed"}
    if nonpassing:
        raise InventoryError(f"Tests did not pass: {nonpassing}")
    required = {"result": "Passed", "totalTestCount": len(expected),
                "passedTests": len(expected), "failedTests": 0,
                "skippedTests": 0, "expectedFailures": 0}
    if any(summary.get(key) != value for key, value in required.items()):
        raise InventoryError("xcresult summary does not prove one passing run of every expected test")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True, help="Repository root")
    parser.add_argument("--test-source-directory", type=Path,
                        default=Path("host-mac/RemoteDesktopHostTests"),
                        help="Test sources relative to the repository root")
    parser.add_argument("--test-target", default="RemoteDesktopHostTests")
    parser.add_argument("--selectors", action="store_true")
    parser.add_argument("--result", type=Path)
    args = parser.parse_args()
    manifest = load_manifest(args.manifest)
    compare(set(manifest["expectedTests"]), selected_source_tests(manifest, args.source_root,
        source_directory=args.test_source_directory, target=args.test_target), "Source")
    if args.result:
        def read(kind: str) -> dict:
            return json.loads(subprocess.check_output([
                "xcrun", "xcresulttool", "get", "test-results", kind,
                "--path", str(args.result)], text=True))
        verify_result(manifest, read("summary"), read("tests"))
        print(f"Verified exactly {len(manifest['expectedTests'])} reviewed XCTest identifiers; all passed.")
    elif args.selectors:
        print("\n".join(manifest["selectors"]))
    else:
        print(f"Reviewed source inventory: {len(manifest['expectedTests'])} tests")


if __name__ == "__main__":
    try:
        main()
    except (InventoryError, ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
