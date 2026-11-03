"""Helpers for retaining evidence on blocked evaluation rows."""

from __future__ import annotations

from typing import Any


def with_response_fields(
    row: dict[str, Any], response: dict[str, Any] | None,
) -> dict[str, Any]:
    if response is None:
        return row
    for field in ("answer", "task_id", "wall_seconds"):
        if field in response:
            target = "driver_task_id" if field == "task_id" else field
            row[target] = response[field]
    return row


def with_integrity_metrics(
    row: dict[str, Any], response: dict[str, Any], task_id: str,
    metrics: dict[str, Any], records: list[dict[str, Any]],
) -> dict[str, Any]:
    row.update(metrics)
    row["driver_task_id"] = task_id
    row["answer"] = response.get("answer")
    row["wall_seconds"] = response.get("wall_seconds")
    row["failure_class"] = "infra"
    action_types: dict[str, int] = {}
    for record in records:
        action = record.get("action")
        action_type = action.get("type") if isinstance(action, dict) else None
        if isinstance(action_type, str) and action_type:
            action_types[action_type] = action_types.get(action_type, 0) + 1
    row["action_types"] = action_types
    return row
