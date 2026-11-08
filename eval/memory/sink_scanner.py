"""Bounded offline synthetic-canary scanning for declared artifact sinks.

This utility reports text-scan coverage only. It does not execute B7 cases,
inspect images with OCR, or establish any suite pass.
"""

from __future__ import annotations

import base64
import os
import json
import re
import stat
from pathlib import Path
from typing import Mapping, Sequence
from urllib.parse import quote

try:
    from .fixture_schema import OBSERVATIONS
except ImportError:  # Direct `python eval/run_suite.py` invocation.
    from fixture_schema import OBSERVATIONS

MAX_SINK_BYTES = 8 * 1024 * 1024
MAX_SINKS = 128
MAX_CANARIES = 64
MAX_CANARY_CHARS = 4096
_SAFE_ID = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
_SAFE_SINK_IDS = frozenset(OBSERVATIONS)


def _variants(value: str) -> set[str]:
    normalized = "".join(ch for ch in value.casefold() if ch.isalnum())
    seeds = {value, normalized}
    code_units = value.encode("utf-16-be")
    seeds.add("".join(f"\\u{int.from_bytes(code_units[i:i + 2], 'big'):04x}"
                      for i in range(0, len(code_units), 2)))
    seeds.add(json.dumps(value, ensure_ascii=True)[1:-1])
    variants = set(seeds)
    for seed in seeds:
        variants.add(quote(seed, safe=""))
        variants.add("".join(f"%{byte:02X}" for byte in seed.encode("utf-8")))
        variants.add(base64.b64encode(seed.encode("utf-8")).decode("ascii"))
    return {item.casefold() for item in variants if item}


def _contains_token_bounded(text: str, value: str) -> bool:
    start = 0
    while (match := text.find(value, start)) >= 0:
        before_is_alphanumeric = match > 0 and text[match - 1].isalnum()
        end = match + len(value)
        after_is_alphanumeric = end < len(text) and text[end].isalnum()
        if not before_is_alphanumeric and not after_is_alphanumeric:
            return True
        start = match + 1
    return False


def _matches_canary(text: str, value: str, forms: set[str] | None = None) -> bool:
    """Match literal encodings or a separator-normalized value on token bounds."""
    folded = text.casefold()
    forms = _variants(value) if forms is None else forms
    normalized_value = "".join(ch for ch in value.casefold() if ch.isalnum())
    short_alphabetic = normalized_value.isalpha() and len(normalized_value) <= 4
    if (any(_contains_token_bounded(folded, form) for form in forms) if short_alphabetic
            else any(form in folded for form in forms)):
        return True
    if not normalized_value:
        return False
    normalized_chars: list[str] = []
    source_positions: list[int] = []
    for index, character in enumerate(folded):
        if character.isalnum():
            normalized_chars.append(character)
            source_positions.append(index)
    normalized_text = "".join(normalized_chars)
    start = 0
    while (match := normalized_text.find(normalized_value, start)) >= 0:
        source_start = source_positions[match]
        source_end = source_positions[match + len(normalized_value) - 1]
        before_is_alphanumeric = source_start > 0 and folded[source_start - 1].isalnum()
        after_is_alphanumeric = source_end + 1 < len(folded) and folded[source_end + 1].isalnum()
        if not before_is_alphanumeric and not after_is_alphanumeric:
            return True
        start = match + 1
    return False


def _safe_identifier(value: object) -> bool:
    return isinstance(value, str) and bool(_SAFE_ID.fullmatch(value)) and value in _SAFE_SINK_IDS


def _valid_canary(canary_id: object, value: object) -> bool:
    if not isinstance(canary_id, str) or not _SAFE_ID.fullmatch(canary_id) or not isinstance(value, str) or not (0 < len(value) <= MAX_CANARY_CHARS):
        return False
    try:
        value.encode("utf-16-be")
    except UnicodeEncodeError:
        return False
    return True


