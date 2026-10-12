"""Strict validators for the Agent JSON schemas shared with Swift."""

from __future__ import annotations

import json
import math
import re
from functools import lru_cache
from pathlib import Path
from typing import Any


SCHEMA_DIR = (
    Path(__file__).resolve().parents[2]
    / "RemoteDesktopHost"
    / "Agent"
    / "Schemas"
)


@lru_cache(maxsize=None)
def _validator(name: str) -> Any:
    try:
        from jsonschema import Draft202012Validator, FormatChecker
        from jsonschema.exceptions import SchemaError
        from referencing import Registry, Resource
    except ImportError as error:
        raise RuntimeError(
            "Agent contract validation requires the 'jsonschema' package"
        ) from error

    schema_path = SCHEMA_DIR / f"{name}.schema.json"
    try:
        with schema_path.open(encoding="utf-8") as stream:
            schema = json.load(stream)
        documents = {}
        for related_path in SCHEMA_DIR.glob("*.schema.json"):
            with related_path.open(encoding="utf-8") as stream:
                document = json.load(stream)
            document["$id"] = related_path.as_uri()
            documents[related_path.as_uri()] = document
        schema["$id"] = schema_path.as_uri()
        Draft202012Validator.check_schema(schema)
    except (OSError, json.JSONDecodeError, SchemaError) as error:
        raise RuntimeError(f"Unable to load Agent schema {schema_path}") from error

    registry = Registry().with_resources(
        (uri, Resource.from_contents(document)) for uri, document in documents.items()
    )
    return Draft202012Validator(
        schema, registry=registry, format_checker=FormatChecker()
    )


def _ensure_finite(value: Any, path: str = "$") -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError(f"{path}: numeric values must be finite")
    if isinstance(value, dict):
        for key, item in value.items():
            _ensure_finite(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _ensure_finite(item, f"{path}[{index}]")


def _secure_marker(value: str) -> bool:
    normalized = "".join(character for character in value.casefold() if character.isalnum())
    markers = {
        "password",
        "passwordfield",
        "passwordtextfield",
        "secure",
        "securefield",
        "securetextfield",
        "axsecuretextfield",
        "otp",
        "onetimecode",
        "verificationcode",
        "secret",
        "credential",
        "sensitive",
    }
    if normalized in markers:
        return True
    tokens = {
        token.casefold()
        for token in re.findall(r"[A-Z]+(?=[A-Z][a-z]|\b)|[A-Z]?[a-z]+|\d+", value)
    }
    return bool(tokens & {"password", "secure", "otp", "secret", "credential", "sensitive"})


def _validate_secure_redaction(observation: dict[str, Any]) -> None:
    secure_element_ids = set()
    for index, element in enumerate(observation.get("elements", [])):
        secure = (
            _secure_marker(element.get("role", ""))
            or any(_secure_marker(state) for state in element.get("state", []))
        )
        if secure:
            secure_element_ids.add(element.get("id"))
        if secure and element.get("value") is not None:
            raise ValueError(f"$.elements[{index}].value: secure values must be null")

    focus = observation.get("focus")
    if focus is not None and (
        _secure_marker(focus.get("role", "")) or focus.get("id") in secure_element_ids
    ):
        if focus.get("value_prefix"):
            raise ValueError("$.focus.value_prefix: secure values must be empty")


def _validate_observation_semantics(observation: dict[str, Any]) -> None:
    ids = [element["id"] for element in observation["elements"]]
    if len(ids) != len(set(ids)):
        raise ValueError("$.elements: element IDs must be unique")
    if observation["budget"]["step"] > observation["budget"]["max_steps"]:
        raise ValueError("$.budget.step: must not exceed max_steps")
    focus = observation["focus"]
    if focus is not None and focus["selection"][0] > focus["selection"][1]:
        raise ValueError("$.focus.selection: start must not exceed end")


def _validate(name: str, value: Any) -> None:
    _ensure_finite(value)
    validator = _validator(name)
    errors = sorted(
        validator.iter_errors(value),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    if errors:
        error = errors[0]
        path = "$" + "".join(
            f"[{part}]" if isinstance(part, int) else f".{part}"
            for part in error.absolute_path
        )
        raise ValueError(f"{path}: {error.message}")


def validate_observation(value: dict[str, Any]) -> None:
    """Raise ValueError unless value is a valid, redacted observation."""
    _validate("observation", value)
    _validate_observation_semantics(value)
    _validate_secure_redaction(value)


def validate_action(value: dict[str, Any]) -> None:
    """Raise ValueError unless value is one strict action variant."""
    _validate("action", value)


def validate_episode(value: dict[str, Any]) -> None:
    """Raise ValueError unless value is a strict JSONL episode record."""
    _validate("episode", value)
    if value.get("type") == "step":
        _validate_observation_semantics(value["observation"])
        _validate_secure_redaction(value["observation"])


def compact_json(value: Any) -> str:
    """Return deterministic compact JSON, rejecting non-finite numbers."""
    _ensure_finite(value)
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False)
