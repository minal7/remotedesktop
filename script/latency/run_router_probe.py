#!/usr/bin/env python3
"""Bounded, opt-in observation of ICMP replies from the current IPv4 router.

Times describe when this process observes ping's output, not kernel packet times.
Only typed measurements are written; ping and route output is never persisted.
"""
from __future__ import annotations

import argparse
import ctypes
import ipaddress
import json
import math
import os
import pty
import re
import selectors
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

INTERVAL_SECONDS = 0.09
MAX_SECONDS = 120.0
MAX_RECORDS = 1250
MAX_LINE = 4096
MAX_OUTPUT_BYTES = 1_000_000
_REQUEST = re.compile(r"^\d+ bytes to \S+: icmp_seq=(\d+)(?:\s|$)")
_REPLY = re.compile(r"^\d+ bytes from \S+: icmp_seq=(\d+)(?:\s|$).*[ ]time=([0-9]+(?:\.[0-9]+)?) ms(?:\s|$)")
_TIMEOUT = re.compile(r"^Request timeout for icmp_seq (\d+)\s*$")


def duration(value: str) -> float:
    try:
        result = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError('duration must be a number') from exc
    if not math.isfinite(result) or not 1 <= result <= MAX_SECONDS:
        raise argparse.ArgumentTypeError('duration must be between 1 and 120 seconds')
    return result


def output_path(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute() or path.name in ('', '.', '..') or '\x00' in value:
        raise argparse.ArgumentTypeError('output must be an absolute file path')
    return path


def system_uptime_calibration() -> dict:
    """Compare Python's mach clock directly with Foundation's host uptime."""
    if sys.platform != 'darwin' or time.get_clock_info('monotonic').implementation != 'mach_absolute_time()':
        raise RuntimeError('unsupported host clock')
    ctypes.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
    objc = ctypes.CDLL('/usr/lib/libobjc.A.dylib')
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    address = ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value
    obj_send = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(address)
    double_send = ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_void_p, ctypes.c_void_p)(address)
    obj = obj_send(objc.objc_getClass(b'NSProcessInfo'), objc.sel_registerName(b'processInfo'))
    before = time.monotonic()
    uptime = double_send(obj, objc.sel_registerName(b'systemUptime'))
    after = time.monotonic()
    offset = uptime - (before + after) / 2
    uncertainty = (after - before) / 2
    if not all(map(math.isfinite, (offset, uncertainty))) or abs(offset) > 0.01 or uncertainty > 0.01:
        raise RuntimeError('host clock calibration failed')
    return {'offset_seconds': offset, 'uncertainty_seconds': uncertainty}


