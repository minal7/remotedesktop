"""Validate signed-host episode artifacts and their matching screenshots."""

from __future__ import annotations

import base64
import json
import uuid
from pathlib import Path
from typing import Any, Callable


def read_episode_records(
    episode_path: str | None,
    episode_root: Path,
    validate_episode: Callable[[dict[str, Any]], Any],
    normalize_text: Callable[[Any], str],
    expected_prompt: str | None = None,
    expected_task_id: str | None = None,
) -> list[dict[str, Any]]:
    if not episode_path:
        return []
    path = Path(episode_path).expanduser()
    if path.name != "episode.jsonl" or not path.is_file():
        return []
    try:
        path = path.resolve(strict=True)
        if not path.is_relative_to(episode_root):
            return []
    except OSError:
        return []
    records = _load_records(path, validate_episode)
    if not records or not _episode_path_matches(path, episode_root, records, expected_task_id):
        return []
    steps = [record for record in records if record.get("type") == "step"]
    if not _steps_are_ordered(records, steps):
        return []
    if expected_prompt and normalize_text(expected_prompt) not in normalize_text(
        steps[0].get("observation", {}).get("task", "")
    ):
        return []
    return records if _screenshots_match(path.parent, steps) else []


def _load_records(path: Path, validator: Callable[[dict[str, Any]], Any]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                if not line.strip():
                    continue
                record = json.loads(line)
                if not isinstance(record, dict):
                    return []
                validator(record)
                records.append(record)
    except (OSError, json.JSONDecodeError, ValueError, RuntimeError):
        return []
    return records


def _episode_path_matches(
    path: Path, root: Path, records: list[dict[str, Any]], expected_task_id: str | None,
) -> bool:
    episode_id = records[0].get("episode_id")
    if not episode_id or path.parent.name != episode_id:
        return False
    if expected_task_id and episode_id != expected_task_id:
        return False
    try:
        relative = path.relative_to(root)
        uuid.UUID(relative.parts[0])
        uuid.UUID(episode_id)
    except (ValueError, TypeError, AttributeError, IndexError):
        return False
    return len(relative.parts) == 4 and relative.parts[1:] == (
        "episodes", episode_id, "episode.jsonl",
    )


def _steps_are_ordered(records: list[dict[str, Any]], steps: list[dict[str, Any]]) -> bool:
    if not steps or [record.get("step") for record in steps] != list(range(len(steps))):
        return False
    episode_id = records[0].get("episode_id")
    return (all(record.get("episode_id") == episode_id for record in records)
            and not any(record.get("type") == "footer" for record in records[:-1]))


def _screenshots_match(directory: Path, steps: list[dict[str, Any]]) -> bool:
    for record in steps:
        try:
            png = base64.b64decode(record["observation"]["screenshot"], validate=True)
            path = directory / f"step-{record['step']:03d}.png"
            if not path.is_file() or path.read_bytes() != png or not png.startswith(b"\x89PNG\r\n\x1a\n"):
                return False
        except (KeyError, TypeError, ValueError, OSError):
            return False
    return True
