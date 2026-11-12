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
    sources = ['CompanionMonitorModels.swift', 'NativeCompanionMonitor.swift', 'NativePersonaMemory.swift', 'NativeCompanionStore.swift', 'NativeCompanionTransport.swift', 'NativeClaudeHelper.swift',
               'NativeCompanionObservers.swift', 'NativeCompanionRoles.swift', 'NativeOpenCodeServiceMonitor.swift', 'NativeCompanionRuntime.swift', 'NativeCompanionDaily.swift', 'NativeCompanionProactive.swift', 'NativeCompanionProactiveStore.swift', 'NativeMacPerception.swift', 'NativeCalendarPerception.swift', 'NativeCompanionContext.swift', 'NativeCompanionInitiative.swift', 'NativeNotificationDatabase.swift', 'NativeNotificationPerception.swift', 'CompanionPathWatch.swift', 'CompanionFocusIntents.swift', 'NativeFocusPerception.swift', 'NativeDirectoryPerception.swift', 'NativeEnvironmentPerception.swift', 'NativeWindowPerception.swift']
    unit = OUT / 'native-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', *[str(ROOT / 'App' / name) for name in sources],
                    str(ROOT / 'Tests/CompanionWindowTests.swift'), str(ROOT / 'Tests/CompanionEnvironmentTests.swift'), str(ROOT / 'Tests/CompanionFocusTests.swift'), str(ROOT / 'Tests/CompanionNotificationTests.swift'), str(ROOT / 'Tests/CompanionInitiativeTests.swift'), str(ROOT / 'Tests/CompanionContextTests.swift'), str(ROOT / 'Tests/CompanionCalendarTests.swift'), str(ROOT / 'Tests/CompanionMacPerceptionTests.swift'), str(ROOT / 'Tests/CompanionProactiveTests.swift'), str(ROOT / 'Tests/CompanionMonitorTests.swift'), str(ROOT / 'Tests/CompanionDailyTests.swift'), str(ROOT / 'Tests/NativeCompanionTests.swift'), '-lsqlite3', '-framework', 'Network', '-framework', 'CoreServices', '-o', str(unit)], check=True)
    resources = APP.parent.parent / 'Resources/Companion'
    subprocess.run([str(unit), str(resources / 'claude-helper.mjs'), str(resources / 'prompt.json'), shutil.which('node') or '/missing/node', str(APP)], check=True)
    state = {'calls': 0, 'sent': False, 'read': False, 'saved': False, 'tools': set(), 'prompts': [], 'messages': [], 'trySearch': False, 'searchDenied': False, 'dailyCalls': 0, 'tryIntention': False, 'intentionProposed': False}

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
            state['messages'].append(request.get('messages', []))
            for message in request.get('messages', []):
                if message.get('role') == 'tool' and 'Web search is disabled by the user' in str(message.get('content', '')):
                    state['searchDenied'] = True
            call = None
            send_name = next((n for n in names if n.endswith('companion_send_message')), None)
            read_name = next((n for n in names if n.endswith('private_memory_read')), None)
            save_name = next((n for n in names if n.endswith('public_record_update')), None)
            search_name = next((n for n in names if n.endswith('_web_search')), None)
            intention_name = next((n for n in names if n.endswith('intention_propose')), None)
            if state['tryIntention'] and intention_name and 'TEST_CHARACTER_A' in system:
                state['tryIntention'] = False
                contexts = []
                for message in request.get('messages', []):
                    content = message.get('content', '')
                    if isinstance(content, list):
                        content = '\n'.join(part.get('text', '') for part in content)
                    try:
                        parsed = json.loads(content)
                        if isinstance(parsed, dict) and parsed.get('characterId') == A:
                            contexts.append(parsed)
                    except (TypeError, ValueError):
                        pass
                assert contexts, 'Missing compiled role context'
                evidence = [row['id'] for row in contexts[-1]['socialContext'] if row.get('from') == A]
                assert evidence, 'Own dialogue evidence was not supplied'
                call = {'name': intention_name, 'arguments': json.dumps({'goal': 'Share a movie thought later.', 'topicKey': 'movie-follow-up', 'evidenceIds': evidence[0]})}
                state['intentionProposed'] = True
            elif state['trySearch'] and search_name:
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
            if 'You consolidate one character' in system:
                assert not names, 'Archive tasks must not expose tools'
                snapshots = []
                for message in request.get('messages', []):
                    value = message.get('content', '')
                    if isinstance(value, list):
                        value = '\n'.join(part.get('text', '') for part in value)
                    try:
                        parsed = json.loads(value)
                        if isinstance(parsed, dict) and 'dialogue' in parsed:
                            snapshots.append(parsed)
                    except (ValueError, TypeError):
                        pass
                assert snapshots, request
                ids = [row['id'] for row in snapshots[-1]['dialogue']]
                state['dailyCalls'] += 1
                call = None
                content = json.dumps({'summary': 'We exchanged greetings and agreed to watch a movie.', 'summaryEvidenceIds': ids,
                                      'items': [{'kind': 'open_loop', 'content': 'Watch a movie tomorrow.', 'evidenceIds': ids}], 'resolved': []})
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
            input_lock = threading.Lock()

            def read():
                for line in child.stdout:
                    try:
                        event = json.loads(line)
                        all_events.append(event)
                        if event.get('type') == 'utterance' and event.get('outputId'):
                            # Simulated host receipt for the headless protocol fixture, not a screen claim.
                            with input_lock:
                                for status in ['presented', 'completed']:
                                    child.stdin.write(json.dumps({'type': 'output_receipt', 'outputId': event['outputId'], 'characterId': event['characterId'], 'status': status}) + '\n')
                                child.stdin.flush()
                        mailbox.put(event)
                    except (ValueError, BrokenPipeError):
                        pass
            threading.Thread(target=read, daemon=True).start()

            def send(value):
                with input_lock:
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
            state['tryIntention'] = True
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
        assert state['calls'] == 9, state['calls']
        assert state['intentionProposed']
        assert db.execute("SELECT COUNT(*) FROM proactive_intentions WHERE owner=? AND topic_key='movie-follow-up' AND state='pending'", (A,)).fetchone()[0] == 1
        db.close()
        # The actual private pack is a release gate locally; no redistribution is required.
        pack = ROOT / 'doc/companion/persona_pack'
        identity_rotation = False
        if pack.exists():
            for role, speaker, marker in [(A, '22', 'TEST_CHARACTER_A'), (B, '33', 'TEST_CHARACTER_B')]:
                text = (pack / f'persona_{speaker}.md').read_text()
                (root / 'characters' / role / 'persona.md').write_text(text + '\n' + marker)
            child, send, until = launch()
            try:
                # A second Controller must fail before opening the existing database.
                duplicate = subprocess.run([str(APP), '--companion-runtime-probe'], env=env, input='', capture_output=True, text=True, timeout=10)
                assert duplicate.returncode != 0 and 'already owns' in duplicate.stdout, duplicate.stdout
                send({'type': 'trigger', 'characterId': A})
                until('topic.end', timeout=75)
                prompt22 = state['prompts'][-1]
                assert '身高160cm' in prompt22 and '你是机娘' not in prompt22
                contexts = []
                for message in state['messages'][-1]:
                    if message.get('role') == 'system':
                        continue
                    content = message.get('content', '')
                    if isinstance(content, str):
                        try:
                            value = json.loads(content)
                            if isinstance(value, dict) and 'identityRevision' in value:
                                contexts.append(value)
                        except ValueError:
                            pass
                assert contexts and contexts[-1]['identityRevision'] >= 2, contexts
                cards = {c['id']: c for c in contexts[-1]['characters']}
                assert '机娘' not in cards[A]['confirmed'] and '机娘' in cards[B]['confirmed'], cards
                assert contexts[-1]['identityCorrection']
                send({'type': 'trigger', 'characterId': B})
                until('topic.end', timeout=75)
                assert '你是机娘' in state['prompts'][-1] and 'TEST_CHARACTER_A' not in state['prompts'][-1]
            finally:
                child.stdin.close()
                child.wait(timeout=15)
            assert child.returncode == 0
            with sqlite3.connect(root / 'state.sqlite') as db:
                current_a = json.loads(db.execute('SELECT value FROM state WHERE key=?', (f'session:{A}',)).fetchone()[0])
                current_b = json.loads(db.execute('SELECT value FROM state WHERE key=?', (f'session:{B}',)).fetchone()[0])
                assert current_a != session_a and current_b != session_b and current_a != current_b
                assert db.execute('SELECT COUNT(*) FROM persona_revisions').fetchone()[0] >= 4
            identity_rotation = True
        # Exercise the real OpenCode archivist, session rotation and one-time wake memory.
        config["hourlyRequests"] = 120
        child, send, until = launch()
        try:
            now = time.time()
            send({'type': 'daily-run', 'now': now})
            until('daily.done')  # initialize the calendar schedule without a model call
            with sqlite3.connect(root / 'state.sqlite') as db:
                due = max(json.loads(row[0])['due'] for row in db.execute("SELECT value FROM state WHERE key LIKE 'dailySchedule:%'"))
            send({'type': 'daily-run', 'now': due + 1})
            done = until('daily.done', timeout=120)
            assert state['dailyCalls'] == 2, done
            assert all(job['status'] == 'completed' for job in done['data']['dailyArchives']), done
            send({'type': 'trigger', 'characterId': A})
            until('topic.end', timeout=75)
            first_messages = state['messages'][-1]
            assert 'Watch a movie tomorrow.' in json.dumps(first_messages), first_messages
            send({'type': 'trigger', 'characterId': A})
            until('topic.end', timeout=75)
            send({'type': 'daily-run', 'now': due + 1})
            until('daily.done')
            assert state['dailyCalls'] == 2, 'A completed daily batch was generated twice'
        finally:
            child.stdin.close()
            child.wait(timeout=15)
        assert child.returncode == 0
        with sqlite3.connect(root / 'state.sqlite') as db:
            rotated_a = json.loads(db.execute('SELECT value FROM state WHERE key=?', (f'session:{A}',)).fetchone()[0])
            assert rotated_a != session_a
            assert db.execute("SELECT COUNT(*) FROM daily_archives WHERE status='completed' AND new_session IS NOT NULL").fetchone()[0] == 2
            assert db.execute("SELECT COUNT(*) FROM daily_open_loops WHERE status='open'").fetchone()[0] == 2
            assert all(json.loads(row[0]) for row in db.execute('SELECT usage FROM daily_archives'))
        report = {'passed': True, 'upstreamCalls': state['calls'], 'toolCount': len(state['tools']), 'utterances': [e['text'] for e in all_events if e['type'] == 'utterance'],
                  'helperStartsDuringRoleExchange': diagnostics['helper']['starts'], 'independentSessions': True, 'restartAndContextConsumption': True,
                  'searchRevocationEnforced': state['searchDenied'], 'sharedNoteCreatedViaMCP': state['saved'], 'actual2233IdentityRotation': identity_rotation,
                  'dailyArchiveCalls': state['dailyCalls'], 'dailyRotationAndRecall': True}
        (OUT / 'native-protocol.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    server.shutdown()


if __name__ == '__main__':
    main()
