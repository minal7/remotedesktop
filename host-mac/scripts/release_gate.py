#!/usr/bin/env python3
"""Fail-closed Computer Use release gate aggregator.

The live acceptance runner remains the source of truth for individual jobs.
This script only aggregates its independent checker outputs and typed evidence
from external release checkers; it never treats a task/model response as proof.
"""

from __future__ import annotations

import argparse
from datetime import date, datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import time
import uuid
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
TRACE_ROOT = Path.home() / "Library/Application Support/RemoteDesktopHost/Traces"
SCRIPT_DIR = Path(__file__).resolve().parent
JOB_PATH = SCRIPT_DIR / "acceptance/run_job.sh"
REPORT_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
EVIDENCE_MAX_AGE_SECONDS = 24 * 60 * 60

GATES = [
    ("G1", "Gmail bridge: 10/10 drafts, 3/3 send stops, median ≤ 60s"),
    ("G2", "Drive and Dropbox: 10/10 each, median ≤ 45s, zero native panels"),
    ("G3", "Flights: ≥9/10, zero hallucinated prices, median ≤120s"),
    ("G4", "Apple Mail: 10/10"),
    ("G5", "Away: 5 starts ≤15s, 5 pushes ≤10s, 3 locked hand-offs"),
    ("G6", "Three consecutive full G1–G4 runs on different client dates"),
    ("G7", "Deterministic suite green ≤900s and CI green on the PR"),
    ("G8", "Injection, network audit, and credential hand-off checks"),
    ("G9", "No hang >250ms, RSS ≤8GB, thermal state acceptable"),
    ("G10", "Signed/notarized host, spctl acceptance, iOS 1.2 TestFlight"),
    ("G11", "Fresh-account onboarding complete ≤10 minutes"),
    ("G12", "README, privacy, support, and release notes updated"),
]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or unsafe JSON evidence: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON evidence must be an object: {path}")
    return value


def parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def is_number(value: Any) -> bool:
    return type(value) in (int, float)


def valid_full_report(report: dict[str, Any], commit: str, current_time: datetime,
                      current_source_clean: bool = True) -> bool:
    created = parse_time(report.get("generated_at"))
    run_id = report.get("run_id")
    try:
        client_date = date.fromisoformat(report.get("client_date", ""))
    except (TypeError, ValueError):
        return False
    if created is None or abs((client_date - created.date()).days) > 1:
        return False
    return bool(current_source_clean and report.get("source_tree_clean") is True
        and report.get("schema") == 1 and isinstance(report.get("jobs"), dict)
        and report.get("mode") == "full" and report.get("commit") == commit
        and current_time >= created
        and (current_time - created).total_seconds() <= REPORT_MAX_AGE_SECONDS
        and isinstance(run_id, str) and re.fullmatch(r"[a-f0-9]{32}", run_id))


def artifact_digest_map(summary_path: Path) -> dict[str, str]:
    summary = load_json(summary_path)
    paths = [summary_path]
    records = summary.get("runs")
    if not isinstance(records, list):
        raise ValueError("runner summary has no runs array")
    for record in records:
        trace = Path(record["trace"])
        paths.extend(trace / name for name in ("expected.json", "outcome.json", "checker.json"))
    return {str(path): sha256_file(path) for path in paths}


