"""Opt-in trained-model diagnostic: one proposal, no execution, joined cleanup.
Arguments: request.json output-directory assets-directory signed-llama-server [4|5 GiB] [fara-q6|fara-q6-reading].
The 5 GiB option is diagnostic only and does not change the production profile.
"""
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

request_file = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
assets = Path(sys.argv[3]).resolve()
binary = Path(sys.argv[4]).resolve()
memory_limit_gib = int(sys.argv[5]) if len(sys.argv) > 5 else 4
assert memory_limit_gib in (4, 5)
output.mkdir(exist_ok=False)
request_bytes = request_file.read_bytes()
request_body = json.loads(request_bytes)
assert request_body['max_tokens'] == 1024 and request_body['stream'] is False
alias = request_body['model']
if alias == 'holo-browser-v1':
    assert request_body['parallel_tool_calls'] is False
    assert request_body['tool_choice'] == 'required'
    assert {tool['function']['name'] for tool in request_body['tools']} <= {'click', 'scroll', 'web_search', 'wait', 'answer', 'key', 'type', 'ask_user', 'visit_url', 'history_back'}
    model_name, projector_name = 'Holo-3.1-4B.Q4_K_M.gguf', 'Holo-3.1-4B.mmproj-f16.gguf'
    model_label = 'Holo'
elif alias == 'gui-owl-desktop-v1':
    assert 'tools' not in request_body and 'tool_choice' not in request_body
    assert request_body['temperature'] == 0 and request_body['seed'] == 20260913
    assert memory_limit_gib == 4
    model_name, projector_name = 'GUI-Owl-1.5-2B-Instruct.Q4_K_M.gguf', 'GUI-Owl-1.5-2B-Instruct.mmproj-f16.gguf'
    model_label = 'GUI-Owl-desktop'
elif alias == 'fara-browser-v1':
    assert len(sys.argv) == 7 and sys.argv[6] in ('fara-q6', 'fara-q6-reading')
    assert memory_limit_gib == 5
    assert 'tools' not in request_body and 'tool_choice' not in request_body
    assert request_body['reasoning_format'] == 'none'
    if sys.argv[6] == 'fara-q6':
        assert request_body['temperature'] == 0
    else:
        assert 'temperature' not in request_body
        assert len(request_body['messages']) == 2
        assert request_body['messages'][0] == {'role':'system', 'content':"You are given the markdown content of a web page. Answer the user's question based solely on this content. Be concise and extract only the relevant information."}
    model_name, projector_name = 'Fara1.5-4B-Q6_K.gguf', 'mmproj-Fara1.5-4B-f16.gguf'
    model_label = 'Fara-Q6-reading' if sys.argv[6].endswith('-reading') else 'Fara-Q6'
else:
    raise AssertionError('Unsupported diagnostic model alias')
processes = subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True)
assert not any(Path(line.strip()).name == 'llama-server' for line in processes.splitlines()), 'Another inference worker is active'
subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True)
manifest = json.loads((assets / 'verified-assets.json').read_text())
assert {item['name'] for item in manifest['files']} == {model_name, projector_name}
for item in manifest['files']:
    path = assets / item['name']
    assert path.stat().st_size == item['bytes']
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        while data := handle.read(4 * 1024**2):
            digest.update(data)
    assert digest.hexdigest() == item['sha256']

# Offsets are from this SDK's sys/resource.h rusage_info_v4: UUID[16],
# six UInt64 counters, resident size, physical footprint. Keep a full-size
# buffer for the system call, and sample the same max metric as the app.
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int
def memory_bytes(pid):
    buffer = ctypes.create_string_buffer(1024)
    if libproc.proc_pid_rusage(pid, 4, ctypes.byref(buffer)) != 0:
        return None
    resident, footprint = struct.unpack_from('=QQ', buffer.raw, 64)
    return max(resident, footprint)
assert memory_bytes(os.getpid()) > 0

