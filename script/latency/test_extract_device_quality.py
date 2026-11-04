"""Synthetic-only tests for strict quality attachment selection."""
import tempfile
from pathlib import Path
import unittest

import extract_device_quality as extract


class QualityAttachmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        (self.directory / 'artifact.png').write_bytes(b'synthetic')
        self.name = 'latency-quality-A.png'
        self.attachment = {'exportedFileName': 'artifact.png', 'suggestedHumanReadableName': self.name,
                           'deviceId': 'device-1'}
        self.manifest = [{'testIdentifier': extract.TARGET + '/' + extract.TEST_ID,
                          'attachments': [self.attachment]}]

    def select(self):
        return extract.select_attachment(self.manifest, self.directory, self.name, 'device-1')

    def test_selects_exact_test_name_and_device(self):
        self.assertEqual(self.select(), self.directory / 'artifact.png')
        self.manifest[0]['testIdentifier'] = extract.TEST_ID.removesuffix('()')
        self.assertEqual(self.select(), self.directory / 'artifact.png')
        self.manifest[0]['testIdentifier'] = extract.TEST_ID.replace('()', '(other)')
        with self.assertRaises(ValueError): self.select()

    def test_rejects_duplicates_other_devices_and_unexpected_names(self):
        self.manifest[0]['attachments'].append(dict(self.attachment))
        with self.assertRaises(ValueError): self.select()
        self.manifest[0]['attachments'].pop()
        self.attachment['deviceId'] = 'other'
        with self.assertRaises(ValueError): self.select()
        self.attachment['deviceId'] = 'device-1'
        self.attachment['suggestedHumanReadableName'] = 'screenshot.png'
        with self.assertRaises(ValueError): self.select()

    def test_rejects_wrong_test_and_path_escape(self):
        self.manifest[0]['testIdentifier'] = 'AnotherTest/testCaptureF4AAndB'
        with self.assertRaises(ValueError): self.select()
        self.manifest[0]['testIdentifier'] = extract.TEST_ID
        self.attachment['exportedFileName'] = '../outside.png'
        with self.assertRaises(ValueError): self.select()
        self.attachment['exportedFileName'] = 'link.png'
        (self.directory / 'link.png').symlink_to(self.directory / 'artifact.png')
        with self.assertRaises(ValueError): self.select()


if __name__ == '__main__':
    unittest.main()
