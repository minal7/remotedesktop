"""Generic local checkers for the native-app smoke tasks."""

from __future__ import annotations

import subprocess
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
        info = path.stat()
        evidence = (f"folder exists: {path.name}; device={info.st_dev}; inode={info.st_ino}; "
                    f"mode={info.st_mode:o}; mtime_ns={info.st_mtime_ns}")
        return True, evidence
    return False, f"unsupported native checker {kind!r}"


def _safe_path(value: Any, root: Path) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    if root.is_symlink():
        return None
    root_raw = root
    root = root.resolve(strict=True)
    candidate = Path(value)
    if not candidate.is_absolute() or candidate.is_symlink():
        return None
    try:
        permitted = [root_raw]
        for name in ("Documents", "Desktop"):
            base = Path.home() / name
            if base.is_dir() and not base.is_symlink():
                permitted.append(base)
        lexical_base = next((base for base in permitted
                             if candidate == base or candidate.is_relative_to(base)), None)
        if lexical_base is None:
            return None
        current = candidate
        while current != lexical_base:
            if current.is_symlink():
                return None
            current = current.parent
        if lexical_base.is_symlink():
            return None
        resolved = candidate.resolve(strict=False)
        resolved_base = lexical_base.resolve(strict=True)
        return resolved if resolved == resolved_base or resolved.is_relative_to(resolved_base) else None
    except OSError:
        return None


def _file_text(path: Path, expected: dict[str, Any]) -> tuple[bool, str]:
    stem = expected.get("stem")
    candidates = [path]
    if isinstance(stem, str):
        if path.name != stem:
            return False, "checker path and expected filename stem differ"
        candidates = [path.with_name(f"{stem}.txt")]
        if expected.get("allow_rtf") is True:
            candidates.append(path.with_name(f"{stem}.rtf"))
    existing = [candidate for candidate in candidates if candidate.exists() or candidate.is_symlink()]
    if len(existing) != 1:
        return False, "expected exactly one output file with the requested filename stem"
    path = existing[0]
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 1_000_000:
            return False, "expected regular output file is missing or unsafe"
        if path.suffix.casefold() == ".rtf":
            if expected.get("allow_rtf") is not True:
                return False, "rich-text output is not allowed for this task"
            converted = subprocess.run(
                ["/usr/bin/textutil", "-convert", "txt", "-stdout", str(path)],
                capture_output=True, text=True, timeout=10, check=False,
            )
            if converted.returncode != 0:
                return False, "rich-text output could not be converted"
            content = converted.stdout
        else:
            content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        return False, "expected output file could not be read"
    if "equals" in expected and content != expected["equals"]:
        return False, "output file content did not match"
    lines = content.splitlines()
    missing = [text.removesuffix("\n") for text in expected.get("contains", [])
               if text.removesuffix("\n") not in lines]
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
