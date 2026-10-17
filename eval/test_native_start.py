from __future__ import annotations

import subprocess
import unittest
from unittest.mock import patch

import native_start


class NativeStartTests(unittest.TestCase):
    def test_prepare_returns_serializable_exact_document_lease(self) -> None:
        calls = []

        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            return subprocess.CompletedProcess(argv, 0, "4321:98765\n", "")

        lease = native_start.prepare_textedit_untitled(runner)
        self.assertEqual(lease.as_dict(), {"pid": 4321, "window_id": 98765})
        self.assertEqual(native_start.NativeDocumentLease.from_dict(lease.as_dict()), lease)
        self.assertEqual(calls[0][0], ["/usr/bin/osascript", "-"])
        self.assertIn("make new document", calls[0][1]["input"])
        self.assertIn("(count of documents) is not 0", calls[0][1]["input"])
        self.assertIn("every window whose name is documentName", calls[0][1]["input"])
        self.assertIn("count of matchingWindows) is not 1", calls[0][1]["input"])
        self.assertNotIn("path of newDocument", calls[0][1]["input"])
        self.assertNotIn("Start.txt", calls[0][1]["input"])

    def test_close_targets_only_leased_document_and_process(self) -> None:
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "closed\n", "")

        native_start.close_textedit_untitled({"pid": 4321, "window_id": 98765}, runner)
        self.assertIn("appPID is not 4321", calls[0])
        self.assertIn("id is 98765", calls[0])
        self.assertIn("saving no", calls[0])
        self.assertIn("document of first item of matchingWindows", calls[0])

    def test_close_rejects_invalid_or_ambiguous_lease(self) -> None:
        with self.assertRaises(ValueError):
            native_start.NativeDocumentLease.from_dict({"pid": True, "window_id": 9})
        with self.assertRaises(ValueError):
            native_start.close_textedit_untitled({"pid": 1, "window_id": -1})

    def test_notes_setup_only_clears_selection(self) -> None:
        calls = []

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, "", "")

        native_start.prepare_notes_no_selection(runner)
        self.assertIn("set selection to {}", calls[0])
        self.assertNotIn("delete", calls[0].casefold())
        self.assertNotIn("make new note", calls[0].casefold())

    def test_empty_textedit_reset_only_quits_without_documents(self) -> None:
        calls = []
        responses = iter(["4321\n", "quit\n"])

        def runner(argv, **kwargs):
            calls.append(kwargs["input"])
            return subprocess.CompletedProcess(argv, 0, next(responses), "")

        native_start.reset_empty_textedit(runner)
        self.assertIn("if (count of documents) is 0 then", calls[1])
        self.assertIn("quit", calls[1])

        calls.clear()
        responses = iter(["4321\n", "has_documents\n"])
        native_start.reset_empty_textedit(runner)
        self.assertIn("if (count of documents) is 0 then", calls[1])


if __name__ == "__main__":
    unittest.main()
