from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path.cwd()
sys.path.insert(0, str(root / 'script/latency'))
from run_device_pairs import IPAD_HANDOFF, require_device_window
flag = Path('/Users/michael/.codex/worktrees/remote-desktop-release/remote desktop/build/.release-qa-active')
config = json.loads((root / 'build/latency/lab-v2/ipad-handoff-config.json').read_text())
handoff = datetime.fromisoformat(config['not_before'].replace('Z', '+00:00'))
if '--guarded' not in sys.argv:
    print('Waiting for 18:30 Pacific and the release QA flag to clear; no device commands started.', flush=True)
    while datetime.now(timezone.utc) < handoff or flag.exists() or not IPAD_HANDOFF.is_file():
        time.sleep(.5)
    os.execv(sys.executable, [sys.executable, str(root / 'script/latency/qa_guard.py'),
        '--flag', str(flag), '--timeout', '900', '--', sys.executable, str(Path(__file__).resolve()), '--guarded'])
if flag.exists() or datetime.now(timezone.utc) < handoff:
    raise SystemExit(75)
require_device_window()
host_app = root / 'build/latency/mac/Build/Products/Debug/RemoteDesktopHost.app'
client_app = root / 'build/latency/ios-derived/Build/Products/Debug-iphoneos/RemoteDesktop.app'
output = root / 'build/latency/lab-v2/ipad-f1-first-window'
output.mkdir(exist_ok=False)
host = install = sweep = None
pending = 0
logs = []

def cancel(sig, _frame):
    global pending
    pending = pending or sig

for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, cancel)

def check():
    if pending or flag.exists():
        raise RuntimeError('Release QA or cancellation ended this iPad window.')
    require_device_window()

def log(name):
    handle = (output / name).open('wb')
    logs.append(handle)
    return handle

def wait_owned(process, timeout):
    deadline = time.monotonic() + timeout
    while process.poll() is None:
        check()
        if host is not None and process is not host and host.poll() is not None:
            raise RuntimeError('Isolated Debug host ended before the iPad sweep.')
        if time.monotonic() > deadline:
            raise RuntimeError('Owned command exceeded its time limit.')
        time.sleep(.2)
    return process.returncode

try:
    check()
    print('Starting the isolated Debug host for the first iPad F1 sweep.', flush=True)
    host = subprocess.Popen([sys.executable, 'script/latency/run_debug_host.py', '--internal-guarded',
        '--host-app', str(host_app), '--host-id', config['host_id'], '--qa-flag', str(flag),
        '--output', str(output / 'host'), '--timeout', '850'], stdout=log('host-controller.log'), stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 20
    while not (output / 'host/state.json').exists():
        check()
        if host.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Debug host failed to start.')
        time.sleep(.2)
    check()
    print('Running four interleaved F1 A/B pairs on the iPad over LAN.', flush=True)
    sweep = subprocess.Popen([sys.executable, 'script/latency/run_device_pairs.py', '--guarded',
        '--device', config['device_id'], '--host-id', config['host_id'], '--host-app', str(host_app), '--client-app', str(client_app),
        '--qa-flag', str(flag), '--not-before', config['not_before'], '--fix', 'F1',
        '--marker-binary', str(root / 'build/latency/lab-v2/DeviceMarkerProbe'),
        '--host-traces', str(Path.home() / 'Library/Application Support/RemoteDesktopHost/Latency'),
        '--output', str(output / 'pairs')], stdout=log('sweep.log'), stderr=subprocess.STDOUT)
    code = wait_owned(sweep, 650)
    print('F1 paired sweep exit ' + str(code), flush=True)
    if code:
        raise RuntimeError('F1 sweep did not complete; inspect retained run files.')
finally:
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, signal.SIG_IGN)
    # Stop the paired controller first: it owns the physical client and marker.
    for process in (sweep, install, host):
        if process is not None and process.poll() is None:
            process.terminate()
    for process in (sweep, install, host):
        if process is None:
            continue
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
            print('An owned controller required forced cleanup; verify its recorded state.', flush=True)
    for handle in logs:
        handle.close()
