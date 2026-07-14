#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest


SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
HOST_DIRECTORY = SCRIPT_DIRECTORY.parent
SOURCE_ROOT = HOST_DIRECTORY / "ThirdPartyRuntime/llama-b9992"
VERIFIER_PATH = SCRIPT_DIRECTORY / "verify_llama_runtime.py"

spec = importlib.util.spec_from_file_location("verify_llama_runtime", VERIFIER_PATH)
assert spec is not None and spec.loader is not None
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class PinnedLlamaRuntimeVerifierTests(unittest.TestCase):
    def make_copy(self) -> tuple[tempfile.TemporaryDirectory[str], pathlib.Path]:
        temporary = tempfile.TemporaryDirectory(prefix="llama-runtime-verifier-")
        root = pathlib.Path(temporary.name) / "llama-b9992"
        shutil.copytree(SOURCE_ROOT, root, symlinks=True)
        return temporary, root

    def verify_source(self, root: pathlib.Path) -> None:
        verifier.verify(
            root,
            root / "runtime-manifest.json",
            signed=False,
            expected_team="",
        )

    def test_pinned_source_passes(self) -> None:
        self.verify_source(SOURCE_ROOT)

    def test_bundle_destination_is_resource_directory(self) -> None:
        manifest = json.loads(
            (SOURCE_ROOT / "runtime-manifest.json").read_text(encoding="utf-8")
        )
        expected = "Contents/Resources/ComputerUseRuntime/llama-b9992"
        self.assertEqual(verifier.PINNED_DESTINATION, expected)
        self.assertEqual(manifest["destination"], expected)

    def test_unlisted_file_fails_closed(self) -> None:
        temporary, root = self.make_copy()
        self.addCleanup(temporary.cleanup)
        (root / "unexpected-tool").write_bytes(b"not allowlisted")
        with self.assertRaisesRegex(verifier.VerificationError, "entry set differs"):
            self.verify_source(root)

    def test_modified_binary_fails_checksum(self) -> None:
        temporary, root = self.make_copy()
        self.addCleanup(temporary.cleanup)
        executable = root / "llama-server"
        data = bytearray(executable.read_bytes())
        data[-1] ^= 0x01
        executable.write_bytes(data)
        with self.assertRaisesRegex(verifier.VerificationError, "SHA-256 mismatch"):
            self.verify_source(root)

    def test_escaping_symlink_fails_closed(self) -> None:
        temporary, root = self.make_copy()
        self.addCleanup(temporary.cleanup)
        link = root / "libllama.0.dylib"
        link.unlink()
        link.symlink_to("../../outside.dylib")
        with self.assertRaisesRegex(verifier.VerificationError, "symlink target mismatch"):
            self.verify_source(root)

    def test_release_provenance_cannot_drift(self) -> None:
        temporary, root = self.make_copy()
        self.addCleanup(temporary.cleanup)
        manifest_path = root / "runtime-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["release"]["tag"] = "latest"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(verifier.VerificationError, "not pinned b9992"):
            self.verify_source(root)

    def test_upstream_adhoc_signature_is_rejected_as_a_bundled_signature(self) -> None:
        with self.assertRaisesRegex(verifier.VerificationError, "ad hoc signature is forbidden"):
            verifier.verify(
                SOURCE_ROOT,
                SOURCE_ROOT / "runtime-manifest.json",
                signed=True,
                expected_team="",
            )


if __name__ == "__main__":
    unittest.main()
