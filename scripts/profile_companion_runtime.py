#!/usr/bin/env python3
"""Bounded old/new Controller process-tree comparison; no UI automation.

Same SDK version, isolated transcript fixture, identical request burst/source
configuration. Report launch/RPC latency and per-process RSS/physical footprint
and cumulative CPU. Summed footprint is labelled, not treated as unique RAM.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.local/verification/swift-migration'
APP = ROOT / 'dist/Lite2D.app/Contents/MacOS/Lite2D'


class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ['user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins', 'wired', 'resident', 'footprint', 'start', 'exit',
         'child_user', 'child_system', 'child_idle_wakeups', 'child_interrupt_wakeups', 'child_pageins', 'child_elapsed', 'read_bytes', 'written_bytes']]


libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
timebase = Timebase()
ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(timebase))
CPU_SCALE = timebase.numer / timebase.denom / 1e9


def tree(pid):
    rows = []
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True).splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    selected = {pid}
    for _ in range(5):
        selected.update(p for p, parent, _ in rows if parent in selected)
    result = []
    for p, parent, command in rows:
        if p not in selected:
            continue
        value = Usage()
        if libproc.proc_pid_rusage(p, 2, ctypes.byref(value)) == 0:
            result.append({'pid': p, 'parent': parent, 'name': Path(command).name, 'rss': value.resident,
                           'footprint': value.footprint, 'cpuSeconds': (value.user + value.system) * CPU_SCALE})
    return result


def fixture(directory):
    project = directory / 'claude/projects/-fixture'
    project.mkdir(parents=True)
    for index in range(10):
        sid = f'11111111-1111-4111-8111-{index:012d}'
        rows = [{'uuid': f'user-{index}', 'parentUuid': None, 'sessionId': sid, 'type': 'user', 'isSidechain': False,
                 'cwd': '/fixture', 'timestamp': '2026-11-05T00:00:00Z', 'message': {'role': 'user', 'content': 'benchmark fixture'}},
                {'uuid': f'answer-{index}', 'parentUuid': f'user-{index}', 'sessionId': sid, 'type': 'assistant', 'isSidechain': False,
                 'cwd': '/fixture', 'timestamp': '2026-11-05T00:00:01Z', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'benchmark answer'}]}}]
        (project / f'{sid}.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    return directory / 'claude'


def measure(kind, seconds):
    with tempfile.TemporaryDirectory(prefix=f'lite2d-profile-{kind}-') as tmp:
        root = Path(tmp)
        claude = fixture(root)
        env = dict(os.environ, CLAUDE_CONFIG_DIR=str(claude), LITE2D_NATIVE_PROBE_ROOT=str(root / 'state'),
                   LITE2D_COMPANION_ROOT=str(root / 'state'), LITE2D_NODE=shutil.which('node'))
        if kind == 'old-node':
            wrapper = root / 'baseline.mjs'
            module = (ROOT / 'Companion/controller.mjs').as_uri()
            wrapper.write_text(f'''import {{Controller}} from {json.dumps(module)};
import {{createInterface}} from 'node:readline';
import {{mkdir}} from 'node:fs/promises';
await mkdir(process.env.LITE2D_COMPANION_ROOT,{{recursive:true}});
const c=new Controller({{root:process.env.LITE2D_COMPANION_ROOT,send:e=>process.stdout.write(JSON.stringify(e)+'\\n')}});
await c.start();const lines=createInterface({{input:process.stdin}});let chain=Promise.resolve();
lines.on('line',line=>{{const m=JSON.parse(line);chain=chain.then(async()=>{{if(m.type==='sdk-list'){{const t=performance.now();const r=await c.observers.list('claude');process.stdout.write(JSON.stringify({{type:'sdk.result',count:r.length,durationMs:performance.now()-t}})+'\\n');}}else await c.command(m);}});}});
lines.on('close',async()=>{{await chain;await c.close();process.exit(0);}});
''')
            command = [shutil.which('node'), '--disable-warning=ExperimentalWarning', str(wrapper)]
        else:
            command = [str(APP), '--companion-runtime-probe']
        launched = time.monotonic()
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        mailbox = queue.Queue()

        def consume():
            for line in child.stdout:
                try:
                    mailbox.put(json.loads(line))
                except ValueError:
                    pass
        threading.Thread(target=consume, daemon=True).start()

        def send(value):
            child.stdin.write(json.dumps(value) + '\n'); child.stdin.flush()

        def wait(kind):
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                event = mailbox.get(timeout=max(0.1, deadline - time.monotonic()))
                if event['type'] in ['error', 'probe.error']:
                    raise RuntimeError(event)
                if event['type'] == kind:
                    return event
            raise RuntimeError(f'No {kind}')
        samples = []
        try:
            wait('ready')
            ready_ms = (time.monotonic() - launched) * 1000
            send({'type': 'sdk-list'}); cold = wait('sdk.result')
            send({'type': 'sdk-list'}); warm = wait('sdk.result')
            send({'type': 'configure', 'config': {'enabled': True, 'intervalMinutes': 0, 'characters': [], 'hourlyRequests': 12,
                                                 'sources': {'claude': {'enabled': True}}}})
            start = time.monotonic()
            burst = 0
            while time.monotonic() - start < seconds:
                elapsed = time.monotonic() - start
                if kind == 'new-swift' and (not samples or int(elapsed) % 15 == 0):
                    send({'type': 'poll'})
                if 5 <= elapsed < 10 and burst < 5:
                    send({'type': 'sdk-list'}); wait('sdk.result'); burst += 1
                rows = tree(child.pid)
                samples.append({'elapsed': elapsed, 'processes': rows, 'rssSum': sum(r['rss'] for r in rows),
                                'footprintSum': sum(r['footprint'] for r in rows), 'cpuSum': sum(r['cpuSeconds'] for r in rows)})
                time.sleep(1)
            if kind == 'new-swift':
                send({'type': 'diagnostics'}); helper = wait('diagnostics')['data']['helper']
            else:
                helper = {'running': True, 'starts': 1}
            active = [s for s in samples if 5 <= s['elapsed'] <= 11]
            quiet = samples[-min(10, len(samples)):]
            summary = {'kind': kind, 'seconds': seconds, 'controllerReadyMs': ready_ms,
                       'coldSDKMs': cold['durationMs'], 'warmSDKMs': warm['durationMs'], 'fixtureCount': cold['count'],
                       'activeFootprintPeakMiB': max(s['footprintSum'] for s in active) / 1048576,
                       'activeRSSPeakMiB': max(s['rssSum'] for s in active) / 1048576,
                       'activeCPUSeconds': active[-1]['cpuSum'] - active[0]['cpuSum'],
                       'quietFootprintMeanMiB': sum(s['footprintSum'] for s in quiet) / len(quiet) / 1048576,
                       'quietRSSMeanMiB': sum(s['rssSum'] for s in quiet) / len(quiet) / 1048576,
                       'quietCPUSeconds': quiet[-1]['cpuSum'] - quiet[0]['cpuSum'], 'quietProcesses': quiet[-1]['processes'], 'helper': helper,
                       'cpuTimesUseMachTimebase': True}
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                child.terminate(); child.wait(timeout=5)
        (OUT / f'profile-{kind}.json').write_text(json.dumps({'summary': summary, 'samples': samples}, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
        return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=90)
    parser.add_argument('--kind', choices=['old-node', 'new-swift', 'both'], default='both')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for kind in ['old-node', 'new-swift'] if args.kind == 'both' else [args.kind]:
        measure(kind, args.seconds)
