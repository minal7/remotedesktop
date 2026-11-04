"""Synthetic image checks for CompareStaticText; set LATENCY_COMPARE_BINARY."""
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib


def write_png(path, width, height, pixels):
    """Write opaque 8-bit RGB without any external imaging dependency."""
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff))
    scanlines = b''.join(b'\0' + bytes(channel for pixel in pixels[y * width:(y + 1) * width]
                                       for channel in pixel)
                         for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'
                     + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(scanlines)) + chunk(b'IEND', b''))


def crop_pixels(pixels, width, crop):
    x, y, w, h = crop
    return [pixels[(y + row) * width + x + col] for row in range(h) for col in range(w)]


def round_edge(value):
    # All mapped coordinates are nonnegative; Swift rounds half away from zero.
    return math.floor(value + .5)


class CompareStaticTextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        binary = os.environ.get('LATENCY_COMPARE_BINARY')
        if not binary:
            raise unittest.SkipTest('Set LATENCY_COMPARE_BINARY to the already-built comparator')
        cls.binary = str(Path(binary).resolve(strict=True))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.reference_size = [48, 48]
        self.reference_crop = [3, 2, 30, 40]
        self.fonts = {'11pt': [3, 2, 30, 12], '12pt': [3, 16, 30, 12],
                      '13pt': [3, 30, 30, 12]}
        self.fixture = {'image_pixels': self.reference_size, 'crop_pixels': self.reference_crop,
                        'font_crops_pixels': self.fonts}

    def inputs(self, reference, a, b, screen_size, capture_crop):
        write_png(self.root / 'reference.png', *self.reference_size, reference)
        write_png(self.root / 'a.png', capture_crop[2], capture_crop[3], a)
        write_png(self.root / 'b.png', capture_crop[2], capture_crop[3], b)
        capture = {'image_pixels': screen_size, 'crop_pixels': capture_crop,
                   'reference_pixels': self.reference_size, 'reference_crop_pixels': self.reference_crop}
        (self.root / 'fixture.json').write_text(json.dumps(self.fixture))
        (self.root / 'capture.json').write_text(json.dumps(capture))
        return capture

    def compare(self, *, succeeds=True):
        result_path = self.root / 'result.json'
        process = subprocess.run([self.binary, str(self.root / 'reference.png'), str(self.root / 'a.png'),
                                  str(self.root / 'b.png'), str(self.root / 'fixture.json'),
                                  str(self.root / 'capture.json'), str(result_path)],
                                 capture_output=True, text=True, timeout=30)
        if succeeds:
            self.assertEqual(process.returncode, 0, process.stderr)
            return json.loads(result_path.read_text())
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(result_path.exists())

    def test_asymmetric_top_left_identity_and_blur(self):
        width, height = self.reference_size
        # Asymmetric texture on both axes makes any vertical flip or offset visible.
        reference = [(25 + (x * 17 + y * 29) % 190,
                      20 + (x * 31 + y * 7) % 200,
                      15 + (x * 11 + y * 19) % 210)
                     for y in range(height) for x in range(width)]
        sharp = crop_pixels(reference, width, self.reference_crop)
        cw, ch = self.reference_crop[2:]
        blurred = []
        for y in range(ch):
            for x in range(cw):
                neighbors = [sharp[ny * cw + nx]
                             for ny in range(max(0, y - 1), min(ch, y + 2))
                             for nx in range(max(0, x - 1), min(cw, x + 2))]
                blurred.append(tuple(round(sum(p[c] for p in neighbors) / len(neighbors)) for c in range(3)))
        self.inputs(reference, sharp, blurred, self.reference_size, self.reference_crop)
        result = self.compare()
        for name in self.fonts:
            with self.subTest(font=name):
                self.assertAlmostEqual(result['fonts'][name]['a_ssim'], 1.0, places=10)
                self.assertLess(result['fonts'][name]['b_ssim'], result['fonts'][name]['a_ssim'] - .05)
                self.assertLess(result['fonts'][name]['a_vs_b_ssim'], 1.0)

    def test_fractional_aspect_fit_matches_analytic_linear_gradient(self):
        width, height = self.reference_size
        def gradient(x, y):
            return (30 + 2*x + y, 20 + x + 2*y, 10 + x + y)
        reference = [gradient(x, y) for y in range(height) for x in range(width)]
        # 91x70 creates horizontal letterboxing and scale 70/48, neither an
        # integer scale nor an integer left edge. The independent expected image
        # evaluates the known linear function directly at pixel centers.
        screen = [91, 70]
        scale = screen[1] / height
        left = (screen[0] - width * scale) / 2
        x, y, w, h = self.reference_crop
        x0, y0 = round_edge(left + x * scale), round_edge(y * scale)
        x1, y1 = round_edge(left + (x + w) * scale), round_edge((y + h) * scale)
        rectangle = [x0, y0, x1 - x0, y1 - y0]
        expected = []
        for py in range(y0, y1):
            for px in range(x0, x1):
                source_x = (px + .5 - left) / scale - .5
                source_y = (py + .5) / scale - .5
                expected.append(tuple(round(v) for v in gradient(source_x, source_y)))
        self.inputs(reference, expected, expected, screen, rectangle)
        result = self.compare()
        for name in self.fonts:
            with self.subTest(font=name):
                self.assertGreater(result['fonts'][name]['a_ssim'], .999)
                self.assertAlmostEqual(result['fonts'][name]['a_vs_b_ssim'], 1.0, places=10)

    def test_mismatched_and_out_of_bounds_geometry_rejected(self):
        reference = [(x * 4, y * 4, (x + y) * 2) for y in range(48) for x in range(48)]
        sharp = crop_pixels(reference, 48, self.reference_crop)
        capture = self.inputs(reference, sharp, sharp, self.reference_size, self.reference_crop)
        capture['reference_pixels'] = [49, 48]
        (self.root / 'capture.json').write_text(json.dumps(capture))
        self.compare(succeeds=False)
        capture['reference_pixels'] = self.reference_size
        (self.root / 'capture.json').write_text(json.dumps(capture))
        self.fixture['font_crops_pixels']['11pt'] = [40, 2, 30, 12]
        (self.root / 'fixture.json').write_text(json.dumps(self.fixture))
        self.compare(succeeds=False)
        self.fixture['font_crops_pixels']['11pt'] = [3, 2, 30, 12]
        (self.root / 'fixture.json').write_text(json.dumps(self.fixture))
        # Valid PNG but a different B size must not compare.
        write_png(self.root / 'b.png', 8, 8, [(0, 0, 0)] * 64)
        self.compare(succeeds=False)


if __name__ == '__main__':
    unittest.main()
