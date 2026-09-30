// desk/test/fixtures/opencode-fixture.mjs
// Builds an OpenCode-shaped data dir: opencode.db (DDL mirrors sst/opencode packages/core/src/session/sql.ts and project/sql.ts)
// and legacy storage/**/*.json, filled with synthetic rows.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

export const DDL = [
  'CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, vcs TEXT, name TEXT, icon_url TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_initialized INTEGER, sandboxes TEXT NOT NULL)',
  `CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, path TEXT,
    title TEXT NOT NULL, version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER, metadata TEXT, cost REAL NOT NULL DEFAULT 0,
    tokens_input INTEGER NOT NULL DEFAULT 0, tokens_output INTEGER NOT NULL DEFAULT 0, tokens_reasoning INTEGER NOT NULL DEFAULT 0,
    tokens_cache_read INTEGER NOT NULL DEFAULT 0, tokens_cache_write INTEGER NOT NULL DEFAULT 0, permission TEXT, agent TEXT, model TEXT,
    time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_compacting INTEGER, time_archived INTEGER)`,
  'CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)',
  'CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)',
];

/**
 * projects: [{ id, worktree, name? }]
 * sessions: [{ id, project_id, parent_id?, directory, title, agent?, model?: {id,providerID}, created, updated, archived?, tokens?: {input,output,...} }]
 * messages: [{ id, session_id, created, data: object | string }]  (body markers are injected automatically)
 * parts:    [{ id, message_id, session_id, created, data: object | string }]
 * legacy:   { projects: {id: obj}, sessions: {projectId: [obj]}, messages: {sessionId: {msgId: obj | string}} }
 * Returns the data dir (containing opencode.db when `db` is not false).
 */
export function buildOpenCodeFixture(dataDir, { projects = [], sessions = [], messages = [], parts = [], legacy = null, db = true }) {
  fs.mkdirSync(dataDir, { recursive: true });
  if (db) {
    const conn = new DatabaseSync(path.join(dataDir, 'opencode.db'));
    for (const s of DDL) conn.exec(s);
    const ip = conn.prepare('INSERT INTO project (id, worktree, name, time_created, time_updated, sandboxes) VALUES (?,?,?,?,?,?)');
    for (const p of projects) ip.run(p.id, p.worktree, p.name ?? null, 1, 1, '[]');
    const is = conn.prepare(`INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, agent, model, tokens_input, tokens_output, tokens_reasoning,
      tokens_cache_read, tokens_cache_write, time_created, time_updated, time_archived) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
    for (const s of sessions) {
      const t = s.tokens || {};
      is.run(s.id, s.project_id, s.parent_id ?? null, 'slug', s.directory, s.title, '1.2.0', s.agent ?? null, s.model ? JSON.stringify(s.model) : null,
        t.input ?? 0, t.output ?? 0, t.reasoning ?? 0, t.read ?? 0, t.write ?? 0, s.created, s.updated, s.archived ?? null);
    }
    const im = conn.prepare('INSERT INTO message VALUES (?,?,?,?,?)');
    for (const m of messages) im.run(m.id, m.session_id, m.created, m.created, typeof m.data === 'string' ? m.data : JSON.stringify({ system: 'BODY_MARKER', summary_text: 'BODY_MARKER', ...m.data }));
    const ipt = conn.prepare('INSERT INTO part VALUES (?,?,?,?,?,?)');
    for (const p of parts) ipt.run(p.id, p.message_id, p.session_id, p.created, p.created, typeof p.data === 'string' ? p.data : JSON.stringify({ text: 'BODY_MARKER', state: { input: 'BODY_MARKER', output: 'BODY_MARKER' }, ...p.data }));
    conn.close();
  }
  if (legacy) {
    const root = path.join(dataDir, 'storage');
    const w = (f, o) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, typeof o === 'string' ? o : JSON.stringify(o)); };
    for (const [id, p] of Object.entries(legacy.projects || {})) w(path.join(root, 'project', id + '.json'), p);
    for (const [pid, list] of Object.entries(legacy.sessions || {})) for (const s of list) w(path.join(root, 'session', pid, (s.id || 'bad') + '.json'), typeof s === 'string' ? s : s);
    for (const [sid, ms] of Object.entries(legacy.messages || {})) for (const [mid, m] of Object.entries(ms)) w(path.join(root, 'message', sid, mid + '.json'), typeof m === 'string' ? m : { summary: { title: 'BODY_MARKER' }, ...m });
  }
  return dataDir;
}