def scan_declared_sinks(
    sinks: Mapping[str, Path],
    *,
    required_sink_ids: Sequence[str],
    canaries: Mapping[str, str],
    capture_coverage: bool = False,
    ocr_coverage: bool = False,
    max_sink_bytes: int = MAX_SINK_BYTES,
) -> dict[str, object]:
    """Scan explicitly declared files; output contains IDs and stable codes only."""
    findings: list[dict[str, str]] = []
    incomplete: list[dict[str, str]] = []
    scanned: list[str] = []
    if type(max_sink_bytes) is not int or not (1 <= max_sink_bytes <= MAX_SINK_BYTES):
        max_sink_bytes = MAX_SINK_BYTES
        incomplete.append({"sink_id": "scan", "code": "invalid_limit"})

    required_values = list(required_sink_ids) if isinstance(required_sink_ids, Sequence) and not isinstance(required_sink_ids, (str, bytes)) else []
    required = {item for item in required_values[:MAX_SINKS] if _safe_identifier(item)}
    declared_values = list(sinks) if isinstance(sinks, Mapping) else []
    declared = {item for item in declared_values[:MAX_SINKS] if _safe_identifier(item)}
    invalid = (not isinstance(sinks, Mapping) or not required_values
               or len(required_values) > MAX_SINKS or len(declared_values) > MAX_SINKS
               or any(not _safe_identifier(item) for item in required_values + declared_values))
    canary_items = list(canaries.items())[:MAX_CANARIES + 1] if isinstance(canaries, Mapping) else []
    valid_canaries = 0 < len(canary_items) <= MAX_CANARIES and all(
        _valid_canary(key, value) for key, value in canary_items)
    if type(capture_coverage) is not bool or type(ocr_coverage) is not bool:
        incomplete.append({"sink_id": "scan", "code": "invalid_coverage_declaration"})
    if invalid or not valid_canaries:
        incomplete.append({"sink_id": "scan", "code": "invalid_declaration"})

    variants = ({canary_id: _variants(value) for canary_id, value in canary_items
                 if _valid_canary(canary_id, value)} if valid_canaries else {})

    for sink_id in sorted(required - declared):
        incomplete.append({"sink_id": sink_id, "code": "sink_missing"})

    for sink_id in sorted(declared):
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
            descriptor = os.open(os.fspath(sinks[sink_id]), flags)
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                os.close(descriptor)
                incomplete.append({"sink_id": sink_id, "code": "sink_unsupported"})
                continue
            with os.fdopen(descriptor, "rb") as stream:
                raw = stream.read(max_sink_bytes + 1)
        except (OSError, TypeError, ValueError):
            incomplete.append({"sink_id": sink_id, "code": "sink_unreadable"})
            continue
        if len(raw) > max_sink_bytes:
            incomplete.append({"sink_id": sink_id, "code": "sink_truncated"})
            continue
        if not raw:
            incomplete.append({"sink_id": sink_id, "code": "sink_empty"})
            continue

        decoded = _decode_text(raw)
        if decoded is None:
            incomplete.append({"sink_id": sink_id, "code": "sink_unsupported"})
            continue
        if any(ord(character) < 0x20 and character not in "\t\n\r" for character in decoded):
            incomplete.append({"sink_id": sink_id, "code": "sink_unsupported"})
            continue

        unescaped = re.sub(r"(?:\\u[0-9a-fA-F]{4})+",
                           lambda match: _decode_json_escape(match.group(0)), decoded)
        matched = any(_matches_canary(unescaped, value, variants[canary_id])
                      for canary_id, value in canary_items
                      if _valid_canary(canary_id, value))
        if matched:
            findings.append({"sink_id": sink_id, "code": "synthetic_canary_found"})
        elif re.search(r"\\u[0-9a-fA-F]{4}", decoded):
            incomplete.append({"sink_id": sink_id, "code": "json_escape_unresolved"})
            continue
        scanned.append(sink_id)

    if capture_coverage is not True:
        incomplete.append({"sink_id": "capture", "code": "capture_coverage_missing"})
    if ocr_coverage is not True:
        incomplete.append({"sink_id": "images", "code": "ocr_coverage_missing"})

    status = "leak_detected" if findings else (
        "incomplete" if incomplete else "covered_text_scan")
    return {
        "status": status,
        "findings": findings,
        "incomplete": incomplete,
        "scanned_sink_ids": sorted(scanned),
        "b7_pass": False,
        "coverage_scope": "bounded text scan; capture and OCR declarations are caller supplied and unverified",
    }


def _decode_json_escape(value: str) -> str:
    try:
        return json.loads('"' + value + '"')
    except (json.JSONDecodeError, UnicodeDecodeError):
        return value


def _decode_text(raw: bytes) -> str | None:
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        try:
            text = raw.decode("utf-16")
        except UnicodeDecodeError:
            return None
        return text if "\x00" not in text else None
    try:
        text = raw.decode("utf-8-sig")
        if "\x00" not in text:
            return text
    except UnicodeDecodeError:
        pass
    if len(raw) < 4 or len(raw) % 2:
        return None
    even_zeros = sum(raw[index] == 0 for index in range(0, len(raw), 2)) / (len(raw) // 2)
    odd_zeros = sum(raw[index] == 0 for index in range(1, len(raw), 2)) / (len(raw) // 2)
    zero_count = raw.count(b"\x00")
    if zero_count < 4:
        return None
    if even_zeros >= 0.40 and odd_zeros <= 0.05:
        encoding = "utf-16-be"
    elif odd_zeros >= 0.40 and even_zeros <= 0.05:
        encoding = "utf-16-le"
    else:
        return None
    try:
        text = raw.decode(encoding)
    except UnicodeDecodeError:
        return None
    return text if "\x00" not in text else None
