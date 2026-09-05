#!/usr/bin/env python3
"""Run real AppKit/WebKit form goals against the frozen local planner candidate.

Requires an already downloaded model, the qualified comparison llama-server,
and a Mac with Accessibility permission for the Swift test runner. Downloads
nothing and does not install or enable a production computer-use capability.
"""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs/audits/2026-09-04-mac-computer-use/native-text-planner-candidate-v1.json"


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def verified_path(path, digest, size=None):
    path = path.resolve(strict=True)
    if not path.is_file() or (size is not None and path.stat().st_size != size):
        raise ValueError("Frozen artifact size or file type mismatch")
    actual = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            actual.update(block)
    if actual.hexdigest() != digest:
        raise ValueError("Frozen artifact SHA-256 mismatch: " + path.name)
    return path


def private_file(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(content)


def stop(process):
    # Both children start new sessions, so this group contains only our child
    # and its descendants (including a Swift test launched by the shell).
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


@contextmanager
def process_scope():
    children = []
    try:
        yield children
    finally:
        for child in reversed(children):
            stop(child)


def ready(process, base_url, alias, key):
    opener = build_opener(ProxyHandler({}), NoRedirects())
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("Local model process exited before readiness")
        try:
            request = Request(base_url + "/v1/models", headers={"Authorization": "Bearer " + key})
            with opener.open(request, timeout=2) as response:
                data = response.read(262145)
            if len(data) > 262144:
                raise ValueError("Oversized model readiness response")
            if any(item.get("id") == alias for item in json.loads(data).get("data", [])):
                return
        except (HTTPError, URLError, TimeoutError):
            pass
        time.sleep(0.1)
    raise TimeoutError("Local model did not become ready within 90 seconds")


def verify_test_report(path):
    expected = {"testRealNativeNaturalLanguageGoalsAndResume", "testRealBrowserNaturalLanguageGoalsAndResume"}
    cases = ET.parse(path).getroot().findall(".//testcase")
    names = [case.attrib.get("name") for case in cases]
    if len(names) != len(expected) or set(names) != expected:
        raise ValueError("Native model acceptance did not execute the exact two reviewed fixtures")
    if any(case.find(tag) is not None for case in cases for tag in ("failure", "error", "skipped")):
        raise ValueError("Native model acceptance contains a failed or skipped fixture")
    return sorted(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--server-binary", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--faults-only", action="store_true", help="Diagnose the six fault/resume scenarios per fixture; does not qualify the ten regression goals")
    args = parser.parse_args()
    os.umask(0o077)
    manifest = json.loads(MANIFEST.read_text())
    model = verified_path(args.model_path, manifest["modelSHA256"], manifest["modelBytes"])
    binary = verified_path(args.server_binary, manifest["runtimeSHA256"])
    verified_path(ROOT / manifest["benchmarkSource"], manifest["benchmarkSHA256"])
    report = args.report.resolve()
    report.parent.mkdir(parents=True, exist_ok=True)
    log_path = report.with_suffix(".server.log")
    xunit_path = report.with_suffix(".xunit.xml")
    if xunit_path.exists():
        raise FileExistsError("Refusing to replace existing test evidence")
    # Refuse to overwrite evidence from a previous run.
    private_file(log_path, "")
    private_file(report, json.dumps({"status": "running"}) + "\n")
    summary = {"status": "failed", "modelSHA256": manifest["modelSHA256"],
               "runtimeSHA256": manifest["runtimeSHA256"], "configuration": manifest["configuration"],
               "scope": "faults-only" if args.faults_only else "regression-and-faults"}
    server = tests = None
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="remotedesktop-native-model-") as directory, process_scope() as children:
            directory = Path(directory)
            key = secrets.token_urlsafe(32)
            alias = "text-planner-" + secrets.token_hex(8)
            key_file = directory / "key"
            private_file(key_file, key + "\n")
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            base_url = f"http://127.0.0.1:{port}"
            environment = {name: value for name, value in os.environ.items()
                           if not name.startswith(("LLAMA_", "HF_"))}
            environment["HF_HUB_OFFLINE"] = "1"
            with log_path.open("w") as log:
                server = subprocess.Popen([
                    str(binary), "--model", str(model), "--host", "127.0.0.1", "--port", str(port),
                    "--alias", alias, "--api-key-file", str(key_file), "--offline", "--no-ui",
                    "--no-mmproj", "--log-disable", "--parallel", "1", "--ctx-size", "4096",
                    "--cache-ram", "0", "--threads", "4", "--threads-batch", "4",
                    "--n-gpu-layers", "99", "--jinja", "--reasoning", "on", "--reasoning-budget", "512",
                ], env=environment, stdout=log, stderr=log, start_new_session=True)
                children.append(server)
                ready(server, base_url, alias, key)
                summary["startupSeconds"] = time.monotonic() - started
                connection_file = directory / "connection.json"
                private_file(connection_file, json.dumps({"baseURL": base_url, "bearerToken": key, "modelAlias": alias}))
                environment["RUN_NATIVE_TEXT_GOALS_LOCAL_ACCEPTANCE"] = "1"
                environment["COMPUTER_USE_TEXT_GOALS_FAULTS_ONLY"] = "1" if args.faults_only else "0"
                environment["COMPUTER_USE_TEXT_MODEL_CONNECTION_FILE"] = str(connection_file)
                environment["COMPUTER_USE_TEST_XUNIT_REPORT"] = str(xunit_path)
                print("Frozen local planner ready; running real native and browser goal fixtures.", flush=True)
                tests = subprocess.Popen(["/bin/bash", str(ROOT / "host-mac/scripts/run_text_edit_acceptance.sh"),
                                          "--local-goals-only"], env=environment, cwd=ROOT, start_new_session=True)
                children.append(tests)
                summary["testExitCode"] = tests.wait(timeout=600)
                if summary["testExitCode"] == 0:
                    summary["verifiedTestMethods"] = verify_test_report(xunit_path)
                summary["status"] = "passed" if summary["testExitCode"] == 0 else "failed"
                return summary["testExitCode"]
    except BaseException as error:
        summary["errorType"] = type(error).__name__
        raise
    finally:
        summary["elapsedSeconds"] = time.monotonic() - started
        report.write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
