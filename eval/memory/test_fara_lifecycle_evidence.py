from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path

from eval.memory.fara_evidence import analyze_fara_receipt


IDENTITY = {
    "run_id": "11111111-1111-4111-8111-111111111111",
    "case_id": "fixture-case-1",
    "driver_task_id": "task-abc",
    "run_token": "0123456789abcdef0123456789abcdef",
}
CANARIES = {"short": "987"}
CONTEXT = '[{"id":"memory-a","kind":"fact","body":"synthetic","source":"owner_message","observedAt":10,"active":true}]'


class FaraLifecycleEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        os.chmod(self.root, 0o700)
        self.exchange = self.root / "evidence" / "fara-exchange"
        self.exchange.mkdir(parents=True, mode=0o700)
        os.chmod(self.root / "evidence", 0o700)
        os.chmod(self.exchange, 0o700)

    def tearDown(self):
        self.temp.cleanup()

    def write_v2(self, specs):
        attempts = []
        for index, spec in enumerate(specs):
            request = spec.get("request")
            response = spec.get("response")
            request_artifact = self._write_artifact(index, "request", request) if request is not None else None
            response_artifact = self._write_artifact(index, "response", response) if response is not None else None
            attempts.append({
                "index": index,
                "request_id": str(uuid.UUID(int=index + 1)),
                "kind": spec["kind"],
                "outcome": spec["outcome"],
                "request": request_artifact,
                "response": response_artifact,
                "response_complete": spec.get("response_complete", spec["outcome"] == "completed"),
            })
        receipt = {
            "schema_version": 2,
            "producer_id": "fara_http_lifecycle",
            "capture_scope": "dispatched_model_http_attempts",
            "coverage_status": "incomplete",
            "identity": dict(IDENTITY),
            "attempt_count": len(attempts),
            "capture_failure_count": 0,
            "overflowed": False,
            "attempts": attempts,
        }
        (self.exchange / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
        os.chmod(self.exchange / "receipt.json", 0o600)
        return receipt

    def _write_artifact(self, index, role, body):
        name = f"{index:03d}.{role}.body"
        (self.exchange / name).write_bytes(body)
        os.chmod(self.exchange / name, 0o600)
        return {"path": f"evidence/fara-exchange/{name}",
                "sha256": hashlib.sha256(body).hexdigest(), "byte_count": len(body)}

    def analyze(self, memory_receipt=None):
        return analyze_fara_receipt(self.root, expected_identity=IDENTITY, canaries=CANARIES,
                                    memory_fixture_receipt=memory_receipt)

    @staticmethod
    def _memory_receipt(context):
        return {
            "case_id": IDENTITY["case_id"], "run_id": IDENTITY["run_id"],
            "run_token": IDENTITY["run_token"], "driver_task_id": IDENTITY["driver_task_id"],
            "binding_reference": "a" * 64, "selected_memory_item_ids": ["memory-a"],
            "excluded_superseded_memory_item_ids": [],
            "context_sha256": hashlib.sha256(context.encode()).hexdigest(),
            "coverage_status": "incomplete", "b7_pass": False,
        }

    @staticmethod
    def _request(context):
        task = "Choose the usual seat.\n\n<saved-memory-reference-data>\n" + context + "\n</saved-memory-reference-data>"
        observation = json.dumps({"task": task, "surface": {"kind": "web"}}, separators=(",", ":"))
        return json.dumps({"messages": [{"role": "user", "content": [{"type": "text", "text": observation}]}]},
                          separators=(",", ":")).encode()

    def test_v2_scans_all_attempt_phases_and_partial_error_bodies_without_pass(self):
        self.write_v2([
            {"kind": "apply_template", "outcome": "completed", "request": b'{"input":"ordinary"}',
             "response": b'{"prompt":"ordinary"}'},
            {"kind": "tokenize", "outcome": "cancelled", "request": b'{"input":"ordinary"}',
             "response": b"partial 987", "response_complete": False},
            {"kind": "chat_completion", "outcome": "completed", "request": b'{"messages":[]}',
             "response": b""},
        ])
        result = self.analyze()
        self.assertEqual(result["receipt_code"], "validated")
        self.assertEqual(result["attempt_capture"]["attempt_count"], 3)
        self.assertEqual(result["attempt_capture"]["outcomes"]["cancelled"], 1)
        self.assertTrue(any(item["code"] == "synthetic_canary_match_unverified" for item in result["potential_matches"]))
        self.assertEqual(result["status"], "potential_match_unverified")
        self.assertFalse(result["b7_pass"])

    def test_v2_memory_delivery_uses_only_completed_chat_completion_attempts(self):
        request = self._request(CONTEXT)
        self.write_v2([
            {"kind": "apply_template", "outcome": "completed", "request": request, "response": b"template"},
            {"kind": "chat_completion", "outcome": "cancelled", "request": request,
             "response": b"partial", "response_complete": False},
            {"kind": "chat_completion", "outcome": "completed", "request": request, "response": b""},
        ])
        result = self.analyze(self._memory_receipt(CONTEXT))
        delivery = result["memory_context_delivery"]
        self.assertEqual(delivery["status"], "matched_successful_requests")
        self.assertEqual(delivery["matched_request_count"], 1)
        self.assertEqual(delivery["successful_request_count"], 1)
        self.assertFalse(delivery["b7_pass"])

    def test_v2_missing_response_artifact_is_not_a_success_or_delivered_exchange(self):
        request = self._request(CONTEXT)
        self.write_v2([
            {"kind": "chat_completion", "outcome": "completed", "request": request, "response": None},
            {"kind": "chat_completion", "outcome": "completed", "request": request, "response": b"{}"},
        ])
        path = self.exchange / "receipt.json"
        receipt = json.loads(path.read_text())
        receipt["capture_failure_count"] = 1
        path.write_text(json.dumps(receipt), encoding="utf-8")
        result = self.analyze(self._memory_receipt(CONTEXT))
        self.assertEqual(result["receipt_code"], "validated")
        self.assertEqual(result["successful_exchange_count"], 1)
        self.assertEqual(result["memory_context_delivery"]["successful_request_count"], 1)
        self.assertEqual(result["memory_context_delivery"]["matched_request_count"], 1)
        self.assertEqual(result["sinks"]["model_action"]["status"], "capture_failed")
        self.assertEqual(result["sinks"]["failed_or_cancelled_exchanges"]["status"], "capture_failed")
        self.assertFalse(result["b7_pass"])

    def test_v2_empty_request_body_is_a_valid_observed_http_body(self):
        self.write_v2([{"kind": "chat_completion", "outcome": "completed", "request": b"", "response": b""}])
        result = self.analyze()
        self.assertEqual(result["receipt_code"], "validated")
        self.assertEqual(result["successful_exchange_count"], 1)
        self.assertEqual(result["sinks"]["model_prompt"]["artifact_count"], 1)
        self.assertEqual(result["sinks"]["model_action"]["artifact_count"], 1)
        self.assertFalse(result["b7_pass"])

    def test_v2_zero_byte_partial_response_is_valid_but_not_a_complete_success(self):
        self.write_v2([
            {"kind": "chat_completion", "outcome": "cancelled", "request": b'{"prompt":"ordinary"}',
             "response": b"", "response_complete": False},
            {"kind": "tokenize", "outcome": "transport_error", "request": b'{"input":"ordinary"}',
             "response": b"", "response_complete": False},
        ])
        result = self.analyze()
        self.assertEqual(result["receipt_code"], "validated")
        self.assertEqual(result["successful_exchange_count"], 0)
        self.assertEqual(result["attempt_capture"]["outcomes"]["cancelled"], 1)
        self.assertEqual(result["attempt_capture"]["outcomes"]["transport_error"], 1)
        self.assertEqual(result["sinks"]["model_action"]["artifact_count"], 2)
        self.assertEqual(result["status"], "incomplete")
        self.assertFalse(result["b7_pass"])

    def test_v2_cancelled_context_request_never_counts_as_delivered(self):
        request = self._request(CONTEXT)
        self.write_v2([{"kind": "chat_completion", "outcome": "cancelled", "request": request,
                        "response": None, "response_complete": False}])
        delivery = self.analyze(self._memory_receipt(CONTEXT))["memory_context_delivery"]
        self.assertEqual(delivery["status"], "incomplete")
        self.assertEqual(delivery["successful_request_count"], 0)
        self.assertFalse(delivery["b7_pass"])

    def test_v2_rejects_malformed_receipt_without_falling_back_to_valid_v1_fields(self):
        self.write_v2([{"kind": "chat_completion", "outcome": "completed", "request": b"{}", "response": b"{}"}])
        path = self.exchange / "receipt.json"
        receipt = json.loads(path.read_text())
        receipt["attempts"][0]["request_id"] = "NOT-A-UUID"
        # V1-looking properties must not make this malformed v2 receipt readable.
        receipt.update({"successful_exchange_count": 1, "sinks": {}})
        path.write_text(json.dumps(receipt), encoding="utf-8")
        result = self.analyze()
        self.assertEqual(result["status"], "evidence_invalid")
        self.assertEqual(result["receipt_code"], "lifecycle_receipt_shape")
        self.assertFalse(result["b7_pass"])

    def test_v2_checks_identity_attempt_order_and_duplicate_request_ids(self):
        self.write_v2([
            {"kind": "chat_completion", "outcome": "completed", "request": b"{}", "response": b"{}"},
            {"kind": "tokenize", "outcome": "completed", "request": b"{}", "response": b"{}"},
        ])
        path = self.exchange / "receipt.json"
        receipt = json.loads(path.read_text())
        receipt["identity"]["run_id"] = "22222222-2222-4222-8222-222222222222"
        path.write_text(json.dumps(receipt), encoding="utf-8")
        self.assertEqual(self.analyze()["receipt_code"], "identity_mismatch")
        receipt["identity"] = dict(IDENTITY)
        receipt["attempts"][1]["request_id"] = receipt["attempts"][0]["request_id"]
        path.write_text(json.dumps(receipt), encoding="utf-8")
        self.assertEqual(self.analyze()["receipt_code"], "attempt_declaration")
        receipt["attempts"][1]["request_id"] = str(uuid.UUID(int=2))
        receipt["attempts"][1]["index"] = True
        path.write_text(json.dumps(receipt), encoding="utf-8")
        self.assertEqual(self.analyze()["receipt_code"], "attempt_declaration")

    def test_v2_checks_artifact_binding_and_capture_failure_for_missing_completed_body(self):
        self.write_v2([{"kind": "chat_completion", "outcome": "completed", "request": b"{}", "response": b"{}"}])
        path = self.exchange / "receipt.json"
        receipt = json.loads(path.read_text())
        receipt["attempts"][0]["request"]["path"] = "evidence/fara-exchange/001.request.body"
        path.write_text(json.dumps(receipt), encoding="utf-8")
        self.assertEqual(self.analyze()["receipt_code"], "artifact_declaration")
        receipt["attempts"][0]["request"]["path"] = "evidence/fara-exchange/000.request.body"
        receipt["attempts"][0]["response"]["sha256"] = "0" * 64
        path.write_text(json.dumps(receipt), encoding="utf-8")
        self.assertEqual(self.analyze()["receipt_code"], "artifact_integrity")
        receipt["attempts"][0]["response"]["sha256"] = hashlib.sha256(b"{}").hexdigest()
        receipt["attempts"][0]["response"] = None
        receipt["capture_failure_count"] = 0
        path.write_text(json.dumps(receipt), encoding="utf-8")
        self.assertEqual(self.analyze()["receipt_code"], "attempt_completion_declaration")
        receipt["capture_failure_count"] = 1
        path.write_text(json.dumps(receipt), encoding="utf-8")
        result = self.analyze()
        self.assertEqual(result["receipt_code"], "validated")
        self.assertEqual(result["attempt_capture"]["status"], "validated")
        self.assertEqual(result["attempt_capture"]["capture_failure_count"], 1)
        self.assertFalse(result["b7_pass"])

    def test_v2_accepts_bounded_overflow_sentinel_and_rejects_oversized_attempt_list(self):
        self.write_v2([{"kind": "chat_completion", "outcome": "pending", "request": b"{}",
                        "response": None, "response_complete": False} for _ in range(160)])
        path = self.exchange / "receipt.json"
        receipt = json.loads(path.read_text())
        receipt["overflowed"] = True
        receipt["capture_failure_count"] = 1
        path.write_text(json.dumps(receipt), encoding="utf-8")
        result = self.analyze()
        self.assertEqual(result["receipt_code"], "validated")
        self.assertEqual(result["attempt_capture"]["attempt_count"], 160)
        self.assertTrue(result["attempt_capture"]["overflowed"])
        self.assertFalse(result["b7_pass"])
        receipt["attempts"].append(dict(receipt["attempts"][-1], index=160,
                                        request_id=str(uuid.UUID(int=161))))
        receipt["attempt_count"] = 161
        path.write_text(json.dumps(receipt), encoding="utf-8")
        self.assertEqual(self.analyze()["receipt_code"], "lifecycle_count_bounds")

    def test_v2_http_error_must_not_include_response_and_pending_is_incomplete(self):
        self.write_v2([{"kind": "tokenize", "outcome": "http_error", "request": b"{}",
                        "response": b"must not be read"}])
        self.assertEqual(self.analyze()["receipt_code"], "http_error_response")
        path = self.exchange / "receipt.json"
        receipt = json.loads(path.read_text())
        receipt["attempts"][0]["outcome"] = "pending"
        receipt["attempts"][0]["response"] = None
        receipt["attempts"][0]["response_complete"] = False
        path.write_text(json.dumps(receipt), encoding="utf-8")
        result = self.analyze()
        self.assertEqual(result["receipt_code"], "validated")
        self.assertEqual(result["attempt_capture"]["outcomes"]["pending"], 1)
        self.assertIn({"sink_id": "attempts", "code": "attempts_incomplete_or_capture_failed"}, result["incomplete"])

    def test_v2_transport_error_partial_body_is_scanned_but_raw_payload_is_not_returned(self):
        partial = b"synthetic internal response prefix 987"
        self.write_v2([{"kind": "chat_completion", "outcome": "transport_error", "request": b'{"prompt":"private-fixture"}',
                        "response": partial, "response_complete": False}])
        result = self.analyze()
        encoded = json.dumps(result)
        self.assertEqual(result["receipt_code"], "validated")
        self.assertEqual(result["attempt_capture"]["outcomes"]["transport_error"], 1)
        self.assertIn("synthetic_canary_match_unverified", encoded)
        self.assertNotIn("private-fixture", encoded)
        self.assertNotIn(partial.decode(), encoded)
        self.assertNotIn(".request.body", encoded)
        self.assertFalse(result["b7_pass"])


if __name__ == "__main__":
    unittest.main()