def discover_router() -> str:
    try:
        result = subprocess.run(['/sbin/route', '-n', 'get', 'default'], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=3, check=False, text=True)
        if result.returncode != 0 or len(result.stdout) > 16384:
            raise ValueError()
        matches = re.findall(r'^\s*gateway:\s*(\S+)\s*$', result.stdout, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError()
        address = ipaddress.IPv4Address(matches[0])
        if address.is_unspecified or address.is_multicast or address.is_loopback:
            raise ValueError()
        return str(address)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        raise RuntimeError('default IPv4 router unavailable') from None


# Status: 0 unanswered, 1 received, 2 timeout, 3 received after timeout.
# End reason: 0 duration, 1 interrupt, 2 utility exit. Timing basis 1: output observation.
@dataclass
class Measurements:
    offset: float = 0.0

    def __post_init__(self):
        self.records = {}
        self.duplicates = 0
        self.reordered = 0
        self.malformed = 0
        self.max_response_sequence = -1
        self.last_request_time = None
        self.last_response_time = None
        self.truncated = False

    def _record(self, seq):
        if not 0 <= seq < MAX_RECORDS:
            self.malformed += 1
            return None
        if seq not in self.records:
            if len(self.records) >= MAX_RECORDS:
                self.truncated = True
                return None
            self.records[seq] = {'sequence': seq, 'request_observed_s': None,
                                 'response_observed_s': None, 'request_interval_s': None,
                                 'response_interval_s': None, 'rtt_ms': None,
                                 'timeout_observed_s': None}
        return self.records[seq]

    def observe(self, line: str, observed: float):
        if not math.isfinite(observed):
            self.malformed += 1
            return
        when = observed + self.offset
        request = _REQUEST.match(line)
        reply = _REPLY.match(line)
        timeout = _TIMEOUT.fullmatch(line)
        match = request or reply or timeout
        if match is None:
            # Ignore headers and summaries without copying arbitrary utility text.
            if 'icmp_seq' in line:
                self.malformed += 1
            return
        seq = int(match.group(1))
        record = self._record(seq)
        if record is None:
            return
        if request:
            if record['request_observed_s'] is not None:
                self.duplicates += 1
                return
            record['request_observed_s'] = when
            if self.last_request_time is not None:
                record['request_interval_s'] = max(0.0, when - self.last_request_time)
            self.last_request_time = when
        elif reply:
            rtt = float(reply.group(2))
            if not math.isfinite(rtt) or rtt > 1_000_000:
                self.malformed += 1
                return
            if record['response_observed_s'] is not None:
                self.duplicates += 1
                return
            if seq < self.max_response_sequence:
                self.reordered += 1
            self.max_response_sequence = max(self.max_response_sequence, seq)
            record['response_observed_s'] = when
            record['rtt_ms'] = rtt
            if self.last_response_time is not None:
                record['response_interval_s'] = max(0.0, when - self.last_response_time)
            self.last_response_time = when
        else:
            if record['timeout_observed_s'] is None:
                record['timeout_observed_s'] = when
            else:
                self.duplicates += 1

    def result(self):
        rows = []
        for seq in sorted(self.records):
            row = dict(self.records[seq])
            if row['response_observed_s'] is not None:
                row['status'] = 3 if row['timeout_observed_s'] is not None and row['timeout_observed_s'] <= row['response_observed_s'] else 1
            elif row['timeout_observed_s'] is not None:
                row['status'] = 2
            else:
                row['status'] = 0
            rows.append(row)
        # An unobserved sequence is not asserted to have been sent or lost.
        observed_requests = {r['sequence'] for r in rows if r['request_observed_s'] is not None}
        missing = ([i for i in range(max(observed_requests) + 1) if i not in observed_requests]
                   if observed_requests else [])
        return {'records': rows, 'unobserved_request_sequences': missing,
                'counts': {'requests_observed': len(observed_requests),
                           'responses_observed': sum(r['response_observed_s'] is not None for r in rows),
                           'timeouts_observed': sum(r['timeout_observed_s'] is not None for r in rows),
                           'unanswered_observed_requests': sum(r['request_observed_s'] is not None and r['response_observed_s'] is None for r in rows),
                           'unobserved_requests': len(missing), 'duplicates': self.duplicates,
                           'reordered_responses': self.reordered, 'malformed': self.malformed},
                'truncated': int(self.truncated)}


def collect(router: str, seconds: float, clock, stop_requested, popen=subprocess.Popen):
    """PTY ensures prompt utility output; only this child is signalled on exit."""
    measurements = Measurements(clock['offset_seconds'])
    master, slave = pty.openpty()
    child = None
    selector = selectors.DefaultSelector()
    pending = bytearray()
    dropping = False
    start = time.monotonic()
    end_reason = 0
    stop_time = None
    try:
        child = popen(['/sbin/ping', '-n', '-i', str(INTERVAL_SECONDS), '--apple-print-req', router],
                      stdin=subprocess.DEVNULL, stdout=slave, stderr=subprocess.DEVNULL,
                      close_fds=True)
        os.close(slave)
        slave = -1
        os.set_blocking(master, False)
        selector.register(master, selectors.EVENT_READ)
        deadline = start + seconds
        while True:
            now = time.monotonic()
            if stop_requested():
                end_reason = 1
                break
            if now >= deadline:
                break
            if child.poll() is not None:
                end_reason = 2
                break
            for key, _ in selector.select(min(0.1, deadline - now)):
                try:
                    chunk = os.read(key.fd, 4096)
                except (BlockingIOError, OSError):
                    continue
                observed = time.monotonic()
                for byte in chunk:
                    if byte == 10:
                        if not dropping:
                            measurements.observe(pending.decode('ascii', 'replace').strip(), observed)
                        else:
                            measurements.malformed += 1
                        pending.clear()
                        dropping = False
                    elif not dropping:
                        if len(pending) < MAX_LINE:
                            pending.append(byte)
                        else:
                            pending.clear()
                            dropping = True
        stop_time = time.monotonic()
    finally:
        selector.close()
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=1)
        os.close(master)
        if slave >= 0:
            os.close(slave)
    result = measurements.result()
    result.update({'start_s': start + clock['offset_seconds'],
                   'end_s': stop_time + clock['offset_seconds'],
                   'requested_duration_s': seconds, 'requested_interval_s': INTERVAL_SECONDS,
                   'clock': clock, 'end_reason': end_reason,
                   'timing_basis': 1})
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=duration, required=True)
    parser.add_argument('--output', type=output_path, required=True)
    args = parser.parse_args(argv)
    stop = [False]
    previous = {}
    fd = None
    try:
        clock = system_uptime_calibration()
        router = discover_router()
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, lambda _sig, _frame: stop.__setitem__(0, True))
        result = collect(router, args.seconds, clock, lambda: stop[0])
        encoded = (json.dumps(result, allow_nan=False, separators=(',', ':')) + '\n').encode('ascii')
        if len(encoded) > MAX_OUTPUT_BYTES:
            raise RuntimeError('output limit exceeded')
        with os.fdopen(fd, 'wb') as output:
            fd = None
            output.write(encoded)
        return 0 if result['end_reason'] == 0 else 1
    except (OSError, RuntimeError):
        print('router probe failed', file=sys.stderr)
        return 1
    finally:
        if fd is not None:
            os.close(fd)
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    raise SystemExit(main())
