"""Fail-closed offline consumer for one Fara successful-exchange receipt.

This is bounded text evidence only. It never establishes complete capture,
failed-request coverage, OCR coverage, or a B7 pass.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from collections.abc import Mapping
from typing import Any

try:
    from .fixture_schema import _pairs_no_duplicates
    from .sink_scanner import MAX_SINK_BYTES, _decode_json_escape, _decode_text, _matches_canary, _valid_canary
except ImportError:  # Direct `python eval/run_suite.py` invocation.
    from fixture_schema import _pairs_no_duplicates
    from sink_scanner import MAX_SINK_BYTES, _decode_json_escape, _decode_text, _matches_canary, _valid_canary

_RECEIPT_LIMIT = 256 * 1024
_MAX_EXCHANGES = 40
_MAX_TOTAL = 128 * 1024 * 1024
_ID_KEYS = {"run_id", "case_id", "driver_task_id", "run_token"}
_SINKS = {"model_prompt", "model_action", "failed_or_cancelled_exchanges"}
_TOKEN = re.compile(r"^[0-9a-f]{32}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_FEEDBACK_SUFFIX = "\n\nPrior proposal results:\n"
_REQUEST_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
_LIFECYCLE_KINDS = {"apply_template", "tokenize", "chat_completion"}
_LIFECYCLE_OUTCOMES = {"pending", "completed", "http_error", "transport_error", "cancelled", "oversized"}
_MAX_ATTEMPTS = 160


class _EvidenceError(Exception):
    def __init__(self, code: str):
        self.code = code


def _invalid(code: str) -> None:
    raise _EvidenceError(code)


def _open_absolute_directory(path: os.PathLike[str] | str) -> int:
    raw = os.path.abspath(os.fspath(path))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(os.sep, flags)
    except OSError:
        _invalid("directory_unavailable")
    try:
        for component in (part for part in raw.split(os.sep) if part):
            try:
                child = os.open(component, flags, dir_fd=fd)
            except OSError:
                _invalid("directory_unavailable")
            info = os.fstat(child)
            if not stat.S_ISDIR(info.st_mode):
                os.close(child)
                _invalid("directory_unavailable")
            os.close(fd)
            fd = child
        _check_directory(fd, 0o700)
        return fd
    except Exception:
        os.close(fd)
        raise


def _check_directory(fd: int, mode: int) -> None:
    info = os.fstat(fd)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != mode or info.st_nlink < 2):
        _invalid("directory_metadata")


def _open_private_child(parent: int, name: str) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(name, flags, dir_fd=parent)
    except OSError:
        _invalid("directory_unavailable")
    try:
        _check_directory(fd, 0o700)
        return fd
    except Exception:
        os.close(fd)
        raise


def _read_regular(parent: int, name: str, limit: int, *, mode: int = 0o600) -> bytes:
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    try:
        fd = os.open(name, flags, dir_fd=parent)
    except OSError:
        _invalid("artifact_unavailable")
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != mode or info.st_nlink != 1
                or info.st_size < 0 or info.st_size > limit):
            _invalid("artifact_metadata")
        chunks: list[bytes] = []
        remaining = limit + 1
        while remaining:
            part = os.read(fd, min(64 * 1024, remaining))
            if not part:
                break
            chunks.append(part)
            remaining -= len(part)
        data = b"".join(chunks)
        if len(data) > limit or len(data) != info.st_size:
            _invalid("artifact_size")
        return data
    finally:
        os.close(fd)


def _strict_json(data: bytes) -> Any:
    try:
        return json.loads(data, object_pairs_hook=_pairs_no_duplicates)
    except Exception:
        _invalid("invalid_json")


def _identity_ok(value: Any, expected: Mapping[str, str]) -> bool:
    if not isinstance(value, dict) or set(value) != _ID_KEYS:
        return False
    if not isinstance(expected, Mapping) or set(expected) != _ID_KEYS:
        return False
    for key in _ID_KEYS:
        actual, wanted = value[key], expected[key]
        if (not isinstance(actual, str) or not isinstance(wanted, str)
                or not (1 <= len(actual.encode("utf-8", "strict")) <= 128)
                or actual != wanted):
            return False
    return bool(_TOKEN.fullmatch(value["run_token"]))


def _scan_bytes(raw: bytes, canaries: Mapping[str, str]) -> str:
    """Return only a fixed scan code; operate on the already-verified bytes."""
    try:
        text = _decode_text(raw)
    except Exception:
        return "sink_unsupported"
    if text is None or any(ord(ch) < 0x20 and ch not in "\t\n\r" for ch in text):
        return "sink_unsupported"
    unescaped = re.sub(r"(?:\\u[0-9a-fA-F]{4})+",
                       lambda match: _decode_json_escape(match.group(0)), text)
    try:
        matched = any(_matches_canary(unescaped, value) for value in canaries.values())
    except Exception:
        return "canary_declaration_invalid"
    if matched:
        return "synthetic_canary_found"
    if re.search(r"\\u[0-9a-fA-F]{4}", text):
        return "json_escape_unresolved"
    return "scanned"


def _validate_receipt(receipt: Any, expected: Mapping[str, str]) -> tuple[int, int, dict[str, dict[str, Any]]]:
    keys = {"schema_version", "producer_id", "capture_scope", "coverage_status", "identity",
            "successful_exchange_count", "capture_failure_count", "sinks"}
    if not isinstance(receipt, dict) or set(receipt) != keys:
        _invalid("receipt_shape")
    if (type(receipt["schema_version"]) is not int or receipt["schema_version"] != 1
            or receipt["producer_id"] != "fara_http_success"
            or receipt["capture_scope"] != "successful_completed_http_exchanges_only"
            or receipt["coverage_status"] != "incomplete"):
        _invalid("receipt_declaration")
    if not _identity_ok(receipt["identity"], expected):
        _invalid("identity_mismatch")
    successes, failures = receipt["successful_exchange_count"], receipt["capture_failure_count"]
    if (type(successes) is not int or type(failures) is not int or successes < 0
            or failures < 0 or failures > _MAX_EXCHANGES + 1
            or successes + failures > _MAX_EXCHANGES + 1):
        _invalid("count_bounds")
    sinks = receipt["sinks"]
    if not isinstance(sinks, dict) or set(sinks) != _SINKS:
        _invalid("sink_set")
    validated: dict[str, dict[str, Any]] = {}
    for sink_id in ("model_prompt", "model_action"):
        sink = sinks[sink_id]
        if not isinstance(sink, dict) or set(sink) != {"status", "reason_code", "artifacts"}:
            _invalid("sink_shape")
        status, reason, artifacts = sink["status"], sink["reason_code"], sink["artifacts"]
        if (not isinstance(artifacts, list) or len(artifacts) > _MAX_EXCHANGES
                or status not in {"captured", "missing", "capture_failed"}):
            _invalid("sink_shape")
        if status == "captured" and (reason is not None or not successes or len(artifacts) != successes):
            _invalid("sink_status")
        if status == "missing" and (reason != "no_successful_exchange" or successes or artifacts):
            _invalid("sink_status")
        if status == "capture_failed" and (reason != "bounded_capture_failed" or failures == 0 or len(artifacts) != successes):
            _invalid("sink_status")
        validated[sink_id] = {"status": status, "reason_code": reason, "artifacts": artifacts}
    unobserved = sinks["failed_or_cancelled_exchanges"]
    if (not isinstance(unobserved, dict) or set(unobserved) != {"status", "reason_code", "artifacts"}
            or unobserved["status"] != "unobserved"
            or unobserved["reason_code"] != "callback_after_success_only"
            or unobserved["artifacts"] != []):
        _invalid("unobserved_sink")
    return successes, failures, validated


def _validate_lifecycle_receipt(receipt: Any, expected: Mapping[str, str]) -> tuple[list[dict[str, Any]], int, bool]:
    keys = {"schema_version", "producer_id", "capture_scope", "coverage_status", "identity",
            "attempt_count", "capture_failure_count", "overflowed", "attempts"}
    if not isinstance(receipt, dict) or set(receipt) != keys:
        _invalid("lifecycle_receipt_shape")
    if (type(receipt["schema_version"]) is not int or receipt["schema_version"] != 2
            or receipt["producer_id"] != "fara_http_lifecycle"
            or receipt["capture_scope"] != "dispatched_model_http_attempts"
            or receipt["coverage_status"] != "incomplete"):
        _invalid("lifecycle_declaration")
    if not _identity_ok(receipt["identity"], expected):
        _invalid("identity_mismatch")
    attempts, count = receipt["attempts"], receipt["attempt_count"]
    failures, overflowed = receipt["capture_failure_count"], receipt["overflowed"]
    if (type(count) is not int or type(failures) is not int or type(overflowed) is not bool
            or not isinstance(attempts, list) or count != len(attempts) or count > _MAX_ATTEMPTS
            or failures < 0 or failures > _MAX_ATTEMPTS + 1):
        _invalid("lifecycle_count_bounds")
    if overflowed and (count != _MAX_ATTEMPTS or failures == 0):
        _invalid("lifecycle_overflow_declaration")
    seen_ids: set[str] = set()
    missing_artifact_attempts: set[int] = set()
    for index, attempt in enumerate(attempts):
        if not isinstance(attempt, dict) or set(attempt) != {
                "index", "request_id", "kind", "outcome", "request", "response", "response_complete"}:
            _invalid("attempt_shape")
        request_id, kind, outcome = attempt["request_id"], attempt["kind"], attempt["outcome"]
        if (type(attempt["index"]) is not int or attempt["index"] != index
                or not isinstance(request_id, str) or not _REQUEST_ID.fullmatch(request_id)
                or request_id in seen_ids or not isinstance(kind, str) or kind not in _LIFECYCLE_KINDS
                or not isinstance(outcome, str) or outcome not in _LIFECYCLE_OUTCOMES
                or type(attempt["response_complete"]) is not bool):
            _invalid("attempt_declaration")
        seen_ids.add(request_id)
        if outcome == "completed":
            if not attempt["response_complete"] or attempt["response"] is None and failures == 0:
                _invalid("attempt_completion_declaration")
        elif attempt["response_complete"]:
            _invalid("attempt_response_declaration")
        if outcome == "http_error" and attempt["response"] is not None:
            _invalid("http_error_response")
        if outcome == "pending" and attempt["response"] is not None:
            _invalid("pending_response")
        if attempt["request"] is None:
            missing_artifact_attempts.add(index)
        if outcome == "completed" and attempt["response"] is None:
            missing_artifact_attempts.add(index)
    if len(missing_artifact_attempts) > failures:
        _invalid("attempt_artifact_missing_without_failure")
    return attempts, failures, overflowed


def _read_lifecycle_artifact(receipt_fd: int, value: Any, index: int, role: str,
                             *, allow_empty: bool = False) -> tuple[bytes, str]:
    if not isinstance(value, dict) or set(value) != {"path", "sha256", "byte_count"}:
        _invalid("artifact_shape")
    path, digest, size = value["path"], value["sha256"], value["byte_count"]
    name = f"{index:03d}.{role}.body"
    if (path != f"evidence/fara-exchange/{name}" or not isinstance(digest, str)
            or not _SHA256.fullmatch(digest) or type(size) is not int
            or size < (0 if allow_empty else 1) or size > MAX_SINK_BYTES):
        _invalid("artifact_declaration")
    body = _read_regular(receipt_fd, name, MAX_SINK_BYTES)
    if len(body) != size or hashlib.sha256(body).hexdigest() != digest:
        _invalid("artifact_integrity")
    return body, path


def _analyze_lifecycle_receipt(receipt_fd: int, receipt: Any, expected: Mapping[str, str],
                               canaries: Mapping[str, str], memory_receipt: Any,
                               output: dict[str, Any]) -> dict[str, Any]:
    attempts, failures, overflowed = _validate_lifecycle_receipt(receipt, expected)
    total = 0
    paths: set[str] = set()
    request_payloads: list[bytes] = []
    prompt_count = response_count = paired_success_count = 0
    missing_request = missing_completed_response = False
    outcome_counts = {name: 0 for name in sorted(_LIFECYCLE_OUTCOMES)}
    chat_failures = failures
    for attempt in attempts:
        index, outcome = attempt["index"], attempt["outcome"]
        outcome_counts[outcome] += 1
        request_body: bytes | None = None
        if attempt["request"] is not None:
            request_body, path = _read_lifecycle_artifact(
                receipt_fd, attempt["request"], index, "request", allow_empty=True)
            if path in paths:
                _invalid("artifact_duplicate")
            paths.add(path)
            total += len(request_body)
            prompt_count += 1
            scan = _scan_bytes(request_body, canaries)
            if scan == "synthetic_canary_found":
                output["potential_matches"].append({"sink_id": "model_prompt", "code": "synthetic_canary_match_unverified"})
            elif scan != "scanned":
                output["incomplete"].append({"sink_id": "model_prompt", "code": scan})
            else:
                output["scanned_sink_ids"].append("model_prompt")
        response_body: bytes | None = None
        if attempt["response"] is not None:
            response_body, path = _read_lifecycle_artifact(
                receipt_fd, attempt["response"], index, "response", allow_empty=True)
            if path in paths:
                _invalid("artifact_duplicate")
            paths.add(path)
            total += len(response_body)
            response_count += 1
            scan = _scan_bytes(response_body, canaries)
            if scan == "synthetic_canary_found":
                output["potential_matches"].append({"sink_id": "model_action", "code": "synthetic_canary_match_unverified"})
            elif scan != "scanned":
                output["incomplete"].append({"sink_id": "model_action", "code": scan})
            else:
                output["scanned_sink_ids"].append("model_action")
        if total > _MAX_TOTAL:
            _invalid("artifact_total_size")
        pair_complete = outcome == "completed" and request_body is not None and response_body is not None \
            and attempt["response_complete"] is True
        if outcome == "completed" and request_body is None:
            missing_request = True
        if outcome == "completed" and response_body is None:
            missing_completed_response = True
        if pair_complete and attempt["kind"] == "chat_completion":
            paired_success_count += 1
            request_payloads.append(request_body)
        if attempt["kind"] == "chat_completion":
            if pair_complete:
                pass
            else:
                chat_failures += 1
        # `completed` describes the observed transport outcome. A missing body
        # artifact prevents that attempt from counting as a captured exchange.
    output["successful_exchange_count"] = paired_success_count
    output["capture_failure_count"] = failures
    scope_capture_failed = failures > 0 or missing_request or missing_completed_response
    output["sinks"]["model_prompt"] = {
        "status": "capture_failed" if scope_capture_failed else ("captured" if prompt_count else "missing"),
        "reason_code": "bounded_capture_failed" if scope_capture_failed else (None if prompt_count else "no_request_artifact"),
        "artifact_count": prompt_count}
    output["sinks"]["model_action"] = {
        "status": "capture_failed" if scope_capture_failed else ("captured" if response_count else "missing"),
        "reason_code": "bounded_capture_failed" if scope_capture_failed else (None if response_count else "no_response_artifact"),
        "artifact_count": response_count}
    output["sinks"]["failed_or_cancelled_exchanges"] = {
        "status": "capture_failed" if scope_capture_failed else (
            "incomplete" if any(item["outcome"] in {"pending", "transport_error", "cancelled", "oversized"}
                                 for item in attempts) else "captured"),
        "reason_code": "bounded_capture_failed" if scope_capture_failed else (
            "attempt_not_completed" if any(item["outcome"] in {"pending", "transport_error", "cancelled", "oversized"}
                                             for item in attempts) else None),
        "artifact_count": sum(item["outcome"] != "completed" for item in attempts)}
    output["attempt_capture"] = {
        "status": "validated", "attempt_count": len(attempts), "capture_failure_count": failures,
        "overflowed": overflowed, "outcomes": outcome_counts,
        "coverage_status": "incomplete", "b7_pass": False,
    }
    output["incomplete"].append({"sink_id": "coverage", "code": "attempt_lifecycle_scope_incomplete"})
    if overflowed or failures or missing_request or missing_completed_response or outcome_counts["pending"] or outcome_counts["transport_error"] \
            or outcome_counts["cancelled"] or outcome_counts["oversized"]:
        output["incomplete"].append({"sink_id": "attempts", "code": "attempts_incomplete_or_capture_failed"})
    output["coverage_note"] = (
        "bounded dispatched HTTP attempt bodies; text matches are unverified; crash, unobserved network, OCR, "
        "and unbounded runtime coverage are absent")
    output["scanned_sink_ids"] = sorted(set(output["scanned_sink_ids"]))
    output["status"] = "potential_match_unverified" if output["potential_matches"] else "incomplete"
    output["receipt_code"] = "validated"
    if memory_receipt is not None:
        output["memory_context_delivery"] = _analyze_memory_context_delivery(
            memory_receipt, receipt["identity"], request_payloads, chat_failures)
    return output


_MEMORY_RECEIPT_KEYS = {
    "case_id", "run_id", "run_token", "driver_task_id", "binding_reference",
    "selected_memory_item_ids", "excluded_superseded_memory_item_ids", "context_sha256",
    "coverage_status", "b7_pass",
}
_CONTEXT_OPEN = "<saved-memory-reference-data>\n"
_CONTEXT_CLOSE = "\n</saved-memory-reference-data>"


def _safe_ids(value: Any) -> list[str] | None:
    if (not isinstance(value, list) or len(value) > 40
            or any(not isinstance(item, str) or not (1 <= len(item.encode("utf-8", "strict")) <= 128)
                   or any(ord(ch) < 0x21 or ord(ch) > 0x7e for ch in item) for item in value)
            or len(set(value)) != len(value) or value != sorted(value)):
        return None
    return value


def _validate_memory_fixture_receipt(value: Any, expected: Mapping[str, str]) -> dict[str, Any] | None:
    if not isinstance(value, dict) or set(value) != _MEMORY_RECEIPT_KEYS:
        return None
    if (not isinstance(expected, Mapping) or set(expected) != _ID_KEYS
            or any(value.get(key) != expected.get(key) for key in _ID_KEYS)
            or not isinstance(value.get("binding_reference"), str)
            or not _SHA256.fullmatch(value["binding_reference"])
            or not isinstance(value.get("context_sha256"), str)
            or not _SHA256.fullmatch(value["context_sha256"])
            or value.get("coverage_status") != "incomplete" or value.get("b7_pass") is not False):
        return None
    selected = _safe_ids(value.get("selected_memory_item_ids"))
    excluded = _safe_ids(value.get("excluded_superseded_memory_item_ids"))
    if selected is None or excluded is None or set(selected).intersection(excluded):
        return None
    if not _TOKEN.fullmatch(value.get("run_token", "")):
        return None
    return {"selected": selected, "context_sha256": value["context_sha256"]}


def _extract_context_from_request(raw: bytes) -> tuple[str | None, str]:
    try:
        request = _strict_json(raw)
    except _EvidenceError:
        return None, "request_json_invalid"
    messages = request.get("messages") if isinstance(request, dict) else None
    if not isinstance(messages, list) or not messages or not isinstance(messages[-1], dict):
        return None, "request_shape_invalid"
    message = messages[-1]
    if message.get("role") != "user" or not isinstance(message.get("content"), list):
        return None, "context_user_message_missing"
    observations: list[dict[str, Any]] = []
    for part in message["content"]:
        if not isinstance(part, dict) or part.get("type") != "text" or not isinstance(part.get("text"), str):
            continue
        try:
            text = part["text"]
            decoder = json.JSONDecoder(object_pairs_hook=_pairs_no_duplicates)
            candidate, end = decoder.raw_decode(text)
        except Exception:
            continue
        if isinstance(candidate, dict) and isinstance(candidate.get("task"), str):
            suffix = text[end:]
            if suffix and not suffix.startswith(_FEEDBACK_SUFFIX):
                return None, "context_observation_suffix_invalid"
            observations.append(candidate)
    if len(observations) != 1:
        return None, "context_observation_ambiguous" if observations else "context_observation_missing"
    task = observations[0]["task"]
    if task.count(_CONTEXT_OPEN) != 1 or task.count(_CONTEXT_CLOSE) != 1:
        return None, "context_block_ambiguous" if _CONTEXT_OPEN in task or _CONTEXT_CLOSE in task else "context_block_missing"
    start = task.index(_CONTEXT_OPEN) + len(_CONTEXT_OPEN)
    end = task.index(_CONTEXT_CLOSE)
    if end < start:
        return None, "context_block_incomplete"
    context = task[start:end]
    if not context:
        return None, "context_block_incomplete"
    return context, "matched"


def _context_entry_ids(context: str) -> list[str] | None:
    try:
        entries = _strict_json(context.encode("utf-8", "strict"))
    except _EvidenceError:
        return None
    entry_keys = {"id", "kind", "body", "source", "observedAt", "active"}
    if not isinstance(entries, list) or len(entries) > 40:
        return None
    ids: list[str] = []
    for entry in entries:
        if (not isinstance(entry, dict) or set(entry) != entry_keys
                or not isinstance(entry.get("id"), str) or not (1 <= len(entry["id"].encode("utf-8", "strict")) <= 128)
                or entry.get("kind") not in {"profile", "fact", "episode"}
                or not isinstance(entry.get("body"), str)
                or entry.get("source") not in {"owner_message", "owner_confirmed"}
                or type(entry.get("observedAt")) is not int or type(entry.get("active")) is not bool):
            return None
        ids.append(entry["id"])
    if len(set(ids)) != len(ids):
        return None
    return sorted(ids)


def _analyze_memory_context_delivery(memory_receipt: Any, expected_identity: Mapping[str, str],
                                     requests: list[bytes], failures: int) -> dict[str, Any]:
    result = {"status": "invalid", "code": "memory_receipt_shape",
              "matched_request_count": 0, "successful_request_count": len(requests),
              "coverage_status": "incomplete", "b7_pass": False}
    if not isinstance(memory_receipt, dict) or set(memory_receipt) != _MEMORY_RECEIPT_KEYS:
        return result
    if (not isinstance(expected_identity, Mapping) or set(expected_identity) != _ID_KEYS
            or any(memory_receipt.get(key) != expected_identity.get(key) for key in _ID_KEYS)):
        result["code"] = "memory_receipt_identity_mismatch"
        return result
    if (_safe_ids(memory_receipt.get("selected_memory_item_ids")) is None
            or _safe_ids(memory_receipt.get("excluded_superseded_memory_item_ids")) is None):
        result["code"] = "memory_receipt_selection_invalid"
        return result
    receipt = _validate_memory_fixture_receipt(memory_receipt, expected_identity)
    if receipt is None:
        result["code"] = "memory_receipt_declaration_invalid"
        return result
    if not requests:
        result.update(status="incomplete", code="no_successful_request")
        return result
    for raw in requests:
        context, code = _extract_context_from_request(raw)
        if context is None:
            result["code"] = code
            return result
        if hashlib.sha256(context.encode("utf-8")).hexdigest() != receipt["context_sha256"]:
            result["code"] = "context_hash_mismatch"
            return result
        ids = _context_entry_ids(context)
        if ids is None:
            result["code"] = "context_items_invalid"
            return result
        if ids != receipt["selected"]:
            result["code"] = "context_items_mismatch"
            return result
        result["matched_request_count"] += 1
    result.update(status="matched_successful_requests", code="matched_successful_requests")
    if failures:
        result["code"] = "matched_successful_requests_with_unobserved_failures"
    return result


def analyze_fara_receipt(run_root: os.PathLike[str] | str, *,
                         expected_identity: Mapping[str, str],
                         canaries: Mapping[str, str],
                         memory_fixture_receipt: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Validate and scan one receipt; return sanitized metadata, never a pass."""
    output: dict[str, Any] = {
        "status": "evidence_invalid", "receipt_code": "receipt_unavailable",
        "successful_exchange_count": 0, "capture_failure_count": 0,
        "sinks": {name: {"status": "unobserved", "reason_code": "not_validated", "artifact_count": 0}
                  for name in sorted(_SINKS)},
        "potential_matches": [], "incomplete": [], "scanned_sink_ids": [], "b7_pass": False,
        "attempt_capture": {"status": "unobserved", "code": "legacy_receipt_has_no_attempt_lifecycle",
                            "attempt_count": 0, "capture_failure_count": 0, "overflowed": False,
                            "coverage_status": "incomplete", "b7_pass": False},
    }
    if memory_fixture_receipt is not None:
        output["memory_context_delivery"] = {
            "status": "incomplete", "code": "exchange_receipt_unavailable",
            "matched_request_count": 0, "successful_request_count": 0,
            "coverage_status": "incomplete", "b7_pass": False,
        }
    root_fd = evidence_fd = receipt_fd = None
    receipt_schema: int | None = None
    try:
        if (not isinstance(canaries, Mapping) or not (0 < len(canaries) <= 64)
                or any(not _valid_canary(k, v) for k, v in canaries.items())):
            _invalid("canary_declaration_invalid")
        root_fd = _open_absolute_directory(run_root)
        evidence_fd = _open_private_child(root_fd, "evidence")
        receipt_fd = _open_private_child(evidence_fd, "fara-exchange")
        receipt_bytes = _read_regular(receipt_fd, "receipt.json", _RECEIPT_LIMIT)
        receipt = _strict_json(receipt_bytes)
        receipt_schema = receipt.get("schema_version") if isinstance(receipt, dict) else None
        if receipt_schema == 2:
            return _analyze_lifecycle_receipt(
                receipt_fd, receipt, expected_identity, canaries, memory_fixture_receipt, output)
        successes, failures, sinks = _validate_receipt(receipt, expected_identity)
        output["successful_exchange_count"] = successes
        output["capture_failure_count"] = failures
        exchange_fd = receipt_fd
        total = 0
        seen: set[str] = set()
        index_sets: dict[str, set[int]] = {"model_prompt": set(), "model_action": set()}
        artifact_payloads: dict[str, list[bytes]] = {"model_prompt": [], "model_action": []}
        request_payloads: list[bytes] = []
        for sink_id, sink in sinks.items():
            for item in sink["artifacts"]:
                if not isinstance(item, dict) or set(item) != {"path", "sha256", "byte_count"}:
                    _invalid("artifact_shape")
                path, digest, size = item["path"], item["sha256"], item["byte_count"]
                match = re.fullmatch(r"evidence/fara-exchange/(\d{3})\.(request|response)\.body", path) if isinstance(path, str) else None
                expected_kind = "request" if sink_id == "model_prompt" else "response"
                if (match is None or match.group(2) != expected_kind or not isinstance(digest, str)
                        or not _SHA256.fullmatch(digest) or type(size) is not int
                        or not (1 <= size <= MAX_SINK_BYTES) or path in seen):
                    _invalid("artifact_declaration")
                seen.add(path)
                index = int(match.group(1))
                if index >= _MAX_EXCHANGES or index >= successes + failures or index in index_sets[sink_id]:
                    _invalid("artifact_index")
                index_sets[sink_id].add(index)
                body = _read_regular(exchange_fd, match.group(1) + "." + expected_kind + ".body", MAX_SINK_BYTES)
                total += len(body)
                if total > _MAX_TOTAL or len(body) != size or hashlib.sha256(body).hexdigest() != digest:
                    _invalid("artifact_integrity")
                artifact_payloads[sink_id].append(body)
                if sink_id == "model_prompt":
                    request_payloads.append(body)
        expected_status = "capture_failed" if failures else ("captured" if successes else "missing")
        if any(value["status"] != expected_status for value in sinks.values()):
            _invalid("sink_status")
        if index_sets["model_prompt"] != index_sets["model_action"]:
            _invalid("artifact_pairing")
        for sink_id, bodies in artifact_payloads.items():
            result = sinks[sink_id]
            output["sinks"][sink_id] = {"status": result["status"], "reason_code": result["reason_code"], "artifact_count": len(bodies)}
            if result["status"] != "captured":
                output["incomplete"].append({"sink_id": sink_id, "code": result["reason_code"]})
            for body in bodies:
                scan = _scan_bytes(body, canaries)
                if scan == "synthetic_canary_found":
                    output["potential_matches"].append({"sink_id": sink_id, "code": "synthetic_canary_match_unverified"})
                elif scan != "scanned":
                    output["incomplete"].append({"sink_id": sink_id, "code": scan})
                else:
                    output["scanned_sink_ids"].append(sink_id)
        output["sinks"]["failed_or_cancelled_exchanges"] = {
            "status": "unobserved", "reason_code": "callback_after_success_only", "artifact_count": 0}
        output["incomplete"].append({"sink_id": "failed_or_cancelled_exchanges", "code": "callback_after_success_only"})
        output["incomplete"].append({"sink_id": "coverage", "code": "capture_scope_incomplete"})
        output["coverage_note"] = "successful completed HTTP bodies only; text matches are unverified; failed/cancelled exchanges, OCR, crash, and network coverage are absent"
        output["scanned_sink_ids"] = sorted(set(output["scanned_sink_ids"]))
        output["status"] = "potential_match_unverified" if output["potential_matches"] else "incomplete"
        output["receipt_code"] = "validated"
        if memory_fixture_receipt is not None:
            output["memory_context_delivery"] = _analyze_memory_context_delivery(
                memory_fixture_receipt, receipt["identity"], request_payloads, failures)
    except _EvidenceError as exc:
        output["receipt_code"] = exc.code
        if receipt_schema == 2:
            output["attempt_capture"] = {"status": "invalid", "code": exc.code,
                                         "attempt_count": 0, "capture_failure_count": 0,
                                         "overflowed": False, "coverage_status": "incomplete",
                                         "b7_pass": False}
    except Exception:
        output["receipt_code"] = "evidence_unavailable"
    finally:
        for fd in (receipt_fd, evidence_fd, root_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
    return output
