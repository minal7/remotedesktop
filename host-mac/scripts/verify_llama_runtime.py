#!/usr/bin/env python3
"""Fail-closed verifier for the pinned, locally bundled llama.cpp runtime.

This script intentionally has no download mode. The only accepted inputs are
the source files committed under ThirdPartyRuntime or their signed copy inside
an Xcode build product.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import stat
import struct
import subprocess
import sys
from typing import Any


PINNED_RELEASE = {
    "repository": "ggml-org/llama.cpp",
    "tag": "b9992",
    "revision": "6eddde06a4f25d55d538b5d15628dcc2b6882147",
    "archiveName": "llama-b9992-bin-macos-arm64.tar.gz",
    "archiveURL": "https://github.com/ggml-org/llama.cpp/releases/download/b9992/llama-b9992-bin-macos-arm64.tar.gz",
    "archiveByteCount": 10_744_257,
    "archiveSHA256": "b6021d0d6f87d58514d92a67c6fe2956638c242fc2aa30a11c370645246b90a0",
}
PINNED_DESTINATION = "Contents/Resources/ComputerUseRuntime/llama-b9992"
MACHO_64_MAGIC = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C


class VerificationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    require(path.is_file() and not path.is_symlink(), "manifest must be a regular file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid runtime manifest: {error}") from error
    require(isinstance(value, dict), "manifest root must be an object")
    require(value.get("schemaVersion") == 1, "unsupported manifest schema")
    require(value.get("destination") == PINNED_DESTINATION, "unexpected bundle destination")
    require(value.get("release") == PINNED_RELEASE, "llama.cpp release provenance is not pinned b9992")
    require(value.get("architecture") == "arm64", "only the pinned arm64 runtime is supported")
    require(isinstance(value.get("files"), list), "manifest files must be an array")
    require(isinstance(value.get("symlinks"), list), "manifest symlinks must be an array")
    return value


def safe_leaf(value: Any, label: str) -> str:
    require(isinstance(value, str) and value, f"{label} must be a non-empty string")
    path = pathlib.PurePosixPath(value)
    require(not path.is_absolute(), f"{label} must be relative")
    require(len(path.parts) == 1 and path.parts[0] not in {".", ".."}, f"{label} must be one safe filename")
    return value


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_arm64_macho(path: pathlib.Path) -> None:
    try:
        header = path.read_bytes()[:12]
    except OSError as error:
        raise VerificationError(f"cannot read {path.name}: {error}") from error
    require(len(header) == 12, f"truncated Mach-O file: {path.name}")
    magic, cpu_type, _cpu_subtype = struct.unpack("<III", header)
    require(magic == MACHO_64_MAGIC, f"not a 64-bit little-endian Mach-O: {path.name}")
    require(cpu_type == CPU_TYPE_ARM64, f"not the pinned arm64 build: {path.name}")


def dependency_names(path: pathlib.Path) -> list[str]:
    result = subprocess.run(
        ["/usr/bin/otool", "-L", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    require(result.returncode == 0, f"otool rejected {path.name}")
    return [line.strip().split(" ", 1)[0] for line in result.stdout.splitlines()[1:] if line.strip()]


def verify_signature(path: pathlib.Path, expected_team: str) -> None:
    verify = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    require(verify.returncode == 0, f"invalid signature on {path.name}")
    details = subprocess.run(
        ["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    output = details.stdout + details.stderr
    require(details.returncode == 0, f"cannot inspect signature on {path.name}")
    require("runtime" in output.lower(), f"hardened runtime missing from {path.name}")
    require("Signature=adhoc" not in output, f"ad hoc signature is forbidden on {path.name}")
    if expected_team:
        require(f"TeamIdentifier={expected_team}" in output, f"wrong signing team on {path.name}")


def verify(root: pathlib.Path, manifest_path: pathlib.Path, signed: bool, expected_team: str) -> None:
    root = root.absolute()
    require(root.is_dir() and not root.is_symlink(), "runtime root must be a real directory")
    manifest = load_manifest(manifest_path.absolute())

    real_files: dict[str, dict[str, Any]] = {}
    for entry in manifest["files"]:
        require(isinstance(entry, dict), "file entries must be objects")
        name = safe_leaf(entry.get("path"), "file path")
        require(name not in real_files, f"duplicate file entry: {name}")
        role = entry.get("role")
        require(role in {"dylib", "executable"}, f"invalid role for {name}")
        require((role == "dylib") == name.endswith(".dylib"), f"role/name mismatch for {name}")
        require(isinstance(entry.get("byteCount"), int) and entry["byteCount"] > 0, f"invalid size for {name}")
        digest = entry.get("sha256")
        require(isinstance(digest, str) and len(digest) == 64 and all(c in "0123456789abcdef" for c in digest), f"invalid hash for {name}")
        real_files[name] = entry

    require(
        {name for name, entry in real_files.items() if entry["role"] == "executable"} == {"llama-server"},
        "llama-server must be the sole executable",
    )

    links: dict[str, str] = {}
    for entry in manifest["symlinks"]:
        require(isinstance(entry, dict), "symlink entries must be objects")
        name = safe_leaf(entry.get("path"), "symlink path")
        target = safe_leaf(entry.get("target"), "symlink target")
        require(name not in links and name not in real_files, f"duplicate runtime entry: {name}")
        require(name.endswith(".dylib") and target in real_files, f"invalid dylib link: {name}")
        require(real_files[target]["role"] == "dylib", f"symlink target is not a dylib: {name}")
        links[name] = target

    bundled_manifest = root / "runtime-manifest.json"
    require(
        bundled_manifest.is_file() and not bundled_manifest.is_symlink(),
        "runtime-manifest.json must be a regular file",
    )
    require(
        sha256(bundled_manifest) == sha256(manifest_path),
        "bundled runtime manifest differs from the verified manifest",
    )
    expected_entries = set(real_files) | set(links) | {"runtime-manifest.json"}
    actual_entries = {entry.name for entry in os.scandir(root)}
    require(actual_entries == expected_entries, f"runtime entry set differs: expected {sorted(expected_entries)}, got {sorted(actual_entries)}")

    for name, entry in real_files.items():
        path = root / name
        metadata = path.lstat()
        require(stat.S_ISREG(metadata.st_mode), f"runtime file is not regular: {name}")
        require(not path.is_symlink(), f"runtime file unexpectedly became a symlink: {name}")
        require(metadata.st_mode & stat.S_IXUSR, f"runtime file is not owner-executable: {name}")
        verify_arm64_macho(path)
        if not signed:
            require(metadata.st_size == entry["byteCount"], f"byte count mismatch: {name}")
            require(sha256(path) == entry["sha256"], f"SHA-256 mismatch: {name}")
        else:
            verify_signature(path, expected_team)

    for name, target in links.items():
        path = root / name
        require(path.is_symlink(), f"expected symlink is not a symlink: {name}")
        require(os.readlink(path) == target, f"symlink target mismatch: {name}")
        require((root / target).is_file(), f"symlink target missing: {name}")
        require(path.resolve().parent == root.resolve(), f"symlink escapes runtime root: {name}")

    dependency_aliases = set(real_files) | set(links)
    for name in real_files:
        for dependency in dependency_names(root / name):
            if dependency.startswith("@rpath/"):
                require(dependency.removeprefix("@rpath/") in dependency_aliases, f"missing bundled dependency {dependency} for {name}")
            else:
                require(dependency.startswith("/System/Library/") or dependency.startswith("/usr/lib/"), f"unapproved dependency {dependency} for {name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--expected-team", default="")
    arguments = parser.parse_args()
    try:
        verify(arguments.root, arguments.manifest, arguments.signed, arguments.expected_team)
    except (OSError, VerificationError) as error:
        print(f"llama runtime verification failed: {error}", file=sys.stderr)
        return 1
    mode = "signed bundle" if arguments.signed else "pinned source"
    print(f"Verified llama.cpp b9992 {mode}: {arguments.root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
