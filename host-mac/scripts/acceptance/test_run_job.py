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

    def test_retry_keeps_one_owned_draft_and_attachment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.multiple(runner, TRACE_ROOT=root / "traces",
                                GMAIL_SESSION_PATH=root / "traces/session.json",
                                FIXTURE_ROOT=root / "fixtures", DOWNLOADS=root / "downloads"):
                fixtures = runner.prepare_fixtures()
                first = runner.gmail_session(fixtures)
                retry = runner.gmail_session(fixtures)
                self.assertEqual(first[:3], retry[:3])
                self.assertEqual((first[3], retry[3]), (1, 2))
                self.assertIsNone(first[4])
                self.assertIsNone(retry[4])
                self.assertEqual(list((root / "downloads").iterdir()), [first[2]])
                self.assertEqual(runner.sha256(first[2].read_bytes()),
                                 fixtures["Quarterly Metrics.xlsx"]["sha256"])
                recipient = "checker-only@example.invalid"
                for session in (first, retry):
                    expected, _, _ = runner.make_expected("gmail", "run", 1, fixtures, None,
                        staged_source=session[2], gmail=(session[0], session[1], session[2], recipient,
                                                       session[3], session[4]))
                    self.assertEqual(expected["to"], recipient)
                    self.assertNotIn(recipient, expected["prompt"])
                    self.assertNotIn(str(session[2]), expected["prompt"])
                    self.assertIn(session[1], expected["prompt"])
                    self.assertIn("never send", expected["prompt"])
                    self.assertEqual("reuse it" in expected["prompt"], session[3] > 1)

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

    def test_unverified_legacy_compose_url_is_preserved_but_not_reused(self) -> None:
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
                session = runner.gmail_session(fixtures)
                saved = json.loads(runner.GMAIL_SESSION_PATH.read_text(encoding="utf-8"))
                self.assertIsNone(session[4])
                self.assertEqual(saved["legacy_unverified_compose_url"], old_url)
                self.assertFalse(saved["draft_saved_verified"])
                self.assertEqual(session[3], 1)
                expected, _, _ = runner.make_expected("gmail", "run", 1, fixtures, None,
                    staged_source=session[2], gmail=(session[0], session[1], session[2],
                        "checker-only@example.invalid", session[3], session[4]))
                self.assertNotIn(old_url, expected["prompt"])
                self.assertIn("Use the Gmail compose opened by the host", expected["prompt"])

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
        outcome = self.exact_metadata()
        outcome["raw_outcome"] = "approvalRequired"
        outcome["evidence"]["gmail"].update({
            "send_approval_observed": True,
            "send_approval_fields_exact": True,
            "send_approval_count": 1,
            "approval_responses_granted": 0,
        })
        self.assertTrue(runner.check_gmail({"send_approval_check": True}, outcome)["passed"])
        for key, value in (("send_approval_fields_exact", False), ("send_approval_count", 2),
                           ("approval_responses_granted", 1)):
            invalid = self.exact_metadata()
            invalid["raw_outcome"] = "approvalRequired"
            invalid["evidence"]["gmail"].update(outcome["evidence"]["gmail"])
            invalid["evidence"]["gmail"][key] = value
            with self.subTest(key=key), self.assertRaises(runner.AcceptanceError):
                runner.check_gmail({"send_approval_check": True}, invalid)

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
        return {"raw_outcome": "taskCompleted", "evidence": {
            "draft_create_approved_count": 0, "gmail": {
                "draft_saved_verified": True, "saved_draft_count": 1,
                "saved_attachment_count": 1,
                "saved_draft_url": "https://mail.google.com/mail/u/0/#inbox?compose=FMfcgzQX_ownedDraft123",
                "saved_to_matches": True, "saved_subject_matches": True,
                "saved_body_matches": True, "saved_attachment_name_visible": True,
                "saved_attachment_size_visible": True, "attachment_bytes_verified": False,
                "harness_granted_approvals": 0, "approval_responses_denied": 0,
                "approval_events": [], "approval_events_omitted": 0,
            }}}


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
