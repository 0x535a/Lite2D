import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { OpenCode } from '@opencode/client';
import { Service } from '@opencode/client/service';
import { listSessions, getSessionInfo, getSessionMessages } from '@anthropic-ai/claude-agent-sdk';
import { authorized, clean, hash, textOf } from './policy.mjs';

export class CodexRPC {
  constructor(executable) { this.executable = executable; this.next = 1; this.pending = new Map(); }
  async start() {
    if (this.child) return;
    this.child = spawn(this.executable, ['app-server', '--listen', 'stdio://'], { stdio: ['pipe', 'pipe', 'ignore'] });
    this.child.on('error', e => { this.child = undefined; this.fail(e); }); this.child.on('exit', () => { this.child = undefined; this.fail(new Error('Codex disconnected')); });
    createInterface({ input: this.child.stdout }).on('line', line => {
      try { const m = JSON.parse(line); const p = this.pending.get(m.id); if (p) { clearTimeout(p.timer); this.pending.delete(m.id); m.error ? p.reject(new Error(clean(m.error.message, 200))) : p.resolve(m.result); } } catch { /* nonprotocol lines */ }
    });
    await this.call('initialize', { clientInfo: { name: 'lite2d_companion_observer', version: '1.1.0' }, capabilities: { experimentalApi: false } });
    this.child.stdin.write('{"method":"initialized"}\n');
  }
  fail(error) { for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); } this.pending.clear(); }
  call(method, params) {
    if (!['initialize', 'thread/list', 'thread/read', 'thread/turns/list', 'thread/loaded/list'].includes(method)) return Promise.reject(new Error('Observer method denied'));
    return new Promise((resolve, reject) => {
      if (!this.child?.stdin.writable) { reject(new Error('Codex unavailable')); return; }
      const id = this.next++;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('Codex timeout')); }, 20000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
    });
  }
  close() { this.child?.kill(); this.fail(new Error('Observer stopped')); }
}

export class Observers {
  constructor({ codex = 'codex' } = {}) { this.codex = new CodexRPC(codex); this.baselines = new Map(); this.activity = new Map(); this.initialized = new Set(); }
  async openCode() {
    const endpoint = await Service.discover();
    if (!endpoint) throw new Error('OpenCode service unavailable');
    return OpenCode.make({ baseUrl: endpoint.url, headers: Service.headers(endpoint) });
  }
  async list(backend, roots) {
    if (!roots.length) return [];
    const result = [];
    if (backend === 'opencode') {
      const client = await this.openCode();
      for (const directory of roots) {
        const page = await client.session.list({ directory, limit: 12, order: 'desc' }, { signal: AbortSignal.timeout(12000) });
        for (const s of page.data) if (authorized(s.location?.directory, roots)) result.push({ backend, id: s.id, project: s.location.directory, title: clean(s.title ?? 'OpenCode', 150), updated: s.time.updated });
      }
    } else if (backend === 'codex') {
      await this.codex.start();
      const page = await this.codex.call('thread/list', { cwd: roots, limit: 24, sortKey: 'updated_at', sortDirection: 'desc', modelProviders: [], useStateDbOnly: true });
      for (const s of page.data) if (authorized(s.cwd, roots)) result.push({ backend, id: s.id, project: s.cwd, title: clean(s.name ?? s.preview ?? 'Codex', 150), updated: s.updatedAt * 1000 });
    } else if (backend === 'claude') {
      for (const dir of roots) {
        const page = await listSessions({ dir, limit: 12, includeWorktrees: false, includeProgrammatic: true });
        for (const s of page) if (authorized(s.cwd, roots)) result.push({ backend, id: s.sessionId, project: s.cwd, title: clean(s.customTitle ?? s.summary, 150), updated: s.lastModified });
      }
    } else throw new Error('Unknown observer');
    return result;
  }
  async recent(session, roots) {
    if (!authorized(session.project, roots)) throw new Error('Project not authorized');
    let messages;
    if (session.backend === 'opencode') {
      const client = await this.openCode();
      const check = await client.session.get({ sessionID: session.id });
      if (!authorized(check.location.directory, roots)) throw new Error('Project changed');
      messages = (await client.message.list({ sessionID: session.id, limit: 8, order: 'desc' })).data;
    } else if (session.backend === 'codex') {
      await this.codex.start();
      const check = await this.codex.call('thread/read', { threadId: session.id, includeTurns: false });
      if (!authorized(check.thread.cwd, roots)) throw new Error('Project changed');
      messages = (await this.codex.call('thread/turns/list', { threadId: session.id, limit: 2, sortDirection: 'desc', itemsView: 'summary' })).data;
    } else {
      const check = await getSessionInfo(session.id, { dir: session.project });
      if (!check || !authorized(check.cwd, roots)) throw new Error('Project changed');
      // SDK has offset-from-start pagination, not a tail API. Cache by modification below.
      messages = (await getSessionMessages(session.id, { dir: session.project })).slice(-8);
    }
    return messages.map(m => ({ id: m.id ?? m.uuid ?? hash(textOf(m)), text: clean(textOf(m), 2000) })).filter(m => m.text);
  }
  async poll(backend, roots, excluded = []) {
    const sessions = (await this.list(backend, roots)).filter(s => !excluded.includes(s.id));
    const changes = [];
    for (const s of sessions) {
      const key = `${backend}:${s.id}`; const previous = this.baselines.get(key);
      if (backend === 'claude' && previous === s.updated && this.activity.has(key)) continue;
      // Active threads can persist text without changing list.updatedAt. Read only
      // the newest authorized tails each poll and compare normalized content.
      const messages = await this.recent(s, roots);
      this.baselines.set(key, s.updated);
      const digest = hash(JSON.stringify(messages));
      if (this.activity.get(key)?.digest === digest) continue;
      const activity = { ...s, sessionRef: key, sourceRef: `${key}:${s.updated}`, messages, digest };
      this.activity.set(key, activity);
      if (previous !== undefined || this.initialized.has(backend)) changes.push(activity);
    }
    this.initialized.add(backend);
    return { sessions, changes };
  }
  reset(backend) { this.initialized.delete(backend); for (const key of this.baselines.keys()) if (key.startsWith(`${backend}:`)) this.baselines.delete(key); for (const key of this.activity.keys()) if (key.startsWith(`${backend}:`)) this.activity.delete(key); }
  close() { this.codex.close(); }
}
