#!/usr/bin/env python3
"""Bounded Off/On perception profile, no private content, paid inference or UI automation."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import tempfile
import threading
import time

import profile_companion_runtime as usage

ROOT = Path(__file__).resolve().parents[1]


def measure(app, seconds, enabled):
    with tempfile.TemporaryDirectory(prefix='lite2d-perception-profile-') as tmp:
        directory = Path(tmp)
        state = directory / 'controller'
        project = directory / 'synthetic-project'
        project.mkdir()
        env = dict(os.environ, LITE2D_NATIVE_PROBE_ROOT=str(state))
        child = subprocess.Popen([str(app), '--companion-runtime-probe'], cwd=ROOT, env=env,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        messages = queue.Queue()
        def receive():
            for line in child.stdout:
                try:
                    messages.put(json.loads(line))
                except ValueError:
                    pass
        threading.Thread(target=receive, daemon=True).start()
        def send(value):
            child.stdin.write(json.dumps(value) + '\n')
            child.stdin.flush()
        def wait(kind):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                event = messages.get(timeout=max(0.01, deadline - time.monotonic()))
                if event['type'] in ['error', 'probe.error']:
                    raise RuntimeError(event)
                if event['type'] == kind:
                    return event
            raise RuntimeError('Missing profile handshake')
        samples = []
        try:
            wait('ready')
            perception = {'mode': 'shadow' if enabled else 'off', 'workspace': enabled, 'idle': enabled,
                          'power': enabled, 'network': enabled, 'audio': enabled, 'files': enabled,
                          'directories': [{'id': '33333333-3333-4333-8333-333333333333', 'path': str(project)}]}
            send({'type': 'configure', 'config': {'enabled': True, 'intervalMinutes': 0, 'characters': [],
                                                 'hourlyRequests': 12, 'perception': perception}})
            wait('status')
            time.sleep(3)  # bounded framework warm-up, outside the sampled interval
            started = time.monotonic()
            touched = set()
            while time.monotonic() - started < seconds:
                elapsed = time.monotonic() - started
                send({'type': 'poll'})
                for boundary in [5, 15]:
                    if elapsed >= boundary and boundary not in touched:
                        (project / 'fixture.txt').write_text(f'synthetic change {boundary}')
                        touched.add(boundary)
                processes = usage.tree(child.pid)
                value = usage.Usage()
                wakeups = None
                if usage.libproc.proc_pid_rusage(child.pid, 2, ctypes.byref(value)) == 0:
                    wakeups = value.idle_wakeups + value.interrupt_wakeups
                samples.append({'elapsed': elapsed, 'cpu': sum(p['cpuSeconds'] for p in processes),
                                'footprint': sum(p['footprint'] for p in processes), 'rss': sum(p['rss'] for p in processes),
                                'processCount': len(processes), 'wakeups': wakeups})
                time.sleep(1)
            send({'type': 'diagnostics'})
            diagnostics = wait('diagnostics')['data']
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.terminate()
                child.wait(timeout=5)
        if child.returncode:
            raise RuntimeError('Profile process failed: ' + child.stderr.read()[-1000:])
        with sqlite3.connect(state / 'state.sqlite') as db:
            model_requests = db.execute('SELECT COUNT(*) FROM requests').fetchone()[0]
            event_count = db.execute('SELECT COUNT(*) FROM perception_events').fetchone()[0]
        assert model_requests == 0, 'Perception must not create inference in this fixture'
        assert diagnostics['helper']['starts'] == 0, 'Perception must not start a Node helper'
        duration = samples[-1]['elapsed'] - samples[0]['elapsed']
        summary = {'mode': 'on-shadow' if enabled else 'off', 'sampledSeconds': duration,
                   'cpuSeconds': samples[-1]['cpu'] - samples[0]['cpu'],
                   'oneCoreCPUPercent': 100 * (samples[-1]['cpu'] - samples[0]['cpu']) / duration,
                   'footprintMeanMiB': sum(s['footprint'] for s in samples) / len(samples) / 1048576,
                   'rssMeanMiB': sum(s['rss'] for s in samples) / len(samples) / 1048576,
                   'maxProcessCount': max(s['processCount'] for s in samples), 'modelRequests': model_requests,
                   'helperStarts': diagnostics['helper']['starts'], 'normalizedEventIdentities': event_count,
                   'wakeupsPerSecond': None if samples[0]['wakeups'] is None or samples[-1]['wakeups'] is None else (samples[-1]['wakeups'] - samples[0]['wakeups']) / duration}
        print(json.dumps(summary, ensure_ascii=False), flush=True)
        return {'summary': summary, 'samples': samples}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--app', type=Path, default=ROOT / 'dist/Lite2D.app/Contents/MacOS/Lite2D')
    parser.add_argument('--output', type=Path, default=ROOT / '.local/verification/perception-profile.json')
    args = parser.parse_args()
    if args.seconds < 20:
        parser.error('Use at least 20 seconds per case')
    results = [measure(args.app, args.seconds, False), measure(args.app, args.seconds, True)]
    before, after = (value['summary'] for value in results)
    report = {'cases': results, 'incremental': {'cpuSeconds': after['cpuSeconds'] - before['cpuSeconds'],
              'oneCoreCPUPercent': after['oneCoreCPUPercent'] - before['oneCoreCPUPercent'],
              'footprintMeanMiB': after['footprintMeanMiB'] - before['footprintMeanMiB']},
              'limits': 'Single sequential bounded run, no rendering/real-model load or sensitive sources; summed process footprint is not unique RAM.'}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2))
    print(json.dumps({'incremental': report['incremental'], 'output': str(args.output)}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
