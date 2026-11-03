#!/usr/bin/env python3
"""Small local-only web fixture server with token-isolated browser telemetry."""

from __future__ import annotations

import json
import mimetypes
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
HOST, PORT = "127.0.0.1", 8765
_states: dict[str, dict] = {}
_lock = Lock()
_TOKEN = re.compile(r"^[a-f0-9]{32}$")
_SELECTOR = re.compile(r"^(#[^\x00-\x1f]{1,127}|document|html|body)$")
_EVENT_TYPES = {"click", "input", "change", "scroll", "submit"}
_MAX_BODY = 256 * 1024
_MAX_EVENT_SELECTORS = 128
_MAX_EVENT_COUNT = 1_000_000
_MAX_EVENT_SEQUENCE = 1_000_000_000
_MAX_EVENT_HISTORY = 100


def _safe_token(value: str) -> str | None:
    return value if _TOKEN.fullmatch(value) else None


def _normalize_event_counts(value: object) -> dict[str, dict[str, int]] | None:
    if not isinstance(value, dict) or len(value) > _MAX_EVENT_SELECTORS:
        return None
    normalized: dict[str, dict[str, int]] = {}
    for selector, counts in value.items():
        if not isinstance(selector, str) or not _SELECTOR.fullmatch(selector) or not isinstance(counts, dict):
            return None
        if len(counts) > len(_EVENT_TYPES):
            return None
        normalized[selector] = {}
        for event_type, count in counts.items():
            if event_type not in _EVENT_TYPES or isinstance(count, bool) or not isinstance(count, int):
                return None
            if not 0 <= count <= _MAX_EVENT_COUNT:
                return None
            normalized[selector][event_type] = count
    return normalized


def _normalize_event_history(value: object) -> list[dict[str, object]] | None:
    if not isinstance(value, list) or len(value) > _MAX_EVENT_HISTORY:
        return None
    history: list[dict[str, object]] = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"sequence", "selector", "event_type"}:
            return None
        sequence, selector, event_type = item["sequence"], item["selector"], item["event_type"]
        if isinstance(sequence, bool) or not isinstance(sequence, int) or not 1 <= sequence <= _MAX_EVENT_SEQUENCE:
            return None
        if not isinstance(selector, str) or not _SELECTOR.fullmatch(selector) or event_type not in _EVENT_TYPES:
            return None
        history.append({"sequence": sequence, "selector": selector, "event_type": event_type})
    return history


def _merge_event_history(previous: object, incoming: object) -> list[dict[str, object]] | None:
    old = _normalize_event_history(previous)
    new = _normalize_event_history(incoming)
    if old is None or new is None:
        return None
    by_sequence = {int(item["sequence"]): item for item in old}
    for item in new:
        by_sequence.setdefault(int(item["sequence"]), item)
    return [by_sequence[key] for key in sorted(by_sequence)[-_MAX_EVENT_HISTORY:]]


class Handler(BaseHTTPRequestHandler):
    server_version = "AgentEvalFixture/1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        request = urlsplit(self.path)
        query = parse_qs(request.query)
        if request.path == "/__eval/health":
            self._send(200, b'{"ok":true}', "application/json")
            return
        if request.path == "/__eval/state":
            token = _safe_token((query.get("token") or [""])[0])
            if token is None:
                self._send(400, b'{"error":"invalid token"}', "application/json")
                return
            with _lock:
                state = _states.get(token)
                if state is None:
                    self._send(404, b'{"error":"state not observed"}', "application/json")
                    return
                encoded = json.dumps(state, ensure_ascii=False, allow_nan=False).encode()
            self._send(200, encoded, "application/json")
            return
        relative = request.path.lstrip("/") or "forms.html"
        path = (ROOT / relative).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file() or path.suffix not in {".html", ".js", ".css"}:
            self._send(404, b"not found", "text/plain; charset=utf-8")
            return
        content = path.read_bytes()
        if path.suffix == ".html":
            snippet = b'<script src="/telemetry.js"></script>'
            if b"</body>" in content:
                content = content.replace(b"</body>", snippet + b"</body>")
            else:
                content += snippet
        self._send(200, content, mimetypes.guess_type(path.name)[0] or "application/octet-stream")

    def do_POST(self) -> None:
        request = urlsplit(self.path)
        query = parse_qs(request.query)
        token = _safe_token((query.get("token") or [""])[0])
        if request.path != "/__eval/state" or token is None:
            self._send(404, b'{"error":"not found"}', "application/json")
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length < 1 or length > _MAX_BODY:
            self._send(413, b'{"error":"body limit"}', "application/json")
            return
        try:
            payload = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send(400, b'{"error":"invalid JSON"}', "application/json")
            return
        if not isinstance(payload, dict) or not isinstance(payload.get("elements"), dict):
            self._send(400, b'{"error":"invalid state"}', "application/json")
            return
        with _lock:
            previous = _states.get(token, {})
            state = {
                "run_token": token,
                "url": str(payload.get("url", ""))[:2048],
                "elements": payload["elements"],
                "updated_at": time.time(),
                "submit_count": max(int(previous.get("submit_count", 0)), int(payload.get("submit_count", 0))),
                "delete_count": max(int(previous.get("delete_count", 0)), int(payload.get("delete_count", 0))),
                "share_count": max(int(previous.get("share_count", 0)), int(payload.get("share_count", 0))),
                "secure_nonempty_count": max(int(previous.get("secure_nonempty_count", 0)), int(payload.get("secure_nonempty_count", 0))),
                "event_counts": {},
                "event_history": [],
                "event_sequence": 0,
            }
            incoming_counts = _normalize_event_counts(payload.get("event_counts", {}))
            old_counts = _normalize_event_counts(previous.get("event_counts", {}))
            history = _merge_event_history(previous.get("event_history", []), payload.get("event_history", []))
            sequence = payload.get("event_sequence", 0)
            if incoming_counts is None or old_counts is None or history is None:
                self._send(400, b'{"error":"invalid events"}', "application/json")
                return
            if isinstance(sequence, bool) or not isinstance(sequence, int) or not 0 <= sequence <= _MAX_EVENT_SEQUENCE:
                self._send(400, b'{"error":"invalid event sequence"}', "application/json")
                return
            selectors = old_counts.keys() | incoming_counts.keys()
            if len(selectors) > _MAX_EVENT_SELECTORS:
                self._send(400, b'{"error":"too many event selectors"}', "application/json")
                return
            state["event_history"] = history
            state["event_sequence"] = max(
                int(previous.get("event_sequence", 0)), sequence,
                max((int(item["sequence"]) for item in history), default=0),
            )
            for selector in selectors:
                state["event_counts"][selector] = {}
                old = old_counts.get(selector, {})
                new = incoming_counts.get(selector, {})
                for event_type in old.keys() | new.keys():
                    state["event_counts"][selector][event_type] = max(old.get(event_type, 0), new.get(event_type, 0))
            _states[token] = state
        self._send(200, b'{"ok":true}', "application/json")


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
