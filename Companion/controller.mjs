import { createServer } from 'node:http';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { Store } from './store.mjs';
import { Roles } from './roles.mjs';
import { Observers } from './adapters.mjs';
import { BACKENDS, clean, hash, parseUtterance, validConfig } from './policy.mjs';

export class Controller {
  constructor({ root, send, opencode, codex, observers, roles, now = () => Date.now() }) {
    Object.assign(this, { root, send, now });
    this.store = new Store(root); this.config = validConfig(); this.tokens = new Map();
    this.observers = observers ?? new Observers({ codex }); this.injectedRoles = roles;
    this.opencode = opencode; this.sources = {}; this.sessions = []; this.candidates = new Map();
    this.lastTopic = this.store.get('lastTopic', 0); this.nextIdle = Infinity; this.roleErrors = {};
  }
  async start() {
    await this.store.exportNotes();
    this.broker = createServer(async (req, res) => {
      const actor = this.tokens.get(req.headers.authorization?.replace(/^Bearer /, ''));
      if (!actor || req.method !== 'POST' || req.url !== '/tools') { res.writeHead(403); res.end('{}'); return; }
      let body = '';
      try {
        for await (const chunk of req) { body += chunk; if (body.length > 70000) throw new Error('Tool input too large'); }
        const { name, arguments: args } = JSON.parse(body);
        const output = await this.tool(actor, name, args ?? {});
        res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(output));
      } catch (e) { res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: clean(e.message, 250) })); }
    });
    await new Promise(resolve => this.broker.listen(0, '127.0.0.1', resolve));
    this.roles = this.injectedRoles ?? new Roles({ root: this.root, store: this.store, executable: this.opencode,
      endpoint: `http://127.0.0.1:${this.broker.address().port}/tools`, register: id => {
        for (const [token, actor] of this.tokens) if (actor === id) this.tokens.delete(token);
        const token = randomBytes(32).toString('hex'); this.tokens.set(token, id); return token;
      } });
    this.emit('ready', { history: this.store.history() });
    this.timer = setInterval(() => this.tick().catch(e => this.emit('error', { message: clean(e.message, 200) })), 1000);
  }
  emit(type, payload = {}) { if (this.closed) return; const event = this.store.event(type, payload); this.send(event); return event; }
  status() { return { sources: this.sources, sessions: this.sessions, busy: !!this.topic, roleErrors: this.roleErrors, nextIdle: Number.isFinite(this.nextIdle) ? this.nextIdle : null }; }
  configure(raw) {
    const next = validConfig(raw); const previous = this.config;
    for (const backend of BACKENDS) if (JSON.stringify(previous.sources[backend]) !== JSON.stringify(next.sources[backend])) {
      this.observers.reset(backend);
      this.sessions = this.sessions.filter(s => s.backend !== backend);
      for (const [key, value] of this.candidates) if (value.backend === backend) this.candidates.delete(key);
    }
    if (previous.intervalMinutes !== next.intervalMinutes || (!previous.enabled && next.enabled) || (previous.paused && !next.paused)) this.nextIdle = next.intervalMinutes > 0 ? this.now() + next.intervalMinutes * 60000 : Infinity;
    this.config = next;
    if (!next.enabled || next.paused || this.topic?.participants.some(id => !next.characters.some(c => c.id === id && c.enabled && c.visible)) ||
      (this.topic?.source && JSON.stringify(previous.sources[this.topic.source]) !== JSON.stringify(next.sources[this.topic.source]))) this.stop();
    this.emit('status', this.status());
  }
  visible() { return this.config.characters.filter(c => c.enabled && c.visible); }
  async tick() {
    if (!this.config.enabled) return;
    if (this.now() >= (this.pollAt ?? 0) && !this.polling) {
      this.pollAt = this.now() + 15000; this.polling = true;
      try {
        await Promise.allSettled(BACKENDS.map(async backend => {
          const source = this.config.sources[backend];
          if (!source.enabled) { this.sources[backend] = { state: 'disabled' }; return; }
          try {
            const ownSessions = this.store.db.prepare("SELECT value FROM state WHERE key LIKE 'session:%'").all().map(row => JSON.parse(row.value)).filter(Boolean);
            const result = await this.observers.poll(backend, undefined, ownSessions);
            if (JSON.stringify(source) !== JSON.stringify(this.config.sources[backend])) return;
            this.sessions = [...this.sessions.filter(s => s.backend !== backend), ...result.sessions];
            this.sources[backend] = { state: 'available', count: result.sessions.length, checkedAt: this.now() };
            for (const change of result.changes) this.candidates.set(change.sessionRef, { ...change, candidateAt: this.now() });
          } catch (e) { this.sources[backend] = { state: 'unavailable', message: clean(e.message, 180), checkedAt: this.now() }; }
        }));
      } finally { this.polling = false; if (!this.closing) this.emit('status', this.status()); }
    }
    if (this.closing) return;
    for (const [key, value] of this.candidates) if (this.now() - value.candidateAt > 120000) this.candidates.delete(key);
    if (this.config.paused || this.topic || !this.visible().length || this.now() - this.lastTopic < this.config.cooldownSeconds * 1000) return;
    const candidate = [...this.candidates.values()].find(c => this.now() - c.candidateAt >= 10000);
    if (candidate) { this.candidates.delete(candidate.sessionRef); void this.begin({ reason: 'work_activity', evidence: candidate, source: candidate.backend }); }
    else if (this.now() >= this.nextIdle) {
      this.nextIdle = this.config.intervalMinutes > 0 ? this.now() + this.config.intervalMinutes * 60000 : Infinity;
      void this.begin({ reason: 'idle_opportunity' });
    }
  }
  async begin({ reason, evidence, source, characterId }) {
    if (this.topic || this.config.paused || !this.config.enabled) return;
    let choices = this.visible(); if (!choices.length) return;
    if (characterId) choices = choices.filter(c => c.id === characterId);
    if (!choices.length) throw new Error('Selected character is unavailable');
    const watching = evidence?.sessionRef ? choices.filter(c => this.store.get(`watches:${c.id}`, []).includes(evidence.sessionRef)) : [];
    if (watching.length) choices = watching;
    const index = this.store.get('speakerIndex', 0) % choices.length; this.store.set('speakerIndex', index + 1);
    const character = choices[index];
    const topic = { id: randomUUID(), source, participants: [character.id], abort: new AbortController(), queue: [], utterances: 0, requests: 0, started: this.now(), sentBy: new Set() };
    topic.done = new Promise(resolve => { topic.resolve = resolve; });
    this.topic = topic; this.lastTopic = this.now(); this.store.set('lastTopic', this.lastTopic);
    const timeout = setTimeout(() => this.stop('timeout'), 90000);
    this.emit('topic.start', { topicId: topic.id, reason });
    try {
      await this.turn(character, { reason, evidence }, topic);
      while (topic.queue.length && !topic.abort.signal.aborted && topic.utterances < 4) {
        const envelope = topic.queue.shift(); const recipient = this.visible().find(c => c.id === envelope.to);
        if (!recipient) continue;
        if (!topic.participants.includes(recipient.id)) topic.participants.push(recipient.id);
        this.emit('conversation.focus', { topicId: topic.id, speakerId: envelope.from, listenerId: envelope.to, validUntil: new Date(topic.started + 90000).toISOString() });
        await this.turn(recipient, { reason: 'character_message', from: envelope.from, message: envelope.text }, topic, envelope);
      }
    } catch (e) {
      if (!topic.abort.signal.aborted) { this.roleErrors[character.id] = clean(e.message, 240); this.emit('error', { characterId: character.id, message: clean(e.message, 240) }); }
    } finally {
      clearTimeout(timeout);
      this.store.db.prepare("UPDATE deliveries SET status='cancelled' WHERE topic=? AND status='queued'").run(topic.id);
      this.store.db.prepare("UPDATE deliveries SET status='delivery_unknown' WHERE topic=? AND status='delivering'").run(topic.id);
      this.emit('topic.end', { topicId: topic.id, reason: topic.abort.signal.aborted ? 'cancelled' : 'completed' });
      if (this.topic === topic) this.topic = undefined;
      this.emit('status', this.status());
      await this.store.exportNotes().catch(() => {});
      topic.resolve();
    }
  }
  async turn(character, input, topic, envelope) {
    topic.abort.signal.throwIfAborted();
    if (topic.requests >= 6 || topic.utterances >= 4 || !this.store.spend(this.config.hourlyRequests, this.now())) return;
    topic.requests++;
    topic.speaker = character.id;
    if (envelope) this.store.db.prepare("UPDATE deliveries SET status='delivering' WHERE id=?").run(envelope.id);
    const context = {
      topicId: topic.id, ...input, quotedEvidence: true,
      intent: 'Choose whether you have a worthwhile, new thing to say: interest in work, celebration/concern supported by evidence, curiosity, shared experience, or follow-up. You may skip. Do not invent user feelings or facts. Never ask the user to type a reply.',
      ...(input.reason === 'manual_test' ? { manualTest: 'The user pressed your test button. Say one short visible greeting in your own Persona, or send a short message to an available companion. This is a presentation test: avoid skip unless you cannot safely respond. No user chat input is expected.' } : {}),
      recentConversation: this.store.history(16).filter(e => e.type === 'utterance').map(e => ({ from: e.characterId, text: e.text })),
      sharedMemory: this.store.listRecords().slice(0, 10).map(r => ({ path: r.path, ...this.store.readRecord(r.path), content: clean(this.store.readRecord(r.path).content, 1200) })),
      privateMemory: clean(this.store.get(`memory:${character.id}`, ''), 3000),
      characters: this.visible().map(c => ({ id: c.id, name: c.name })), remainingUtterances: 4 - topic.utterances,
    };
    const output = await this.roles.generate(character, context, { model: this.config.model, signal: topic.abort.signal,
      reserveNext: () => this.store.spend(this.config.hourlyRequests, this.now()) });
    topic.abort.signal.throwIfAborted(); delete this.roleErrors[character.id];
    if (envelope) this.store.db.prepare("UPDATE deliveries SET status='delivered' WHERE id=?").run(envelope.id);
    const parsed = parseUtterance(output);
    if (topic.sentBy.has(character.id)) { topic.sentBy.delete(character.id); return; }
    if (parsed.skip || !parsed.text) {
      if (input.reason === 'manual_test') this.emit('test.result', { characterId: character.id, result: 'skipped' });
      return;
    }
    this.say(character.id, parsed.text, topic, { emotion: parsed.emotion, to: envelope?.from });
    if (envelope) {
      const sender = this.visible().find(c => c.id === envelope.from);
      if (sender) {
        const id = randomUUID(); this.delivery(id, topic.id, character.id, sender.id, parsed.text, 'delivering');
        try {
          const remote = await this.roles.receive(sender, { id, from: character.id, text: parsed.text }, this.config.model);
          this.store.db.prepare("UPDATE deliveries SET status='accepted_pending_context',remote_id=? WHERE id=?").run(remote, id);
        } catch { this.store.db.prepare("UPDATE deliveries SET status='delivery_unknown' WHERE id=?").run(id); }
      }
    }
  }
  delivery(id, topic, from, to, text, status) { this.store.db.prepare('INSERT INTO deliveries VALUES (?,?,?,?,?,?,?,?)').run(id, topic, from, to, text, status, null, new Date().toISOString()); }
  say(characterId, text, topic, extra = {}) {
    if (topic.abort.signal.aborted || topic.utterances >= 4 || !this.visible().some(c => c.id === characterId)) return;
    topic.utterances++; this.emit('utterance', { characterId, name: this.config.characters.find(c => c.id === characterId)?.name, text: clean(text, 300), topicId: topic.id, ...extra });
  }
  async tool(actor, name, args) {
    if (!this.config.enabled || this.config.paused || !this.config.characters.some(c => c.id === actor && c.enabled)) throw new Error('Character is paused');
    await this.roles.nextStep?.(actor);
    if (name === 'companion_list_characters') return this.visible().filter(c => c.id !== actor).map(c => ({ id: c.id, name: c.name }));
    if (name === 'observer_list_sessions') return this.sessions;
    if (name === 'observer_get_recent_work') return [...this.observers.activity.values()].filter(a => this.config.sources[a.backend].enabled).slice(-8);
    if (name === 'observer_watch_session' || name === 'observer_unwatch_session') {
      const session = this.sessions.find(s => `${s.backend}:${s.id}` === args.sessionRef);
      if (!session || !this.config.sources[session.backend].enabled) throw new Error('Session not authorized');
      const watched = this.store.get(`watches:${actor}`, []).filter(x => x !== args.sessionRef);
      if (name === 'observer_watch_session') watched.push(args.sessionRef);
      this.store.set(`watches:${actor}`, watched.slice(-24)); return { watching: name === 'observer_watch_session' };
    }
    if (name === 'observer_get_activity' || name === 'observer_get_session_summary') {
      let activity = this.observers.activity.get(args.sessionRef);
      const session = this.sessions.find(s => `${s.backend}:${s.id}` === args.sessionRef);
      if (!session || !this.config.sources[session.backend].enabled) throw new Error('Activity not authorized or unavailable');
      if (!activity) {
        activity = { ...session, sessionRef: args.sessionRef, sourceRef: `${args.sessionRef}:${session.updated}`, messages: await this.observers.recent(session) };
        if (!this.config.sources[session.backend].enabled) throw new Error('Source access revoked');
        this.observers.activity.set(args.sessionRef, activity);
      }
      return activity;
    }
    if (name === 'public_record_list') return this.store.listRecords();
    if (name === 'public_record_read') return this.store.readRecord(args.path);
    if (name === 'public_record_update') {
      const result = this.store.updateRecord(actor, args.path, clean(args.content, 32768), args.expectedRevision);
      if (!result.conflict) { await this.store.exportNotes(); this.emit('record.changed', { characterId: actor, path: args.path, revision: result.revision }); } return result;
    }
    if (name === 'private_memory_read') return { content: this.store.get(`memory:${actor}`, '') };
    if (name === 'private_memory_update') {
      if (typeof args.content !== 'string' || Buffer.byteLength(args.content) > 32768) throw new Error('Memory exceeds 32 KB');
      this.store.set(`memory:${actor}`, clean(args.content, 32768)); await this.store.exportNotes(); return { updated: true };
    }
    if (name === 'companion_send_message') {
      const topic = this.topic;
      if (!topic || topic.abort.signal.aborted || topic.speaker !== actor || !this.visible().some(c => c.id === args.to && c.id !== actor)) throw new Error('No available recipient or topic');
      if (typeof args.text !== 'string' || !args.text.trim() || args.text.length > 300 || topic.utterances + topic.queue.length >= 4) throw new Error('Message or topic limit exceeded');
      const id = randomUUID(); const text = clean(args.text, 300);
      this.delivery(id, topic.id, actor, args.to, text, 'queued');
      if (!topic.participants.includes(args.to)) topic.participants.push(args.to);
      this.emit('conversation.focus', { topicId: topic.id, speakerId: actor, listenerId: args.to, validUntil: new Date(topic.started + 90000).toISOString() });
      topic.sentBy.add(actor); this.say(actor, text, topic, { to: args.to });
      topic.queue.push({ id, from: actor, to: args.to, text });
      return { messageId: id, status: 'queued' };
    }
    throw new Error('Tool denied');
  }
  stop(reason = 'cancelled') {
    this.candidates.clear();
    if (this.topic) { this.topic.abort.abort(new Error(reason)); this.emit('topic.end', { topicId: this.topic.id, reason }); void this.roles?.interrupt(); }
    this.nextIdle = this.config.intervalMinutes > 0 ? this.now() + this.config.intervalMinutes * 60000 : Infinity;
  }
  async command(command) {
    if (command.type === 'configure') { this.configure(command.config); return; }
    if (command.type === 'stop') { this.stop(); return; }
    if (command.type === 'trigger') {
      if (!this.config.enabled || this.config.paused) throw new Error('Companion is disabled or in Do Not Disturb');
      if (this.topic) throw new Error('A conversation is already running');
      if (!this.visible().some(c => c.id === command.characterId)) throw new Error('Enable and show this character before testing');
      const used = this.store.db.prepare('SELECT COUNT(*) AS n FROM requests WHERE at>=?').get(this.now() - 3600000).n;
      if (used >= this.config.hourlyRequests) throw new Error('Hourly model budget reached');
      return this.begin({ reason: 'manual_test', characterId: command.characterId });
    }
    if (command.type === 'history') { this.emit('history', { history: this.store.history(400) }); return; }
    if (command.type === 'records') {
      this.emit('records', { records: this.store.listRecords().map(r => ({ path: r.path, ...this.store.readRecord(r.path) })) }); return;
    }
    if (command.type === 'memory' && /^[\da-f-]{36}$/i.test(command.characterId ?? '')) {
      this.emit('memory', { characterId: command.characterId, content: this.store.get(`memory:${command.characterId}`, '') }); return;
    }
    if (command.type === 'saveMemory' && /^[\da-f-]{36}$/i.test(command.characterId ?? '') && typeof command.content === 'string' && Buffer.byteLength(command.content) <= 32768) {
      this.stop(); this.store.set(`memory:${command.characterId}`, clean(command.content, 32768));
      await this.store.exportNotes();
      this.emit('memory', { characterId: command.characterId, content: this.store.get(`memory:${command.characterId}`, '') }); return;
    }
    if (command.type === 'saveRecord') {
      this.stop(); const result = this.store.updateRecord('user', command.path, clean(command.content, 32768), command.expectedRevision);
      if (result.conflict) throw new Error('Memory changed; refresh and merge your edits.');
      this.emit('record.changed', { characterId: 'user', path: command.path, revision: result.revision });
      await this.store.exportNotes();
      this.emit('records', { records: this.store.listRecords().map(r => ({ path: r.path, ...this.store.readRecord(r.path) })) }); return;
    }
    if (command.type === 'clear') {
      this.stop(); await this.roles.interrupt();
      if (command.scope === 'history') this.store.db.exec('DELETE FROM events; DELETE FROM deliveries;');
      else if (command.scope === 'public') this.store.deleteRecords();
      else if (/^[\da-f-]{36}$/i.test(command.scope ?? '')) {
        this.store.set(`memory:${command.scope}`, '');
        // Disassociate the old model context; never pretend deleting notes erased its session.
        this.store.set(`session:${command.scope}`, null); this.roles.instances?.delete(command.scope);
      }
      await this.store.exportNotes();
      this.emit('history', { history: this.store.history() });
      this.emit('records', { records: this.store.listRecords().map(r => ({ path: r.path, ...this.store.readRecord(r.path) })) }); return;
    }
    throw new Error('Unknown host command');
  }
  async close() {
    if (this.closed || this.closing) return;
    this.closing = true; clearInterval(this.timer); const work = this.topic?.done;
    this.stop(); this.observers.close(); await this.roles?.interrupt(); this.roles?.close();
    if (work) await Promise.race([work, new Promise(resolve => setTimeout(resolve, 4000))]);
    await this.store.exportQueue?.catch(() => {});
    this.broker?.close(); this.closed = true; this.store.close();
  }
}
