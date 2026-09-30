// desk/adapters/codex.mjs
// Codex CLI source adapter (experimental). Reads the state_N.sqlite index read-only (whitelisted columns) and the tail of each
// rollout JSONL for running/finished, model, token and last-tool hints. Never copies prompts, messages or tool output.
import fs from 'node:fs/promises';
import path from 'node:path';
import { clip, RUNNING_MS, IDLE_MS, STALE_MS } from '../lib/model.mjs';

export const TAIL_BYTES = 65536;
export const HEAD_BYTES = 262144;
const RETRY_DELAYS = [100, 200, 400];
const toIso = v => { const t = typeof v === 'number' ? v : Date.parse(v); return Number.isFinite(t) ? new Date(t).toISOString() : null; };
const isBusy = e => e && (e.errcode === 5 || e.errcode === 6 || /busy|locked/i.test(String(e.message)));
async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }
const str = v => (typeof v === 'string' && v ? v : null);
const num = v => (Number.isFinite(v) ? v : null);

export function codexHomeOf(env) {
  const vars = env.vars || {};
  const join = env.platform === 'win32' ? path.win32.join : path.posix.join;
  return vars.CODEX_HOME || join(env.home, '.codex');
}
const cleanCwd = p => (typeof p === 'string' && p ? p.replace(/^\\\\\?\\/, '') : null);

/** Highest numbered state_N.sqlite in the codex home, or null. */
async function findStateDb(home) {
  let names = [];
  try { names = await fs.readdir(home); } catch { return null; }
  let best = null;
  for (const n of names) {
    const m = /^state_(\d+)\.sqlite$/.exec(n);
    if (m && (!best || Number(m[1]) > best.n)) best = { n: Number(m[1]), file: path.join(home, n) };
  }
  return best && best.file;
}

async function readRange(file, start, len) {
  const fh = await fs.open(file, 'r');
  try { const buf = Buffer.alloc(len); const { bytesRead } = await fh.read(buf, 0, len, start); return buf.subarray(0, bytesRead).toString('utf8'); } finally { await fh.close(); }
}

function parseLines(text, dropFirst) {
  const parts = text.split('\n');
  if (dropFirst) parts.shift();
  const out = [];
  for (const raw of parts) { const l = raw.trim(); if (!l) continue; try { const o = JSON.parse(l); if (o && typeof o === 'object') out.push(o); } catch { /* partial line */ } }
  return out;
}

/** Whitelisted facts from the tail of a rollout. Returns null when the file is unreadable. */
async function readTail(file, size) {
  try {
    const start = Math.max(0, size - TAIL_BYTES);
    const recs = parseLines(await readRange(file, start, size - start), start > 0);
    let turn = null, model = null, context = null, total = null, last = null;
    for (const r of recs) {
      const p = r.payload && typeof r.payload === 'object' ? r.payload : {};
      const at = toIso(r.timestamp);
      if (r.type === 'turn_context') { if (str(p.model)) model = p.model; }
      else if (r.type === 'event_msg') {
        if (p.type === 'task_started') turn = 'open';
        else if (p.type === 'task_complete') turn = 'complete';
        else if (p.type === 'turn_aborted') turn = 'aborted';
        else if (p.type === 'token_count' && p.info && typeof p.info === 'object') {
          const l = p.info.last_token_usage && num(p.info.last_token_usage.total_tokens);
          const t = p.info.total_token_usage && num(p.info.total_token_usage.total_tokens);
          if (l !== null && l !== undefined) context = l;
          if (t !== null && t !== undefined) total = t;
        }
        if (p.type === 'user_message') last = { at, kind: 'user', toolName: null, summary: null };
        else if (p.type === 'agent_message') last = { at, kind: 'assistant', toolName: null, summary: null };
      } else if (r.type === 'response_item') {
        if (p.type === 'function_call' || p.type === 'custom_tool_call' || p.type === 'local_shell_call') {
          const name = str(p.name) || (p.type === 'local_shell_call' ? 'shell' : null);
          last = { at, kind: 'tool', toolName: name, summary: clip(name, 80) };
        } else if (p.type === 'message' && p.role === 'assistant') last = { at, kind: 'assistant', toolName: null, summary: null };
      }
    }
    return { turn, model, context, total, last };
  } catch { return null; }
}

