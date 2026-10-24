#!/usr/bin/env python3
"""Verify SQLCipher build outputs against the checked-in source pin and local record."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil


def sha256(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            size += len(block)
            digest.update(block)
    return digest.hexdigest(), size


def verify(output: Path, manifest_path: Path) -> None:
    if output.is_symlink() or not output.is_dir():
        raise ValueError("SQLCipher output directory is missing or unsafe.")
    for directory in (output / "include", output / "lib"):
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError("SQLCipher output contains an unsafe artifact directory.")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    record_path = output / "build-record.json"
    if record_path.is_symlink() or not record_path.is_file():
        raise ValueError("SQLCipher output has no verifiable build record.")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    expected_source = {
        "sourceCommit": manifest["sourceCommit"],
        "archiveSHA256": manifest["archiveSHA256Observed"],
        "archiveBytes": manifest["archiveBytesObserved"],
    }
    if record.get("schemaVersion") != 1 or record.get("source") != expected_source:
        raise ValueError("SQLCipher build record does not match the pinned source manifest.")
    expected_options = {
        "sqlite_has_codec": "1",
        "sqlite_extra_init": "sqlcipher_extra_init",
        "sqlite_extra_shutdown": "sqlcipher_extra_shutdown",
        "sqlite_threadsafe": "1",
        "sqlite_temp_store": "3 (configure --with-tempstore=always)",
        "fts5": "enabled (configure --enable-fts5)",
        "loadable_extensions": "disabled (configure --disable-load-extension and SQLITE_OMIT_LOAD_EXTENSION)",
        "crypto_provider": "CommonCrypto (SQLCIPHER_CRYPTO_CC)",
    }
    options = {}
    for line in (output / "build-options.txt").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            options[key] = value
    if any(options.get(key) != value for key, value in expected_options.items()):
        raise ValueError("SQLCipher build options do not match the approved configuration.")
    expected_artifacts = {"lib/libsqlcipher.a", "include/sqlite3.h", "build-options.txt"}
    artifacts = record.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != expected_artifacts:
        raise ValueError("SQLCipher build record does not list the expected artifacts.")
    for relative in expected_artifacts:
        path = output / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError("SQLCipher build artifact is missing or unsafe.")
        digest, size = sha256(path)
        if artifacts[relative] != {"sha256": digest, "bytes": size}:
            raise ValueError("SQLCipher build artifact differs from its local build record.")


def remove_owned_legacy_output(output: Path, manifest_path: Path) -> None:
    """Remove only this builder's exact three-file unrecorded output before a clean rebuild."""
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if output.is_symlink() or not output.is_dir():
        raise ValueError("SQLCipher output is not a real directory.")
    expected_files = {"lib/libsqlcipher.a", "include/sqlite3.h", "build-options.txt"}
    actual_files = set()
    actual_dirs = set()
    for path in output.rglob("*"):
        if path.is_symlink():
            raise ValueError("SQLCipher output contains a symlink.")
        relative = path.relative_to(output).as_posix()
        if path.is_dir():
            actual_dirs.add(relative)
        elif path.is_file():
            actual_files.add(relative)
        else:
            raise ValueError("SQLCipher output contains an unsupported file type.")
    if actual_files not in (expected_files, expected_files | {"build-record.json"}) or \
            actual_dirs != {"lib", "include"}:
        raise ValueError("SQLCipher output contains files outside the builder's known layout.")
    options = {}
    for line in (output / "build-options.txt").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            options[key] = value
    if options.get("source_commit") != manifest["sourceCommit"]:
        raise ValueError("SQLCipher output does not identify the pinned source commit.")
    shutil.rmtree(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--remove-owned-legacy-output", action="store_true")
    arguments = parser.parse_args()
    if arguments.remove_owned_legacy_output:
        try:
            remove_owned_legacy_output(arguments.output, arguments.manifest)
        except (OSError, ValueError, json.JSONDecodeError, KeyError, TypeError):
            parser.error("SQLCipher output is not a safely replaceable builder output.")
        print("Removed only the known generated SQLCipher output; rebuilding from staged pinned source.")
        return 0
    try:
        verify(arguments.output, arguments.manifest)
    except (OSError, ValueError, json.JSONDecodeError, KeyError, TypeError):
        parser.error("SQLCipher output could not be verified against the pinned build record.")
    print("Verified SQLCipher build output and source record.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
