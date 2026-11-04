import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { Roles } from './roles.mjs';
import { Controller } from './controller.mjs';

// A deterministic OpenAI-compatible upstream fixture. This verifies the real
// OpenCode session/MCP engine and our routing, not external model availability.
test('native OpenCode sessions execute real scoped MCP messages and retain independent contexts', { timeout: 90000 }, async () => {
  const A = '11111111-1111-4111-8111-111111111111', B = '22222222-2222-4222-8222-222222222222';
  const root = await mkdtemp(path.join(os.tmpdir(), 'lite2d-native-'));
  let calls = 0, sent = false, read = false; const toolsSeen = new Set();
  const upstream = createServer(async (req, res) => {
    let body = ''; for await (const chunk of req) body += chunk;
    const request = JSON.parse(body); calls++;
    const system = JSON.stringify(request.messages?.filter(m => m.role === 'system') ?? request.instructions ?? request.system ?? []);
    const names = (request.tools ?? []).map(t => t.function?.name ?? t.name); names.forEach(t => toolsSeen.add(t));
    let call;
    const sendName = names.find(n => /companion_send_message$/.test(n));
    const readName = names.find(n => /private_memory_read$/.test(n));
    if (system.includes('TEST_CHARACTER_A') && !sent && sendName) { sent = true; call = { name: sendName, arguments: JSON.stringify({ to: B, text: 'Hello from A' }) }; }
    else if (system.includes('TEST_CHARACTER_B') && !read && readName) { read = true; call = { name: readName, arguments: '{}' }; }
    const content = system.includes('TEST_CHARACTER_A') ? '{"skip":true}' : '{"text":"Independent reply from B","emotion":"neutral"}';
    const delta = call ? { role: 'assistant', tool_calls: [{ index: 0, id: `call_${calls}`, type: 'function', function: call }] } : { role: 'assistant', content };
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    const chunk = (d, finish) => ({ id: `chatcmpl_${calls}`, object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000), model: 'companion', choices: [{ index: 0, delta: d, finish_reason: finish }] });
    res.write(`data: ${JSON.stringify(chunk(delta, null))}\n\n`);
    res.write(`data: ${JSON.stringify(chunk({}, call ? 'tool_calls' : 'stop'))}\n\n`);
    res.end('data: [DONE]\n\n');
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const events = [];
  const observers = { activity: new Map(), close() {}, reset() {}, async poll() { return { sessions: [], changes: [] }; } };
  const c = new Controller({ root, send: e => events.push(e), observers });
  let restarted;
  try {
    for (const [id, text] of [[A, 'TEST_CHARACTER_A. Warm character.'], [B, 'TEST_CHARACTER_B. Calm character.']]) {
      const dir = path.join(root, 'characters', id); await mkdir(dir, { recursive: true }); await writeFile(path.join(dir, 'persona.md'), text);
    }
    await c.start(); clearInterval(c.timer); c.roles.close();
    c.roles = new Roles({ root, store: c.store, endpoint: `http://127.0.0.1:${c.broker.address().port}/tools`,
      register: id => { const token = `test-token-${id}`; c.tokens.set(token, id); return token; },
      providerConfig: { fixture: { name: 'Local protocol fixture', package: '@opencode/ai/providers/openai-compatible',
        settings: { baseURL: `http://127.0.0.1:${upstream.address().port}/v1`, apiKey: 'local-fixture' },
        models: { companion: { name: 'Companion protocol fixture', limit: { context: 16000, output: 1000 }, capabilities: { tools: true, input: ['text'], output: ['text'] } } } } } });
    c.configure({ enabled: true, characters: [A, B].map(id => ({ id, name: id, enabled: true, visible: true })), intervalMinutes: 30, model: 'fixture/companion', hourlyRequests: 12 });
    await c.begin({ reason: 'idle_opportunity' });
    const errors = events.filter(e => e.type === 'error');
    assert.equal(errors.length, 0, JSON.stringify(errors));
    assert.ok(sent, `No message tool was offered. Tools: ${[...toolsSeen].join(',')}`);
    assert.ok(read, 'Recipient must execute its own memory tool');
    assert.ok([...toolsSeen].every(name => name.startsWith('companion_')), 'Only Companion tools are exposed to the model, never shell/execute/file tools');
    assert.deepEqual(events.filter(e => e.type === 'utterance').map(e => e.text), ['Hello from A', 'Independent reply from B']);
    const sessionA = c.store.get(`session:${A}`), sessionB = c.store.get(`session:${B}`);
    assert.notEqual(sessionA, sessionB);
    const messagesB = await c.roles.client.message.list({ sessionID: sessionB, limit: 12 });
    assert.ok(messagesB.data.some(m => m.type === 'synthetic' && JSON.stringify(m).includes('Hello from A')));
    const inbox = await c.roles.client.session.inbox.list({ sessionID: sessionA });
    assert.ok(inbox.some(m => JSON.stringify(m).includes('Independent reply from B')), 'Reply is durably queued without waking A again');
    for (const action of ['shell', 'execute', 'edit', 'write', 'external_directory']) {
      const result = await c.roles.client.permission.create({ sessionID: sessionA, action, resources: ['*'], agent: 'companion' });
      assert.equal(result.effect, 'deny', action);
    }
    assert.ok(calls >= 4, 'Both sessions and their independent tool turns reached the upstream');
    assert.equal(c.store.db.prepare('SELECT COUNT(*) AS n FROM requests').get().n, calls, 'Tool continuations are charged as model requests');
    await c.tool(A, 'private_memory_update', { content: 'Only A remembers this.' });
    const providers = c.roles.providerConfig;
    await c.close();
    restarted = new Controller({ root, send() {}, observers }); await restarted.start(); clearInterval(restarted.timer); restarted.roles.close();
    restarted.roles = new Roles({ root, store: restarted.store, endpoint: `http://127.0.0.1:${restarted.broker.address().port}/tools`,
      register: id => { const token = `restart-${id}`; restarted.tokens.set(token, id); return token; }, providerConfig: providers });
    const resumed = await restarted.roles.prepare({ id: A }, 'fixture/companion');
    assert.equal(resumed.sessionID, sessionA, 'Restart restores the same role session');
    assert.equal(restarted.store.get(`memory:${A}`), 'Only A remembers this.');
    assert.equal(restarted.store.get(`memory:${B}`, ''), '');
    assert.equal(restarted.store.db.prepare("SELECT COUNT(*) AS n FROM deliveries WHERE status='accepted_pending_context'").get().n, 1);
    assert.equal(calls, 4, 'Restart and non-generating inbox acceptance do not call the model');
    restarted.configure({ enabled: true, characters: [A, B].map(id => ({ id, name: id, enabled: true, visible: true })), intervalMinutes: 30, model: 'fixture/companion', hourlyRequests: 12 });
    // Speaker index was persisted as 1 after the first topic: make the source A
    // the next speaker for this explicit context-consumption acceptance check.
    restarted.store.set('speakerIndex', 0);
    await restarted.begin({ reason: 'idle_opportunity' });
    assert.equal(restarted.store.db.prepare("SELECT COUNT(*) AS n FROM deliveries WHERE status='context_consumed'").get().n, 1);
    assert.equal(calls, 5, 'Source consumes the reply only on its next allowed generation');
  } finally { await c.close(); await restarted?.close(); upstream.close(); await rm(root, { recursive: true, force: true }); }
});