def check_ci_url(url: str | None, commit: str) -> tuple[bool, str]:
    if not isinstance(url, str):
        return False, "missing exact green CI run URL"
    match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/actions/runs/([0-9]+)(?:/.*)?", url)
    if not match:
        return False, "CI URL is not a GitHub Actions run link"
    if shutil.which("gh") is None:
        return False, "GitHub CLI is unavailable to independently verify CI run status"
    completed = subprocess.run(["gh", "run", "view", match.group(2), "--repo", match.group(1),
        "--json", "status,conclusion,headSha,url"], cwd=ROOT, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        return False, "could not query the supplied CI run through gh"
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return False, "gh returned invalid run metadata"
    if (value.get("status") != "completed" or value.get("conclusion") != "success"
            or value.get("headSha") != commit or value.get("url") != url):
        return False, "CI run is not green on the exact source commit"
    return True, url


def release_doc_diff() -> tuple[bool, str]:
    required = {"README.md", "docs/privacy.html", "docs/support.html", "RELEASE_NOTES.md"}
    base_ref = next((ref for ref in ("origin/main", "main") if subprocess.run(
        ["git", "rev-parse", "--verify", ref], cwd=ROOT, capture_output=True,
        text=True, check=False).returncode == 0), None)
    if base_ref is None:
        return False, "main merge-base is unavailable"
    base = subprocess.run(["git", "merge-base", "HEAD", base_ref], cwd=ROOT,
                          capture_output=True, text=True, check=False)
    if base.returncode != 0:
        return False, "could not resolve PR diff base"
    changed = subprocess.run(["git", "diff", "--name-only", f"{base.stdout.strip()}...HEAD"],
                             cwd=ROOT, capture_output=True, text=True, check=False)
    if changed.returncode != 0:
        return False, "could not inspect committed PR diff"
    found = required.intersection(changed.stdout.splitlines())
    missing = sorted(required - found)
    return not missing, ("PR diff contains all four required documents" if not missing
                         else f"PR diff is missing: {', '.join(missing)}")


def source_tree_clean() -> bool:
    status = subprocess.run(["git", "status", "--porcelain", "--untracked-files=all"],
                            cwd=ROOT, capture_output=True, text=True, check=False)
    return status.returncode == 0 and not status.stdout.strip()


def validated_job_summary(summary_path: Path, job: str, runs: int,
                          current_commit: str, started: float,
                          finished: float) -> tuple[dict[str, Any] | None, str]:
    """Validate a fresh full summary against every independent per-run checker."""
    try:
        summary = load_json(summary_path)
        flight_acceptance = (job == "flights" and summary.get("runs_requested") == 10
                             and type(summary.get("runs_passed")) is int
                             and summary["runs_passed"] >= 9)
        if summary.get("job") != job or (summary.get("status") != "passed" and not flight_acceptance):
            return None, "runner summary is missing or failed"
        if (summary.get("runs_requested") != runs
                or (summary.get("runs_passed") != runs and not flight_acceptance)):
            return None, "partial run batch"
        records = summary.get("runs")
        if not isinstance(records, list) or len(records) != runs:
            return None, "summary does not contain every run"
        passed_records = 0
        cheapest_options_correct = 0
        hallucinated_price_count = 0
        identifiers: set[str] = set()
        for record in records:
            if not isinstance(record, dict):
                return None, "run result is not a structured record"
            if record.get("passed") is True:
                passed_records += 1
            elif job != "flights":
                return None, "one or more independently checked runs failed"
            run_id = record.get("run_id")
            trace_text = record.get("trace")
            if not isinstance(run_id, str) or not re.fullmatch(r"[a-f0-9]{32}", run_id) or run_id in identifiers:
                return None, "run identity is missing, invalid, or replayed"
            identifiers.add(run_id)
            if not isinstance(trace_text, str):
                return None, "run trace path is missing"
            trace = Path(trace_text)
            if trace.is_symlink() or not trace.is_dir() or trace.parent.resolve() != TRACE_ROOT.resolve():
                return None, "run trace is outside the private acceptance trace directory"
            if not (started <= trace.stat().st_mtime <= finished + 5):
                return None, "run trace is stale or predates this gate invocation"
            expected = load_json(trace / "expected.json")
            outcome = load_json(trace / "outcome.json")
            checker = load_json(trace / "checker.json")
            checked = checker.get("check")
            if not isinstance(checked, dict) or not isinstance(outcome.get("evidence"), dict):
                return None, "checker or outcome evidence is not a structured object"
            if (expected.get("job") != job or expected.get("run_id") != run_id
                    or outcome.get("job") != job or outcome.get("run_id") != run_id
                    or checker.get("job") != job or checker.get("run_id") != run_id
                    or checker.get("passed") is not record.get("passed")
                    or checked.get("passed") is not record.get("passed")):
                return None, "expected/outcome/checker identity or checker result does not match"
            if job == "flights":
                cheapest = checked.get("cheapest_option_correct")
                hallucinated = checked.get("hallucinated_price_count")
                if type(cheapest) is not bool:
                    return None, "flight independent checker is missing boolean cheapest_option_correct"
                if type(hallucinated) is not int or hallucinated < 0:
                    return None, "flight independent checker is missing a nonnegative hallucinated_price_count"
                cheapest_options_correct += int(cheapest)
                hallucinated_price_count += hallucinated
                if hallucinated != 0:
                    return None, "flight checker found a hallucinated price"
            # The gate manifest binds checker files to a source commit and
            # a narrow invocation window.
            evidence = outcome.get("evidence", {})
            if job in {"drive", "dropbox"} and evidence.get("native_file_panel_count") != 0:
                return None, "missing proof of zero native file panels"
            if job == "gmail" and evidence.get("send_approval_granted") is True:
                return None, "Gmail send approval was granted during acceptance"
        median = summary.get("median_seconds")
        if not is_number(median) or median < 0:
            return None, "summary median is missing"
        if job == "flights":
            if passed_records < 9:
                return None, f"flight pass rate is {passed_records}/10; at least 9/10 is required"
            if cheapest_options_correct < 9:
                return None, f"flight cheapest-option checker passed {cheapest_options_correct}/10; at least 9/10 is required"
            summary["cheapest_options_correct_count"] = cheapest_options_correct
            summary["hallucinated_price_count"] = hallucinated_price_count
        summary["_summary_path"] = str(summary_path)
        return summary, "independent checker passed"
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        return None, f"invalid evidence: {error}"


def gate_result(passed: bool, evidence: str, owner_action: str = "") -> dict[str, Any]:
    return {"passed": bool(passed), "evidence": evidence,
            "owner_action": owner_action if not passed else ""}


def three_day_history(reports: list[dict[str, Any]], today: date,
                      current_commit: str) -> tuple[bool, str]:
    eligible: list[dict[str, Any]] = []
    run_ids: set[str] = set()
    for report in reports:
        run_id, client_date = report.get("run_id"), report.get("client_date")
        if (report.get("mode") != "full" or report.get("commit") != current_commit
                or report.get("source_tree_clean") is not True):
            continue
        if not isinstance(client_date, str):
            eligible.append({"invalid": True, "generated_at": report.get("generated_at", "")})
            continue
        try:
            parsed_date = date.fromisoformat(client_date)
        except ValueError:
            eligible.append({"invalid": True, "generated_at": report.get("generated_at", "")})
            continue
        age = (today - parsed_date).days
        if 0 <= age <= 21:
            created = parse_time(report.get("generated_at"))
            if created is None or abs((parsed_date - created.date()).days) > 1:
                eligible.append({"invalid": True, "generated_at": report.get("generated_at", "")})
            elif not isinstance(run_id, str) or not re.fullmatch(r"[a-f0-9]{32}", run_id) or run_id in run_ids:
                eligible.append({"invalid": True, "generated_at": report.get("generated_at", "")})
            else:
                run_ids.add(run_id)
                eligible.append(report)
    eligible.sort(key=lambda item: item.get("generated_at", ""))
    consecutive: list[dict[str, Any]] = []
    for report in eligible:
        if report.get("invalid") is True:
            consecutive = []
            continue
        try:
            run_date = date.fromisoformat(report["client_date"])
        except (KeyError, ValueError):
            consecutive = []
            continue
        if report.get("g1_g4_passed") is not True:
            consecutive = []
        else:
            if consecutive and consecutive[-1]["client_date"] == run_date.isoformat():
                # The newest attempt on a repeated date starts a fresh sequence.
                consecutive = []
            consecutive.append(report)
    if len(consecutive) < 3:
        return False, f"only {len(consecutive)} consecutive full G1–G4 runs on distinct client dates for this commit"
    return True, "; ".join(f"{item['client_date']} {item['run_id'][:8]}" for item in consecutive[-3:])


def evaluate_g1(drafts: dict[str, Any] | None, sends: dict[str, Any] | None) -> tuple[bool, str]:
    if drafts is None or sends is None:
        return False, "missing current-commit bridge-backed Gmail draft or send evidence"
    passed = (drafts.get("runs_passed") == 10 and drafts.get("runs_requested") == 10
              and is_number(drafts.get("median_seconds")) and drafts["median_seconds"] <= 60
              and sends.get("runs_passed") == 3 and sends.get("runs_requested") == 3)
    return passed, f"drafts={drafts.get('runs_passed')}/10 median={drafts.get('median_seconds')}s; send stops={sends.get('runs_passed')}/3"


def evaluate_g2(drive: dict[str, Any] | None, dropbox: dict[str, Any] | None) -> tuple[bool, str]:
    if drive is None or dropbox is None:
        return False, "missing bridge/no-native-panel checker evidence for Drive or Dropbox"
    passed = all(item.get("runs_passed") == 10 and item.get("runs_requested") == 10
                 and is_number(item.get("median_seconds")) and item["median_seconds"] <= 45
                 for item in (drive, dropbox))
    return passed, f"Drive {drive.get('runs_passed')}/10 median={drive.get('median_seconds')}s; Dropbox {dropbox.get('runs_passed')}/10 median={dropbox.get('median_seconds')}s"


def evidence_file(path: Path | None, gate: str, commit: str,
                  current_time: datetime) -> tuple[bool, str]:
    if path is None:
        return False, "no evidence file supplied"
    try:
        value = load_json(path)
        if value.get("gate") != gate or value.get("commit") != commit:
            return False, "evidence gate or commit does not match this checkout"
        created = parse_time(value.get("collected_at"))
        if created is None or created > current_time or (current_time - created).total_seconds() > EVIDENCE_MAX_AGE_SECONDS:
            return False, "evidence is missing a fresh, timezone-qualified collection time"
        if value.get("source") not in {"owner-manual", "release-workflow", "instrument", "security-checker"}:
            return False, "evidence source is not an accepted real tool or owner record"
        # Require concrete raw material references. A model-supplied `passed`
        # field is deliberately ignored; gate-specific fields below are typed.
        artifacts = value.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts:
            return False, "evidence has no raw artifact references"
        local_artifacts: list[Path] = []
        for item in artifacts:
            if not isinstance(item, str) or not item:
                return False, "artifact references must be nonempty paths or URLs"
            if item.startswith("https://"):
                if gate == "G5":
                    return False, "manual-assist evidence must include the local timestamped run log"
                continue
            artifact = Path(item).expanduser()
            if artifact.is_symlink() or not artifact.is_file():
                return False, f"raw artifact is unavailable: {item}"
            local_artifacts.append(artifact)
        if gate == "G5":
            timestamp_count = 0
            for artifact in local_artifacts:
                raw = artifact.read_text(encoding="utf-8", errors="replace")
                timestamp_count += len(re.findall(r"\b20\d{2}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\b", raw))
            if timestamp_count < 13:
                return False, "manual-assist raw log needs at least 13 timezone-qualified event timestamps"
            checks = (value.get("cellular_starts"), value.get("approval_pushes"), value.get("locked_handoffs"))
            if not (isinstance(checks[0], list) and len(checks[0]) == 5
                    and isinstance(checks[1], list) and len(checks[1]) == 5
                    and isinstance(checks[2], list) and len(checks[2]) == 3):
                return False, "manual-assist log must contain 5 starts, 5 approval pushes, and 3 locked hand-offs"
            if not all(is_number(v) and 0 <= v <= 15 for v in checks[0]):
                return False, "cellular start timing is invalid or exceeds 15s"
            if not all(is_number(v) and 0 <= v <= 10 for v in checks[1]):
                return False, "approval push timing is invalid or exceeds 10s"
            if not all(isinstance(v, dict) and v.get("locked") is True and v.get("pre_unlock_effects") == 0
                       for v in checks[2]):
                return False, "locked hand-off log is missing lock or zero-effect proof"
        return True, "; ".join(str(item) for item in artifacts)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        return False, f"invalid typed evidence: {error}"


def render_table(gates: dict[str, dict[str, Any]]) -> str:
    lines = ["Gate | Result | Evidence | Owner action", "--- | --- | --- | ---"]
    for code, _ in GATES:
        row = gates[code]
        status = "PASS" if row["passed"] else "FAIL"
        evidence = str(row.get("evidence", "" )).replace("|", "\\|").replace("\n", " ")
        owner = str(row.get("owner_action", "")).replace("|", "\\|").replace("\n", " ")
        lines.append(f"{code} | {status} | {evidence} | {owner}")
    return "\n".join(lines)


def private_command(path: Path | None, default: list[str], label: str) -> list[str]:
    if path is None:
        return default
    value = load_json(path)
    command = value.get("command")
    if not isinstance(command, list) or not command or not all(isinstance(item, str) for item in command):
        raise ValueError(f"{label} must be JSON with a string `command` argv array")
    if "xcodebuild" not in Path(command[0]).name:
        raise ValueError(f"{label} must invoke xcodebuild through structured argv")
    return command


def default_build_command(derived: Path) -> list[str]:
    return ["/usr/bin/xcodebuild", "-project", "host-mac/RemoteDesktopHost.xcodeproj",
            "-scheme", "RemoteDesktopHost", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived), "build"]


