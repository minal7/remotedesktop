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
    infra_rows = [row for row in rows if _is_infrastructure(row)]
    eligible = [row for row in rows if not _is_infrastructure(row)]
    (output / "run_metadata.json").write_text(json.dumps({
        "execution": execution,
        "golden_vm_eligible": execution == "tart" and bool(eligible)
            and all(row.get("vm_execution_verified") is True for row in eligible),
        "scheduled_task_runs": len(rows),
        "evaluated_task_runs": len(eligible),
        "infra_blocked_task_runs": len(infra_rows),
        "observed_infra_task_runs": sum(_has_observation(row) for row in infra_rows),
        "count_semantics": {
            "scheduled_task_runs": "all result rows, including infrastructure rows",
            "evaluated_task_runs": "non-infrastructure rows used in model denominators",
            "infra_blocked_task_runs": "rows with INFRA-BLOCKED status or infra failure_class",
            "observed_infra_task_runs": "infrastructure rows with one or more recorded steps",
        },
        "actual_policies": _count_values(rows, "policy"),
        "actual_environments": _count_values(rows, "environment"),
        "actual_crop_modes": _count_values(rows, "crop_mode"),
        "note": "real-host Mac baseline; no VM reset" if execution == "real-host" else "golden Tart VM run",
    }, indent=2) + "\n", encoding="utf-8")
    _write_json(output / "results.json", rows)
    _write_csv(output / "results.csv", rows)
    _write_group_summary(output / "by_suite.json", rows, "suite")
    _write_skill_summary(output / "by_skill.json", rows)
    _write_skill_policy_summary(output / "by_skill_policy.json", rows)
    _write_group_summary(output / "by_policy.json", rows, "policy")
    _write_group_summary(output / "by_environment.json", rows, "environment")
    _write_group_summary(output / "by_crop_mode.json", rows, "crop_mode")
    _write_group_summary(output / "by_requested_crop_mode.json", rows, "requested_crop_mode")
    _write_checker_verdicts(output / "checker_verdicts.jsonl", rows)


def _write_json(path: Path, rows: list[dict[str, Any]]) -> None:
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temp.replace(path)


def _write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields = ["suite", "task_id", "environment", "policy", "requested_policy", "crop_mode", "requested_crop_mode",
              "status", "success", "steps", "wall_seconds", "failure_class",
              "mean_step_latency_ms", "median_observe_latency_ms", "median_model_latency_ms",
              "median_execute_latency_ms", "median_total_step_latency_ms", "observe_step_latencies_ms",
              "model_step_latencies_ms", "execute_step_latencies_ms", "total_step_latencies_ms", "approvals",
              "approval_requests", "gate_rejections", "rejected_risky_proposals",
              "unsafe_count", "checker", "execution"]
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: json.dumps(row.get(key, {} if key == "gate_rejections" else []), sort_keys=True)
                             if key in {"gate_rejections", "observe_step_latencies_ms", "model_step_latencies_ms",
                                        "execute_step_latencies_ms", "total_step_latencies_ms"} else row.get(key)
                             for key in fields})


def _write_skill_summary(path: Path, rows: list[dict[str, Any]]) -> None:
    by_tag: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        for tag in row.get("tags", []):
            by_tag[tag].append(row)
    summary = {tag: _tag_summary(tagged) for tag, tagged in sorted(by_tag.items())}
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def _count_values(rows: list[dict[str, Any]], field: str) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    for row in rows:
        counts[str(row.get(field) or "none")] += 1
    return dict(sorted(counts.items()))


def _write_group_summary(path: Path, rows: list[dict[str, Any]], field: str) -> None:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[str(row.get(field) or "none")].append(row)
    summary = {key: _tag_summary(value) for key, value in sorted(groups.items())}
    path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")


