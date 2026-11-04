import { DatabaseSync } from 'node:sqlite';
import { mkdir, readFile, realpath, lstat, writeFile, rename, readdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import { hash } from './policy.mjs';

export class Store {
  constructor(root) {
    this.root = root;
    this.db = new DatabaseSync(path.join(root, 'state.sqlite'));
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;
      CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,at TEXT NOT NULL,type TEXT NOT NULL,payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS records(path TEXT PRIMARY KEY,content TEXT NOT NULL,revision TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS changes(id INTEGER PRIMARY KEY,at TEXT,actor TEXT,path TEXT,before_revision TEXT,revision TEXT,content TEXT);
      CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY,topic TEXT,sender TEXT,recipient TEXT,text TEXT,status TEXT,remote_id TEXT,at TEXT);
      CREATE TABLE IF NOT EXISTS requests(at INTEGER NOT NULL);
      UPDATE deliveries SET status='delivery_unknown' WHERE status='delivering';`);
  }
  get(key, fallback = undefined) { const row = this.db.prepare('SELECT value FROM state WHERE key=?').get(key); return row ? JSON.parse(row.value) : fallback; }
  set(key, value) { this.db.prepare('INSERT OR REPLACE INTO state VALUES (?,?)').run(key, JSON.stringify(value)); }
  event(type, payload) {
    const at = new Date().toISOString();
    const seq = Number(this.db.prepare('INSERT INTO events(at,type,payload) VALUES (?,?,?)').run(at, type, JSON.stringify(payload)).lastInsertRowid);
    return { protocolVersion: 1, sequence: seq, createdAt: at, type, ...payload };
  }
  history(limit = 200) {
    return this.db.prepare("SELECT seq,at,type,payload FROM events WHERE type IN ('utterance','topic.end','error','record.changed') ORDER BY seq DESC LIMIT ?")
      .all(limit).reverse().map(r => ({ sequence: r.seq, createdAt: r.at, type: r.type, ...JSON.parse(r.payload) }));
  }
  spend(limit, now = Date.now()) {
    this.db.prepare('DELETE FROM requests WHERE at<?').run(now - 3600000);
    if (this.db.prepare('SELECT COUNT(*) AS n FROM requests').get().n >= limit) return false;
    this.db.prepare('INSERT INTO requests VALUES (?)').run(now); return true;
  }
  readRecord(key) {
    if (!/^[\w\u0080-\uffff][\w\u0080-\uffff .-]{0,120}\.md$/u.test(key) || key.includes('..')) throw new Error('Invalid record name');
    return this.db.prepare('SELECT content,revision FROM records WHERE path=?').get(key) ?? { content: '', revision: hash('') };
  }
  updateRecord(actor, key, content, expectedRevision) {
    if (typeof content !== 'string' || Buffer.byteLength(content) > 32768) throw new Error('Record exceeds 32 KB');
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const before = this.readRecord(key);
      if (before.revision !== expectedRevision) { this.db.exec('ROLLBACK'); return { conflict: true, revision: before.revision }; }
      const revision = hash(content);
      this.db.prepare('INSERT OR REPLACE INTO records VALUES (?,?,?)').run(key, content, revision);
      this.db.prepare('INSERT INTO changes(at,actor,path,before_revision,revision,content) VALUES (?,?,?,?,?,?)')
        .run(new Date().toISOString(), actor, key, before.revision, revision, content);
      this.db.exec('COMMIT'); return { revision };
    } catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  listRecords() { return this.db.prepare('SELECT path,revision FROM records ORDER BY path').all(); }
  deleteRecords() { this.db.exec('DELETE FROM records; DELETE FROM changes;'); }
  exportNotes() {
    this.exportQueue = (this.exportQueue ?? Promise.resolve()).catch(() => {}).then(() => this.projectNotes());
    return this.exportQueue;
  }
  async projectNotes() {
    const projection = async (relative, content) => {
      const file = path.join(this.root, relative);
      const parts = path.relative(this.root, path.dirname(file)).split(path.sep);
      let directory = this.root;
      for (const part of parts) {
        directory = path.join(directory, part);
        await mkdir(directory, { recursive: true, mode: 0o700 });
        if ((await lstat(directory)).isSymbolicLink()) throw new Error('Memory directory must not be a symbolic link');
      }
      const temp = `${file}.new`;
      const info = await lstat(temp).catch(() => null);
      if (info?.isSymbolicLink()) throw new Error('Invalid memory projection');
      await writeFile(temp, content, { mode: 0o600 }); await rename(temp, file);
    };
    for (const row of this.db.prepare("SELECT key,value FROM state WHERE key LIKE 'memory:%'").all()) {
      const id = row.key.slice(7);
      if (/^[\da-f-]{36}$/i.test(id)) await projection(`characters/${id}/memory.md`, JSON.parse(row.value));
    }
    for (const record of this.listRecords()) await projection(`public/records/${record.path}`, this.readRecord(record.path).content);
    const recordsDir = path.join(this.root, 'public/records');
    const recorded = new Set(this.listRecords().map(r => r.path));
    if (!((await lstat(recordsDir).catch(() => null))?.isSymbolicLink())) {
      for (const name of await readdir(recordsDir).catch(() => [])) if (name.endsWith('.md') && !recorded.has(name)) await unlink(path.join(recordsDir, name));
    }
    const exchanges = this.db.prepare("SELECT at,payload FROM events WHERE type='utterance' ORDER BY seq DESC LIMIT 1000").all().reverse();
    await projection('public/exchanges/recent.md', '# Companion exchanges\n\n' + exchanges.map(row => {
      const e = JSON.parse(row.payload); return `## ${row.at} · ${e.characterId}\n\n${e.text}\n`;
    }).join('\n'));
  }
  close() { this.db.close(); }
}
export async function persona(root, id) {
  if (!/^[\da-f-]{36}$/i.test(id)) throw new Error('Invalid character');
  const dir = path.join(root, 'characters', id);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, 'persona.md');
  const stat = await lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 65536) throw new Error('Persona must be a regular Markdown file under 64 KB');
  if (path.dirname(await realpath(file)) !== await realpath(dir)) throw new Error('Invalid Persona location');
  const text = await readFile(file, 'utf8');
  if (!text.trim()) throw new Error('Persona is empty');
  return { text, dir, digest: hash(text) };
}
