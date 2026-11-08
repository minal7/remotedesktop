"""Contract tests for the shared Swift and Python agent schemas."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path
from unittest.mock import patch

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry
from referencing.exceptions import Unresolvable

from .contracts import (
    _validator,
    compact_json,
    validate_action,
    validate_episode,
    validate_observation,
)


def target_id(identifier: int = 1) -> dict[str, int]:
    return {"id": identifier}


def observation() -> dict:
    return {
        "task": "Complete the requested task",
        "surface": {"kind": "web", "url": "https://example.test/", "title": "Example"},
        "screenshot": "iVBORw0KGgo=",
        "elements": [{"id": 1, "role": "button", "name": "Continue", "value": None,
                      "state": ["enabled"], "bbox": [1, 2, 30, 12], "in_view": True}],
        "focus": {"id": 2, "role": "textbox", "name": "Search", "value_prefix": "", "selection": [0, 0]},
        "history": [],
        "budget": {"step": 0, "max_steps": 40},
    }


def action_variants() -> list[dict]:
    return [
        {"type": "click", "target": target_id(), "button": "left", "count": 2},
        {"type": "type", "target": target_id(), "text": "sample", "mode": "replace"},
        {"type": "key", "chord": "cmd+l"},
        {"type": "scroll", "target": {"x": 2.5, "y": 4}, "direction": "down", "amount": 100},
        {"type": "select", "target": target_id(), "option": "Second"},
        {"type": "drag", "from": target_id(1), "to": {"x": 8, "y": 9}},
        {"type": "open_url", "url": "https://example.test/path"},
        {"type": "open_app", "name": "Sample Editor"},
        {"type": "find_files", "query": "quarterly report", "kind": "document",
         "modified_after": "2025-01-01T00:00:00Z"},
        {"type": "set_files", "target": target_id(), "file_ids": ["file-1"]},
        {"type": "wait", "seconds": 1.5},
        {"type": "ask_user", "question": "Which option?", "choices": ["A", "B"]},
        {"type": "done", "answer": "Completed."},
        {"type": "fail", "reason": "The task cannot be completed."},
    ]


def step_record() -> dict:
    return {
        "type": "step", "episode_id": "episode-1", "step": 0,
        "observation": observation(), "prompt_version": "v1",
        "raw_model_output": '{"type":"done","answer":"Completed."}',
        "action": {"type": "done", "answer": "Completed."},
        "gate": {"decision": "allowed", "reason": ""},
        "execution": {"status": "ok", "result": "Completed."},
        "timings": {"observation_ms": 2, "policy_ms": 5, "gate_ms": 1,
                     "execution_ms": 3, "record_ms": 1, "total_ms": 12},
    }


class ContractTests(unittest.TestCase):
    def test_missing_required_format_support_fails_closed(self) -> None:
        for missing in ("uri", "date-time"):
            supported = {name: checker for name, checker in FormatChecker.checkers.items()
                         if name != missing}
            with self.subTest(missing=missing), patch.object(FormatChecker, "checkers", supported):
                _validator.cache_clear()
                try:
                    with self.assertRaisesRegex(RuntimeError, "missing format support for " + missing):
                        validate_action({"type": "done", "answer": "Completed."})
                finally:
                    _validator.cache_clear()

    def test_shared_cross_language_corpus(self) -> None:
        corpus_path = Path(__file__).resolve().parents[2] / "AcceptanceFixtures" / "agent-contracts.json"
        corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
        self.assertTrue(corpus)
        self.assertEqual(len({case["name"] for case in corpus}), len(corpus))
        validators = {
            "action": validate_action,
            "observation": validate_observation,
            "episode": validate_episode,
        }
        for case in corpus:
            with self.subTest(name=case["name"]):
                payload = json.loads(compact_json(case["payload"]))
                try:
                    validators[case["kind"]](payload)
                    actual = True
                except ValueError:
                    actual = False
                self.assertEqual(actual, case["valid"])

    def test_prompt_budget_schema_and_examples(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        prompt = (repo_root / "policy" / "prompts" / "v1.txt").read_text(encoding="utf-8")
        schema_text = prompt.split("Action schema:\n", maxsplit=1)[1].split(
            "\n\nGeneric examples", maxsplit=1
        )[0]
        embedded_schema = json.loads(schema_text)
        schema_path = (
            repo_root
            / "host-mac"
            / "RemoteDesktopHost"
            / "Agent"
            / "Schemas"
            / "action.schema.json"
        )
        self.assertEqual(embedded_schema, json.loads(schema_path.read_text(encoding="utf-8")))

        system_text = prompt.split("Action schema:\n", maxsplit=1)[0]
        self.assertLessEqual(len(re.findall(r"\b[\w'-]+\b", system_text)), 200)
        examples_text = prompt.split("Generic examples (one action each):\n", maxsplit=1)[1]
        examples = [json.loads(line) for line in examples_text.splitlines() if line.startswith("{")]
        self.assertEqual(len(examples), 3)
        for example in examples:
            validate_action(example)

    def test_unknown_schema_references_fail_without_network_retrieval(self) -> None:
        schema = {"$schema": "https://json-schema.org/draft/2020-12/schema",
                  "$ref": "https://example.invalid/remote.schema.json"}
        validator = Draft202012Validator(schema, registry=Registry())
        with self.assertRaises(Exception) as raised:
            list(validator.iter_errors({}))
        self.assertIsInstance(raised.exception.__cause__, Unresolvable)

    def test_all_action_variants_and_alternatives(self) -> None:
        for action in action_variants():
            with self.subTest(action=action["type"]):
                validate_action(action)
        validate_action({"type": "click", "target": {"x": 1, "y": 2}})
        validate_action({"type": "type", "text": "x", "mode": "append"})

    def test_action_rejects_extra_keys_bad_targets_and_invalid_bounds(self) -> None:
        invalid = [
            {"type": "done", "answer": "ok", "extra": True},
            {"type": "click", "target": {"id": 1, "x": 2}},
            {"type": "click", "target": {"id": -1}},
            {"type": "wait", "seconds": 10.1},
            {"type": "wait", "seconds": 0},
            {"type": "key", "chord": ""},
        ]
        for action in invalid:
            with self.subTest(action=action), self.assertRaises(ValueError):
                validate_action(action)

    def test_observation_surface_shapes_and_secure_redaction(self) -> None:
        validate_observation(observation())
        app = observation()
        app["surface"] = {"kind": "app", "app": "org.example.Editor"}
        validate_observation(app)
        secret = observation()
        secret["elements"][0].update(role="password-field", value="not allowed")
        with self.assertRaisesRegex(ValueError, "secure values must be null"):
            validate_observation(secret)
        secret_focus = observation()
        secret_focus["focus"].update(role="secure-text-field", value_prefix="secret")
        with self.assertRaisesRegex(ValueError, "secure values must be empty"):
            validate_observation(secret_focus)
        linked_focus = observation()
        linked_focus["elements"][0].update(role="AXSecureTextField", value=None)
        linked_focus["focus"].update(id=1, role="textbox", value_prefix="secret")
        with self.assertRaisesRegex(ValueError, "secure values must be empty"):
            validate_observation(linked_focus)

    def test_secure_markers_are_bounded_to_role_and_state(self) -> None:
        ordinary = observation()
        ordinary["elements"][0].update(
            role="HotPickButton", name="Password help", value="password is a word",
            state=["enabled", "description mentions credentials"],
        )
        validate_observation(ordinary)

        secure_state = observation()
        secure_state["elements"][0].update(state=["AXSecureTextField"], value="secret")
        with self.assertRaisesRegex(ValueError, "secure values must be null"):
            validate_observation(secure_state)

    def test_observation_semantic_bounds_and_unique_ids(self) -> None:
        duplicate = observation()
        duplicate["elements"].append(dict(duplicate["elements"][0]))
        out_of_budget = observation()
        out_of_budget["budget"] = {"step": 41, "max_steps": 40}
        reversed_selection = observation()
        reversed_selection["focus"]["selection"] = [4, 2]
        for value in (duplicate, out_of_budget, reversed_selection):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_observation(value)

    def test_observation_rejects_unknown_surface_fields_and_bad_numeric_shapes(self) -> None:
        bad_surface = observation()
        bad_surface["surface"]["app"] = "org.example.Editor"
        bad_bbox = observation()
        bad_bbox["elements"][0]["bbox"] = [1, 2, 3]
        bad_id = observation()
        bad_id["elements"][0]["id"] = -1
        for value in (bad_surface, bad_bbox, bad_id):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_observation(value)

    def test_episode_step_footer_roundtrip(self) -> None:
        step = step_record()
        direct_step = step_record()
        direct_step["source"] = "direct"
        footer = {"type": "footer", "episode_id": "episode-1", "outcome": "success",
                  "approvals": [], "corrections": [], "checker_verdict": "passed"}
        for record in (step, direct_step, footer):
            encoded = compact_json(record)
            decoded = json.loads(encoded)
            validate_episode(decoded)
            self.assertEqual(decoded, record)

    def test_episode_rejects_bad_timing_and_unknown_fields(self) -> None:
        bad_time = step_record()
        bad_time["timings"]["policy_ms"] = -1
        bad_field = step_record()
        bad_field["unexpected"] = True
        for record in (bad_time, bad_field):
            with self.subTest(record=record), self.assertRaises(ValueError):
                validate_episode(record)

        missing_timing = step_record()
        del missing_timing["timings"]["gate_ms"]
        with self.assertRaises(ValueError):
            validate_episode(missing_timing)

    def test_non_finite_numbers_are_rejected(self) -> None:
        for number in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(number=number), self.assertRaises(ValueError):
                validate_action({"type": "scroll", "direction": "down", "amount": number})
            bad_observation = observation()
            bad_observation["elements"][0]["bbox"][0] = number
            with self.subTest(number=number), self.assertRaises(ValueError):
                validate_observation(bad_observation)

    def test_compact_json_is_deterministic(self) -> None:
        self.assertEqual(compact_json({"b": 1, "a": 2}), '{"a":2,"b":1}')
        with self.assertRaises(ValueError):
            compact_json({"number": float("nan")})


if __name__ == "__main__":
    unittest.main()