def _write_skill_policy_summary(path: Path, rows: list[dict[str, Any]]) -> None:
    grouped: dict[str, dict[str, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for row in rows:
        for tag in row.get("tags", []):
            grouped[tag][str(row.get("policy") or "none")].append(row)
    summary = {tag: {policy: _tag_summary(items) for policy, items in sorted(policies.items())}
               for tag, policies in sorted(grouped.items())}
    path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")


def _tag_summary(tagged: list[dict[str, Any]]) -> dict[str, Any]:
    infra_rows = [row for row in tagged if _is_infrastructure(row)]
    evaluated = [row for row in tagged if not _is_infrastructure(row)]
    latencies = [row["mean_step_latency_ms"] for row in evaluated
                 if isinstance(row.get("mean_step_latency_ms"), (int, float))]
    phases = {"observe": "observe_step_latencies_ms", "model": "model_step_latencies_ms",
              "execute": "execute_step_latencies_ms", "total": "total_step_latencies_ms"}
    samples = {phase: _step_samples(evaluated, field) for phase, field in phases.items()}
    required_fields = tuple(phases.values())
    complete_rows = sum(all(isinstance(row.get(field), list) for field in required_fields) for row in evaluated)
    aggregation = ("pooled_step_samples" if evaluated and complete_rows == len(evaluated)
                   else "pooled_available_step_samples" if complete_rows or any(samples.values())
                   else "unavailable_no_raw_step_samples")
    rejections: dict[str, int] = defaultdict(int)
    failure_classes: dict[str, int] = defaultdict(int)
    for row in evaluated:
        for reason, count in row.get("gate_rejections", {}).items():
            rejections[reason] += count
        if row.get("failure_class"):
            failure_classes[str(row["failure_class"])] += 1
    successes = sum(row.get("success") is True for row in evaluated)
    return {
        "scheduled_tasks": len(tagged), "tasks": len(evaluated),
        "infra_blocked": len(infra_rows),
        "observed_infra": sum(_has_observation(row) for row in infra_rows), "successes": successes,
        "count_semantics": {
            "scheduled_tasks": "all rows in this group",
            "tasks": "non-infrastructure rows used in model denominators",
            "infra_blocked": "rows with INFRA-BLOCKED status or infra failure_class",
            "observed_infra": "infrastructure rows with one or more recorded steps",
        },
        "success_rate": successes / len(evaluated) if evaluated else None,
        "mean_steps": sum(row.get("steps", 0) for row in evaluated) / len(evaluated) if evaluated else None,
        "mean_wall_seconds": sum(row.get("wall_seconds", 0) or 0 for row in evaluated) / len(evaluated) if evaluated else None,
        "mean_step_latency_ms": sum(latencies) / len(latencies) if latencies else None,
        "median_total_step_latency_ms": median(samples["total"]) if samples["total"] else None,
        "median_observe_latency_ms": median(samples["observe"]) if samples["observe"] else None,
        "median_model_latency_ms": median(samples["model"]) if samples["model"] else None,
        "median_execute_latency_ms": median(samples["execute"]) if samples["execute"] else None,
        "latency_aggregation": aggregation,
        "approvals": sum(row.get("approvals", 0) for row in evaluated),
        "approval_requests": sum(row.get("approval_requests", 0) for row in evaluated),
        "gate_rejections": dict(rejections),
        "rejected_risky_proposals": sum(row.get("rejected_risky_proposals", 0) for row in evaluated),
        "unsafe_count": sum(row.get("unsafe_count", 0) for row in evaluated),
        "failure_classes": dict(failure_classes),
    }


def _is_infrastructure(row: dict[str, Any]) -> bool:
    return row.get("status") == "INFRA-BLOCKED" or row.get("failure_class") == "infra"


def _has_observation(row: dict[str, Any]) -> bool:
    steps = row.get("steps")
    return isinstance(steps, int) and not isinstance(steps, bool) and steps > 0


def _step_samples(rows: list[dict[str, Any]], field: str) -> list[float]:
    return [value for row in rows for value in (row.get(field) if isinstance(row.get(field), list) else [])
            if isinstance(value, (int, float)) and not isinstance(value, bool)]


def _write_checker_verdicts(path: Path, rows: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8") as stream:
        for row in rows:
            verdict = {key: row.get(key) for key in ("suite", "task_id", "episode_path", "checker_pass", "checker")}
            stream.write(json.dumps(verdict) + "\n")
