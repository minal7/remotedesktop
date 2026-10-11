"""Focused tests for the independent core-job acceptance checks."""

from __future__ import annotations

from email.message import EmailMessage
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.parse import quote
from unittest.mock import patch


RUNNER_PATH = Path(__file__).with_name("run_job.py")
SPEC = importlib.util.spec_from_file_location("acceptance_run_job", RUNNER_PATH)
assert SPEC is not None and SPEC.loader is not None
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class GmailHarnessTests(unittest.TestCase):
    def test_noncompleted_gmail_run_reports_actual_text_entry_failure_before_oracle_checks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            trace = Path(temporary)
            text = "I couldn't complete that task: The app did not confirm the exact text edit. Check the field before continuing; the edit was not retried."
            outcome = {
                "job": "gmail", "run_id": "run", "task_id": "task",
                "raw_outcome": "unableToComplete", "text": text,
                "elapsed_ms": 1, "failure_class": "text-entry",
                "evidence": {"gmail": {
                    "compose_count": 1,
                    "compose_url": "https://mail.google.com/mail/u/0/#inbox",
                    "subject_matches": False,
                }},
            }
            (trace / "outcome.json").write_text(json.dumps(outcome), encoding="utf-8")
            passed, check = runner.verify_run(trace,
                {"job": "gmail", "run_id": "run", "send_approval_check": False}, 0)
            self.assertFalse(passed)
            self.assertEqual(check["reason"], text)
            self.assertEqual(check["failure_class"], "text-entry")

    def test_retry_without_verified_url_fails_and_keeps_one_owned_attachment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                first = runner.gmail_session(fixtures)
                state_before_retry = runner.GMAIL_SESSION_PATH.read_bytes()
                files_before_retry = sorted((path.name, path.read_bytes())
                    for path in (root / "downloads").iterdir())
                self.assertIsNone(first[4])
                with self.assertRaises(runner.AcceptanceError):
                    runner.gmail_session(fixtures)
                self.assertEqual(runner.GMAIL_SESSION_PATH.read_bytes(), state_before_retry)
                self.assertEqual(sorted((path.name, path.read_bytes())
                    for path in (root / "downloads").iterdir()), files_before_retry)
                self.assertEqual([name for name, _ in files_before_retry], [first[2].name])
                self.assertEqual(runner.sha256(first[2].read_bytes()),
                                 fixtures["Quarterly Metrics.xlsx"]["sha256"])
                recipient = "checker-only@example.invalid"
                expected, _, _ = runner.make_expected("gmail", "run", 1, fixtures, None,
                    staged_source=first[2], gmail=(first[0], first[1], first[2], recipient,
                                                   first[3], first[4]))
                self.assertEqual(expected["to"], recipient)
                self.assertNotIn(recipient, expected["prompt"])
                self.assertNotIn(str(first[2]), expected["prompt"])
                self.assertIn(first[1], expected["prompt"])
                self.assertIn("never send", expected["prompt"])
                self.assertNotIn("reuse it", expected["prompt"])

    def test_successful_draft_run_rotates_to_a_fresh_token_and_subject(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observed_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_ownedDraft123"
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                first = runner.gmail_session(fixtures)
                token, subject, staged, attempt, _ = first
                state = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                state.update({"draft_saved_verified": True, "existing_draft_url": observed_url})
                runner.GMAIL_SESSION_PATH.write_text(json.dumps(state), encoding="utf-8")
                verified = (token, subject, staged, "checker@example.invalid", attempt, observed_url)
                before_last_run = runner.GMAIL_SESSION_PATH.read_bytes()
                self.assertEqual(runner.rotate_gmail_session_after_success(verified,
                    passed=True, more_runs=False), verified)
                self.assertEqual(runner.GMAIL_SESSION_PATH.read_bytes(), before_last_run)

                fresh = runner.rotate_gmail_session_after_success(verified,
                    passed=True, more_runs=True)

                self.assertNotEqual(fresh[0], token)
                self.assertRegex(fresh[0], r"^[a-f0-9]{32}$")
                self.assertEqual(fresh[1], f"Remote Desktop acceptance [{fresh[0]}]")
                self.assertEqual(fresh[2], staged)
                self.assertEqual(fresh[3:], ("checker@example.invalid", 1, None))
                saved = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                self.assertEqual(saved, {"schema_version": 2, "token": fresh[0], "attempts": 1,
                                         "attachment_token": token,
                                         "draft_saved_verified": False})

    def test_rotated_gmail_session_stays_in_memory_until_a_verified_retry_url_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_oldDraft123"
            retry_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_retryDraft456"
            saved_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_savedDraft789"
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                first = runner.gmail_session(fixtures)
                attachment_path = first[2]
                state = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                state.update({"draft_saved_verified": True, "existing_draft_url": old_url})
                runner.GMAIL_SESSION_PATH.write_text(json.dumps(state), encoding="utf-8")
                gmail = (first[0], first[1], attachment_path, "checker@example.invalid", first[3], old_url)
                fresh = runner.rotate_gmail_session_after_success(gmail, passed=True, more_runs=True)

                rotated_state = runner.GMAIL_SESSION_PATH.read_bytes()
                with self.assertRaises(runner.AcceptanceError):
                    runner.gmail_session(fixtures)
                self.assertEqual(runner.GMAIL_SESSION_PATH.read_bytes(), rotated_state)
                current = fresh
                self.assertEqual(current[2], attachment_path)
                expected, _, _ = runner.make_expected("gmail", "run", 2, fixtures, None,
                    staged_source=current[2], gmail=current)
                self.assertEqual(expected["gmail_attempt"], 1)
                self.assertIsNone(expected["gmail_existing_draft_url"])
                self.assertIn("Use the Gmail compose opened by the host", expected["prompt"])
                self.assertIn("do not create another compose", expected["prompt"])
                self.assertEqual(expected["attachment_name"], attachment_path.name)
                self.assertIn(attachment_path.name, expected["body"])

                trace = root / "traces/retry"
                trace.mkdir()
                retry_outcome = {"evidence": {"gmail": {"draft_saved_verified": False,
                    "saved_draft_url": retry_url, "saved_draft_count": 1,
                    "saved_subject_matches": True}}}
                (trace / "outcome.json").write_text(json.dumps(retry_outcome), encoding="utf-8")
                current_gmail = current
                runner.persist_gmail_retry_compose_url(current_gmail, trace / "outcome.json")
                retry = runner.gmail_session(fixtures)
                self.assertEqual(retry[2], attachment_path)
                self.assertEqual(retry[4], retry_url)

                success_outcome = {"evidence": {"gmail": {"draft_saved_verified": True,
                    "saved_draft_url": saved_url}}}
                (trace / "outcome.json").write_text(json.dumps(success_outcome), encoding="utf-8")
                retry_gmail = (retry[0], retry[1], retry[2], "checker@example.invalid", retry[3], retry[4])
                runner.persist_verified_gmail_draft_url(retry_gmail, trace / "outcome.json")
                verified = runner.gmail_session(fixtures)
                self.assertEqual(verified[2], attachment_path)
                self.assertEqual(verified[4], saved_url)
                expected_verified, _, _ = runner.make_expected("gmail", "run", 3, fixtures, None,
                    staged_source=verified[2], gmail=(verified[0], verified[1], verified[2],
                        "checker@example.invalid", verified[3], verified[4]))
                self.assertEqual(expected_verified["attachment_name"], attachment_path.name)
                self.assertIn(attachment_path.name, expected_verified["body"])

    def test_failed_and_send_approval_runs_do_not_rotate_gmail_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observed_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_ownedDraft123"
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                session = runner.gmail_session(fixtures)
                gmail = (session[0], session[1], session[2], "checker@example.invalid",
                         session[3], None)
                before = runner.GMAIL_SESSION_PATH.read_bytes()
                self.assertEqual(runner.rotate_gmail_session_after_success(gmail,
                    passed=False, more_runs=True), gmail)
                self.assertEqual(runner.GMAIL_SESSION_PATH.read_bytes(), before)
                send_gmail = (*gmail[:5], observed_url)
                self.assertEqual(runner.rotate_gmail_session_after_success(send_gmail,
                    passed=True, more_runs=True, send_approval_check=True), send_gmail)
                self.assertEqual(runner.GMAIL_SESSION_PATH.read_bytes(), before)

    def test_gmail_batch_rejects_duplicate_tokens_and_observed_draft_identities(self) -> None:
        first_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_ownedDraft123"
        second_url = "https://mail.google.com/mail/u/1/#drafts/FMfcgzQX_otherDraft456"
        tokens: set[str] = set()
        identities: set[tuple[str, str]] = set()
        runner.record_gmail_batch_draft_identity("a" * 32, first_url, tokens, identities)
        with self.assertRaises(runner.AcceptanceError):
            runner.record_gmail_batch_draft_identity("a" * 32, second_url, tokens, identities)
        with self.assertRaises(runner.AcceptanceError):
            runner.record_gmail_batch_draft_identity("b" * 32, first_url, tokens, identities)
        with self.assertRaises(runner.AcceptanceError):
            runner.record_gmail_batch_draft_identity("c" * 32,
                "https://mail.google.com/mail/u/0/#inbox", tokens, identities)

    def test_observed_compose_url_is_reused_for_the_same_owned_draft(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observed_url = "https://mail.google.com/mail/u/0/#drafts/FMfcgzQX_ownedDraft123"
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                runner.TRACE_ROOT.mkdir(mode=0o700)
                runner.GMAIL_SESSION_PATH.write_text(json.dumps({
                    "schema_version": 1, "token": "a" * 32, "attempts": 1,
                    "existing_draft_url": observed_url, "draft_saved_verified": True,
                }), encoding="utf-8")
                fixtures = runner.prepare_fixtures()
                session = runner.gmail_session(fixtures)
                self.assertEqual(session[4], observed_url)
                self.assertEqual(json.loads(runner.GMAIL_SESSION_PATH.read_text())[
                    "existing_draft_url"], observed_url)
                expected, _, _ = runner.make_expected("gmail", "run", 1, fixtures, None,
                    staged_source=session[2], gmail=(session[0], session[1], session[2],
                        "checker-only@example.invalid", session[3], session[4]))
                self.assertNotIn(observed_url, expected["prompt"])
                self.assertIn("Resume the exact test-owned Gmail draft selected by the host", expected["prompt"])
                self.assertNotIn("create one test-owned draft", expected["prompt"])
                self.assertNotIn("checker-only@example.invalid", expected["prompt"])
                self.assertNotIn(str(session[2]), expected["prompt"])

    def test_unverified_legacy_compose_url_fails_before_new_compose(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_oldBlankDraft123"
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                runner.TRACE_ROOT.mkdir(mode=0o700)
                runner.GMAIL_SESSION_PATH.write_text(json.dumps({
                    "schema_version": 1, "token": "c" * 32, "attempts": 3,
                    "existing_draft_url": old_url,
                }), encoding="utf-8")
                fixtures = runner.prepare_fixtures()
                before_state = runner.GMAIL_SESSION_PATH.read_bytes()
                with self.assertRaises(runner.AcceptanceError):
                    runner.gmail_session(fixtures)
                self.assertEqual(runner.GMAIL_SESSION_PATH.read_bytes(), before_state)
                self.assertFalse((root / "downloads").exists())

    def test_fresh_zero_attempt_gmail_identity_can_be_initialized(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                token = "d" * 32
                runner.TRACE_ROOT.mkdir(mode=0o700)
                runner.GMAIL_SESSION_PATH.write_text(json.dumps({
                    "schema_version": 2, "token": token, "attempts": 0,
                    "attachment_token": token, "draft_saved_verified": False,
                }), encoding="utf-8")
                fixtures = runner.prepare_fixtures()
                session = runner.gmail_session(fixtures)
                self.assertEqual(session[0], token)
                self.assertEqual(session[3], 1)
                self.assertIsNone(session[4])

    def test_attempted_gmail_identity_without_verified_retry_url_fails_before_new_compose(self) -> None:
        old_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_unverifiedDraft123"
        for state_kind in ("no-url", "legacy-unverified-url", "conflicting-draft-ids"):
            with self.subTest(state_kind=state_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                    GMAIL_SESSION_PATH=root / "traces/session.json",
                                    FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                    fixtures = runner.prepare_fixtures()
                    first = runner.gmail_session(fixtures)
                    state = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                    state["attempts"] = 3
                    if state_kind == "legacy-unverified-url":
                        state["existing_draft_url"] = old_url
                        state["draft_saved_verified"] = False
                    elif state_kind == "conflicting-draft-ids":
                        state["retry_compose_url"] = (
                            "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_firstDraft123"
                            "&compose=FMfcgzQX_secondDraft456")
                    runner.GMAIL_SESSION_PATH.write_text(json.dumps(state, sort_keys=True) + "\n",
                        encoding="utf-8")
                    before_state = runner.GMAIL_SESSION_PATH.read_bytes()
                    before_files = sorted((path.name, path.read_bytes())
                        for path in (root / "downloads").iterdir())

                    with self.assertRaises(runner.AcceptanceError):
                        runner.gmail_session(fixtures)

                    self.assertEqual(runner.GMAIL_SESSION_PATH.read_bytes(), before_state)
                    self.assertEqual(sorted((path.name, path.read_bytes())
                        for path in (root / "downloads").iterdir()), before_files)
                    saved = json.loads(before_state)
                    self.assertEqual(saved["token"], first[0])
                    self.assertEqual(saved["attempts"], 3)
                    self.assertEqual(len(before_files), 1)
                    self.assertEqual(before_files[0][0], first[2].name)


    def test_verified_saved_draft_url_is_persisted_for_later_gate_runs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observed_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_verifiedDraft123"
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                token, subject, staged, attempt, _ = runner.gmail_session(fixtures)
                trace = root / "traces/run"
                trace.mkdir()
                (trace / "outcome.json").write_text(json.dumps({"evidence": {"gmail": {
                    "draft_saved_verified": True, "saved_draft_url": observed_url,
                }}}), encoding="utf-8")
                gmail = (token, subject, staged, "checker@example.invalid", attempt, None)
                updated = runner.persist_verified_gmail_draft_url(gmail, trace / "outcome.json")
                self.assertEqual(updated[5], observed_url)
                retry = runner.gmail_session(fixtures)
                self.assertEqual(retry[0], token)
                self.assertEqual(retry[4], observed_url)
                self.assertEqual(retry[3], attempt + 1)

    def test_exact_subject_url_is_reused_after_failed_oracle_without_becoming_verified(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observed_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_retryDraft123"
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                token, subject, staged, attempt, _ = runner.gmail_session(fixtures)
                trace = root / "traces/run"
                trace.mkdir()
                (trace / "outcome.json").write_text(json.dumps({"evidence": {"gmail": {
                    "draft_saved_verified": False, "saved_draft_url": observed_url,
                    "saved_draft_count": 1, "saved_subject_matches": True,
                }}}), encoding="utf-8")
                gmail = (token, subject, staged, "checker@example.invalid", attempt, None)
                runner.persist_gmail_retry_compose_url(gmail, trace / "outcome.json")
                saved = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                self.assertEqual(saved["retry_compose_url"], observed_url)
                self.assertFalse(saved["draft_saved_verified"])
                self.assertNotIn("existing_draft_url", saved)
                retry = runner.gmail_session(fixtures)
                self.assertEqual(retry[4], observed_url)
                self.assertFalse(json.loads(runner.GMAIL_SESSION_PATH.read_text())["draft_saved_verified"])
                expected, _, _ = runner.make_expected("gmail", "run", 2, fixtures, None,
                    staged_source=staged, gmail=(token, subject, staged,
                        "checker@example.invalid", retry[3], retry[4]))
                self.assertIn("Resume the exact test-owned Gmail draft", expected["prompt"])
                self.assertNotIn(observed_url, expected["prompt"])

    def test_unverified_retry_target_requires_exact_unique_subject(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                token, subject, staged, attempt, _ = runner.gmail_session(fixtures)
                trace = root / "traces/run"
                trace.mkdir()
                url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_notOwned123"
                for evidence in (
                    {"saved_draft_url": "https://mail.google.com/mail/u/0/#inbox",
                     "saved_draft_count": 2, "saved_subject_matches": True},
                    {"saved_draft_url": url, "saved_draft_count": 1, "saved_subject_matches": False},
                ):
                    (trace / "outcome.json").write_text(json.dumps({"evidence": {"gmail": evidence}}), encoding="utf-8")
                    runner.persist_gmail_retry_compose_url(
                        (token, subject, staged, "checker@example.invalid", attempt, None), trace / "outcome.json")
                    saved = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                    self.assertNotIn("retry_compose_url", saved)

    def test_verified_recovery_bookmark_persists_only_as_unverified_retry_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recovery_url = "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_recoveryDraft123"
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                token, subject, staged, attempt, _ = runner.gmail_session(fixtures)
                trace = root / "traces/run"
                trace.mkdir()
                outcome = {"raw_outcome": "unableToComplete", "evidence": {"gmail": {
                    "capture_status": "no-focused-default-browser-page",
                    "recovery_compose_url": recovery_url,
                    "recovery_subject_verified": True,
                }}}
                outcome_path = trace / "outcome.json"
                outcome_path.write_text(json.dumps(outcome), encoding="utf-8")
                gmail = (token, subject, staged, "checker@example.invalid", attempt, None)
                runner.persist_gmail_retry_compose_url(gmail, outcome_path)
                saved = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                self.assertEqual(saved["retry_compose_url"], recovery_url)
                self.assertFalse(saved["draft_saved_verified"])
                self.assertNotIn("existing_draft_url", saved)
                retry = runner.gmail_session(fixtures)
                self.assertEqual(retry[4], recovery_url)
                self.assertFalse(json.loads(runner.GMAIL_SESSION_PATH.read_text())[
                    "draft_saved_verified"])

    def test_recovery_bookmark_rejects_wrong_account_malformed_or_unverified_url(self) -> None:
        invalid_evidence = (
            {"recovery_compose_url": "https://mail.google.com/mail/u/1/#drafts?compose=FMfcgzQX_wrongAccount123",
             "recovery_subject_verified": True, "gmail_account_index": 0},
            {"recovery_compose_url": "https://mail.google.com.evil.invalid/mail/u/0/#drafts?compose=FMfcgzQX_foreign123",
             "recovery_subject_verified": True, "gmail_account_index": 0},
            {"recovery_compose_url": "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_one123&compose=FMfcgzQX_two456",
             "recovery_subject_verified": True, "gmail_account_index": 0},
            {"recovery_compose_url": "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_unverified123",
             "recovery_subject_verified": False, "gmail_account_index": 0},
            {"recovery_compose_url": "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_missingProof123",
             "gmail_account_index": 0},
        )
        for evidence in invalid_evidence:
            with self.subTest(evidence=evidence), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                    GMAIL_SESSION_PATH=root / "traces/session.json",
                                    FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                    fixtures = runner.prepare_fixtures()
                    token, subject, staged, attempt, _ = runner.gmail_session(fixtures)
                    trace = root / "traces/run"
                    trace.mkdir()
                    (trace / "outcome.json").write_text(json.dumps({
                        "raw_outcome": "unableToComplete", "evidence": {"gmail": evidence},
                    }), encoding="utf-8")
                    runner.persist_gmail_retry_compose_url(
                        (token, subject, staged, "checker@example.invalid", attempt, None),
                        trace / "outcome.json")
                    saved = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                    self.assertNotIn("retry_compose_url", saved)
                    self.assertFalse(saved["draft_saved_verified"])

    def test_independently_observed_saved_or_current_url_precedes_recovery_bookmark(self) -> None:
        candidates = (
            ({"saved_draft_url": "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_saved123456",
              "saved_subject_matches": True, "saved_draft_count": 1},
             "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_saved123456"),
            ({"compose_url": "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_current123456",
              "subject_matches": True, "compose_count": 1},
             "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_current123456"),
        )
        for primary, expected_url in candidates:
            with self.subTest(expected_url=expected_url), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                    GMAIL_SESSION_PATH=root / "traces/session.json",
                                    FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                    fixtures = runner.prepare_fixtures()
                    token, subject, staged, attempt, _ = runner.gmail_session(fixtures)
                    trace = root / "traces/run"
                    trace.mkdir()
                    evidence = dict(primary)
                    evidence.update({
                        "recovery_compose_url": "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_recovery123456",
                        "recovery_subject_verified": True,
                        "gmail_account_index": 0,
                    })
                    (trace / "outcome.json").write_text(json.dumps({
                        "raw_outcome": "unableToComplete", "evidence": {"gmail": evidence},
                    }), encoding="utf-8")
                    runner.persist_gmail_retry_compose_url(
                        (token, subject, staged, "checker@example.invalid", attempt, None),
                        trace / "outcome.json")
                    saved = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                    self.assertEqual(saved["retry_compose_url"], expected_url)
                    self.assertFalse(saved["draft_saved_verified"])

    def test_owned_compose_url_rejects_malformed_or_foreign_targets(self) -> None:
        invalid = (
            "not a URL",
            "https://mail.google.com/mail/u/0/",
            "https://mail.google.com.evil.invalid/mail/u/0/#drafts/FMfcgzQX_ownedDraft123",
            "https://user@mail.google.com/mail/u/0/#drafts/FMfcgzQX_ownedDraft123",
            "https://mail.google.com/mail/u/../#drafts/FMfcgzQX_ownedDraft123",
            "https://mail.google.com/mail/u/0/#inbox",
            "https://mail.google.com/mail/u/0/#inbox?compose=bad/value",
            "https://mail.google.com/mail/u/0/#compose=FMfcgzQX_" + "a" * 2_050,
        )
        for url in invalid:
            with self.subTest(url=url[:80]), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                    GMAIL_SESSION_PATH=root / "traces/session.json",
                                    FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                    runner.TRACE_ROOT.mkdir(mode=0o700)
                    runner.GMAIL_SESSION_PATH.write_text(json.dumps({
                        "schema_version": 1, "token": "b" * 32, "attempts": 1,
                        "existing_draft_url": url,
                    }), encoding="utf-8")
                    fixtures = runner.prepare_fixtures()
                    with self.assertRaises(runner.AcceptanceError):
                        runner.gmail_session(fixtures)

    def test_saved_draft_exact_fields_and_attachment_metadata_pass_without_hash_gate(self) -> None:
        outcome = self.exact_metadata()
        check = runner.check_gmail({"send_approval_check": False}, outcome)
        self.assertTrue(check["passed"])
        self.assertTrue(check["draft_saved_verified"])
        self.assertFalse(check["attachment_bytes_verified"])
        outcome["evidence"]["gmail"]["saved_attachment_count"] = 2
        with self.assertRaises(runner.AcceptanceError):
            runner.check_gmail({"send_approval_check": False}, outcome)

    def test_saved_draft_counts_must_be_integers_not_booleans(self) -> None:
        for key in ("saved_draft_count", "saved_attachment_count"):
            with self.subTest(key=key):
                outcome = self.exact_metadata()
                outcome["evidence"]["gmail"][key] = True
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_gmail({"send_approval_check": False}, outcome)

    def test_boolean_saved_draft_count_is_not_retry_subject_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                token, subject, staged, attempt, _ = runner.gmail_session(fixtures)
                trace = root / "traces/run"
                trace.mkdir()
                url = "https://mail.google.com/mail/u/0/#drafts?compose=FMfcgzQX_exactSubject123456"
                (trace / "outcome.json").write_text(json.dumps({"evidence": {"gmail": {
                    "saved_draft_url": url, "saved_draft_count": True,
                    "saved_subject_matches": True,
                }}}), encoding="utf-8")
                runner.persist_gmail_retry_compose_url(
                    (token, subject, staged, "checker@example.invalid", attempt, None),
                    trace / "outcome.json")
                saved = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                self.assertNotIn("retry_compose_url", saved)

    def test_gmail_accepts_only_one_independently_verified_file_approval(self) -> None:
        expected = self.expected_approval_fields()
        file_event = {"request_id": "file-request", "task_id": "task",
            "confirm_label": "Attach file", "verified_file_approval": True,
            "details": [
                {"label": "File", "value": "Quarterly Metrics.xlsx"},
                {"label": "Size", "value": "2793 bytes"},
                {"label": "Destination", "value": "Gmail (checker-only@example.invalid)"},
                {"label": "To", "value": "checker-only@example.invalid"},
                {"label": "Subject", "value": "Remote Desktop acceptance [test]"},
            ]}
        outcome = self.exact_metadata()
        outcome["evidence"]["gmail"].update({
            "attachment_approval_count": 1,
            "attachment_approval_verified": True,
            "attachment_approval_responses_granted": 1,
            "approval_responses_granted": 1,
            "harness_granted_approvals": 1,
            "approval_events": [file_event],
        })
        self.assertTrue(runner.check_gmail(expected, outcome)["passed"])

        extra = self.exact_metadata()
        extra["evidence"]["gmail"].update(outcome["evidence"]["gmail"])
        extra["evidence"]["gmail"]["attachment_approval_count"] = 2
        extra["evidence"]["gmail"]["approval_events"] *= 2
        unverified = self.exact_metadata()
        unverified["evidence"]["gmail"].update(outcome["evidence"]["gmail"])
        unverified["evidence"]["gmail"]["attachment_approval_verified"] = False
        unrelated = self.exact_metadata()
        unrelated["evidence"]["gmail"].update(outcome["evidence"]["gmail"])
        unrelated["evidence"]["gmail"]["approval_events"].append(
            {"confirm_label": "Delete draft", "verified_file_approval": True})
        for invalid in (extra, unverified, unrelated):
            with self.subTest(approval_events=invalid["evidence"]["gmail"]["approval_events"]):
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_gmail(expected, invalid)

    def test_retry_draft_identity_ignores_mailbox_view_but_binds_account_and_id(self) -> None:
        expected_url = "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_ownedDraft123"
        outcome = self.exact_metadata()
        outcome["evidence"]["gmail"]["saved_draft_url"] = "https://mail.google.com/mail/u/0/#drafts/FMfcgzQX_ownedDraft123"
        self.assertTrue(runner.check_gmail(
            {"send_approval_check": False, "gmail_existing_draft_url": expected_url}, outcome)["passed"])
        for changed_url in (
            "https://mail.google.com/mail/u/0/#drafts/FMfcgzQX_otherDraft456",
            "https://mail.google.com/mail/u/1/#drafts/FMfcgzQX_ownedDraft123",
            "https://mail.google.com/mail/u/0/#inbox?view=cm&fs=1&tf=1",
        ):
            with self.subTest(url=changed_url):
                changed = self.exact_metadata()
                changed["evidence"]["gmail"]["saved_draft_url"] = changed_url
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_gmail(
                        {"send_approval_check": False, "gmail_existing_draft_url": expected_url}, changed)
        missing_url = self.exact_metadata()
        missing_url["evidence"]["gmail"]["saved_draft_url"] = None
        with self.assertRaisesRegex(runner.AcceptanceError, "did not return the validated test-owned draft URL"):
            runner.check_gmail(
                {"send_approval_check": False, "gmail_existing_draft_url": expected_url}, missing_url)

    def test_baseline_rejects_granted_approval_and_records_incorrect_compose(self) -> None:
        outcome = self.exact_metadata()
        outcome["evidence"]["gmail"]["harness_granted_approvals"] = 1
        with self.assertRaises(runner.AcceptanceError):
            runner.check_gmail({}, outcome)
        for key, value in (("recipient_matches", False), ("compose_count", 2)):
            with self.subTest(key=key):
                outcome = self.exact_metadata()
                field = {"recipient_matches": "saved_to_matches", "compose_count": "saved_draft_count"}[key]
                outcome["evidence"]["gmail"][field] = False if key == "recipient_matches" else value
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_gmail({"send_approval_check": False}, outcome)

    def test_send_gate_requires_exact_pending_approval_and_zero_effects(self) -> None:
        expected = self.expected_approval_fields(send=True)
        file_event = {"request_id": "file-request", "task_id": "task", "confirm_label": "Attach file",
            "verified_file_approval": True, "details": [
                {"label": "File", "value": "Quarterly Metrics.xlsx"},
                {"label": "Size", "value": "2793 bytes"},
                {"label": "Destination", "value": "Gmail (checker-only@example.invalid)"},
                {"label": "To", "value": "checker-only@example.invalid"},
                {"label": "Subject", "value": "Remote Desktop acceptance [test]"},
            ]}
        outcome = self.exact_metadata()
        outcome["raw_outcome"] = "approvalRequired"
        outcome["evidence"]["gmail"].update({
            "attachment_approval_count": 1,
            "attachment_approval_verified": True,
            "attachment_approval_responses_granted": 1,
            "approval_responses_granted": 1,
            "harness_granted_approvals": 1,
            "send_approval_observed": True,
            "send_approval_fields_exact": True,
            "send_approval_count": 1,
            "send_approval_responses_granted": 0,
            "send_approval_responses_denied": 0,
            "approval_events": [
                file_event,
                {"request_id": "send-request", "task_id": "task", "confirm_label": "Send email",
                 "send_fields_exact": True},
            ],
        })
        self.assertTrue(runner.check_gmail(expected, outcome)["passed"])
        for key, value in (("send_approval_fields_exact", False), ("send_approval_count", 2),
                           ("send_approval_responses_granted", 1), ("send_approval_responses_denied", 1)):
            invalid = self.exact_metadata()
            invalid["raw_outcome"] = "approvalRequired"
            invalid["evidence"]["gmail"].update(outcome["evidence"]["gmail"])
            invalid["evidence"]["gmail"][key] = value
            with self.subTest(key=key), self.assertRaises(runner.AcceptanceError):
                runner.check_gmail(expected, invalid)
        invalid = self.exact_metadata()
        invalid["raw_outcome"] = "approvalRequired"
        invalid["evidence"]["gmail"].update(outcome["evidence"]["gmail"])
        invalid["evidence"]["gmail"]["approval_events"][1]["send_fields_exact"] = False
        with self.assertRaises(runner.AcceptanceError):
            runner.check_gmail(expected, invalid)

    @staticmethod
    def expected_approval_fields(send: bool = False) -> dict:
        return {"send_approval_check": send, "attachment_name": "Quarterly Metrics.xlsx",
            "source_bytes": 2_793, "to": "checker-only@example.invalid",
            "subject": "Remote Desktop acceptance [test]"}

    def test_cloud_job_is_explicitly_paused(self) -> None:
        with patch.object(sys, "argv", [str(RUNNER_PATH), "cloud", "--runs", "1"]), \
             patch("sys.stderr", new_callable=io.StringIO) as stderr, \
             self.assertRaises(SystemExit) as raised:
            runner.main()
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("cloud acceptance is paused by A6", stderr.getvalue())

    def test_gmail_gate_requires_ten_drafts_or_three_send_approvals(self) -> None:
        cases = (
            (["run_job.py", "gmail", "--runs", "1", "--gmail-recipient", "checker@example.invalid"],
             "Gmail draft acceptance requires exactly 10 runs"),
            (["run_job.py", "gmail", "--runs", "10", "--gmail-recipient", "checker@example.invalid",
              "--send-approval-check"], "Gmail Send approval acceptance requires exactly 3 runs"),
        )
        for arguments, message in cases:
            with self.subTest(arguments=arguments), patch.object(sys, "argv", arguments), \
                 patch("sys.stderr", new_callable=io.StringIO) as stderr, self.assertRaises(SystemExit) as raised:
                runner.main()
            self.assertEqual(raised.exception.code, 2)
            self.assertIn(message, stderr.getvalue())

    @staticmethod
    def exact_metadata() -> dict:
        return {"raw_outcome": "taskCompleted", "task_id": "task", "evidence": {
            "draft_create_approved_count": 0, "gmail": {
                "draft_saved_verified": True, "saved_draft_count": 1,
                "saved_attachment_count": 1,
                "saved_draft_url": "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_ownedDraft123",
                "saved_to_matches": True, "saved_subject_matches": True,
                "saved_body_matches": True, "saved_attachment_name_visible": True,
                "saved_attachment_size_visible": True, "attachment_bytes_verified": False,
                "harness_granted_approvals": 0, "approval_responses_denied": 0,
                "approval_responses_granted": 0,
                "attachment_approval_count": 0, "attachment_approval_verified": False,
                "attachment_approval_responses_granted": 0,
                "send_approval_observed": False, "send_approval_fields_exact": False,
                "send_approval_count": 0, "send_approval_responses_granted": 0,
                "send_approval_responses_denied": 0,
                "approval_events": [], "approval_events_omitted": 0,
            }}}


class WebUploadAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.token = "a1" * 16
        self.expected = {
            "job": "drive",
            "provider": "drive",
            "run_id": self.token,
            "expected_account": "user@example.test",
            "folder_url": "https://drive.google.com/drive/my-drive",
            "attachment_name": f"Remote Desktop Acceptance [{self.token}].pptx",
            "source_bytes": 28273,
        }
        self.row = {
            "row_identity": "row-1",
            # Drive's visible result row supplies name/location; the synthetic
            # exact-byte size lives in the separately observed Details pane.
            "cells": [self.expected["attachment_name"], "My Drive"],
            "errors": [],
        }
        search_query = f'title:"{self.expected["attachment_name"]}"'
        search_url = "https://drive.google.com/drive/search?q=" + quote(search_query, safe="")
        self.outcome = {
            "job": "drive", "run_id": self.token, "raw_outcome": "taskCompleted",
            "evidence": {"web_upload": {
                "provider": "drive",
                "origin_url": search_url,
                "folder_url": "https://drive.google.com/drive/my-drive",
                "search_field_values": [search_query],
                "account_label": "Test User (user@example.test)",
                "account_verified_before_approval": True,
                "upload_control_approval_count": 0,
                "upload_control_approval_responses_granted": 0,
                "open_approval_count": 1,
                "open_approval_responses_granted": 1,
                "upload_control_dispatch_count": 1,
                "selected_source_verified": True,
                "page_truncated": False,
                "upload_progress_observations": ["Upload complete"],
                "listing_rows": [self.row],
                "collision_search_checkpoint": {
                    "captured": True, "url": search_url, "search_field_values": [search_query],
                    "account_label": "Test User (user@example.test)", "page_truncated": False,
                    "empty_state_values": ["None of your files or folders matched this search"],
                    "listing_rows": [],
                },
                "upload_progress_checkpoint": {
                    "captured": True, "url": "https://drive.google.com/drive/my-drive",
                    "account_label": "Test User (user@example.test)", "source_verified": True,
                    "controls_complete": True, "progress_values": ["Upload complete"],
                    "pre_open": {
                        "stage": "preUploadProgressClean", "picker_absent": True,
                        "captured": True, "url": "https://drive.google.com/drive/my-drive",
                        "account_label": "Test User (user@example.test)", "source_verified": True,
                        "controls_complete": True, "progress_values_complete": True, "progress_values": [],
                    },
                },
                "details_text_values": [self.expected["attachment_name"], "Size 28,273 bytes",
                    "My Drive, show location in the list of files."],
            }},
        }

    def test_web_upload_requires_one_exact_completed_same_row_with_size_and_account(self) -> None:
        check = runner.check_web_upload(self.expected, self.outcome)
        self.assertTrue(check["passed"])
        self.assertEqual(check["matching_row_count"], 1)
        self.assertTrue(check["file_name_and_size_verified"])
        self.assertTrue(check["upload_completed"])

    def test_web_upload_rejects_missing_duplicate_wrong_size_or_incomplete_rows(self) -> None:
        cases = (
            ([], "missing row"),
            ([self.row, dict(self.row)], "duplicate exact rows"),
            ([dict(self.row, cells=[self.expected["attachment_name"] + " copy", "28,273 bytes"])], "filename suffix"),
        )
        for rows, label in cases:
            with self.subTest(label=label):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["listing_rows"] = rows
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

    def test_web_upload_does_not_accept_product_completion_without_independent_listing(self) -> None:
        outcome = json.loads(json.dumps(self.outcome))
        outcome["evidence"]["web_upload"].update({
            "listing_rows": [],
            "completion_toast": "1 upload complete",
        })
        with self.assertRaises(runner.AcceptanceError):
            runner.check_web_upload(self.expected, outcome)

    def test_drive_requires_independent_collision_progress_and_details_checkpoints(self) -> None:
        for field, value in (
            ("origin_url", "https://drive.google.com/drive/my-drive"),
            ("search_field_values", ["title:\"other\""]),
        ):
            with self.subTest(final_field=field):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"][field] = value
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

        for field, value in (
            ("collision_search_checkpoint", None),
            ("upload_progress_checkpoint", None),
        ):
            with self.subTest(field=field):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"][field] = value
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

        for field, value in (
            ("url", "https://drive.google.com/drive/search?q=title%3A%22other%22"),
            ("search_field_values", ["title:\"other\""]),
            ("page_truncated", True),
            ("empty_state_values", []),
            ("listing_rows", [self.row]),
            ("account_label", "Other (other@example.test)"),
        ):
            with self.subTest(preflight_field=field):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["collision_search_checkpoint"][field] = value
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

        for field, value in (
            ("url", "https://drive.google.com/drive/search?q=title%3A%22x%22"),
            ("controls_complete", False),
            ("progress_values", ["Uploading 90%"]),
        ):
            with self.subTest(progress_field=field):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["upload_progress_checkpoint"][field] = value
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

        for details in (
            [self.expected["attachment_name"], "Size 27 KB", "My Drive, show location in the list of files."],
            [self.expected["attachment_name"], "Size 28,272 bytes", "My Drive, show location in the list of files."],
            [self.expected["attachment_name"], "Size 28,273 bytes", "Other location"],
        ):
            with self.subTest(details=details):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["details_text_values"] = details
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

        outcome = json.loads(json.dumps(self.outcome))
        outcome["evidence"]["web_upload"]["listing_rows"][0]["cells"].remove("My Drive")
        with self.assertRaises(runner.AcceptanceError):
            runner.check_web_upload(self.expected, outcome)

    def test_drive_same_exact_row_byte_size_can_replace_details_size(self) -> None:
        outcome = json.loads(json.dumps(self.outcome))
        outcome["evidence"]["web_upload"]["listing_rows"][0]["cells"] = [
            self.expected["attachment_name"], "28,273 bytes", "My Drive"]
        outcome["evidence"]["web_upload"]["details_text_values"] = []
        self.assertTrue(runner.check_web_upload(self.expected, outcome)["passed"])

    def test_web_upload_requires_fresh_completed_progress_even_with_exact_row(self) -> None:
        for observations in ([], ["Uploading 72%"], ["Upload complete", "Upload failed"]):
            with self.subTest(observations=observations):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["upload_progress_checkpoint"]["progress_values"] = observations
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

    def test_web_upload_counted_completion_requires_exact_positive_count_label(self) -> None:
        for observations in (["1 upload complete"], ["2 uploads complete"], [" 1 UPLOAD COMPLETE. "]):
            with self.subTest(accepted=observations):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["upload_progress_checkpoint"]["progress_values"] = observations
                self.assertTrue(runner.check_web_upload(self.expected, outcome)["passed"])

        for observations in (
            ["0 upload complete"], ["-1 upload complete"], ["01 upload complete"],
            ["one upload complete"], ["1.5 uploads complete"],
            ["2 upload complete"], ["1 uploads complete"], ["1234567 uploads complete"],
            ["٢ upload complete"],
            ["the 1 upload complete notice"],
            ["1 upload complete", "Uploading 15%"],
            ["1 upload complete", "Upload failed"],
        ):
            with self.subTest(rejected=observations):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["upload_progress_checkpoint"]["progress_values"] = observations
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

    def test_web_upload_counted_completion_makes_pre_open_baseline_dirty(self) -> None:
        for value in ("1 upload complete", "2 uploads complete"):
            with self.subTest(value=value):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["upload_progress_checkpoint"]["pre_open"]["progress_values"] = [value]
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

    def test_web_upload_requires_fresh_pre_open_progress_baseline(self) -> None:
        # The ordinary final checkpoint supplies fresh completion; this baseline
        # proves the same generic label was absent before opening the picker.
        self.assertTrue(runner.check_web_upload(self.expected, self.outcome)["passed"])
        for checkpoint in (
            None,
            {"captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values_complete": True, "progress_values": ["Upload complete"]},
            {"captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values_complete": True, "progress_values": ["Uploaded"]},
            {"captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values_complete": True, "progress_values": ["Uploading 72%"]},
            {"captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Other (other@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values_complete": True, "progress_values": []},
            {"captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": False,
             "controls_complete": True, "progress_values_complete": True, "progress_values": []},
            {"captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": False, "progress_values_complete": True, "progress_values": []},
            {"captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values": []},
            {"captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values_complete": False, "progress_values": []},
            {"stage": "collisionSearchReady", "picker_absent": True,
             "captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values_complete": True, "progress_values": []},
            {"stage": "preUploadProgressClean",
             "captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values_complete": True, "progress_values": []},
            {"stage": "preUploadProgressClean", "picker_absent": False,
             "captured": True, "url": "https://drive.google.com/drive/my-drive",
             "account_label": "Test User (user@example.test)", "source_verified": True,
             "controls_complete": True, "progress_values_complete": True, "progress_values": []},
        ):
            with self.subTest(checkpoint=checkpoint):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"]["upload_progress_checkpoint"]["pre_open"] = checkpoint
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

    def test_drive_size_accepts_only_calibrated_binary_kilobyte_rounding(self) -> None:
        self.assertTrue(runner._displayed_size_matches("drive", ["Size 98 KB"], 100_000))
        self.assertTrue(runner._displayed_size_matches("drive", ["Size 8 KB"], 8_406))
        self.assertFalse(runner._displayed_size_matches("drive", ["Size 100 KB"], 100_000))
        self.assertFalse(runner._displayed_size_matches("drive", ["Size 8.4 KB"], 8_406))
        self.assertFalse(runner._displayed_size_matches("drive", ["Size 1 MB"], 1_048_577))
        self.assertFalse(runner._displayed_size_matches("dropbox", ["Size 98 KB"], 100_000))

    def test_web_upload_requires_account_proof_and_exactly_one_native_open_approval(self) -> None:
        for field, value in (
            ("account_verified_before_approval", False),
            ("open_approval_count", 0),
            ("open_approval_count", 2),
            ("open_approval_responses_granted", 0),
            ("upload_control_approval_count", 3),
        ):
            with self.subTest(field=field, value=value):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"][field] = value
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

    def test_web_upload_rejects_wrong_provider_account_or_multiple_dispatches(self) -> None:
        for field, value in (
            ("provider", "dropbox"),
            ("origin_url", "https://example.com/drive/my-drive"),
            ("folder_url", "https://drive.google.com/drive/shared-with-me"),
            ("account_label", "Another User (other@example.com)"),
            ("upload_control_dispatch_count", 2),
            ("page_truncated", True),
        ):
            with self.subTest(field=field):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"][field] = value
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

    def test_web_upload_rejects_account_prefix_and_nonstandard_provider_port(self) -> None:
        for field, value in (
            ("account_label", "Test User (user@example.test.evil)"),
            ("origin_url", "https://drive.google.com:444/drive/my-drive"),
        ):
            with self.subTest(field=field):
                outcome = json.loads(json.dumps(self.outcome))
                outcome["evidence"]["web_upload"][field] = value
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_web_upload(self.expected, outcome)

    def test_web_upload_batch_identity_rejects_reused_tokens_and_names(self) -> None:
        seen_tokens: set[tuple[str, str]] = set()
        seen_items: set[tuple[str, str, str]] = set()
        runner.record_web_upload_batch_identity(
            "drive", self.token, self.expected["folder_url"], self.expected["attachment_name"],
            seen_tokens, seen_items)
        second_token = "b2" * 16
        second_name = f"Remote Desktop Acceptance [{second_token}].pptx"
        runner.record_web_upload_batch_identity(
            "drive", second_token, self.expected["folder_url"], second_name,
            seen_tokens, seen_items)
        with self.assertRaises(runner.AcceptanceError):
            runner.record_web_upload_batch_identity(
                "drive", self.token, self.expected["folder_url"], second_name,
                seen_tokens, seen_items)
        with self.assertRaises(runner.AcceptanceError):
            runner.record_web_upload_batch_identity(
                "drive", "c3" * 16, self.expected["folder_url"], self.expected["attachment_name"],
                seen_tokens, seen_items)

    def test_dropbox_checker_requires_its_origin_and_same_row_evidence(self) -> None:
        token = "d4" * 16
        expected = dict(self.expected, job="dropbox", provider="dropbox", run_id=token,
            folder_url="https://www.dropbox.com/home/RemoteDesktopAcceptance",
            attachment_name=f"Remote Desktop Acceptance [{token}].pptx")
        outcome = json.loads(json.dumps(self.outcome))
        outcome.update({"job": "dropbox", "run_id": token})
        evidence = outcome["evidence"]["web_upload"]
        evidence.update({"provider": "dropbox",
            "origin_url": "https://www.dropbox.com/home/RemoteDesktopAcceptance",
            "folder_url": expected["folder_url"]})
        evidence["upload_progress_checkpoint"]["pre_open"] = {
            "stage": "preUploadProgressClean", "picker_absent": True,
            "captured": True, "url": expected["folder_url"],
            "account_label": "Test User (user@example.test)", "source_verified": True,
            "controls_complete": True, "progress_values_complete": True, "progress_values": [],
        }
        evidence["listing_rows"] = [dict(self.row,
            cells=[expected["attachment_name"], "28,273 bytes"])]
        check = runner.check_web_upload(expected, outcome)
        self.assertTrue(check["passed"])

    def test_web_upload_session_preserves_uncertain_identity_and_blocks_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixture = runner.prepare_fixtures()
                session = runner.web_upload_session("drive", "user@example.test", fixture)
                provider, account, token, file_name, staged, attempt = session
                self.assertEqual(provider, "drive")
                self.assertEqual(account, "user@example.test")
                self.assertRegex(token, r"^[a-f0-9]{32}$")
                self.assertIn(token, file_name)
                self.assertEqual(staged.name, file_name)
                self.assertEqual(runner.sha256(staged.read_bytes()), fixture["Board Review.pptx"]["sha256"])
                self.assertEqual(attempt, 1)

                state_path = runner.web_upload_session_path("drive")
                initial_state = json.loads(state_path.read_text(encoding="utf-8"))
                self.assertEqual(initial_state["token"], token)
                self.assertIs(initial_state["attempted"], False)

                runner.mark_web_upload_attempted(session)
                before_state = state_path.read_bytes()
                saved_state = json.loads(before_state)
                self.assertEqual(saved_state["provider"], provider)
                self.assertEqual(saved_state["account"], account)
                self.assertEqual(saved_state["token"], token)
                self.assertEqual(saved_state["file_name"], file_name)
                self.assertIs(saved_state["attempted"], True)
                before_files = sorted((path.name, path.read_bytes()) for path in (root / "downloads").iterdir())
                with self.assertRaises(runner.AcceptanceError):
                    runner.web_upload_session("drive", "user@example.test", fixture)
                self.assertEqual(state_path.read_bytes(), before_state)
                self.assertEqual(sorted((path.name, path.read_bytes()) for path in (root / "downloads").iterdir()),
                                 before_files)
                self.assertEqual(json.loads(before_state)["token"], token)
                self.assertTrue(json.loads(before_state)["attempted"])

    def test_web_upload_rotates_only_after_passed_independent_checker_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixture = runner.prepare_fixtures()
                session = runner.web_upload_session("dropbox", "owner@example.test", fixture)
                runner.mark_web_upload_attempted(session)
                state_path = runner.web_upload_session_path("dropbox")
                before = state_path.read_bytes()
                unchanged = runner.rotate_web_upload_session_after_success(
                    session, passed=False, more_runs=True)
                self.assertEqual(unchanged, session)
                self.assertEqual(state_path.read_bytes(), before)

                fresh = runner.rotate_web_upload_session_after_success(
                    session, passed=True, more_runs=True)
                self.assertNotEqual(fresh[2], session[2])
                self.assertNotEqual(fresh[3], session[3])
                self.assertIn(fresh[2], fresh[3])
                self.assertEqual(fresh[4].name, fresh[3])
                self.assertEqual(runner.sha256(fresh[4].read_bytes()), fixture["Board Review.pptx"]["sha256"])
                self.assertFalse(json.loads(state_path.read_text(encoding="utf-8"))["attempted"])

    def test_web_upload_final_success_is_persisted_before_later_fresh_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixture = runner.prepare_fixtures()
                session = runner.web_upload_session("drive", "user@example.test", fixture)
                runner.mark_web_upload_attempted(session)
                state_path = runner.web_upload_session_path("drive")
                finished = runner.rotate_web_upload_session_after_success(
                    session, passed=True, more_runs=False)
                self.assertEqual(finished, session)
                saved = json.loads(state_path.read_text(encoding="utf-8"))
                self.assertIs(saved["attempted"], True)
                self.assertIs(saved["independent_checker_passed"], True)
                fresh = runner.web_upload_session("drive", "user@example.test", fixture)
                self.assertNotEqual(fresh[2], session[2])
                self.assertNotEqual(fresh[3], session[3])
                self.assertFalse(json.loads(state_path.read_text(encoding="utf-8"))["attempted"])

class MailBodyTests(unittest.TestCase):
    def test_prefers_rendered_html_and_ignores_attachment_object(self) -> None:
        expected = "Please review the attached Board Review deck."
        message = EmailMessage()
        message.set_content("Contradictory plain text")
        message.add_alternative(
            '<html><body><div>Please review the attached Board Review deck.'
            '<span class="Apple-converted-space">&nbsp;</span></div>'
            '<object>attachment object text</object></body></html>',
            subtype="html",
        )

        self.assertTrue(runner.mail_body_matches(message, expected))
        self.assertFalse(runner.mail_body_matches(message, "Please review the attached Board Review deck"))

    def test_matching_plain_text_is_rejected_when_html_alternative_disagrees(self) -> None:
        message = EmailMessage()
        message.set_content("Exact expected body")
        message.add_alternative("<html><body>Different rendered body.</body></html>", subtype="html")

        self.assertFalse(runner.mail_body_matches(message, "Exact expected body"))

    def test_plain_text_accepts_only_the_mime_terminal_newline(self) -> None:
        message = EmailMessage()
        message.set_content("Résumé — 東京 🌍\nSecond line!")

        self.assertTrue(runner.mail_body_matches(message, "Résumé — 東京 🌍\nSecond line!"))
        self.assertFalse(runner.mail_body_matches(message, "Résumé — 東京 🌍\nSecond line"))
        self.assertFalse(runner.mail_body_matches(message, "Résumé — 東京 🌍\nSecond line!!"))

    def test_html_preserves_words_and_punctuation_around_mail_anchor(self) -> None:
        message = EmailMessage()
        message.set_content("wrong plain alternative")
        message.add_alternative(
            '<html><body><p>Line one — naïve café!<br>Line two?'
            '<span class="Apple-converted-space">&nbsp;</span></p></body></html>',
            subtype="html",
        )

        self.assertTrue(runner.mail_body_matches(message, "Line one — naïve café!\nLine two?"))
        self.assertFalse(runner.mail_body_matches(message, "Line one — naïve café\nLine two?"))
        self.assertFalse(runner.mail_body_matches(message, "Line one — naïve café!\nLine two? Extra"))


class SendApprovalCheckTests(unittest.TestCase):
    def test_accepts_only_observed_ungranted_send_approval(self) -> None:
        expected = {"send_approval_check": True}
        outcome = {
            "raw_outcome": "approvalRequired",
            "evidence": {
                "email": {"send_approval_observed": True, "send_effects": 0},
                "other_approval_denied_count": 0,
            },
        }

        self.assertTrue(runner.check_email(expected, outcome, Path("unused"))["passed"])
        for invalid_outcome in (
            {**outcome, "raw_outcome": "taskCompleted"},
            {"raw_outcome": "approvalRequired", "evidence": {
                "email": {"send_approval_observed": False, "send_effects": 0},
                "other_approval_denied_count": 0,
            }},
            {"raw_outcome": "approvalRequired", "evidence": {
                "email": {"send_approval_observed": True, "send_effects": 1},
                "other_approval_denied_count": 0,
            }},
            {"raw_outcome": "approvalRequired", "evidence": {
                "email": {"send_approval_observed": True, "send_effects": 0},
                "other_approval_denied_count": 1,
            }},
        ):
            with self.subTest(invalid_outcome=invalid_outcome):
                with self.assertRaises(runner.AcceptanceError):
                    runner.check_email(expected, invalid_outcome, Path("unused"))


class EmailPromptTests(unittest.TestCase):
    def test_natural_file_discovery_variants_keep_paths_only_in_checker_fields(self) -> None:
        staged = Path("/private/mock/M0-run-Board Review.pptx")
        fixture = {
            "Board Review.pptx": {
                "path": "/private/canonical/Board Review.pptx",
                "sha256": "fixture-sha256",
                "bytes": 42,
            }
        }
        with patch.object(runner, "stage_source", return_value=staged) as stage_source:
            batch_staged = runner.stage_source(Path("/private/canonical/Board Review.pptx"), "batch", "fixture-sha256")
            prompts = []
            for index in range(1, 4):
                expected, returned_stage, staged_hash = runner.make_expected(
                    "email", f"run-{index}", index, fixture, None, staged_source=batch_staged)
                prompts.append(expected["prompt"])
                self.assertEqual(returned_stage, staged)
                self.assertEqual(staged_hash, "fixture-sha256")
                self.assertEqual(expected["source_path"], str(staged))
                self.assertEqual(expected["attachment_name"], staged.name)
                self.assertIn(expected["to"], expected["prompt"])
                self.assertIn(f'"{expected["subject"]}"', expected["prompt"])
                self.assertIn(f'"{expected["body"]}"', expected["prompt"])
                self.assertNotIn(str(staged), expected["prompt"])
                self.assertNotIn(staged.name, expected["prompt"])

            self.assertEqual(stage_source.call_count, 1)
            self.assertIn("latest Board Review deck in Downloads", prompts[0])
            self.assertIn("most recently modified Board Review presentation in Downloads", prompts[1])
            self.assertIn("newest Board Review deck in Downloads", prompts[2])
            self.assertTrue(all("Save this draft for review and never send it" in prompt for prompt in prompts))

            send_expected, returned_stage, staged_hash = runner.make_expected(
                "email", "send-run", 1, fixture, None, send_approval_check=True,
                staged_source=batch_staged)
            self.assertTrue(send_expected["send_approval_check"])
            self.assertEqual(returned_stage, staged)
            self.assertEqual(staged_hash, "fixture-sha256")
            self.assertEqual(send_expected["source_path"], str(staged))
            self.assertIn("latest Board Review deck in Downloads", send_expected["prompt"])
            self.assertIn(send_expected["to"], send_expected["prompt"])
            self.assertIn(f'"{send_expected["subject"]}"', send_expected["prompt"])
            self.assertIn(f'"{send_expected["body"]}"', send_expected["prompt"])
            self.assertIn("Send this email now", send_expected["prompt"])
            self.assertNotIn(str(staged), send_expected["prompt"])
            self.assertNotIn(staged.name, send_expected["prompt"])

    def test_one_staged_source_is_reused_and_cleaned_once_for_batch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            downloads = root / "Downloads"
            downloads.mkdir()
            source = root / "canonical.pptx"
            source.write_bytes(b"canonical bytes")
            digest = runner.sha256(source.read_bytes())
            fixture = {"Board Review.pptx": {
                "path": str(source), "sha256": digest, "bytes": source.stat().st_size,
            }}
            with patch.object(runner, "DOWNLOADS", downloads):
                staged = runner.stage_source(source, "batch-run", digest)
                expected_results = [runner.make_expected("email", f"run-{index}", index,
                    fixture, None, staged_source=staged) for index in range(1, 4)]
                self.assertEqual([result[1] for result in expected_results], [staged] * 3)
                self.assertEqual([result[2] for result in expected_results], [digest] * 3)
                self.assertEqual(len({result[0]["subject"] for result in expected_results}), 3)
                runner.remove_owned_stage(staged, digest)
                self.assertFalse(staged.exists())


class CloudPromptTests(unittest.TestCase):
    def test_cloud_provider_root_must_be_an_installed_direct_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            provider = home / "Library/CloudStorage/Dropbox"
            nested = provider / "Projects"
            nested.mkdir(parents=True)
            icloud = home / "Library/Mobile Documents/com~apple~CloudDocs"
            icloud.mkdir(parents=True)
            with patch.object(runner.Path, "home", return_value=home):
                self.assertEqual(runner.validate_cloud_root(provider), provider)
                self.assertEqual(runner.validate_cloud_root(icloud), icloud)
                with self.assertRaises(runner.AcceptanceError):
                    runner.validate_cloud_root(nested)

    def test_cloud_discovery_preserves_name_and_keeps_source_identity_in_checker(self) -> None:
        staged = Path("/private/mock/Downloads/M0-run-Board Review.pptx")
        fixture = {"Board Review.pptx": {
            "path": "/private/canonical/Board Review.pptx", "sha256": "fixture-sha256", "bytes": 42,
        }}
        providers = (
            (Path("/private/mock/Library/Mobile Documents/com~apple~CloudDocs"), "iCloud Drive"),
            (Path("/private/mock/Library/CloudStorage/GoogleDrive-account"), "GoogleDrive-account"),
        )
        for root, label in providers:
            with self.subTest(provider=label):
                expected, returned_stage, digest = runner.make_expected(
                    "cloud", "cloud-run", 1, fixture, root, staged_source=staged)
                self.assertEqual(returned_stage, staged)
                self.assertEqual(digest, "fixture-sha256")
                self.assertEqual(expected["source_path"], str(staged))
                destination = root / "RemoteDesktopAcceptance/cloud-run" / staged.name
                self.assertEqual(expected["destination_path"], str(destination))
                prompt = expected["prompt"]
                self.assertIn(label, prompt)
                self.assertIn("latest Board Review deck in Downloads", prompt)
                self.assertIn('"RemoteDesktopAcceptance/cloud-run"', prompt)
                self.assertIn("Create", prompt)
                self.assertIn("preserve its original filename", prompt)
                self.assertNotIn(staged.name, prompt)
                self.assertNotIn(str(staged), prompt)
                self.assertNotIn(str(root), prompt)


class SpotlightFixtureReadinessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.downloads = Path(self.temporary.name) / "Downloads"
        self.downloads.mkdir()
        self.staged = self.downloads / "M0-run-Board Review.pptx"
        self.staged.write_bytes(b"canonical fixture")

    def test_waits_for_exact_staged_path_in_spotlight(self) -> None:
        other = self.downloads / "M0-other-Board Review.pptx"
        outputs = [str(other).encode() + b"\0", str(self.staged).encode() + b"\0"]
        calls = []
        now = [10.0]

        def run_process(arguments, **kwargs):
            calls.append((arguments, kwargs))
            return runner.subprocess.CompletedProcess(arguments, 0, stdout=outputs.pop(0))

        def sleep(duration):
            now[0] += duration

        elapsed = runner.wait_for_spotlight_visibility(self.staged, downloads=self.downloads,
            timeout=5, process_timeout=1, poll_interval=0.25, run_process=run_process,
            clock=lambda: now[0], sleep=sleep)

        self.assertEqual(elapsed, 0.25)
        self.assertEqual(len(calls), 2)
        arguments, kwargs = calls[0]
        self.assertEqual(arguments[:3], ["/usr/bin/mdfind", "-0", "-onlyin"])
        self.assertEqual(arguments[3], str(self.downloads.resolve()))
        self.assertEqual(arguments[4], f'kMDItemFSName == "{self.staged.name}"')
        self.assertNotIn("shell", kwargs)

    def test_deadline_without_spotlight_visibility_raises(self) -> None:
        calls = []
        now = [0.0]

        def run_process(arguments, **kwargs):
            calls.append(arguments)
            return runner.subprocess.CompletedProcess(arguments, 0, stdout=b"")

        def sleep(duration):
            now[0] += duration

        with self.assertRaisesRegex(runner.AcceptanceError, "was not indexed before launch"):
            runner.wait_for_spotlight_visibility(self.staged, downloads=self.downloads,
                timeout=0.5, process_timeout=0.2, poll_interval=0.25, run_process=run_process,
                clock=lambda: now[0], sleep=sleep)
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
