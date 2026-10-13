"""Strict validation and invocation for the signed host's startup preflight."""

from __future__ import annotations

import json
import math
import subprocess
from dataclasses import dataclass
from typing import Any

EXPECTED_CHECKS = (
    "host_process", "accessibility", "screen_recording", "pixel_environment", "model",
)
SUPPORTED_POLICIES = {"fara15-4b", "ui-tars15-7b"}


@dataclass(frozen=True)
class PreflightResult:
    passed: bool
    reason: str
    owner_action: str
    response: dict[str, Any] | None = None


def evaluate(response: Any, requested_policy: str = "fara15-4b") -> PreflightResult:
    if not isinstance(response, dict):
        return failed("Host preflight did not return a JSON object.", "Start the signed host app and rerun preflight.")
    required = {"operation", "real_host_app", "outcome", "checks", "active_environment", "policy"}
    if (required - response.keys() or response.get("operation") != "preflight"
            or response.get("real_host_app") is not True):
        return failed("Host preflight response was incomplete or did not prove the real app.",
                      "Use the signed Remote Desktop Host evaluation driver.")
    if (requested_policy not in SUPPORTED_POLICIES or response.get("policy") != requested_policy
            or response.get("active_environment") != "pixel"):
        return failed("Host preflight model or environment did not match the request.",
                      "Use the current signed host app evaluation driver.", response)
    if response.get("outcome") != "ready":
        reason = response.get("blocked_reason")
        action = response.get("owner_action")
        if not isinstance(reason, str) or not reason or not isinstance(action, str) or not action:
            return failed("Blocked host preflight omitted its reason or owner action.",
                          "Use the current signed host app evaluation driver.", response)
        return failed(reason if isinstance(reason, str) and reason else "Host startup preflight was blocked.",
                      action if isinstance(action, str) and action else "Resolve the host preflight issue, then rerun.",
                      response)
    checks = response.get("checks")
    if (not isinstance(checks, list) or len(checks) != len(EXPECTED_CHECKS)
            or not all(isinstance(item, dict) for item in checks)
            or [item.get("name") for item in checks] != list(EXPECTED_CHECKS)):
        return failed("Host preflight did not report every required check in order.",
                      "Update the signed host app to the current preflight protocol.", response)
    if any(item.get("status") != "passed" for item in checks):
        return failed("One or more host preflight checks did not pass.",
                      "Resolve the blocked host check shown in the preflight response.", response)
    if response.get("model_status") != "loaded":
        return failed("Host preflight reported incomplete Pixel environment or model readiness.",
                      "Resolve Pixel environment or selected model readiness, then rerun.", response)
    if not _pixel_readiness_is_valid(response):
        return failed("Host preflight did not report valid Pixel readiness details.",
                      "Use the current signed host app evaluation driver.", response)
    return PreflightResult(True, "Host preflight passed.", "", response)


def _pixel_readiness_is_valid(response: dict[str, Any]) -> bool:
    backend = response.get("active_backend", "pixel")
    readiness = response.get("pixel_readiness", {})
    if backend != "pixel" or not isinstance(readiness, dict):
        return False
    if not readiness:
        return True
    p95 = readiness.get("p95_ms")
    return (readiness.get("ready") is True and readiness.get("active_backend") == "pixel"
            and isinstance(p95, (int, float)) and not isinstance(p95, bool)
            and math.isfinite(p95) and p95 >= 0)


def invoke(command: list[str], probe_url: str, env: dict[str, str], timeout: float,
           policy: str = "fara15-4b") -> PreflightResult:
    request = json.dumps({"operation": "preflight", "probe_url": probe_url, "policy": policy}, separators=(",", ":"))
    try:
        completed = subprocess.run(command, input=request, text=True, capture_output=True,
                                   env=env, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        return failed(f"Host preflight invocation failed: {type(error).__name__}.",
                      "Start the signed host app and rerun the evaluation preflight.")
    if completed.returncode != 0:
        return failed(f"Host preflight driver exited with status {completed.returncode}.",
                      "Check the signed host app and evaluation driver logs, then rerun.")
    try:
        response = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return failed("Host preflight stdout was not one JSON response.",
                      "Use the current signed host app evaluation driver.")
    return evaluate(response, policy)


def failed(reason: str, owner_action: str, response: dict[str, Any] | None = None) -> PreflightResult:
    return PreflightResult(False, reason, owner_action, response)


def task_infra_row(task_id: str, suite: str, run_index: int, tags: list[str],
                   execution: str, reason: str,
                   requested_policy: str = "fara15-4b") -> dict[str, Any]:
    return {
        "suite": suite, "task_id": task_id, "run": run_index, "tags": tags,
        "environment": "pixel", "policy": "none", "requested_policy": requested_policy,
        "crop_mode": "unknown", "requested_crop_mode": _requested_crop_mode(requested_policy),
        "status": "INFRA-BLOCKED",
        "success": False, "steps": 0,
        "wall_seconds": None, "checker": reason, "execution": execution,
    }


def _requested_crop_mode(policy: str) -> str:
    return "full-display" if policy == "ui-tars15-7b" else "frontmost-window"


def first_observation_reason(answer: Any) -> str:
    reason = "No valid first host observation was recorded."
    if isinstance(answer, str) and answer:
        reason += f" Host answer: {answer[:300]}"
    return reason
