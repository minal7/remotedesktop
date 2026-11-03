import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


class QAGuardTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.flag = self.root / 'qa-active'
        self.guard = Path(__file__).with_name('qa_guard.py')

    def launch(self, code):
        process = subprocess.Popen([sys.executable, str(self.guard), '--flag', str(self.flag),
                                    '--timeout', '15', '--', sys.executable, '-c', code],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.finish, process)
        return process

    @staticmethod
    def finish(process):
        if process.poll() is None:
            process.terminate()
        process.communicate(timeout=12)

    def await_file(self, path):
        deadline = time.monotonic() + 5
        while not path.exists():
            if time.monotonic() >= deadline:
                self.fail(f'Child did not create {path.name}')
            time.sleep(.02)

    @staticmethod
    def running(pid):
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
        return result.returncode == 0 and result.stdout.strip() and not result.stdout.strip().startswith('Z')

    def testExistingQAFlagNeverStartsChild(self):
        self.flag.touch()
        marker = self.root / 'started'
        process = self.launch(f'from pathlib import Path; Path({str(marker)!r}).touch()')
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, 75)
        self.assertFalse(marker.exists())

    def testTerminatingGuardAlsoTerminatesItsChild(self):
        marker = self.root / 'pid'
        process = self.launch(f'import os,time; from pathlib import Path; Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(30)')
        self.await_file(marker)
        child = int(marker.read_text())
        process.terminate()
        process.communicate(timeout=12)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM)
        self.assertFalse(self.running(child))

    def testQAClaimStopsDescendantEvenAfterLeaderExits(self):
        marker = self.root / 'descendant'
        child_code = ('import os,signal,time; from pathlib import Path; '
                      'signal.signal(signal.SIGINT, signal.SIG_IGN); '
                      f'Path({str(marker)!r}).write_text(str(os.getpid())); time.sleep(30)')
        parent_code = ('import signal,subprocess,sys,time; '
                       'signal.signal(signal.SIGINT, lambda *_: sys.exit(0)); '
                       f'subprocess.Popen([sys.executable, "-c", {child_code!r}]); time.sleep(30)')
        process = self.launch(parent_code)
        self.await_file(marker)
        child = int(marker.read_text())
        self.flag.touch()
        process.communicate(timeout=12)
        self.assertEqual(process.returncode, 75)
        self.assertFalse(self.running(child))


if __name__ == '__main__':
    unittest.main()
