"""Shared JSON contracts for the local computer-use agent."""

from .contracts import (
    compact_json,
    validate_action,
    validate_episode,
    validate_observation,
)
from .wire_types import Action, Episode, Observation

__all__ = [
    "compact_json",
    "validate_action",
    "validate_episode",
    "validate_observation",
    "Action",
    "Episode",
    "Observation",
]