def default_test_command(derived: Path, result_bundle: Path) -> list[str]:
    return ["/usr/bin/xcodebuild", "-project", "host-mac/RemoteDesktopHost.xcodeproj",
            "-scheme", "RemoteDesktopHost", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
            "-jobs", "1", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", "90",
            "-derivedDataPath", str(derived), "-resultBundlePath", str(result_bundle),
            "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "test"]


def xcode_test_result_path(command: list[str]) -> Path:
    actions = [item for item in command if item in {"test", "test-without-building", "build-for-testing"}]
    if len(actions) != 1 or actions[0] not in {"test", "test-without-building"}:
        raise ValueError("full host suite argv must contain exactly one test or test-without-building action")
    if any(item == "-only-testing" or item.startswith("-only-testing:")
           or item == "-skip-testing" or item.startswith("-skip-testing:") for item in command):
        raise ValueError("full host suite argv cannot select or skip individual tests")
    try:
        index = command.index("-resultBundlePath")
        raw_path = command[index + 1]
    except (ValueError, IndexError):
        equal_form = next((item.split("=", 1)[1] for item in command
                           if item.startswith("-resultBundlePath=")), None)
        if not equal_form:
            raise ValueError("full host suite argv must write a fresh xcresult bundle")
        raw_path = equal_form
    if not raw_path or raw_path.startswith("-"):
        raise ValueError("full host suite result bundle path is invalid")
    path = Path(raw_path).expanduser()
    return (ROOT / path).resolve() if not path.is_absolute() else path.resolve()


def with_test_result_bundle(command: list[str], bundle: Path) -> list[str]:
    # Private argv supplies local signing/toolchain choices. The gate owns its
    # result destination, including when the supplied base argv has no path.
    result: list[str] = []
    index = 0
    while index < len(command):
        argument = command[index]
        if argument == "-resultBundlePath":
            if index + 1 >= len(command):
                raise ValueError("result bundle option is missing its value")
            index += 2
            continue
        if not argument.startswith("-resultBundlePath="):
            result.append(argument)
        index += 1
    return [*result, "-resultBundlePath", str(bundle)]


def validate_xcode_test_result(bundle: Path, started_at: float,
                               finished_at: float) -> tuple[bool, str]:
    try:
        if bundle.is_symlink() or not bundle.is_dir():
            return False, "fresh xcresult bundle is missing or unsafe"
        mtime = bundle.stat().st_mtime
        if not (started_at <= mtime <= finished_at + 5):
            return False, "xcresult bundle is stale or predates this suite run"
        completed = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                    "--path", str(bundle)], cwd=ROOT, capture_output=True,
                                   text=True, check=False)
        if completed.returncode != 0:
            return False, "xcresulttool could not read the host suite summary"
        summary = json.loads(completed.stdout)
        if not isinstance(summary, dict):
            return False, "xcresult summary is not a JSON object"
        total = summary.get("totalTestCount")
        passed = summary.get("passedTests")
        failed = summary.get("failedTests")
        expected_failures = summary.get("expectedFailures")
        skipped = summary.get("skippedTests", 0)
        if (summary.get("result") != "Passed" or type(total) is not int or total <= 0
                or type(passed) is not int or type(skipped) is not int or skipped < 0
                or passed + skipped != total
                or type(failed) is not int or failed != 0
                or type(expected_failures) is not int or expected_failures != 0):
            return False, "xcresult summary does not prove a passing nonempty suite with zero failures"
        return True, f"xcresult Passed: {passed} passed, {skipped} skipped, {failed} failed"
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        return False, f"invalid xcresult evidence: {error}"


