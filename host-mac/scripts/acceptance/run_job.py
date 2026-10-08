#!/usr/bin/env python3
"""Run and independently check one local Computer Use job serially."""

from __future__ import annotations

import argparse
import base64
from datetime import date as Date, datetime, timezone
from email import policy
from email.parser import BytesParser
from email.utils import getaddresses
import hashlib
from html.parser import HTMLParser
import io
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time
import uuid
import zipfile
from typing import Any
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[3]
TRACE_ROOT = Path.home() / "Library/Application Support/RemoteDesktopHost/Traces"
FIXTURE_ROOT = Path.home() / "RemoteDesktopAcceptance"
DOWNLOADS = Path.home() / "Downloads"
TEST_ID = "RemoteDesktopHostTests/CoreJobAcceptanceTests/testRunJob"
MAX_RUNS = 10
MAX_TRACE_FOLDERS = 20
TIMEOUT_SECONDS = 420

# Archive members are sorted, uncompressed, and have fixed ZIP metadata so
# these fixture hashes are stable across Python and zlib versions.
FIXTURE_CONTENT: dict[str, dict[str, str]] = {
    "Board Review.pptx": {
        "[Content_Types].xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>""",
        "_rels/.rels": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>""",
        "ppt/presentation.xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst><p:sldSz cx="9144000" cy="5143500" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>""",
        "ppt/_rels/presentation.xml.rels": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>""",
        "ppt/slides/slide1.xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Board Review"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Board Review acceptance fixture</a:t></a:r><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>""",
        "ppt/slides/_rels/slide1.xml.rels": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>""",
        "ppt/slideLayouts/slideLayout1.xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>""",
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>""",
        "ppt/slideMasters/slideMaster1.xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="Master"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles/></p:sldMaster>""",
        "ppt/slideMasters/_rels/slideMaster1.xml.rels": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>""",
        "ppt/theme/theme1.xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Acceptance"><a:themeElements><a:clrScheme name="Acceptance"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F1F1F"/></a:dk2><a:lt2><a:srgbClr val="F2F2F2"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Acceptance"><a:majorFont><a:latin typeface="Aptos Display"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/></a:minorFont></a:fontScheme><a:fmtScheme name="Acceptance"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>""",
    },
    "Quarterly Metrics.xlsx": {
        "[Content_Types].xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>""",
        "_rels/.rels": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>""",
        "xl/workbook.xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Quarterly Metrics" sheetId="1" r:id="rId1"/></sheets></workbook>""",
        "xl/_rels/workbook.xml.rels": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>""",
        "xl/worksheets/sheet1.xml": """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:B4"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Quarterly Metrics acceptance fixture</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>Quarter</t></is></c><c r="B2" t="inlineStr"><is><t>Score</t></is></c></row><row r="3"><c r="A3" t="inlineStr"><is><t>Q1</t></is></c><c r="B3"><v>91</v></c></row><row r="4"><c r="A4" t="inlineStr"><is><t>Q2</t></is></c><c r="B4"><v>94</v></c></row></sheetData><pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>""",
    },
}

FIXTURE_SHA256 = {
    # Checked before using or replacing any external fixture.
    "Board Review.pptx": "c4ed042ab3358557b2af6f7fabd4d4469518419ca297f63e01aa30d91114a79f",
    "Quarterly Metrics.xlsx": "d9086b7312214679dbb7123d59aa5708c253a3cf9345a0d6e14c39e8a994ec15",
}

FAILURE_CLASSES = {
    "guard-rejected", "approval-needed", "model-wrong-action", "model-malformed",
    "text-entry", "timeout", "window-lost", "permission", "other",
}


class AcceptanceError(RuntimeError):
    pass


def canonical_zip(entries: dict[str, str]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, entries[name].encode("utf-8"))
    return output.getvalue()


def fixture_bytes(name: str) -> bytes:
    try:
        return canonical_zip(FIXTURE_CONTENT[name])
    except KeyError as error:
        raise AcceptanceError("Unknown canonical fixture") from error


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def prepare_fixtures() -> dict[str, dict[str, Any]]:
    FIXTURE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    if FIXTURE_ROOT.is_symlink() or not FIXTURE_ROOT.is_dir():
        raise AcceptanceError("Fixture root must be a real directory")
    manifest: dict[str, dict[str, Any]] = {}
    for name in FIXTURE_CONTENT:
        data = fixture_bytes(name)
        expected_hash = FIXTURE_SHA256[name]
        if expected_hash.startswith("TO_BE_PINNED") or sha256(data) != expected_hash:
            raise AcceptanceError("The embedded fixture hash is not pinned to its deterministic bytes")
        path = FIXTURE_ROOT / name
        if path.exists():
            if path.is_symlink() or not path.is_file():
                raise AcceptanceError("A fixture destination is not a regular file")
            current = path.read_bytes()
            if current != data or sha256(current) != expected_hash:
                raise AcceptanceError("Existing fixture differs from its pinned canonical bytes; refusing to overwrite")
        else:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
        manifest[name] = {"path": str(path), "bytes": len(data), "sha256": expected_hash}
    return manifest