/** First line only (session_meta): id, cwd, timestamp, parent thread when present. */
async function readMeta(file) {
  const text = await readRange(file, 0, HEAD_BYTES);
  const nl = text.indexOf('\n');
  if (nl < 0 && text.length >= HEAD_BYTES) throw new Error('meta line too long');
  const o = JSON.parse(nl < 0 ? text : text.slice(0, nl));
  if (!o || o.type !== 'session_meta' || !o.payload) throw new Error('not session_meta');
  const p = o.payload;
  const sp = p.source && p.source.subagent && p.source.subagent.thread_spawn;
  return { id: str(p.id), cwd: cleanCwd(p.cwd), at: toIso(p.timestamp || o.timestamp), parent: sp && str(sp.parent_thread_id),
    nickname: str(p.agent_nickname), role: str(p.agent_role), model: str(p.model) };
}

function readThreads(conn, env) {
  const cutoff = env.now() - env.days * 86400000;
  const rows = conn.prepare('SELECT * FROM threads').all();
  const out = [];
  let skipped = 0;
  for (const r of rows) {
    try {
      const updated = num(r.updated_at_ms) ?? (num(r.updated_at) !== null ? r.updated_at * 1000 : null);
      const created = num(r.created_at_ms) ?? (num(r.created_at) !== null ? r.created_at * 1000 : null);
      if (!str(r.id)) throw new Error('id');
      if ((updated ?? created ?? 0) < cutoff) continue;
      out.push({ id: r.id, rolloutPath: str(r.rollout_path), cwd: cleanCwd(r.cwd), title: str(r.name) || str(r.title), model: str(r.model),
        tokensUsed: num(r.tokens_used), created, updated, archived: r.archived === 1, nickname: str(r.agent_nickname), role: str(r.agent_role) });
    } catch { skipped++; }
  }
  const edges = new Map();
  try { for (const e of conn.prepare('SELECT parent_thread_id, child_thread_id, status FROM thread_spawn_edges').all()) edges.set(e.child_thread_id, { parent: e.parent_thread_id, status: str(e.status) }); } catch { /* table optional */ }
  return { rows: out, edges, skipped };
}

async function openAndRead(mod, dbPath, env, sleep) {
  for (let attempt = 0; ; attempt++) {
    let conn = null;
    try { conn = new mod.DatabaseSync(dbPath, { readOnly: true }); return readThreads(conn, env); }
    catch (e) { if (!isBusy(e) || attempt >= RETRY_DELAYS.length) throw e; await sleep(RETRY_DELAYS[attempt]); }
    finally { if (conn) { try { conn.close(); } catch { /* already closed */ } } }
  }
}

async function* walkRollouts(dir, depth = 0) {
  let ents = [];
  try { ents = await fs.readdir(dir, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory() && depth < 3) yield* walkRollouts(p, depth + 1);
    else if (e.isFile() && /^rollout-.*\.jsonl$/.test(e.name)) yield p;
  }
}

function stateFor(tail, edge, updatedMs, nowMs) {
  const at = toIso(updatedMs);
  if (edge && /^(closed|completed|done)$/i.test(edge.status || '')) return { kind: 'fixed', state: 'finished', stateSource: 'field' };
  const age = nowMs - updatedMs;
  if (tail && tail.turn === 'open' && age < STALE_MS) return { kind: 'fixed', state: 'running', stateSource: 'field' };
  if (tail && (tail.turn === 'complete' || tail.turn === 'aborted')) {
    return { kind: 'fixed', state: age < IDLE_MS ? 'idle' : 'finished', stateSource: 'field' };
  }
  return { kind: 'mtime', at, stateSource: 'mtime' };
}

