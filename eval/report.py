"""Report writing and per-skill aggregation for evaluation runs."""

from __future__ import annotations

import csv
import json
from collections import defaultdict
from pathlib import Path
from statistics import median
from typing import Any


def write_report(output: Path, rows: list[dict[str, Any]], execution: str) -> None:
    output.mkdir(parents=True, exist_ok=True)
    infra_rows = [row for row in rows if row.get("status") == "INFRA-BLOCKED"]
    eligible = [row for row in rows if row.get("status") != "INFRA-BLOCKED"]
    (output / "run_metadata.json").write_text(json.dumps({
        "execution": execution,
        "golden_vm_eligible": execution == "tart" and bool(eligible)
            and all(row.get("vm_execution_verified") is True for row in eligible),
        "scheduled_task_runs": len(rows),
        "evaluated_task_runs": len(eligible),
        "infra_blocked_task_runs": len(infra_rows),
        "note": "real-host Mac baseline; no VM reset" if execution == "real-host" else "golden Tart VM run",
    }, indent=2) + "\n", encoding="utf-8")
    _write_json(output / "results.json", rows)
    _write_csv(output / "results.csv", rows)
    _write_skill_summary(output / "by_skill.json", rows)
    _write_checker_verdicts(output / "checker_verdicts.jsonl", rows)


def _write_json(path: Path, rows: list[dict[str, Any]]) -> None:
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temp.replace(path)


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = ["suite", "task_id", "status", "success", "steps", "wall_seconds",
              "mean_step_latency_ms", "median_total_step_latency_ms", "approvals",
              "approval_requests", "gate_rejections", "rejected_risky_proposals",
              "unsafe_count", "checker", "execution"]
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: json.dumps(row.get(key, {}), sort_keys=True)
                             if key == "gate_rejections" else row.get(key) for key in fields})


def _write_skill_summary(path: Path, rows: list[dict[str, Any]]) -> None:
    by_tag: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        for tag in row.get("tags", []):
            by_tag[tag].append(row)
    summary = {tag: _tag_summary(tagged) for tag, tagged in sorted(by_tag.items())}
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def _tag_summary(tagged: list[dict[str, Any]]) -> dict[str, Any]:
    evaluated = [row for row in tagged if row.get("status") != "INFRA-BLOCKED"]
    latencies = [row["mean_step_latency_ms"] for row in evaluated
                 if isinstance(row.get("mean_step_latency_ms"), (int, float))]
    samples = [value for row in evaluated for value in row.get("total_step_latencies_ms", [])
               if isinstance(value, (int, float)) and not isinstance(value, bool)]
    medians = samples or [row["median_total_step_latency_ms"] for row in evaluated
                          if isinstance(row.get("median_total_step_latency_ms"), (int, float))]
    rejections: dict[str, int] = defaultdict(int)
    for row in evaluated:
        for reason, count in row.get("gate_rejections", {}).items():
            rejections[reason] += count
    successes = sum(row.get("success") is True for row in evaluated)
    return {
        "scheduled_tasks": len(tagged), "tasks": len(evaluated),
        "infra_blocked": len(tagged) - len(evaluated), "successes": successes,
        "success_rate": successes / len(evaluated) if evaluated else None,
        "mean_steps": sum(row.get("steps", 0) for row in evaluated) / len(evaluated) if evaluated else None,
        "mean_wall_seconds": sum(row.get("wall_seconds", 0) or 0 for row in evaluated) / len(evaluated) if evaluated else None,
        "mean_step_latency_ms": sum(latencies) / len(latencies) if latencies else None,
        "median_total_step_latency_ms": median(medians) if medians else None,
        "approvals": sum(row.get("approvals", 0) for row in evaluated),
        "approval_requests": sum(row.get("approval_requests", 0) for row in evaluated),
        "gate_rejections": dict(rejections),
        "rejected_risky_proposals": sum(row.get("rejected_risky_proposals", 0) for row in evaluated),
        "unsafe_count": sum(row.get("unsafe_count", 0) for row in evaluated),
    }


def _write_checker_verdicts(path: Path, rows: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8") as stream:
        for row in rows:
            verdict = {key: row.get(key) for key in ("suite", "task_id", "episode_path", "checker_pass", "checker")}
            stream.write(json.dumps(verdict) + "\n")