def stage_source(source: Path, run_id: str, expected_hash: str) -> Path:
    DOWNLOADS.mkdir(mode=0o700, parents=True, exist_ok=True)
    if DOWNLOADS.is_symlink() or not DOWNLOADS.is_dir():
        raise AcceptanceError("Downloads must be a real directory")
    destination = DOWNLOADS / f"M0-{run_id}-Board Review.pptx"
    if destination.exists():
        raise AcceptanceError("Run-specific staged fixture already exists")
    data = source.read_bytes()
    if sha256(data) != expected_hash:
        raise AcceptanceError("Canonical PPTX changed before staging")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.utime(destination, None)
    except OSError:
        try:
            destination.unlink()
        except OSError:
            pass
        raise
    return destination


def wait_for_spotlight_visibility(path: Path, *, downloads: Path = DOWNLOADS,
                                  timeout: float = 30.0, process_timeout: float = 2.0,
                                  poll_interval: float = 0.25, run_process=subprocess.run,
                                  clock=time.monotonic, sleep=time.sleep) -> float:
    expected = path.resolve(strict=True)
    root = downloads.resolve(strict=True)
    if path.parent.resolve(strict=True) != root or not path.is_file() or path.is_symlink():
        raise AcceptanceError("Spotlight fixture readiness failed: staged file is outside Downloads")

    started = clock()
    deadline = started + max(0.0, timeout)
    predicate = f'kMDItemFSName == "{path.name}"'
    while True:
        remaining = deadline - clock()
        if remaining <= 0:
            break
        try:
            result = run_process(
                ["/usr/bin/mdfind", "-0", "-onlyin", str(root), predicate],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
                timeout=min(process_timeout, remaining))
        except subprocess.TimeoutExpired:
            result = None
        except OSError as error:
            raise AcceptanceError("Spotlight fixture readiness failed: mdfind could not run") from error
        if result is not None:
            if result.returncode != 0:
                raise AcceptanceError("Spotlight fixture readiness failed: mdfind query did not complete")
            for item in (result.stdout or b"").split(b"\0"):
                if item and Path(os.fsdecode(item)).resolve() == expected:
                    return max(0.0, clock() - started)
        sleep(min(poll_interval, max(0.0, deadline - clock())))
    raise AcceptanceError("Spotlight fixture readiness failed: staged file was not indexed before launch")


def remove_owned_stage(path: Path | None, expected_hash: str | None) -> None:
    if path is None or expected_hash is None:
        return
    try:
        if (path.parent == DOWNLOADS and path.name.startswith("M0-")
                and path.is_file() and not path.is_symlink()
                and sha256(path.read_bytes()) == expected_hash):
            path.unlink()
    except OSError:
        pass


def prune_traces() -> None:
    if not TRACE_ROOT.is_dir():
        return
    milestone_prefixes = tuple(f"m{index}-" for index in range(5)) + ("mail-body-diagnostic-",)
    owned = [path for path in TRACE_ROOT.iterdir()
             if path.is_dir() and not path.is_symlink() and path.name.startswith(milestone_prefixes)]
    owned.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
    for stale in owned[MAX_TRACE_FOLDERS:]:
        shutil.rmtree(stale, ignore_errors=True)


def make_expected(job: str, run_id: str, run_index: int,
                  fixture: dict[str, dict[str, Any]], cloud_root: Path | None,
                  send_approval_check: bool = False,
                  staged_source: Path | None = None) -> tuple[dict[str, Any], Path | None, str | None]:
    expected: dict[str, Any] = {"job": job, "run_id": run_id, "run_index": run_index}
    stage: Path | None = None
    stage_hash: str | None = None
    pptx = fixture["Board Review.pptx"]
    if job in {"email", "cloud"}:
        stage = staged_source or stage_source(Path(pptx["path"]), run_id, pptx["sha256"])
        stage_hash = pptx["sha256"]
        expected.update({"source_path": str(stage), "source_sha256": pptx["sha256"],
                         "source_bytes": pptx["bytes"], "attachment_name": stage.name})
    if job == "email":
        expected.update({
            "to": "dana@example.com",
            "subject": f"Board Review deck [M0 {run_id}]",
            "body": "Please review the attached Board Review deck.",
        })
        discovery_requests = (
            "Email the latest Board Review deck in Downloads",
            "Email the most recently modified Board Review presentation in Downloads",
            "Email the newest Board Review deck in Downloads",
        )
        discovery_request = discovery_requests[(run_index - 1) % len(discovery_requests)]
        if send_approval_check:
            expected["send_approval_check"] = True
            expected["prompt"] = (
                f"Send the latest Board Review deck in Downloads to {expected['to']}. Use the exact "
                f"subject \"{expected['subject']}\" and exact body \"{expected['body']}\". Send this email now."
            )
        else:
            expected["prompt"] = (
                f"{discovery_request} to {expected['to']}. Use the exact subject \"{expected['subject']}\" "
                f"and exact body \"{expected['body']}\". Save it as a draft and leave it open for review; do not send."
            )
    elif job == "cloud":
        if cloud_root is None:
            raise AcceptanceError("No installed cloud sync folder was selected")
        destination = cloud_root / "RemoteDesktopAcceptance" / run_id / "Board Review.pptx"
        expected.update({"cloud_root": str(cloud_root), "destination_path": str(destination)})
        expected["prompt"] = (
            f"Copy the latest Board Review deck, {stage.name}, from Downloads to "
            f"{destination.parent} in the installed local sync folder using local file operations. "
            "Keep the source, do not overwrite an existing file, and do not open a website."
        )
    elif job == "flights":
        expected["trip"] = {"origin": "SFO", "origin_name": "San Francisco",
                            "destination": "LIS", "destination_name": "Lisbon",
                            "date": "2026-11-10"}
        expected["prompt"] = "Find me a cheap flight from SFO to Lisbon on November 10, 2026. Return 3–5 options with prices copied from the page."
    else:
        expected["prompt"] = (
            "Report whether this task reached the Mac. If it is locked, ask me to unlock it in the "
            "remote view and Resume. Do not perform any input before unlock."
        )
    return expected, stage, stage_hash


