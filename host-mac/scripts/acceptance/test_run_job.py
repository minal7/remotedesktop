"""Focused tests for the independent Mail acceptance checks."""

from __future__ import annotations

from email.message import EmailMessage
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


RUNNER_PATH = Path(__file__).with_name("run_job.py")
SPEC = importlib.util.spec_from_file_location("acceptance_run_job", RUNNER_PATH)
assert SPEC is not None and SPEC.loader is not None
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


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
            self.assertTrue(all("leave it open for review; do not send" in prompt for prompt in prompts))

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