def run_command(command: list[str], label: str, log_path: Path,
                timeout: int | None = None) -> tuple[int, float]:
    started = time.monotonic()
    log_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with log_path.open("x", encoding="utf-8") as log:
        log.write(f"$ argv: {json.dumps(command)}\n")
        log.flush()
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                   env=os.environ.copy(), start_new_session=True)
        try:
            returncode = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            log.write(f"\nTimed out after {timeout}s; terminating owned process group.\n")
            log.flush()
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            # The direct child may exit on TERM while one of its descendants
            # ignores it. Finish only the owned group before returning.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                process.wait()
            elapsed = time.monotonic() - started
            print(f"{label}: FAIL (timeout after {elapsed:.1f}s), log {log_path}", flush=True)
            return 124, elapsed
    elapsed = time.monotonic() - started
    print(f"{label}: {'PASS' if returncode == 0 else 'FAIL'} ({elapsed:.1f}s), log {log_path}", flush=True)
    return returncode, elapsed


def latest_summary(job: str) -> Path | None:
    candidates: list[Path] = []
    if not TRACE_ROOT.is_dir():
        return None
    for path in TRACE_ROOT.glob(f"m0-acceptance-{job}-*/summary.json"):
        if path.is_symlink() or not path.is_file():
            continue
        candidates.append(path)
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-only", action="store_true", help="Aggregate latest validated evidence; launch no build, UI, or model")
    parser.add_argument("--build-argv-json", type=Path, help="Private JSON {command:[...]} override for the host build")
    parser.add_argument("--test-argv-json", type=Path, help="Private JSON {command:[...]} override for the full deterministic xcodebuild test suite")
    parser.add_argument("--gmail-recipient", default=os.getenv("RELEASE_GATE_GMAIL_RECIPIENT"))
    parser.add_argument("--drive-account", default=os.getenv("RELEASE_GATE_DRIVE_ACCOUNT"))
    parser.add_argument("--dropbox-account", default=os.getenv("RELEASE_GATE_DROPBOX_ACCOUNT"))
    parser.add_argument("--ci-url", default=os.getenv("RELEASE_GATE_CI_URL"))
    parser.add_argument("--g5-evidence", type=Path)
    args = parser.parse_args()

    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=False)
    if commit.returncode or not re.fullmatch(r"[0-9a-f]{40,64}", commit.stdout.strip()):
        print("Cannot determine current source commit", file=sys.stderr)
        return 2
    commit_hash = commit.stdout.strip()
    source_clean = source_tree_clean()
    current_time = datetime.now(timezone.utc)
    client_date = date.today().isoformat()
    evidence_args = {"G5": args.g5_evidence}
    jobs: dict[str, dict[str, Any]] = {}
    build_ok = False
    suite_ok = False
    suite_seconds: float | None = None
    suite_started_at: float | None = None
    suite_finished_at: float | None = None
    suite_result_bundle: str | None = None
    ci_ok = False
    ci_detail = "missing exact green CI run URL"
    run_id = uuid.uuid4().hex
    run_root: Path | None = None
    overall_started = time.time()
    overall_finished = overall_started
    all_green = True
    if args.report_only:
        reports = []
        if TRACE_ROOT.is_dir():
            for path in TRACE_ROOT.glob("release-gate-*/report.json"):
                try:
                    report = load_json(path)
                    if valid_full_report(report, commit_hash, current_time, source_clean):
                        report["_report_path"] = str(path)
                        reports.append(report)
                except (OSError, ValueError, json.JSONDecodeError):
                    continue
        if reports:
            source = max(reports, key=lambda item: item["generated_at"])
            jobs.update(source.get("jobs", {}))
            started = parse_time(source.get("started_at"))
            finished = parse_time(source.get("finished_at"))
            if started and finished:
                overall_started, overall_finished = started.timestamp(), finished.timestamp()
            result_path = source.get("suite_result_bundle")
            source_report_path = Path(source.get("_report_path", ""))
            result_started = parse_time(source.get("suite_started_at"))
            result_finished = parse_time(source.get("suite_finished_at"))
            if (isinstance(result_path, str) and result_started and result_finished
                    and source_report_path.is_file()
                    and Path(result_path).resolve().parent == source_report_path.parent.resolve()):
                suite_result_bundle = result_path
                suite_started_at, suite_finished_at = result_started.timestamp(), result_finished.timestamp()
                suite_evidence_ok, suite_evidence = validate_xcode_test_result(
                    Path(result_path), suite_started_at, suite_finished_at)
                suite_ok = source.get("suite_passed") is True and suite_evidence_ok
                suite_seconds = source.get("suite_seconds")
                if not suite_evidence_ok:
                    print(f"Stored host suite evidence: FAIL ({suite_evidence})", file=sys.stderr)
            else:
                suite_ok = False
                suite_seconds = source.get("suite_seconds")
        else:
            overall_started = time.time() - REPORT_MAX_AGE_SECONDS - 1
            overall_finished = time.time()
    else:
        TRACE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        run_root = TRACE_ROOT / f"release-gate-{client_date}-{run_id}"
        run_root.mkdir(mode=0o700, parents=False, exist_ok=False)
        try:
            build_argv = private_command(args.build_argv_json, default_build_command(ROOT / ".build/release-gate"), "build argv")
            build_command = [item for item in build_argv if item not in {"build", "test", "build-for-testing", "test-without-building"}]
            build_command.append("build")
            build_ok = run_command(build_command, "Host build", run_root / "build.log")[0] == 0
        except (OSError, ValueError) as error:
            (run_root / "build.log").write_text(f"Unable to run configured host build: {error}\n", encoding="utf-8")
        if build_ok:
            default_result = run_root / "host-suite.xcresult"
            try:
                test_command = with_test_result_bundle(private_command(args.test_argv_json,
                    default_test_command(ROOT / ".build/release-gate", default_result), "test argv"),
                    default_result)
                result_bundle = xcode_test_result_path(test_command)
                if result_bundle.parent != run_root.resolve():
                    raise ValueError("full host suite result bundle must be inside this gate run's private trace directory")
                if result_bundle.exists() or result_bundle.is_symlink():
                    raise ValueError("full host suite result bundle path already exists; use a fresh path")
                suite_started_at = time.time()
                suite_code, suite_seconds = run_command(test_command, "Full deterministic host suite",
                    run_root / "host-suite.log", timeout=900)
                suite_finished_at = time.time()
                suite_result_bundle = str(result_bundle)
                if suite_code == 0 and suite_seconds <= 900:
                    suite_evidence_ok, suite_evidence = validate_xcode_test_result(
                        result_bundle, suite_started_at, time.time())
                    with (run_root / "host-suite.log").open("a", encoding="utf-8") as log:
                        log.write(f"\nResult validation: {suite_evidence}\n")
                    suite_ok = suite_evidence_ok
                else:
                    suite_ok = False
            except (OSError, ValueError) as error:
                (run_root / "host-suite.log").write_text(f"Unable to run configured full host suite: {error}\n", encoding="utf-8")
        else:
            (run_root / "host-suite.log").write_text("Skipped because the host build failed.\n", encoding="utf-8")
        if build_ok and suite_ok:
            for job, cli_job, count, extra in required_jobs(args):
                command = [str(JOB_PATH), cli_job, "--runs", str(count), *extra]
                code, _ = run_command(command, f"Acceptance {job} x{count}", run_root / f"{job}.log")
                summary = latest_summary(cli_job)
                if summary is not None:
                    try:
                        digests = artifact_digest_map(summary)
                    except (OSError, ValueError, KeyError, TypeError):
                        digests = {}
                    jobs[f"{job}:{count}"] = {"summary_path": str(summary), "runner_exit": code,
                                                "artifact_sha256": digests}
                if code != 0:
                    log = run_root / f"{job}.log"
                    content = log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""
                    if re.search(r"(?i)captcha|sign.in|two.factor|2fa|userInterventionRequired|handoff|owner intervention", content):
                        all_green = False
                        break
        else:
            all_green = False

    gates: dict[str, dict[str, Any]] = {}
    job_summaries: dict[str, dict[str, Any] | None] = {}
    job_specs = required_jobs(args)
    for job, cli_job, count, _ in job_specs:
        record = jobs.get(f"{job}:{count}")
        summary_path = Path(record["summary_path"]) if isinstance(record, dict) and isinstance(record.get("summary_path"), str) else None
        summary, reason = (None, "no fresh runner summary")
        if summary_path is not None:
            summary, reason = validated_job_summary(summary_path, cli_job, count, commit_hash,
                overall_started, overall_finished if args.report_only else time.time())
            if summary is not None and record:
                recorded_digests = record.get("artifact_sha256")
                try:
                    actual_digests = artifact_digest_map(summary_path)
                except (OSError, ValueError, KeyError, TypeError):
                    actual_digests = {}
                if not isinstance(recorded_digests, dict) or actual_digests != recorded_digests:
                    summary, reason = None, "acceptance artifacts changed since the full gate run"
        job_summaries[job] = summary
        jobs.setdefault(f"{job}:{count}", {})["validated"] = summary is not None
        jobs[f"{job}:{count}"]["reason"] = reason

    gmail = job_summaries.get("Gmail drafts")
    send = job_summaries.get("Gmail send approval")
    g1, g1_evidence = evaluate_g1(gmail, send)
    if gmail is None:
        g1_evidence = f"Gmail drafts: {jobs.get('Gmail drafts:10', {}).get('reason', 'missing')}; send: {jobs.get('Gmail send approval:3', {}).get('reason', 'missing')}"
    gates["G1"] = gate_result(g1,
        g1_evidence,
        "R1 bridge attestation and independent checker evidence required")
    uploads = [job_summaries.get("Drive"), job_summaries.get("Dropbox")]
    upload_ok, upload_evidence = evaluate_g2(*uploads)
    if upload_ok is False and (uploads[0] is None or uploads[1] is None):
        upload_evidence = f"Drive: {jobs.get('Drive:10', {}).get('reason', 'missing')}; Dropbox: {jobs.get('Dropbox:10', {}).get('reason', 'missing')}"
    gates["G2"] = gate_result(upload_ok, upload_evidence,
        "R1 bridge and zero-native-file-panel proof required")
    flights = job_summaries.get("Flights")
    gates["G3"] = gate_result(bool(flights and flights["runs_passed"] >= 9 and flights["runs_requested"] == 10
        and is_number(flights.get("median_seconds")) and flights["median_seconds"] <= 120
        and flights.get("cheapest_options_correct_count", 0) >= 9
        and flights.get("hallucinated_price_count") == 0),
        f"{flights['runs_passed']}/10 median={flights['median_seconds']:.1f}s" if flights else "missing fresh independently checked flight summary",
        "Flights checker must expose a zero-hallucinated-price count")
    mail = job_summaries.get("Apple Mail")
    gates["G4"] = gate_result(bool(mail and mail["runs_passed"] == 10),
        f"{mail['runs_passed']}/10" if mail else "missing fresh Apple Mail summary")
    for code in ("G5", "G8", "G9", "G10", "G11"):
        if code in {"G8", "G9", "G10", "G11"}:
            passed, detail = False, "no repository checker currently emits verifiable evidence for this gate"
        else:
            passed, detail = evidence_file(evidence_args[code], code, commit_hash, current_time)
        owner = "Owner action: supply fresh required evidence from the named real tool/checker" if not passed else ""
        if code == "G10":
            owner = "Post-draft/post-merge owner action: run the release workflow from main, then provide signing, notarization, spctl, and TestFlight proof."
            detail = "post-draft/post-merge dependency: release workflow and TestFlight upload run from main after merge"
            passed = False
        if code == "G8":
            owner = "Checker work needed: injection fixtures, outbound-network audit, and credential-fixture hand-off checker"
        if code == "G9":
            owner = "Checker work needed: acceptance-linked Instruments hang and footprint/thermal summary"
        if code == "G11":
            owner = "Owner action: fresh macOS account onboarding run with screen recording or timestamped step log"
        gates[code] = gate_result(passed, detail, owner)
    history: list[dict[str, Any]] = []
    if TRACE_ROOT.is_dir():
        for path in TRACE_ROOT.glob("release-gate-*/report.json"):
            try:
                report = load_json(path)
                history.append(report)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
    # Current run is counted only if every G1-G4 row was fully validated.
    current_g14 = all(gates[key]["passed"] for key in ("G1", "G2", "G3", "G4"))
    history.append({"mode": "full" if not args.report_only else "report-only", "run_id": run_id,
                    "commit": commit_hash, "client_date": client_date, "g1_g4_passed": current_g14,
                    "source_tree_clean": source_clean,
                    "generated_at": current_time.isoformat()})
    g6, history_text = three_day_history(history, date.today(), commit_hash)
    gates["G6"] = gate_result(g6, history_text)
    if args.report_only and reports:
        build_ok = source.get("build_passed") is True
        suite_seconds = source.get("suite_seconds")
        args.ci_url = source.get("ci_url")
        ci_ok, ci_detail = check_ci_url(args.ci_url, commit_hash)
    elif not args.report_only:
        ci_ok, ci_detail = check_ci_url(args.ci_url, commit_hash)
    else:
        ci_detail = "no full gate report for the current commit"
    g7 = bool(source_clean and build_ok and suite_ok and ci_ok
              and is_number(suite_seconds) and suite_seconds <= 900)
    gates["G7"] = gate_result(g7,
        f"build=green; suite={suite_seconds:.1f}s; CI={args.ci_url}" if source_clean and build_ok and suite_ok and ci_ok and suite_seconds is not None else
        f"source={'clean' if source_clean else 'dirty; committed-source evidence required'}; build={'green' if build_ok else 'missing/failed'}; suite={'green' if suite_ok else 'missing/failed/>900s'}; CI={ci_detail}",
        "Provide a successful build, green deterministic suite, and current PR validation workflow URL")

    doc_diff_ok, doc_diff_detail = release_doc_diff()
    gates["G12"] = gate_result(doc_diff_ok, doc_diff_detail,
                                "Update the four required docs in the committed PR diff" if not doc_diff_ok else "")

    ok = all(row["passed"] for row in gates.values())
    overall_finished = time.time()
    payload = {"schema": 1, "mode": "report-only" if args.report_only else "full", "run_id": run_id,
        "commit": commit_hash, "client_date": client_date, "generated_at": current_time.isoformat(),
        "source_tree_clean": source_clean,
        "started_at": datetime.fromtimestamp(overall_started, timezone.utc).isoformat(),
        "finished_at": datetime.fromtimestamp(overall_finished, timezone.utc).isoformat(),
        "suite_started_at": datetime.fromtimestamp(suite_started_at, timezone.utc).isoformat()
            if suite_started_at is not None else None,
        "suite_finished_at": datetime.fromtimestamp(suite_finished_at, timezone.utc).isoformat()
            if suite_finished_at is not None else None,
        "suite_result_bundle": suite_result_bundle,
        "g1_g4_passed": all(gates[key]["passed"] for key in ("G1", "G2", "G3", "G4")),
        "gates": gates, "jobs": jobs, "suite_seconds": suite_seconds, "suite_passed": suite_ok,
        "build_passed": build_ok, "ci_url": args.ci_url, "ci_green": ci_ok}
    if run_root is not None:
        (run_root / "report.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(render_table(gates))
    print(f"\nSource: {commit_hash}; run identity: {run_id}; overall: {'PASS' if ok else 'FAIL'}")
    if args.report_only:
        return 0 if ok else 1
    return 0 if ok and all_green else 1


def required_jobs(args: argparse.Namespace) -> list[tuple[str, str, int, list[str]]]:
    result = [
        ("Gmail drafts", "gmail", 10, ["--gmail-recipient", args.gmail_recipient] if args.gmail_recipient else []),
        ("Gmail send approval", "gmail", 3, ["--send-approval-check", "--gmail-recipient", args.gmail_recipient] if args.gmail_recipient else ["--send-approval-check"]),
        ("Drive", "drive", 10, ["--web-account", args.drive_account] if args.drive_account else []),
        ("Dropbox", "dropbox", 10, ["--web-account", args.dropbox_account] if args.dropbox_account else []),
        ("Flights", "flights", 10, []),
        ("Apple Mail", "email", 10, []),
        ("Away", "away", 10, []),
    ]
    return result


if __name__ == "__main__":
    raise SystemExit(main())