export function createCodexAdapter({ loadSqlite = () => import('node:sqlite'), sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  async function tailOf(file, cache) {
    if (!file) return { tail: null, st: null };
    const st = await statOrNull(file);
    if (!st) return { tail: null, st: null };
    const key = 'tail:' + file;
    const hit = cache.get(key);
    if (hit && hit.size === st.size && hit.mtimeMs === st.mtimeMs) return { tail: hit.tail, st };
    const tail = await readTail(file, st.size);
    cache.set(key, { size: st.size, mtimeMs: st.mtimeMs, tail });
    return { tail, st };
  }

  function depthOf(id, parentOf) {
    let d = 0; const seen = new Set([id]);
    for (let p = parentOf.get(id); p && !seen.has(p) && d < 10; p = parentOf.get(p)) { d++; seen.add(p); }
    return d;
  }

  async function build(env, items, cache) {
    const parentOf = new Map(items.filter(i => i.parent).map(i => [i.id, i.parent]));
    const known = new Set(items.map(i => i.id));
    const sessions = [];
    for (const i of items) {
      const { tail, st } = await tailOf(i.file, cache);
      const updatedMs = Math.max(...[i.updated, st && st.mtimeMs, i.created].filter(Number.isFinite));
      if (!Number.isFinite(updatedMs)) continue;
      const parent = i.parent && known.has(i.parent) ? i.parent : null;
      const title = clip(i.title, 120);
      const stateBasis = stateFor(tail, i.edge, updatedMs, env.now());
      const project = i.cwd || null;
      sessions.push({
        nativeId: i.id, tool: 'codex', parentNativeId: parent, depth: parent ? depthOf(i.id, parentOf) : 0,
        projectPath: project, projectLabel: project ? null : 'Codex (no folder)',
        title: title || `Codex ${i.id.slice(0, 8)}`, titleSource: title ? 'explicit' : 'fallback',
        agentType: clip(i.role, 60) || (parent ? 'subagent' : 'codex'), model: i.model || (tail && tail.model) || null,
        createdAt: toIso(i.created), updatedAt: toIso(updatedMs),
        endedAt: stateBasis.kind === 'fixed' && stateBasis.state === 'finished' ? toIso(updatedMs) : null,
        tokens: { context: tail ? tail.context : null, total: i.tokensUsed ?? (tail ? tail.total : null) },
        lastActivity: tail && tail.last ? tail.last : null,
        refs: { file: i.file || null, db: i.db || null, key: i.id }, archived: i.archived === true, stateBasis,
      });
    }
    return sessions;
  }

  async function scan(env, { cache }) {
    try {
      const home = codexHomeOf(env);
      const dbPath = await findStateDb(home);
      const sdir = path.join(home, 'sessions');
      const stDb = dbPath && await statOrNull(dbPath);
      const wal = dbPath && await statOrNull(dbPath + '-wal');
      const sst = await statOrNull(sdir);
      const fp = [dbPath, stDb && stDb.size, stDb && stDb.mtimeMs, wal && wal.size, wal && wal.mtimeMs, sst && sst.mtimeMs, env.days].join('|');
      const hit = cache.get('result');
      // Rollout tails change without touching the index, so a cached result is reused only briefly.
      if (hit && hit.fp === fp && env.now() - hit.at < RUNNING_MS / 4) return hit.value;
      let items = [], skipped = 0;
      const notes = [];
      if (dbPath) {
        let mod;
        try { mod = await loadSqlite(); } catch { return { sessions: [], skipped: 0, notes: ['node:sqlite unavailable (Node >= 22.13 required)'] }; }
        let read;
        try { read = await openAndRead(mod, dbPath, env, sleep); } catch (e) { return { sessions: [], skipped: 0, notes: [`codex state db unreadable: ${clip(e && e.message, 100)}`] }; }
        skipped = read.skipped;
        items = read.rows.map(r => ({ id: r.id, file: r.rolloutPath, db: dbPath, cwd: r.cwd, title: r.title, model: r.model, tokensUsed: r.tokensUsed,
          created: r.created, updated: r.updated, archived: r.archived, role: r.role || r.nickname,
          parent: (read.edges.get(r.id) || {}).parent || null, edge: read.edges.get(r.id) || null }));
      } else {
        const cutoff = env.now() - env.days * 86400000;
        for await (const file of walkRollouts(sdir)) {
          const fst = await statOrNull(file);
          if (!fst || fst.mtimeMs < cutoff) continue;
          try {
            const m = await readMeta(file);
            if (!m.id) throw new Error('id');
            const created = Date.parse(m.at);
            items.push({ id: m.id, file, db: null, cwd: m.cwd, title: null, model: m.model, tokensUsed: null, created: Number.isFinite(created) ? created : fst.birthtimeMs,
              updated: fst.mtimeMs, archived: false, role: m.role || m.nickname, parent: m.parent, edge: null });
          } catch { skipped++; }
        }
      }
      const sessions = await build(env, items, cache);
      const value = { sessions, skipped, notes };
      cache.set('result', { fp, at: env.now(), value });
      return value;
    } catch (e) {
      return { sessions: [], skipped: 0, notes: [`codex scan failed: ${clip(e && e.message, 100)}`] };
    }
  }

  return {
    tool: 'codex', label: 'Codex', toolShort: 'cx', adapterVersion: '1', experimental: true,
    async detect(env) {
      try {
        const home = codexHomeOf(env);
        if (await findStateDb(home)) return true;
        const st = await statOrNull(path.join(home, 'sessions'));
        return !!(st && st.isDirectory());
      } catch { return false; }
    },
    watchPaths(env) {
      const home = codexHomeOf(env);
      return [{ path: home, recursive: false, filter: 'state_' }, { path: path.join(home, 'sessions'), recursive: true }];
    },
    scan,
  };
}

export default createCodexAdapter();
