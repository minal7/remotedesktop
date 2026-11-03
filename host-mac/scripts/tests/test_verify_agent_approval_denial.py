from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "host-mac/scripts/acceptance/verify_agent_approval_denial.sh"
TASK_ID = "11111111-2222-4333-8444-555555555555"
TOKEN = "a" * 32
FINGERPRINT = "b" * 64


def step(number: int, decision: str, reason: str, status: str,
         fingerprint: str = FINGERPRINT, action: dict[str, object] | None = None) -> dict[str, object]:
    return {
        "type": "step",
        "episode_id": TASK_ID,
        "step": number,
        "observation": {
            "task": f"Deny the local safety action for run token {TOKEN}",
            "surface": {"kind": "app", "app": "com.apple.Safari", "title": "Safety"},
        },
        "action": action if action is not None else {"type": "click", "target": {"element": 7}},
        "gate": {
            "decision": decision,
            "reason": reason,
            "fingerprint": fingerprint,
        },
        "execution": {"status": status, "result": "fixture result"},
    }


class VerifyAgentApprovalDenialTests(unittest.TestCase):
    def run_checker(self, records: list[dict[str, object]]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            support = home / "Library/Application Support"
            ledger = support / "Remote Desktop Host/Computer Use Tasks/processed-prompts.json"
            episode = support / f"RemoteDesktopHost/episodes/{TASK_ID}/episode.jsonl"
            ledger.parent.mkdir(parents=True)
            episode.parent.mkdir(parents=True)
            ledger.write_text(json.dumps({TASK_ID: {"promptClaimed": True, "executionStarted": True}}))
            episode.write_text("".join(json.dumps(record) + "\n" for record in records))
            env = dict(os.environ, REMOTE_DESKTOP_APPROVAL_VERIFY_SUPPORT_ROOT=str(support))
            return subprocess.run(
                ["/bin/bash", str(SCRIPT), TASK_ID, TOKEN],
                env=env, capture_output=True, text=True, check=False,
            )

    def test_accepts_matching_pending_denial_for_native_app_surface(self) -> None:
        records = [
            step(0, "needs_approval", "approval required", "not_executed"),
            step(1, "rejected", "rejected: user declined", "not_executed"),
            {"type": "footer", "episode_id": TASK_ID, "outcome": "cancelled"},
        ]
        result = self.run_checker(records)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_same_fingerprint_when_coordinate_target_is_resolved(self) -> None:
        records = [
            step(0, "needs_approval", "approval required", "not_executed",
                 action={"type": "click", "target": {"point": {"x": 100, "y": 80}}}),
            step(1, "rejected", "rejected: user declined", "not_executed",
                 action={"type": "click", "target": {"element": 7}}),
            {"type": "footer", "episode_id": TASK_ID, "outcome": "cancelled"},
        ]
        result = self.run_checker(records)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_changed_fingerprint(self) -> None:
        records = [
            step(0, "needs_approval", "approval required", "not_executed"),
            step(1, "rejected", "rejected: user declined", "not_executed", "c" * 64),
            {"type": "footer", "episode_id": TASK_ID, "outcome": "cancelled"},
        ]
        self.assertNotEqual(self.run_checker(records).returncode, 0)

    def test_rejects_execution_of_denied_fingerprint(self) -> None:
        records = [
            step(0, "needs_approval", "approval required", "not_executed"),
            step(1, "rejected", "rejected: user declined", "not_executed"),
            step(2, "allowed", "allowed", "ok"),
            {"type": "footer", "episode_id": TASK_ID, "outcome": "completed"},
        ]
        self.assertNotEqual(self.run_checker(records).returncode, 0)

    def test_rejects_unclosed_episode(self) -> None:
        records = [
            step(0, "needs_approval", "approval required", "not_executed"),
            step(1, "rejected", "rejected: user declined", "not_executed"),
        ]
        self.assertNotEqual(self.run_checker(records).returncode, 0)


if __name__ == "__main__":
    unittest.main()
