// Disposable compatibility worker. It never schedules itself, watches files,
// runs query(), handles roles, or mutates history. Swift owns its idle lifetime.
import { createInterface } from 'node:readline';
import { listSessions, getSessionInfo, getSessionMessages } from '@anthropic-ai/claude-agent-sdk';

const lines = createInterface({ input: process.stdin });
const write = value => process.stdout.write(JSON.stringify(value) + '\n');
let chain = Promise.resolve();
const allowedOptions = input => ({
  ...(typeof input.dir === 'string' ? { dir: input.dir, includeWorktrees: false } : {}),
  ...(Number.isInteger(input.limit) ? { limit: Math.max(1, Math.min(input.limit, 200)) } : {}),
  ...(Number.isInteger(input.offset) ? { offset: Math.max(0, input.offset) } : {}),
});
function text(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.map(text).filter(Boolean).join('\n');
  if (!value || typeof value !== 'object') return '';
  if (['thinking', 'reasoning'].includes(value.type)) return '';
  if (value.type === 'tool_use') return `[tool: ${value.name ?? 'activity'}]`;
  if (value.type === 'tool_result') return value.is_error ? '[tool failed]' : '[tool completed]';
  return value.text ?? text(value.content ?? value.message);
}
async function run(request) {
  const { id, method, params = {} } = request;
  if (method === 'shutdown') { lines.close(); return; }
  if (!Number.isInteger(id)) return;
  try {
    let result;
    if (method === 'list') {
      result = (await listSessions({ ...allowedOptions(params), includeProgrammatic: true })).map(s => ({
        sessionId: s.sessionId, title: s.customTitle ?? s.summary ?? 'Claude Code', cwd: s.cwd,
        updated: s.lastModified, created: s.createdAt, fileSize: s.fileSize,
      }));
    } else if (method === 'info' || method === 'recent') {
      if (typeof params.sessionId !== 'string' || !/^[\da-f-]{36}$/i.test(params.sessionId)) throw new Error('Invalid session ID');
      const info = await getSessionInfo(params.sessionId, allowedOptions(params));
      if (method === 'info') result = info ? { sessionId: info.sessionId, cwd: info.cwd, updated: info.lastModified, created: info.createdAt } : null;
      else if (!info) result = [];
      else {
        // Keep the SDK's canonical chain/compaction semantics. Its offset API is
        // not a filesystem-tail API; only the bounded normalized result crosses IPC.
        const messages = await getSessionMessages(params.sessionId, allowedOptions(params));
        result = messages.slice(-8).map(m => ({ id: m.uuid, text: text(m.message).slice(0, 2000) })).filter(m => m.text);
      }
    } else throw new Error('Method denied');
    write({ id, result });
  } catch {
    // No paths, titles, provider/auth data or raw transcripts in error logs.
    write({ id, error: { message: 'Claude history read failed' } });
  }
}
lines.on('line', line => {
  if (line.length > 16384) return;
  try { const request = JSON.parse(line); chain = chain.then(() => run(request)); } catch { /* Ignore invalid input. */ }
});
lines.on('close', () => { chain.finally(() => process.exit(0)); });
write({ type: 'ready', protocolVersion: 1 });
