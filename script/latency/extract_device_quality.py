#!/usr/bin/env python3
"""Export only the explicit synthetic-text crops and geometry from one UI test."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

TEST_ID = 'LatencyQualityLiveE2ETests/testCaptureF4AAndB'
TARGET = 'RemoteDesktopLatencyQualityTests'
ATTACHMENTS = ('latency-quality-A.png', 'latency-quality-B.png', 'latency-quality-geometry.json')


def accepted_identifier(value):
    return value in (TEST_ID, TARGET + '/' + TEST_ID)


def select_attachment(manifest, directory, expected_name, device_id):
    if not isinstance(manifest, list):
        raise ValueError('Attachment manifest must be an array.')
    matches = []
    for test in manifest:
        if not isinstance(test, dict) or not isinstance(test.get('attachments'), list):
            raise ValueError('Invalid test attachment manifest entry.')
        for attachment in test['attachments']:
            if not isinstance(attachment, dict):
                raise ValueError('Invalid attachment metadata.')
            # Filtering is mandatory: reject, rather than retain, any other
            # exported attachment (including automatic diagnostic captures).
            if (not accepted_identifier(test.get('testIdentifier'))
                    or attachment.get('suggestedHumanReadableName') != expected_name
                    or attachment.get('deviceId') != device_id):
                raise ValueError('Export contained an unexpected test, name, or device.')
            name = attachment.get('exportedFileName')
            if not isinstance(name, str) or not name or Path(name).name != name or name in ('.', '..'):
                raise ValueError('Unsafe exported attachment path.')
            path = directory / name
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(directory.resolve()):
                raise ValueError('Exported attachment is missing or outside the export directory.')
            matches.append(path)
    if len(matches) != 1:
        raise ValueError(f'Expected exactly one {expected_name} attachment for the specified device.')
    return matches[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--device-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = args.result.resolve(strict=True)
    if not result.is_dir() or result.suffix != '.xcresult':
        raise ValueError('Expected an existing xcresult bundle.')
    if not args.device_id or args.output.exists():
        raise ValueError('Device ID and a fresh output directory are required.')
    args.output.mkdir(parents=False, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='.quality-export-', dir=args.output) as temporary:
        base = Path(temporary)
        selected = {}
        for index, name in enumerate(ATTACHMENTS):
            directory = base / str(index)
            directory.mkdir()
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result),
                            '--output-path', str(directory), '--test-id', TEST_ID, '--filter', name],
                           check=True, timeout=60)
            manifest = json.loads((directory / 'manifest.json').read_text())
            selected[name] = select_attachment(manifest, directory, name, args.device_id)
            # Reject unlisted files: filter behavior is not assumed to provide
            # privacy if it exports material not represented in the manifest.
            files = list(directory.iterdir())
            if any(p.name != 'manifest.json' and p != selected[name] for p in files):
                raise ValueError('Export contained an unexpected extra file.')
        for name in ATTACHMENTS[:2]:
            with selected[name].open('rb') as stream:
                if stream.read(8) != b'\x89PNG\r\n\x1a\n':
                    raise ValueError('A quality crop is not a PNG.')
        metadata = json.loads(selected[ATTACHMENTS[2]].read_text())
        if not isinstance(metadata, dict) or metadata.get('capture') != 'untimed_synthetic_text':
            raise ValueError('Quality geometry metadata is invalid.')
        for name, source in selected.items():
            shutil.copyfile(source, args.output / name)
    print('Exported only the named synthetic crops and geometry; acceptance not assessed.')


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
