#!/usr/bin/env python3
"""Native Controller/MCP integration using a deterministic local model fixture.

No computer use, external-app automation, real project edits or paid inference.
The installed OpenCode engine still creates and executes independent Sessions.
"""
import http.server
import json
import os
from pathlib import Path
import queue
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.local/verification/swift-migration'
APP = ROOT / 'dist/Lite2D.app/Contents/MacOS/Lite2D'
A = '11111111-1111-4111-8111-111111111111'
B = '22222222-2222-4222-8222-222222222222'
OUT.mkdir(parents=True, exist_ok=True)


def main():
    sources = ['NativePersonaMemory.swift', 'NativeCompanionStore.swift', 'NativeCompanionTransport.swift', 'NativeClaudeHelper.swift',
               'NativeCompanionObservers.swift', 'NativeCompanionRoles.swift', 'NativeOpenCodeServiceMonitor.swift', 'NativeCompanionRuntime.swift']
    unit = OUT / 'native-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', *[str(ROOT / 'App' / name) for name in sources],
                    str(ROOT / 'Tests/NativeCompanionTests.swift'), '-lsqlite3', '-framework', 'Network', '-framework', 'CoreServices', '-o', str(unit)], check=True)
    resources = APP.parent.parent / 'Resources/Companion'
    subprocess.run([str(unit), str(resources / 'claude-helper.mjs'), str(resources / 'prompt.json'), shutil.which('node') or '/missing/node', str(APP)], check=True)
    state = {'calls': 0, 'sent': False, 'read': False, 'saved': False, 'tools': set(), 'prompts': [], 'trySearch': False, 'searchDenied': False}

    class Model(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers['content-length'])))
            state['calls'] += 1
            system = '\n'.join(m.get('content', '') for m in request.get('messages', []) if m.get('role') == 'system')
            names = [t.get('function', {}).get('name', t.get('name', '')) for t in request.get('tools', [])]
            state['tools'].update(names)
            state['prompts'].append(system)
            for message in request.get('messages', []):
                if message.get('role') == 'tool' and 'Web search is disabled by the user' in str(message.get('content', '')):
                    state['searchDenied'] = True
            call = None
            send_name = next((n for n in names if n.endswith('companion_send_message')), None)
            read_name = next((n for n in names if n.endswith('private_memory_read')), None)
            save_name = next((n for n in names if n.endswith('public_record_update')), None)
            search_name = next((n for n in names if n.endswith('_web_search')), None)
            if state['trySearch'] and search_name:
                state['trySearch'] = False
                call = {'name': search_name, 'arguments': json.dumps({'query': 'public fun trivia', 'objective': 'Find a public fact'})}
            elif 'TEST_CHARACTER_A' in system and not state['sent'] and send_name:
                state['sent'] = True
                call = {'name': send_name, 'arguments': json.dumps({'to': B, 'text': 'Hello from native A'})}
            elif 'TEST_CHARACTER_B' in system and not state['saved'] and save_name:
                state['saved'] = True
                call = {'name': save_name, 'arguments': json.dumps({'path': 'shared-topic.md', 'content': 'A greeted B; B replied.'})}
            elif 'TEST_CHARACTER_B' in system and not state['read'] and read_name:
                state['read'] = True
                call = {'name': read_name, 'arguments': '{}'}
            content = '{"skip":true}' if 'TEST_CHARACTER_A' in system else '{"text":"Independent native reply from B","emotion":"neutral"}'
            delta = {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': f'call_{state["calls"]}', 'type': 'function', 'function': call}]} if call else {'role': 'assistant', 'content': content}
            self.send_response(200)
            self.send_header('content-type', 'text/event-stream')
            self.end_headers()
            for value, finish in [(delta, None), ({}, 'tool_calls' if call else 'stop')]:
                chunk = {'id': f'fixture_{state["calls"]}', 'object': 'chat.completion.chunk', 'created': int(time.time()), 'model': 'companion',
                         'choices': [{'index': 0, 'delta': value, 'finish_reason': finish}]}
                self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
            self.wfile.write(b'data: [DONE]\n\n')

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='lite2d-native-protocol-') as directory:
        root = Path(directory)
        providers = {'fixture': {'name': 'Native protocol fixture', 'package': '@opencode/ai/providers/openai-compatible',
                                'settings': {'baseURL': f'http://127.0.0.1:{server.server_port}/v1', 'apiKey': 'local-fixture'},
                                'models': {'companion': {'name': 'Companion fixture', 'limit': {'context': 16000, 'output': 1000}, 'capabilities': {'tools': True, 'input': ['text'], 'output': ['text']}}}}}
        (root / 'providers.json').write_text(json.dumps(providers))
        for role, text in [(A, 'TEST_CHARACTER_A. Warm Persona.'), (B, 'TEST_CHARACTER_B. Calm Persona.')]:
            path = root / 'characters' / role
            path.mkdir(parents=True)
            (path / 'persona.md').write_text(text)
        env = dict(os.environ, LITE2D_NATIVE_PROBE_ROOT=str(root), LITE2D_PROBE_PROVIDERS=str(root / 'providers.json'),
                   LITE2D_NODE=shutil.which('node') or '/missing/node')
        config = {'enabled': True, 'intervalMinutes': 0, 'hourlyRequests': 12, 'model': 'fixture/companion',
                  'characters': [{'id': role, 'name': role, 'enabled': True, 'visible': True} for role in [A, B]]}
        all_events = []

        def launch():
            child = subprocess.Popen([str(APP), '--companion-runtime-probe'], cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            mailbox = queue.Queue()

            def read():
                for line in child.stdout:
                    try:
                        event = json.loads(line)
                        all_events.append(event)
                        mailbox.put(event)
                    except ValueError:
                        pass
            threading.Thread(target=read, daemon=True).start()

            def send(value):
                child.stdin.write(json.dumps(value) + '\n')
                child.stdin.flush()

            def until(kind, timeout=45):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    try:
                        event = mailbox.get(timeout=min(1, max(0.01, deadline - time.monotonic())))
                    except queue.Empty:
                        if child.poll() is not None:
                            raise AssertionError(f'Native probe exited {child.returncode}: {child.stderr.read()[-2500:]}')
                        continue
                    if event['type'] in ['error', 'probe.error']:
                        raise AssertionError(event)
                    if event['type'] == kind:
                        return event
                raise AssertionError(f'Timeout waiting for {kind}; latest events: {all_events[-4:]}')
            until('ready')
            send({'type': 'configure', 'config': config})
            until('status')
            return child, send, until

        child, send, until = launch()
        try:
            send({'type': 'trigger', 'characterId': A})
            until('topic.end', timeout=75)
            utterances = [e for e in all_events if e['type'] == 'utterance']
            assert [e['text'] for e in utterances] == ['Hello from native A', 'Independent native reply from B'], utterances
            assert state['read'] and state['sent']
            assert state['tools'] and all(t.startswith('companion_') for t in state['tools']), state['tools']
            assert state['calls'] == 5, state['calls']
            assert 'companion_web_search' in state['tools'], state['tools']
            send({'type': 'diagnostics'})
            diagnostics = until('diagnostics')['data']
            assert diagnostics['helper']['starts'] == 0, diagnostics
            send({'type': 'saveMemory', 'characterId': A, 'content': 'Only A remembers this.'})
            until('memory')
        finally:
            child.stdin.close()
            child.wait(timeout=15)
        assert child.returncode == 0, child.returncode
        db = sqlite3.connect(root / 'state.sqlite')
        session_a = json.loads(db.execute('SELECT value FROM state WHERE key=?', (f'session:{A}',)).fetchone()[0])
        session_b = json.loads(db.execute('SELECT value FROM state WHERE key=?', (f'session:{B}',)).fetchone()[0])
        assert session_a != session_b
        assert db.execute('SELECT COUNT(*) FROM requests').fetchone()[0] == 5
        assert db.execute('SELECT content FROM records WHERE path=?', ('shared-topic.md',)).fetchone()[0] == 'A greeted B; B replied.'
        assert db.execute("SELECT COUNT(*) FROM deliveries WHERE status='accepted_pending_context'").fetchone()[0] == 1
        db.close()
        child, send, until = launch()
        try:
            send({'type': 'trigger', 'characterId': A})
            until('topic.end', timeout=75)
            assert state['calls'] == 6, state['calls']
            # Revoke search on existing role sessions; the broker must enforce
            # the setting even when the model still has the tool schema.
            config['webSearchEnabled'] = False
            send({'type': 'configure', 'config': config})
            until('status')
            state['trySearch'] = True
            send({'type': 'trigger', 'characterId': A})
            until('topic.end', timeout=75)
            assert state['searchDenied'], 'Search revocation did not reach the tool result'
        finally:
            child.stdin.close()
            child.wait(timeout=15)
        assert child.returncode == 0
        db = sqlite3.connect(root / 'state.sqlite')
        assert json.loads(db.execute('SELECT value FROM state WHERE key=?', (f'session:{A}',)).fetchone()[0]) == session_a
        assert json.loads(db.execute('SELECT value FROM state WHERE key=?', (f'memory:{A}',)).fetchone()[0]) == 'Only A remembers this.'
        assert db.execute("SELECT COUNT(*) FROM deliveries WHERE status='context_consumed'").fetchone()[0] == 1
        assert state['calls'] == 8, state['calls']
        db.close()
        report = {'passed': True, 'upstreamCalls': state['calls'], 'toolCount': len(state['tools']), 'utterances': [e['text'] for e in all_events if e['type'] == 'utterance'],
                  'helperStartsDuringRoleExchange': diagnostics['helper']['starts'], 'independentSessions': True, 'restartAndContextConsumption': True,
                  'searchRevocationEnforced': state['searchDenied'], 'sharedNoteCreatedViaMCP': state['saved']}
        (OUT / 'native-protocol.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    server.shutdown()


if __name__ == '__main__':
    main()
