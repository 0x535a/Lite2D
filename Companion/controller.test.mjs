import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Store, persona } from './store.mjs';
import { clean, textOf, parseUtterance } from './policy.mjs';
import { Controller } from './controller.mjs';
import { Observers, CodexRPC } from './adapters.mjs';

const A = '11111111-1111-4111-8111-111111111111', B = '22222222-2222-4222-8222-222222222222';
const chars = [{ id: A, name: 'A', enabled: true, visible: true }, { id: B, name: 'B', enabled: true, visible: true }];
async function fixture(roles) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lite2d-companion-test-'));
  const events = []; let now = 1800000000000;
  const observers = { activity: new Map(), reset() {}, close() {}, async poll() { return { sessions: [], changes: [] }; } };
  const c = new Controller({ root, send: e => events.push(e), roles, observers, now: () => now });
  await c.start(); clearInterval(c.timer);
  c.configure({ enabled: true, characters: chars, intervalMinutes: 30, hourlyRequests: 12, cooldownSeconds: 0 });
  return { c, events, advance: ms => now += ms, close: async () => { await c.close(); await rm(root, { recursive: true, force: true }); } };
}
test('records compare revisions atomically and preserve author; reject traversal', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lite2d-store-')); const s = new Store(root);
  try {
    const first = s.readRecord('shared.md'); const result = s.updateRecord(A, 'shared.md', 'A wrote this', first.revision);
    assert.ok(result.revision); assert.equal(s.updateRecord(B, 'shared.md', 'overwrite', first.revision).conflict, true);
    assert.equal(s.readRecord('shared.md').content, 'A wrote this');
    assert.equal(s.db.prepare('SELECT actor FROM changes').get().actor, A);
    for (const bad of ['../other.md', '/tmp/x.md', 'a/b.md', 'x..md']) assert.throws(() => s.readRecord(bad));
  } finally { s.close(); await rm(root, { recursive: true, force: true }); }
});
test('Persona accepts plain Markdown, rejects symlinks and empty files', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lite2d-persona-')); const dir = path.join(root, 'characters', A);
  await mkdir(dir, { recursive: true });
  try {
    await writeFile(path.join(dir, 'persona.md'), 'An ordinary Markdown Persona.'); assert.equal((await persona(root, A)).text, 'An ordinary Markdown Persona.');
    await writeFile(path.join(dir, 'persona.md'), ''); await assert.rejects(persona(root, A));
    await rm(path.join(dir, 'persona.md')); await symlink('/etc/hosts', path.join(dir, 'persona.md')); await assert.rejects(persona(root, A));
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('output does not execute arbitrary JSON or expose thinking/tool results', () => {
  assert.deepEqual(parseUtterance('{"skip":true}'), { skip: true });
  assert.equal(parseUtterance('{"command":"rm -rf"}').skip, true);
  assert.equal(textOf([{ type: 'thinking', text: 'private' }, { type: 'text', text: 'visible' }]), 'visible');
  assert.equal(textOf({ type: 'tool_result', content: 'secret raw tool output' }), '[tool completed]');
  assert.equal(clean('api_key=abcdef password=qwerty'), 'api_key=[redacted] password=[redacted]');
});
test('real bridge semantics: sender tool returns before recipient runs, context synchronized, no duplicate', async () => {
  let c, recipientStarted = false; const received = [];
  const roles = { async generate(character) {
    if (character.id === A) {
      const queued = await c.tool(A, 'companion_send_message', { to: B, text: 'Hello B' });
      assert.equal(queued.status, 'queued'); assert.equal(recipientStarted, false); return '{"text":"Hello B"}';
    }
    recipientStarted = true; return '{"text":"Hello A","emotion":"happy"}';
  }, async receive(character, envelope) { received.push({ character: character.id, envelope }); return 'msg_test'; }, async interrupt() {}, close() {} };
  const f = await fixture(roles); c = f.c;
  try {
    await c.begin({ reason: 'idle_opportunity' });
    assert.deepEqual(f.events.filter(e => e.type === 'utterance').map(e => e.text), ['Hello B', 'Hello A']);
    assert.ok(f.events.find(e => e.type === 'conversation.focus'));
    assert.ok(f.events.findIndex(e => e.type === 'conversation.focus') < f.events.findIndex(e => e.type === 'utterance'), 'Gaze begins with the first spoken message, not only at reply generation');
    assert.equal(received[0].character, A);
    assert.equal(c.store.db.prepare("SELECT COUNT(*) AS n FROM deliveries WHERE status='accepted_pending_context'").get().n, 1);
  } finally { await f.close(); }
});
test('hourly budget prevents extra generation and does not multiply with character count', async () => {
  let calls = 0; const f = await fixture({ async generate() { calls++; return 'skip'; }, async interrupt() {}, close() {} });
  try {
    f.c.configure({ enabled: true, characters: chars, intervalMinutes: 5, hourlyRequests: 1, cooldownSeconds: 0 });
    await f.c.begin({ reason: 'idle_opportunity' }); await f.c.begin({ reason: 'idle_opportunity' }); assert.equal(calls, 1);
    f.advance(3600001); await f.c.begin({ reason: 'idle_opportunity' }); assert.equal(calls, 2);
  } finally { await f.close(); }
});
test('stop cancels in-flight output; no late speech; private notes cannot cross identities', async () => {
  let entered; const started = new Promise(r => entered = r);
  const f = await fixture({ async generate(_, __, { signal }) { entered(); await new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(signal.reason))); return 'late speech'; }, async interrupt() {}, close() {} });
  try {
    const turn = f.c.begin({ reason: 'idle_opportunity' }); await started; f.c.stop(); await turn;
    assert.equal(f.events.filter(e => e.type === 'utterance').length, 0);
    await f.c.tool(A, 'private_memory_update', { content: 'A private' }); assert.equal((await f.c.tool(B, 'private_memory_read', {})).content, '');
    await assert.rejects(f.c.tool(A, 'shell', { command: 'echo x' }));
    await assert.rejects(f.c.tool(A, 'companion_send_message', { to: B, text: 'outside topic' }));
  } finally { await f.close(); }
});
test('idle interval changes, disables, persists no missed opportunities on pause', async () => {
  let calls = 0; const f = await fixture({ async generate() { calls++; return 'skip'; }, async interrupt() {}, close() {} });
  try {
    f.c.pollAt = Infinity; f.advance(29 * 60000); await f.c.tick(); assert.equal(calls, 0);
    f.advance(60001); await f.c.tick(); await new Promise(r => setTimeout(r, 10)); assert.equal(calls, 1);
    f.c.configure({ enabled: true, characters: chars, intervalMinutes: 0 }); f.advance(100 * 60000); await f.c.tick(); assert.equal(calls, 1);
    f.c.configure({ enabled: true, paused: true, characters: chars, intervalMinutes: 5 }); f.advance(60 * 60000); await f.c.tick(); assert.equal(calls, 1);
    f.c.configure({ enabled: true, paused: false, characters: chars, intervalMinutes: 5 }); await f.c.tick(); assert.equal(calls, 1);
  } finally { await f.close(); }
});
test('Observer baselines do not replay old messages; failed read can retry; resetting removes cached data', async () => {
  const observer = new Observers(); let updated = 1, failure = false;
  observer.list = async () => [{ backend: 'codex', id: 'test', project: '/allowed', updated }];
  observer.recent = async () => { if (failure) throw new Error('transient'); return [{ id: 'm1', text: String(updated) }]; };
  try {
    assert.equal((await observer.poll('codex', ['/allowed'])).changes.length, 0);
    updated = 2; failure = true; await assert.rejects(observer.poll('codex', ['/allowed']));
    failure = false; assert.equal((await observer.poll('codex', ['/allowed'])).changes.length, 1);
    assert.equal((await observer.poll('codex', ['/allowed'])).changes.length, 0);
    observer.reset('codex'); assert.equal(observer.activity.size, 0);
    assert.equal((await observer.poll('codex', ['/allowed'])).changes.length, 0);
  } finally { observer.close(); }
});
test('Codex protocol has no generic write proxy', async () => {
  const rpc = new CodexRPC('codex'); await assert.rejects(rpc.call('thread/resume', { threadId: 'x' }), /denied/); rpc.close();
});
test('active turn text updates are detected even when the list timestamp does not change', async () => {
  const observer = new Observers(); let text = 'first';
  observer.list = async () => [{ backend: 'codex', id: 'live', project: '/allowed', updated: 1 }];
  observer.recent = async () => [{ id: 'same-message', text }];
  try {
    assert.equal((await observer.poll('codex', ['/allowed'])).changes.length, 0);
    text = 'first plus new progress';
    assert.equal((await observer.poll('codex', ['/allowed'])).changes.length, 1);
    assert.equal((await observer.poll('codex', ['/allowed'])).changes.length, 0);
  } finally { observer.close(); }
});