token = secrets.token_urlsafe(32)
key_path = output / 'temporary-api-key'
with os.fdopen(os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as handle:
    handle.write(token)
with socket.socket() as port_socket:
    port_socket.bind(('127.0.0.1', 0))
    port = port_socket.getsockname()[1]
arguments = [str(binary), '--model', str(assets / model_name),
    '--mmproj', str(assets / projector_name), '--alias', request_body['model'],
    '--host', '127.0.0.1', '--port', str(port), '--api-key-file', str(key_path),
    '--offline', '--no-ui', '--log-disable', '--parallel', '1', '--no-cont-batching',
    '--ctx-size', '8192', '--no-context-shift', '--cache-ram', '0', '--ctx-checkpoints', '0', '--no-cache-idle-slots',
    '--threads', '4', '--threads-batch', '4', '--poll', '0', '--poll-batch', '0',
    '--batch-size', '512', '--ubatch-size', '128', '--n-gpu-layers', '99',
    '--image-max-tokens', '1536', '--mtmd-batch-max-tokens', '1536', '--jinja']
report = dict(scope='one-native-' + model_label + '-protocol-proposal-no-tool-execution',
    requestSHA256=hashlib.sha256(request_bytes).hexdigest(),
    modelAssets=manifest, binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
    targetMacRAMGB=12, wholeApp12GBQualified=False, selectedProductionModelChanged=False,
    memoryMetric='sampled max of resident size and physical footprint', memoryStopLimitBytes=memory_limit_gib * 1024**3,
    diagnosticMemoryLimitOnly=memory_limit_gib != 4, productionMemoryLimitChanged=False,
    peakSampledProcessMemoryBytes=0, memorySamples=0, startupDeadlineSeconds=45,
    generationDeadlineSeconds=45, totalDeadlineSeconds=100, runnerExecutesNoActions=True)
report['minimumImageTokensEnvironment'] = os.environ.get('LLAMA_ARG_IMAGE_MIN_TOKENS')
stop = threading.Event()
process = None
watcher = None
started = time.monotonic()
termination_lock = threading.Lock()
termination_at = None
def stop_owned():
    global termination_at
    with termination_lock:
        if process is None or process.poll() is not None:
            return
        now = time.monotonic()
        signal_to_send = None
        if termination_at is None:
            termination_at = now
            signal_to_send = signal.SIGTERM
        elif now - termination_at >= 5:
            signal_to_send = signal.SIGKILL
        if signal_to_send is not None:
            try:
                os.killpg(process.pid, signal_to_send)
            except ProcessLookupError:
                pass

def interrupted(signum, frame):
    # Let finally join the owned worker, even when the native test cancels us.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise InterruptedError('diagnostic cancelled')

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
def monitor():
    while not stop.wait(0.25):
        if process.poll() is not None:
            return
        if termination_at is not None:
            stop_owned()
            continue
        measured = memory_bytes(process.pid)
        if measured is not None:
            report['memorySamples'] += 1
            report['peakSampledProcessMemoryBytes'] = max(report['peakSampledProcessMemoryBytes'], measured)
            if measured > report['memoryStopLimitBytes']:
                report['watchdogReason'] = 'memory-limit'
                stop_owned()
                continue
        if time.monotonic() - started > report['totalDeadlineSeconds']:
            report['watchdogReason'] = 'deadline'
            stop_owned()
            continue
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def fetch(path, body=None, timeout=2):
    request = urllib.request.Request('http://127.0.0.1:' + str(port) + path,
        data=None if body is None else json.dumps(body, ensure_ascii=False).encode(),
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with opener.open(request, timeout=timeout) as response:
        data = response.read(1024**2 + 1)
        assert len(data) <= 1024**2
        return json.loads(data)
try:
    with (output / 'server.log').open('wb') as log:
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        report['pid'] = process.pid
        watcher = threading.Thread(target=monitor, daemon=True)
        watcher.start()
        deadline = started + 45
        while True:
            if process.poll() is not None:
                raise RuntimeError('server exited before health: ' + str(process.returncode))
            if time.monotonic() >= deadline:
                raise TimeoutError('server startup exceeded 45 seconds')
            try:
                if fetch('/health').get('status') == 'ok':
                    break
            except (urllib.error.URLError, TimeoutError):
                pass
            time.sleep(0.25)
        report['startupSeconds'] = time.monotonic() - started
        print(json.dumps(dict(stage='ready', startupSeconds=report['startupSeconds'])), flush=True)
        generation = time.monotonic()
        response = fetch('/v1/chat/completions', request_body, timeout=45)
        report['generationSeconds'] = time.monotonic() - generation
        (output / 'response.json').write_text(json.dumps(response, ensure_ascii=False, indent=2))
        report['responseReceived'] = True
        report['usage'] = response.get('usage')
        report['finishReason'] = response['choices'][0].get('finish_reason')
except Exception as error:
    report['error'] = type(error).__name__ + ': ' + str(error)
finally:
    stop_owned()
    if process is not None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        report['exitCode'] = process.returncode
        report['ownedProcessExited'] = process.poll() is not None
    stop.set()
    if watcher is not None:
        watcher.join(timeout=3)
    key_path.unlink(missing_ok=True)
    report['credentialRemoved'] = not key_path.exists()
    report['totalSeconds'] = time.monotonic() - started
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({key: report[key] for key in ('responseReceived', 'error', 'watchdogReason', 'startupSeconds', 'generationSeconds', 'peakSampledProcessMemoryBytes', 'totalSeconds', 'ownedProcessExited') if key in report}), flush=True)
sys.exit(0 if report.get('responseReceived') and report.get('ownedProcessExited') else 1)
