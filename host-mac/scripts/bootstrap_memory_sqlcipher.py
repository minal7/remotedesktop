#!/usr/bin/env python3
"""Explicitly stage the pinned SQLCipher source archive for the offline builder."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import ssl
import stat
import tempfile
from urllib.parse import urlparse
import urllib.error
import urllib.request


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPOSITORY_ROOT / "host-mac/ThirdPartyRuntime/sqlcipher/source-manifest.json"
DEFAULT_STAGING = REPOSITORY_ROOT / "build/donor-audit"
MAX_ARCHIVE_BYTES = 25_000_000


class BootstrapError(Exception):
    pass


def load_manifest(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BootstrapError("Pinned SQLCipher source manifest is unavailable or invalid.") from error
    required = {"schemaVersion", "repository", "sourceCommit", "archiveURL", "archiveFile",
                "archiveBytesObserved", "archiveSHA256Observed"}
    if not isinstance(data, dict) or not required.issubset(data) or data["schemaVersion"] != 1:
        raise BootstrapError("Pinned SQLCipher source manifest has an unsupported schema.")
    if data["repository"] != "sqlcipher/sqlcipher":
        raise BootstrapError("Pinned SQLCipher repository is not approved.")
    commit = data["sourceCommit"]
    if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
        raise BootstrapError("Pinned SQLCipher source commit is invalid.")
    expected_url = f"https://codeload.github.com/sqlcipher/sqlcipher/tar.gz/{commit}"
    if data["archiveURL"] != expected_url or data["archiveFile"] != f"sqlcipher-{commit}.tar.gz":
        raise BootstrapError("Pinned SQLCipher archive URL or name does not match its source commit.")
    parsed = urlparse(data["archiveURL"])
    if parsed.scheme != "https" or parsed.hostname != "codeload.github.com":
        raise BootstrapError("Pinned SQLCipher archive host is not approved.")
    size, digest = data["archiveBytesObserved"], data["archiveSHA256Observed"]
    if not isinstance(size, int) or not 0 < size <= MAX_ARCHIVE_BYTES:
        raise BootstrapError("Pinned SQLCipher archive size is outside the accepted bound.")
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise BootstrapError("Pinned SQLCipher archive digest is invalid.")
    return data


def verify_archive(path: Path, manifest: dict) -> None:
    try:
        if not stat.S_ISREG(path.lstat().st_mode):
            raise BootstrapError("SQLCipher archive is not a regular file.")
    except OSError as error:
        raise BootstrapError("SQLCipher archive could not be inspected safely.") from error
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                size += len(block)
                if size > manifest["archiveBytesObserved"]:
                    raise BootstrapError("SQLCipher archive exceeds the pinned size.")
                digest.update(block)
    except OSError as error:
        raise BootstrapError("SQLCipher archive could not be read.") from error
    if size != manifest["archiveBytesObserved"] or digest.hexdigest() != manifest["archiveSHA256Observed"]:
        raise BootstrapError("SQLCipher archive digest or size does not match the pinned manifest.")


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        raise BootstrapError("Pinned SQLCipher archive server redirected; refusing an unpinned source.")


def download_archive(manifest: dict, destination: Path) -> None:
    parsed = urlparse(manifest["archiveURL"])
    if parsed.hostname != "codeload.github.com" or parsed.scheme != "https":
        raise BootstrapError("Pinned SQLCipher archive host is not approved.")
    request = urllib.request.Request(manifest["archiveURL"], headers={"User-Agent": "MemoryStoreKit-build-bootstrap"})
    # Empty proxy list prevents inherited proxy credentials/configuration from affecting the request.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), RejectRedirects(),
                                        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    temporary = None
    try:
        with opener.open(request, timeout=60) as response:
            if response.status != 200:
                raise BootstrapError("Pinned SQLCipher archive request failed.")
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd, name = tempfile.mkstemp(prefix=".sqlcipher-stage-", dir=destination.parent)
            temporary = Path(name)
            os.fchmod(fd, 0o600)
            digest = hashlib.sha256()
            size = 0
            with os.fdopen(fd, "wb") as output:
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > manifest["archiveBytesObserved"]:
                        raise BootstrapError("SQLCipher archive exceeds the pinned size.")
                    digest.update(block)
                    output.write(block)
            if size != manifest["archiveBytesObserved"] or digest.hexdigest() != manifest["archiveSHA256Observed"]:
                raise BootstrapError("SQLCipher archive digest or size does not match the pinned manifest.")
        os.replace(temporary, destination)
        temporary = None
    except (OSError, urllib.error.URLError, ssl.SSLError) as error:
        raise BootstrapError("Pinned SQLCipher source download failed.") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def stage_source(source: Path, manifest: dict, destination: Path) -> None:
    verify_archive(source, manifest)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with source.open("rb") as input_stream:
        fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "wb") as output_stream:
            shutil.copyfileobj(input_stream, output_stream, 1024 * 1024)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--download", action="store_true", help="download the exact public archive in the manifest")
    group.add_argument("--source", type=Path, help="stage a local archive after pinned digest verification")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--staging-dir", type=Path, default=DEFAULT_STAGING)
    arguments = parser.parse_args()
    try:
        manifest = load_manifest(arguments.manifest)
        destination = arguments.staging_dir / manifest["archiveFile"]
        if destination.exists() or destination.is_symlink():
            verify_archive(destination, manifest)
        elif arguments.download:
            download_archive(manifest, destination)
        else:
            stage_source(arguments.source, manifest, destination)
        print(f"Verified pinned SQLCipher source archive: {destination}")
        return 0
    except BootstrapError as error:
        parser.error(str(error))
    except OSError:
        parser.error("SQLCipher archive could not be staged safely.")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
