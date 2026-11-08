#!/usr/bin/env python3
"""Turns finished suite runs into one table, from their results and traces.

  compare.py build/localagent/matrix > build/localagent/matrix/REPORT.md
"""
import json, statistics, sys
from collections import defaultdict
from pathlib import Path

def trace_numbers(path):
    numbers = defaultdict(int)
    if not path.exists():
        return numbers
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("event")
        if kind == "planner":
            numbers["planner_calls"] += 1
            numbers["planner_peak"] = max(numbers["planner_peak"], event.get("prompt_tokens", 0))
            numbers["planner_ms"] += int(event.get("seconds", 0) * 1000)
            numbers["planner_ctx"] = event.get("context_tokens", 0)
        elif kind == "job_start":
            numbers["jobs"] += 1
        elif kind == "compaction":
            numbers["compactions"] += 1
        elif kind == "planner_overflow":
            numbers["overflows"] += 1
        elif kind == "step":
            numbers["worker_peak"] = max(numbers["worker_peak"], event.get("prompt_tokens", 0))
    return numbers

def main():
    setups = defaultdict(list)
    for results in sorted(Path(sys.argv[1]).rglob("results.json")):
        for row in json.loads(results.read_text()):
            suffix = f"-{row['round']}" if (results.parent / f"{row['id']}-{row.get('round', 0)}").exists() else ""
            row.update(trace_numbers(results.parent / (row["id"] + suffix) / "trace.jsonl"))
            setups[results.parent.name.rsplit("-", 1)[0]].append(row)
    print("| Setup | Ad tasks passed | Passed | Said done | Harness faults | Interrupted | Steps | Seconds | Peak GB | Planner peak | Worker peak | Jobs | Compactions |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    def rate(rows):
        counted = [r for r in rows if r["status"] in ("pass", "FAIL")]
        return sum(r["status"] == "pass" for r in counted) / max(1, len(counted))
    for name, rows in sorted(setups.items(), key=lambda item: -rate([r for r in item[1] if r.get("ad")] or item[1])):
        counted = [r for r in rows if r["status"] in ("pass", "FAIL")]
        wins = [r for r in counted if r["status"] == "pass"]
        peaks = [r["peak_gb"] for r in rows if r.get("peak_gb")]
        median = lambda key: statistics.median(r[key] for r in wins) if wins else 0
        ads = [r for r in counted if r.get("ad")]
        print(f"| {name} | {sum(r['status'] == 'pass' for r in ads)}/{len(ads)} | {len(wins)}/{len(counted)} | {sum(bool(r.get('finished')) for r in wins)}/{len(wins)} | {sum(r['status'] in ('HUNG', 'CRASHED') for r in rows)} | {sum(r['status'] == 'interrupted' for r in rows)} "
              f"| {median('steps'):.0f} | {median('seconds'):.0f} | {max(peaks) if peaks else 0:.1f} "
              f"| {max(r.get('planner_peak', 0) for r in rows)} | {max(r.get('worker_peak', 0) for r in rows)} "
              f"| {sum(r.get('jobs', 0) for r in rows)} | {sum(r.get('compactions', 0) for r in rows)} |")
    print("\nPassed means the work really got done. Said done counts the passes where the agent also told the person it had finished. Steps and seconds are medians over passed tasks. Peak GB adds each server's own peak, so it can overstate the true combined peak.\n")
    tasks = sorted({r["id"] for rows in setups.values() for r in rows})
    print("| Task | " + " | ".join(setups) + " |")
    print("|---|" + "---|" * len(setups))
    for task in tasks:
        cells = []
        for rows in setups.values():
            mine = [r for r in rows if r["id"] == task]
            cells.append(f"{sum(r['status'] == 'pass' for r in mine)}/{len(mine)}" if mine else "")
        print(f"| {task} | " + " | ".join(cells) + " |")

if __name__ == "__main__":
    main()
