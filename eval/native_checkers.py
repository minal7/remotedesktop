"""Generic local checkers for the native-app smoke tasks."""

from __future__ import annotations

from pathlib import Path
from typing import Any


def match(
    checker: dict[str, Any],
    records: list[dict[str, Any]],
    answer: str,
    scratch_root: Path | None,
) -> tuple[bool, str]:
    kind, expected = checker.get("type"), checker.get("expect")
    if kind == "app_surface":
        return _app_surface(expected, records, answer)
    if scratch_root is None or not isinstance(expected, dict):
        return False, "native filesystem checker has no per-task scratch root"
    path = _safe_path(expected.get("path"), scratch_root)
    if path is None:
        return False, "native checker path escaped the owned task directory"
    if kind == "file_text":
        return _file_text(path, expected)
    if kind == "folder_exists":
        if not path.is_dir():
            return False, "expected folder was not created"
        absent = [_safe_path(item, scratch_root) for item in expected.get("absent_paths", [])]
        if any(item is None or item.exists() for item in absent):
            return False, "an item expected to be absent still exists"
        return True, "folder state matched"
    return False, f"unsupported native checker {kind!r}"


def _safe_path(value: Any, root: Path) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    root = root.resolve(strict=True)
    candidate = Path(value)
    if not candidate.is_absolute() or candidate.is_symlink():
        return None
    try:
        resolved = candidate.resolve(strict=False)
        return resolved if resolved.is_relative_to(root) else None
    except OSError:
        return None


def _file_text(path: Path, expected: dict[str, Any]) -> tuple[bool, str]:
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 1_000_000:
            return False, "expected regular output file is missing or unsafe"
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return False, "expected output file could not be read"
    if "equals" in expected and content.removesuffix("\n") != expected["equals"].removesuffix("\n"):
        return False, "output file content did not match"
    lines = content.splitlines()
    missing = [text for text in expected.get("contains", []) if text.removesuffix("\n") not in lines]
    return not missing, "output file content matched" if not missing else f"missing content: {', '.join(missing)}"


def _app_surface(expected: Any, records: list[dict[str, Any]], answer: str) -> tuple[bool, str]:
    if not isinstance(expected, dict) or not isinstance(expected.get("bundle_id"), str):
        return False, "app_surface expectation requires bundle_id"
    seen = any(
        record.get("type") == "step"
        and record.get("observation", {}).get("surface", {}).get("kind") == "app"
        and record.get("observation", {}).get("surface", {}).get("app") == expected["bundle_id"]
        for record in records
    )
    if not seen:
        return False, "expected app was not observed"
    missing = [text for text in expected.get("answer_contains", []) if text.casefold() not in answer.casefold()]
    return not missing, "expected app was observed" if not missing else f"answer omitted: {', '.join(missing)}"