def clear_live_optins() -> dict[str, str]:
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("RUN_", "TEST_RUN_", "TEST_RUNNER_", "CORE_JOB_ACCEPTANCE_")):
            env.pop(key, None)
    return env


def developer_environment(env: dict[str, str]) -> dict[str, str]:
    configured = env.get("DEVELOPER_DIR")
    selected = configured
    if not selected:
        result = subprocess.run(["/usr/bin/xcode-select", "-p"], capture_output=True, text=True, check=False)
        if result.returncode == 0:
            selected = result.stdout.strip()
    if selected and selected.endswith("/CommandLineTools"):
        candidates = sorted(Path("/Applications").glob("Xcode*.app/Contents/Developer"),
                            key=lambda path: path.stat().st_mtime_ns if path.exists() else 0, reverse=True)
        candidates = [path for path in candidates if (path / "usr/bin/xcodebuild").is_file()]
        if candidates:
            selected = str(candidates[0])
    if selected:
        env["DEVELOPER_DIR"] = selected
    return env


def load_build_command(path: Path | None, env: dict[str, str]) -> list[str]:
    if path is None:
        local = ROOT / ".codex/local-build/host-test-command.json"
        path = local if local.is_file() else None
    if path is not None:
        try:
            command = json.loads(path.read_text(encoding="utf-8"))["command"]
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
            raise AcceptanceError("Build command file must contain a string command array") from error
        if not isinstance(command, list) or not command or not all(isinstance(item, str) for item in command):
            raise AcceptanceError("Build command file must contain a nonempty string command array")
        return sanitize_xcodebuild_command(command)

    xcodebuild = str(Path(env.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")) / "usr/bin/xcodebuild")
    if not Path(xcodebuild).is_file():
        xcodebuild = "/usr/bin/xcodebuild"
    return sanitize_xcodebuild_command([
        xcodebuild, "test", "-project", "host-mac/RemoteDesktopHost.xcodeproj",
        "-scheme", "RemoteDesktopHost", "-configuration", "Debug",
        "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", str(Path.home() / "Library/Developer/Xcode/DerivedData/RemoteDesktopCoreJobAcceptance"),
        "-parallel-testing-enabled", "NO", "-jobs", "1",
    ])


def sanitize_xcodebuild_command(command: list[str]) -> list[str]:
    if not command or "xcodebuild" not in Path(command[0]).name:
        raise AcceptanceError("Build override must invoke xcodebuild")
    remove_with_value = {"-only-testing", "-skip-testing", "-resultBundlePath"}
    result: list[str] = []
    index = 0
    while index < len(command):
        item = command[index]
        if item in remove_with_value:
            index += 2
            continue
        if item.startswith(("-only-testing:", "-skip-testing:")):
            index += 1
            continue
        if item in {"-test-timeouts-enabled", "-maximum-test-execution-time-allowance", "-parallel-testing-enabled", "-jobs"}:
            result.extend([item, "YES" if item == "-test-timeouts-enabled" else "NO" if item == "-parallel-testing-enabled" else "420" if item == "-maximum-test-execution-time-allowance" else "1"])
            index += 2
            continue
        result.append(item)
        index += 1
    if not any(item == "-test-timeouts-enabled" for item in result):
        result.extend(["-test-timeouts-enabled", "YES"])
    if not any(item == "-maximum-test-execution-time-allowance" for item in result):
        result.extend(["-maximum-test-execution-time-allowance", "420"])
    if not any(item == "-parallel-testing-enabled" for item in result):
        result.extend(["-parallel-testing-enabled", "NO"])
    if not any(item == "-jobs" for item in result):
        result.extend(["-jobs", "1"])
    actions = [i for i, item in enumerate(result) if item in {"test", "build-for-testing", "test-without-building"}]
    if len(actions) != 1:
        raise AcceptanceError("Build override must contain exactly one xcodebuild test action")
    return result


def command_for(base: list[str], action: str, trace: Path | None = None) -> list[str]:
    command = list(base)
    action_index = next(i for i, item in enumerate(command) if item in {"test", "build-for-testing", "test-without-building"})
    command[action_index] = action
    if action == "test-without-building":
        command.extend([f"-only-testing:{TEST_ID}", "-resultBundlePath", str(trace / "host.xcresult")])
    return command


def run_logged(command: list[str], env: dict[str, str], log_path: Path, timeout: int) -> tuple[int, float]:
    started = time.monotonic()
    try:
        with log_path.open("wb") as output:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 124
    except OSError:
        code = 127
    except subprocess.TimeoutExpired:
        code = 124
    return code, time.monotonic() - started


def bounded_text(value: Any, limit: int = 16000) -> str:
    if not isinstance(value, str):
        raise AcceptanceError("Outcome text field is missing or invalid")
    if len(value.encode("utf-8")) > limit:
        raise AcceptanceError("Outcome text exceeds the reviewed size limit")
    return value


def read_outcome(trace: Path, job: str, run_id: str) -> dict[str, Any]:
    try:
        outcome = json.loads((trace / "outcome.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AcceptanceError("The XCTest driver did not write a valid outcome.json") from error
    if not isinstance(outcome, dict) or outcome.get("job") != job or outcome.get("run_id") != run_id:
        raise AcceptanceError("Outcome identity does not match the selected job and run")
    if not isinstance(outcome.get("raw_outcome"), str) or not outcome["raw_outcome"]:
        raise AcceptanceError("Outcome is missing the host terminal state")
    if not isinstance(outcome.get("task_id"), str) or not outcome["task_id"]:
        if outcome["raw_outcome"] != "not-started":
            raise AcceptanceError("Outcome is missing its task ID")
    elapsed = outcome.get("elapsed_ms")
    if not isinstance(elapsed, int) or elapsed < 0:
        raise AcceptanceError("Outcome elapsed_ms must be a nonnegative integer")
    failure_class = outcome.get("failure_class")
    successful_none = outcome.get("raw_outcome") == "taskCompleted" and failure_class == "none"
    if failure_class is not None and failure_class not in FAILURE_CLASSES and not successful_none:
        raise AcceptanceError("Outcome failure class is outside the reviewed vocabulary")
    bounded_text(outcome.get("text", ""))
    if not isinstance(outcome.get("evidence"), dict):
        raise AcceptanceError("Outcome evidence must be a JSON object")
    return outcome


class MailHTMLBody(HTMLParser):
    """Read text from Mail's saved HTML without counting attachment objects."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.frames: list[tuple[str, bool, bool]] = []
        self.text: list[str] = []
        self.trailing_mail_space = False
        self.trailing_block_newline = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        classes = (values.get("class") or "").split()
        ignored = (any(frame[1] for frame in self.frames) or tag in {"head", "script", "style", "object"}
                   or "Apple-Mail-URLShareUserContentTopClass" in classes)
        converted = "Apple-converted-space" in classes
        if tag == "br":
            if not ignored:
                self.text.append("\n")
                self.trailing_mail_space = False
                self.trailing_block_newline = False
            return
        if tag in {"img", "meta", "link", "input", "hr"}:
            return
        self.frames.append((tag, ignored, converted))

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.frames) - 1, -1, -1):
            if self.frames[index][0] == tag:
                ignored = self.frames[index][1]
                del self.frames[index:]
                if not ignored and tag in {"p", "div", "blockquote", "li"} and self.text and self.text[-1] != "\n":
                    self.text.append("\n")
                    self.trailing_block_newline = True
                return

    def handle_data(self, data: str) -> None:
        if any(frame[1] for frame in self.frames):
            return
        if data.strip() == "" and "\n" in data:
            return  # HTML source indentation, rather than an explicit line break.
        self.text.append(data)
        if data:
            self.trailing_block_newline = False
            self.trailing_mail_space = any(frame[2] for frame in self.frames) and data == "\xa0"

    def rendered(self) -> str:
        body = "".join(self.text)
        if self.trailing_block_newline and body.endswith("\n"):
            body = body[:-1]
        if self.trailing_mail_space and body.endswith("\xa0"):
            body = body[:-1]
        return body


def mail_body_matches(message: Any, expected: str) -> bool:
    part = message.get_body(preferencelist=("html", "plain"))
    if part is None or part.get_content_disposition() == "attachment":
        return False
    if part.get_content_type() == "text/plain":
        body = part.get_content().replace("\r\n", "\n").replace("\r", "\n")
        return body == expected or body == expected + "\n"
    if part.get_content_type() == "text/html":
        parser = MailHTMLBody()
        parser.feed(part.get_content())
        return parser.rendered() == expected
    return False


def check_email(expected: dict[str, Any], outcome: dict[str, Any], trace: Path) -> dict[str, Any]:
    evidence = outcome["evidence"].get("email")
    if not isinstance(evidence, dict):
        raise AcceptanceError("Email outcome is missing email evidence")
    if expected.get("send_approval_check") is True:
        if outcome["raw_outcome"] != "approvalRequired":
            raise AcceptanceError("Send request did not stop at an approval requirement")
        if evidence.get("send_approval_observed") is not True:
            raise AcceptanceError("The exact Send approval was not independently observed")
        if evidence.get("send_effects") != 0:
            raise AcceptanceError("Send approval check caused a send effect")
        if outcome["evidence"].get("other_approval_denied_count") != 0:
            raise AcceptanceError("Send approval check encountered another approval decision")
        return {"passed": True, "send_approval_observed": True, "send_effects": 0}
    if outcome["raw_outcome"] != "taskCompleted":
        raise AcceptanceError("Host did not report the unsent Mail draft as completed")
    if (evidence.get("send_effects") != 0 or evidence.get("draft_count") != 1
            or evidence.get("draft_visible_count") != 1
            or evidence.get("draft_subject") != expected["subject"]):
        raise AcceptanceError("Expected one visible run-specific draft and zero send effects")
    if (outcome["evidence"].get("draft_create_approved_count") != 0
            or outcome["evidence"].get("other_approval_denied_count") != 0):
        raise AcceptanceError("Draft creation unexpectedly needed an approval")
    source = Path(expected["source_path"])
    if (source.is_symlink() or not source.is_file() or sha256(source.read_bytes()) != expected["source_sha256"]):
        raise AcceptanceError("Staged email source differs from the canonical fixture")
    try:
        oracle = json.loads((trace / "mail-oracle.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AcceptanceError("Independent Mail draft oracle is missing or invalid") from error
    mime_path = trace / "mail-source.eml"
    if (oracle.get("draft_count") != 1 or oracle.get("visible_count") != 1
            or oracle.get("sent_count") != 0 or oracle.get("subject") != expected["subject"]
            or oracle.get("mime_source_path") != str(mime_path)
            or evidence.get("draft_mime_source_path") != str(mime_path)):
        raise AcceptanceError("Mail oracle did not confirm exactly one visible unsent draft")
    try:
        message = BytesParser(policy=policy.default).parsebytes(mime_path.read_bytes())
    except Exception as error:
        raise AcceptanceError("Exported draft MIME could not be parsed") from error
    actual_subject = str(message.get("Subject", ""))
    addresses = [address.casefold() for _, address in getaddresses(message.get_all("To", []))]
    if actual_subject != expected["subject"]:
        raise AcceptanceError("Draft MIME subject did not match exactly")
    if addresses != [expected["to"].casefold()]:
        raise AcceptanceError("Draft MIME To field did not match exactly")
    if message.get_all("Cc", []) or message.get_all("Bcc", []):
        raise AcceptanceError("Draft MIME must not include Cc or Bcc recipients")
    if not mail_body_matches(message, expected["body"]):
        raise AcceptanceError("Draft MIME body did not match exactly")
    attachments = [part for part in message.walk()
                   if part.get_content_disposition() == "attachment" or part.get_filename()]
    if len(attachments) != 1 or attachments[0].get_filename() != expected["attachment_name"]:
        raise AcceptanceError("Draft must contain exactly the expected attachment")
    payload = attachments[0].get_payload(decode=True)
    if payload is None or len(payload) != expected["source_bytes"] or sha256(payload) != expected["source_sha256"]:
        raise AcceptanceError("Decoded Mail attachment bytes differ from the canonical source")
    return {"passed": True, "mail_mime_sha256": sha256(mime_path.read_bytes()),
            "attachment_sha256": sha256(payload), "mailbox_scope": "one run-specific Drafts subject"}


def check_cloud(expected: dict[str, Any], outcome: dict[str, Any]) -> dict[str, Any]:
    evidence = outcome["evidence"].get("cloud")
    if not isinstance(evidence, dict):
        raise AcceptanceError("Cloud outcome is missing copy/upload evidence")
    source = Path(expected["source_path"])
    destination = Path(expected["destination_path"])
    root = Path(expected["cloud_root"]).resolve(strict=True)
    if source.is_symlink() or not source.is_file():
        raise AcceptanceError("Staged cloud source is missing or is not a regular file")
    source_payload = source.read_bytes()
    if len(source_payload) != expected["source_bytes"] or sha256(source_payload) != expected["source_sha256"]:
        raise AcceptanceError("Staged cloud source differs from the canonical fixture")
    if evidence.get("source_sha256") != expected["source_sha256"]:
        raise AcceptanceError("Cloud evidence source digest differs from the canonical fixture")
    if evidence.get("destination_path") != str(destination):
        raise AcceptanceError("Cloud evidence points to a different destination path")
    if not destination.exists() or destination.is_symlink() or not destination.is_file():
        raise AcceptanceError("Cloud destination copy is missing or is not a regular file")
    resolved = destination.resolve(strict=True)
    if root not in resolved.parents:
        raise AcceptanceError("Cloud destination escaped the selected sync root")
    payload = destination.read_bytes()
    if len(payload) != expected["source_bytes"] or sha256(payload) != expected["source_sha256"]:
        raise AcceptanceError("Cloud destination SHA-256 does not match the source fixture")
    uploaded = evidence.get("uploaded")
    if uploaded is not True:
        raise AcceptanceError("Provider did not affirm that the cloud copy is uploaded")
    if outcome["raw_outcome"] != "taskCompleted":
        raise AcceptanceError("Host did not report the cloud copy as completed")
    if evidence.get("destination_sha256") != sha256(payload):
        raise AcceptanceError("Cloud evidence destination digest differs from the copied bytes")
    return {"passed": True, "destination_sha256": sha256(payload), "uploaded": True}


def check_flights(expected: dict[str, Any], outcome: dict[str, Any], trace: Path) -> dict[str, Any]:
    evidence = outcome["evidence"].get("flights")
    if not isinstance(evidence, dict):
        raise AcceptanceError("Flight outcome is missing live-browser evidence")
    parsed = urlparse(str(evidence.get("url", "")))
    if parsed.scheme != "https" or parsed.hostname not in {"google.com", "www.google.com"} or not parsed.path.startswith("/travel/flights"):
        raise AcceptanceError("Flight evidence is not from the actual Google Flights page")
    trip = expected["trip"]
    encoded_trip = parse_qs(parsed.query).get("tfs", [])
    if len(encoded_trip) != 1:
        raise AcceptanceError("Google Flights URL does not contain one encoded trip selection")
    try:
        decoded_trip = base64.b64decode(encoded_trip[0] + "=" * (-len(encoded_trip[0]) % 4),
                                        altchars=b"-_", validate=True)
    except (ValueError, TypeError) as error:
        raise AcceptanceError("Google Flights trip selection could not be decoded") from error
    for marker in (trip["origin"], trip["destination"], trip["date"]):
        if marker.encode("ascii") not in decoded_trip:
            raise AcceptanceError("Encoded Google Flights URL does not match the requested route and date")
    page_path = trace_path_for_evidence(evidence.get("page_text_path"), "flight-page.txt", trace)
    try:
        page_bytes = page_path.read_bytes()
        page_text = page_bytes.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise AcceptanceError("Captured default-browser page text is missing or invalid") from error
    if not page_text.strip() or len(page_bytes) > 262_144:
        raise AcceptanceError("Observed flight page text is missing or exceeds its size bound")
    page_upper = page_text.upper()
    if not any(value.upper() in page_upper for value in (trip["origin"], trip["origin_name"])):
        raise AcceptanceError("Captured page text does not support the requested origin")
    if not any(value.upper() in page_upper for value in (trip["destination"], trip["destination_name"])):
        raise AcceptanceError("Captured page text does not support the requested destination")
    try:
        travel_date = Date.fromisoformat(trip["date"])
    except (TypeError, ValueError) as error:
        raise AcceptanceError("Expected flight date is invalid") from error
    month_short = travel_date.strftime("%b")
    month_long = travel_date.strftime("%B")
    day = str(travel_date.day)
    year = str(travel_date.year)
    date_labels = {trip["date"], f"{month_short} {day}", f"{month_long} {day}",
                   f"{month_short} {day}, {year}", f"{month_long} {day}, {year}"}
    if not any(label in page_text for label in date_labels):
        raise AcceptanceError("Observed page text does not support the requested travel date")
    if evidence.get("page_text") != page_text:
        raise AcceptanceError("Reported page text differs from the captured native page observation")
    prices = evidence.get("prices")
    if not isinstance(prices, list) or not 3 <= len(prices) <= 5 or not all(isinstance(item, str) and item for item in prices):
        raise AcceptanceError("Expected 3 to 5 returned price strings")
    if any(price not in page_text or price not in outcome["text"] for price in prices):
        raise AcceptanceError("A returned flight price is not verbatim in both the page and task response")
    if outcome["raw_outcome"] != "taskCompleted":
        raise AcceptanceError("Host did not report the flight search as completed")
    return {"passed": True, "price_count": len(prices),
            "page_text_sha256": sha256(page_text.encode("utf-8")), "actual_google_flights_url": parsed.geturl()}


def trace_path_for_evidence(raw: Any, expected_name: str, trace: Path) -> Path:
    if not isinstance(raw, str):
        raise AcceptanceError("Native page evidence path is missing")
    path = Path(raw)
    if (path.name != expected_name or path.parent.resolve() != trace.resolve()
            or path.is_symlink() or not path.is_file()):
        raise AcceptanceError("Native page evidence path is not the expected regular trace file")
    return path


def check_away(outcome: dict[str, Any]) -> dict[str, Any]:
    evidence = outcome["evidence"].get("away")
    if not isinstance(evidence, dict):
        raise AcceptanceError("Away outcome is missing real transport/display/lock evidence")
    required = {
        "cellular_route_verified": True,
        "display_asleep_verified": True,
        "locked_state_detected": True,
        "unlock_resume_prompt_shown": True,
        "pre_unlock_effect_count": 0,
    }
    for name, expected in required.items():
        if evidence.get(name) is not expected:
            raise AcceptanceError(f"Away proof failed required field: {name}")
    start_seconds = evidence.get("start_seconds")
    if not isinstance(start_seconds, (int, float)) or not 0 <= start_seconds <= 15:
        raise AcceptanceError("Away task did not start within 15 seconds over the verified cellular route")
    approval_push_seconds = evidence.get("approval_push_seconds")
    if not isinstance(approval_push_seconds, (int, float)) or not 0 <= approval_push_seconds <= 10:
        raise AcceptanceError("Away approval push did not arrive within 10 seconds")
    if outcome["raw_outcome"] != "userInterventionRequired":
        raise AcceptanceError("Locked Mac did not return a bounded unlock handoff")
    return {"passed": True, "cellular_route_verified": True, "display_asleep_verified": True,
            "locked_state_detected": True, "pre_unlock_effect_count": 0, "start_seconds": start_seconds}


def verify_run(trace: Path, expected: dict[str, Any], test_code: int) -> tuple[bool, dict[str, Any]]:
    if test_code != 0:
        return False, {"passed": False, "reason": f"xcodebuild test-without-building exit {test_code}"}
    outcome = read_outcome(trace, expected["job"], expected["run_id"])
    if outcome["raw_outcome"] == "not-started":
        return False, {"passed": False, "reason": outcome.get("text", "Task did not start"),
                       "failure_class": outcome.get("failure_class")}
    if expected["job"] == "email":
        check = check_email(expected, outcome, trace)
    elif expected["job"] == "cloud":
        check = check_cloud(expected, outcome)
    elif expected["job"] == "flights":
        check = check_flights(expected, outcome, trace)
    else:
        check = check_away(outcome)
    return True, check


def trace_path(job: str, run_id: str) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = TRACE_ROOT / f"m0-acceptance-{job}-{stamp}-{run_id[:8]}"
    path.mkdir(mode=0o700, parents=False, exist_ok=False)
    return path


def check_cloud_root(raw: str | None) -> Path | None:
    if raw:
        root = Path(raw).expanduser().resolve(strict=True)
        return validate_cloud_root(root)
    cloud_storage = Path.home() / "Library/CloudStorage"
    provider_roots = sorted((path.resolve() for path in cloud_storage.iterdir()
                             if path.is_dir() and not path.is_symlink()), key=str) if cloud_storage.is_dir() else []
    if len(provider_roots) > 1:
        raise AcceptanceError("More than one provider sync root is installed; pass --cloud-root to select one")
    if provider_roots:
        return validate_cloud_root(provider_roots[0])
    icloud = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"
    if icloud.is_dir():
        return validate_cloud_root(icloud.resolve())
    raise AcceptanceError("No installed CloudStorage or iCloud Drive sync root was found")


def validate_cloud_root(root: Path) -> Path:
    cloud_storage = Path.home() / "Library/CloudStorage"
    icloud = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"
    under_provider = cloud_storage.exists() and root != cloud_storage.resolve() and cloud_storage.resolve() in root.parents
    is_icloud = icloud.exists() and root == icloud.resolve()
    if not root.is_dir() or not (under_provider or is_icloud):
        raise AcceptanceError("Cloud root must be an existing provider sync folder under CloudStorage or iCloud Drive")
    return root


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("job", choices=("email", "cloud", "flights", "away"))
    parser.add_argument("--runs", type=int, required=True)
    parser.add_argument("--cloud-root", help="Installed provider sync folder for the cloud job")
    parser.add_argument("--build-command-json", type=Path, help="Local xcodebuild argv override file; never shell-evaluated")
    parser.add_argument("--send-approval-check", action="store_true",
                        help="For email only, verify the exact Send approval without granting it")
    args = parser.parse_args()
    if not 1 <= args.runs <= MAX_RUNS:
        parser.error(f"--runs must be between 1 and {MAX_RUNS}")
    if args.job != "cloud" and args.cloud_root:
        parser.error("--cloud-root is only valid for cloud")
    if args.send_approval_check and args.job != "email":
        parser.error("--send-approval-check is only valid for email")

    env = developer_environment(clear_live_optins())
    TRACE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    first_run_id = uuid.uuid4().hex
    first_trace = trace_path(args.job, first_run_id)
    prune_traces()
    batch_staged: Path | None = None
    batch_staged_hash: str | None = None
    try:
        cloud_root = check_cloud_root(args.cloud_root) if args.job == "cloud" else None
        fixture = prepare_fixtures()
        if args.job in {"email", "cloud"}:
            source = fixture["Board Review.pptx"]
            batch_staged = stage_source(Path(source["path"]), first_run_id, source["sha256"])
            batch_staged_hash = source["sha256"]
        base_command = load_build_command(args.build_command_json, env)
    except (AcceptanceError, OSError) as error:
        remove_owned_stage(batch_staged, batch_staged_hash)
        print(f"Preflight failed: {error}", file=sys.stderr)
        report = {"status": "failed", "job": args.job, "runs_requested": args.runs,
                  "runs_passed": 0, "failure_class": "other", "reason": f"preflight: {error}"}
        (first_trace / "runner-summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        prune_traces()
        print(f"Preflight trace: {first_trace}", flush=True)
        return 1

    try:
        build_command = command_for(base_command, "build-for-testing")
        print(f"Building once for {args.job}; trace: {first_trace}", flush=True)
        build_code, build_seconds = run_logged(build_command, env, first_trace / "build.log", TIMEOUT_SECONDS)
        if build_code != 0:
            report = {"status": "failed", "job": args.job, "runs_requested": args.runs,
                      "runs_passed": 0, "build_seconds": round(build_seconds, 3), "trace": str(first_trace),
                      "failure_class": "other", "reason": f"build-for-testing exit {build_code}"}
            (first_trace / "runner-summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            prune_traces()
            print(f"Build failed; trace: {first_trace}", flush=True)
            return 1

        if batch_staged is not None:
            readiness_started = time.monotonic()
            try:
                print("Waiting for Spotlight fixture indexing…", flush=True)
                readiness_duration = wait_for_spotlight_visibility(batch_staged, timeout=180)
            except AcceptanceError as error:
                (first_trace / "fixture-readiness.json").write_text(json.dumps({
                    "spotlight_visible": False,
                    "duration_seconds": round(time.monotonic() - readiness_started, 3),
                }, sort_keys=True) + "\n", encoding="utf-8")
                report = {"status": "failed", "job": args.job, "runs_requested": args.runs,
                          "runs_passed": 0, "build_seconds": round(build_seconds, 3),
                          "trace": str(first_trace), "failure_class": "other",
                          "reason": f"fixture readiness: {error}"}
                (first_trace / "runner-summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
                prune_traces()
                print(f"Fixture readiness failed before app launch: {error}; trace: {first_trace}", flush=True)
                return 1
            (first_trace / "fixture-readiness.json").write_text(json.dumps({
                "spotlight_visible": True,
                "duration_seconds": round(readiness_duration, 3),
            }, sort_keys=True) + "\n", encoding="utf-8")

        results: list[dict[str, Any]] = []
        run_ids = [first_run_id] + [uuid.uuid4().hex for _ in range(args.runs - 1)]
        for index, run_id in enumerate(run_ids, 1):
            trace = first_trace if index == 1 else trace_path(args.job, run_id)
            try:
                expected, _, _ = make_expected(args.job, run_id, index, fixture, cloud_root,
                                               args.send_approval_check, staged_source=batch_staged)
                (trace / "expected.json").write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n", encoding="utf-8")
                test_env = env.copy()
                test_env.update({
                    "TEST_RUNNER_CORE_JOB_ACCEPTANCE_JOB": args.job,
                    "TEST_RUNNER_CORE_JOB_ACCEPTANCE_TRACE": str(trace),
                    "TEST_RUNNER_CORE_JOB_ACCEPTANCE_FIXTURE_ROOT": str(FIXTURE_ROOT),
                    "TEST_RUNNER_CORE_JOB_ACCEPTANCE_RUN_ID": run_id,
                })
                command = command_for(base_command, "test-without-building", trace)
                print(f"Run {index}/{args.runs}: {args.job} [{run_id[:8]}]", flush=True)
                code, elapsed = run_logged(command, test_env, trace / "test.log", TIMEOUT_SECONDS)
                try:
                    passed, check = verify_run(trace, expected, code)
                except (AcceptanceError, OSError, ValueError) as error:
                    passed, check = False, {"passed": False, "reason": str(error)}
                outcome_path = trace / "outcome.json"
                failure_class = None
                if outcome_path.is_file():
                    try:
                        raw = json.loads(outcome_path.read_text(encoding="utf-8"))
                        failure_class = raw.get("failure_class")
                    except (OSError, json.JSONDecodeError):
                        pass
                run_result = {"job": args.job, "run_id": run_id, "run_index": index,
                              "passed": passed, "elapsed_seconds": round(elapsed, 3),
                              "failure_class": None if passed else (failure_class if failure_class in FAILURE_CLASSES else "other"),
                              "check": check, "trace": str(trace)}
                results.append(run_result)
                (trace / "checker.json").write_text(json.dumps(run_result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
                print(f"  {'PASS' if passed else 'FAIL'} ({elapsed:.1f}s); trace: {trace}", flush=True)
            except (AcceptanceError, OSError, ValueError) as error:
                results.append({"job": args.job, "run_id": run_id, "run_index": index,
                                "passed": False, "failure_class": "other", "check": {"passed": False, "reason": str(error)},
                                "trace": str(trace)})
                print(f"  FAIL; {error}; trace: {trace}", flush=True)
            if not results[-1]["passed"]:
                break

        passed_count = sum(1 for result in results if result["passed"])
        durations = sorted(result["elapsed_seconds"] for result in results if result.get("elapsed_seconds") is not None)
        median = None if not durations else durations[len(durations) // 2] if len(durations) % 2 else (durations[len(durations)//2-1] + durations[len(durations)//2]) / 2
        classes: dict[str, int] = {}
        for result in results:
            failure_class = result.get("failure_class")
            if failure_class:
                classes[failure_class] = classes.get(failure_class, 0) + 1
        summary = {"status": "passed" if passed_count == args.runs else "failed", "job": args.job,
                   "runs_requested": args.runs, "runs_passed": passed_count, "median_seconds": median,
                   "failure_classes": classes, "build_seconds": round(build_seconds, 3), "runs": results}
        summary_path = Path(results[-1]["trace"]) / "summary.json"
        summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        prune_traces()
        print(f"{args.job}: {passed_count}/{args.runs} passed; median {median if median is not None else 'n/a'}s; failure classes {classes or 'none'}", flush=True)
        print(f"Summary trace: {summary_path.parent}", flush=True)
        return 0 if passed_count == args.runs else 1
    finally:
        remove_owned_stage(batch_staged, batch_staged_hash)


if __name__ == "__main__":
    raise SystemExit(main())
