// desk/test/fixtures/codex-fixture.mjs
// Builds a Codex-shaped ~/.codex (state_N.sqlite with the real threads / thread_spawn_edges DDL, rollout JSONL). Synthetic data only.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

export const DDL = [
  `CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
    source TEXT NOT NULL, model_provider TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, sandbox_policy TEXT NOT NULL,
    approval_mode TEXT NOT NULL, tokens_used INTEGER NOT NULL DEFAULT 0, has_user_event INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0, archived_at INTEGER, git_sha TEXT, git_branch TEXT, git_origin_url TEXT,
    cli_version TEXT NOT NULL DEFAULT '', first_user_message TEXT NOT NULL DEFAULT '', agent_nickname TEXT, agent_role TEXT,
    memory_mode TEXT NOT NULL DEFAULT 'enabled', model TEXT, reasoning_effort TEXT, agent_path TEXT, created_at_ms INTEGER,
    updated_at_ms INTEGER, thread_source TEXT, preview TEXT NOT NULL DEFAULT '', name TEXT)`,
  'CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL)',
];

export const BODY = 'PROMPT_BODY_MARKER';

/**
 * threads: [{ id, cwd, title?, name?, model?, tokens_used?, created (ms), updated (ms), archived?, agent_nickname?, agent_role?,
 *             rollout: string[] of JSONL lines | null (no file) }]
 * edges:   [{ parent, child, status }]
 * stateFile: file name of the db (default state_5.sqlite); rolloutOnly: skip the db entirely
 */
export function buildCodexFixture(codexHome, { threads = [], edges = [], stateFile = 'state_5.sqlite', rolloutOnly = false, extraStates = [] } = {}) {
  fs.mkdirSync(codexHome, { recursive: true });
  const rows = [];
  for (const t of threads) {
    let rolloutPath = path.join(codexHome, 'sessions', 'missing', `rollout-${t.id}.jsonl`);
    if (t.rollout) {
      const d = new Date(t.created);
      const dir = path.join(codexHome, 'sessions', String(d.getUTCFullYear()), String(d.getUTCMonth() + 1).padStart(2, '0'), String(d.getUTCDate()).padStart(2, '0'));
      fs.mkdirSync(dir, { recursive: true });
      rolloutPath = path.join(dir, `rollout-${d.toISOString().slice(0, 19).replace(/:/g, '-')}-${t.id}.jsonl`);
      fs.writeFileSync(rolloutPath, t.rollout.join('\n') + (t.rolloutNoNewline ? '' : '\n'));
      const m = new Date(t.updated);
      fs.utimesSync(rolloutPath, m, m);
    }
    rows.push({ t, rolloutPath });
  }
  if (!rolloutOnly) {
    for (const f of [...extraStates, stateFile]) {
      const db = new DatabaseSync(path.join(codexHome, f));
      for (const s of DDL) db.exec(s);
      if (f === stateFile) {
        const ins = db.prepare(`INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode,
          tokens_used, archived, first_user_message, preview, agent_nickname, agent_role, model, created_at_ms, updated_at_ms, name)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
        for (const { t, rolloutPath } of rows) {
          ins.run(t.id, rolloutPath, Math.floor(t.created / 1000), Math.floor(t.updated / 1000), 'cli', 'openai', t.cwd, t.title ?? '', 'x', 'y',
            t.tokens_used ?? 0, t.archived ? 1 : 0, BODY, BODY, t.agent_nickname ?? null, t.agent_role ?? null, t.model ?? null, t.created, t.updated, t.name ?? null);
        }
        const ie = db.prepare('INSERT INTO thread_spawn_edges VALUES (?,?,?)');
        for (const e of edges) ie.run(e.parent, e.child, e.status ?? 'open');
      }
      db.close();
    }
  }
  return { dbPath: path.join(codexHome, stateFile), rolloutOf: id => rows.find(r => r.t.id === id)?.rolloutPath };
}

const line = (ts, type, payload) => JSON.stringify({ timestamp: new Date(ts).toISOString(), type, payload });
export const meta = (ts, id, cwd, extra = {}) => line(ts, 'session_meta', { id, cwd, timestamp: new Date(ts).toISOString(), cli_version: '0.1', base_instructions: { text: BODY }, ...extra });
export const turnContext = (ts, model) => line(ts, 'turn_context', { model, cwd: 'x', summary: BODY });
export const started = ts => line(ts, 'event_msg', { type: 'task_started' });
export const complete = ts => line(ts, 'event_msg', { type: 'task_complete', last_agent_message: BODY });
export const aborted = ts => line(ts, 'event_msg', { type: 'turn_aborted', reason: 'interrupted' });
export const userMsg = ts => line(ts, 'event_msg', { type: 'user_message', message: BODY });
export const agentMsg = ts => line(ts, 'event_msg', { type: 'agent_message', message: BODY });
export const tokens = (ts, last, total) => line(ts, 'event_msg', { type: 'token_count', info: { last_token_usage: { total_tokens: last }, total_token_usage: { total_tokens: total } } });
export const toolCall = (ts, name) => line(ts, 'response_item', { type: 'function_call', name, arguments: JSON.stringify({ cmd: BODY }), call_id: 'c1' });
export const toolOut = ts => line(ts, 'response_item', { type: 'function_call_output', call_id: 'c1', output: BODY });
export const assistantText = ts => line(ts, 'response_item', { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: BODY }] });
