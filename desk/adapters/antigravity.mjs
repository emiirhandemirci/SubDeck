// desk/adapters/antigravity.mjs
// Antigravity (Google) source adapter, experimental, tier 1. Root: ANTIGRAVITY_HOME || ~/.gemini/antigravity.
// Sessions = conversations/<uuid>.db files (id = uuid, updatedAt = newest mtime of the .db and its -wal). When
// conversation_summaries.db has a row for the id it adds title, workspace, status, step count and sub-agent links;
// the index can lag behind, so a session without a row still shows (project "unknown", title = "Antigravity <id8>").
// Read-only: node:sqlite with readOnly, whitelisted summary columns only (never preview or the FTS tables), nothing is
// written under the root, no conversation content is read, stored or cached. Protobuf blobs are not decoded in this
// tier, so model and tokens are unknown. antigravity-ide (stale copy) and antigravity-acp (shells) are ignored.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { clip } from '../lib/model.mjs';

async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }
async function readdirSafe(p) { try { return await fs.readdir(p, { withFileTypes: true }); } catch { return []; } }
const rootOf = env => {
  const vars = env.vars || {};
  return vars.ANTIGRAVITY_HOME || path.join(env.home || '', '.gemini', 'antigravity');
};
const convDirOf = env => path.join(rootOf(env), 'conversations');
const summariesOf = env => path.join(rootOf(env), 'conversation_summaries.db');
const isConvFile = n => /^[^.].*\.db$/.test(n);
const iso = ms => new Date(ms).toISOString();
const strOrNull = v => (typeof v === 'string' && v ? v : null);

/** First workspace file URI -> local path; null when empty or unparsable. */
function workspacePath(json) {
  let arr;
  try { arr = JSON.parse(json); } catch { return null; }
  const uri = Array.isArray(arr) ? arr.find(u => typeof u === 'string' && u) : null;
  if (!uri) return null;
  try { return fileURLToPath(uri); }
  catch {
    try { return decodeURIComponent(uri.replace(/^file:(\/\/)?/, '')) || null; } catch { return null; }
  }
}

/** id -> whitelisted summary fields; empty map when the index is missing or unreadable. */
function readSummaries(mod, file) {
  const map = new Map();
  let conn = null;
  try {
    conn = new mod.DatabaseSync(file, { readOnly: true });
    const rows = conn.prepare('SELECT conversation_id, title, workspace_uris, status, step_count, agent_name, parent_conversation_id, nesting_depth FROM conversation_summaries').all();
    for (const r of rows) if (typeof r.conversation_id === 'string') map.set(r.conversation_id, {
      title: strOrNull(r.title), workspace: typeof r.workspace_uris === 'string' ? r.workspace_uris : null, status: strOrNull(r.status),
      steps: typeof r.step_count === 'number' ? r.step_count : null, agent: strOrNull(r.agent_name),
      parent: strOrNull(r.parent_conversation_id), depth: typeof r.nesting_depth === 'number' ? r.nesting_depth : 0,
    });
  } catch { /* missing, locked or different schema: sessions still show without enrichment */ }
  finally { if (conn) { try { conn.close(); } catch { /* already closed */ } } }
  return map;
}

function toSession(id, file, st, wal, sum, summariesFile, now) {
  const mt = Math.max(st.mtimeMs, wal ? wal.mtimeMs : 0);
  const birth = st.birthtimeMs > 0 ? st.birthtimeMs : st.mtimeMs;
  const updatedAt = iso(mt);
  const title = sum && clip(sum.title, 120);
  const projectPath = sum && sum.workspace ? workspacePath(sum.workspace) : null;
  const parent = sum && sum.parent ? sum.parent : null;
  let stateBasis = { kind: 'mtime', at: updatedAt, stateSource: 'mtime' };
  let lastActivity = null;
  if (sum && sum.status) {
    if (sum.status === 'CASCADE_RUN_STATUS_IDLE') {
      stateBasis = { kind: 'fixed', state: now - mt < 1800000 ? 'idle' : 'finished', stateSource: 'field' };
    } else {
      // Unknown enum value: show the raw word, never guess a state.
      stateBasis = { kind: 'fixed', state: 'unknown', stateSource: 'field' };
      lastActivity = { at: updatedAt, kind: 'other', toolName: null, summary: clip('status ' + sum.status, 80) };
    }
  }
  return {
    nativeId: id, tool: 'antigravity', parentNativeId: parent, depth: parent ? Math.max(1, sum.depth || 1) : 0,
    projectPath, projectLabel: projectPath ? null : 'unknown',
    title: title || `Antigravity ${id.slice(0, 8)}`, titleSource: title ? 'summary' : 'fallback',
    agentType: sum && sum.agent ? clip(sum.agent, 40) : null, model: null,
    createdAt: iso(Math.min(birth, mt)), updatedAt, endedAt: null,
    tokens: { context: null, total: null }, lastActivity,
    refs: { file, db: sum ? summariesFile : null, key: null }, archived: false,
    stateBasis,
  };
}

export function createAntigravityAdapter({ loadSqlite = () => import('node:sqlite') } = {}) {
  async function scan(env, { cache }) {
    let mod;
    try { mod = await loadSqlite(); if (!mod || !mod.DatabaseSync) throw new Error('no DatabaseSync'); }
    catch { return { sessions: [], skipped: 0, notes: ['antigravity unavailable: node:sqlite requires Node >= 22.5'] }; }
    const cutoff = env.now() - env.days * 86400000;
    const dir = convDirOf(env);
    const sFile = summariesOf(env);
    const sSt = await statOrNull(sFile);
    const sWal = await statOrNull(sFile + '-wal');
    let summaries = new Map();
    if (sSt && sSt.isFile()) {
      const sig = [sSt.size, sSt.mtimeMs, sWal && sWal.size, sWal && sWal.mtimeMs].join('|');
      const hit = cache.get('antigravity:summaries');
      if (hit && hit.sig === sig) summaries = hit.value;
      else { summaries = readSummaries(mod, sFile); cache.set('antigravity:summaries', { sig, value: summaries }); }
    }
    const sessions = [];
    let skipped = 0;
    for (const e of await readdirSafe(dir)) {
      if (!e.isFile() || !isConvFile(e.name)) continue;
      try {
        const file = path.join(dir, e.name);
        const st = await statOrNull(file);
        if (!st) continue;
        const wal = await statOrNull(file + '-wal');
        if (Math.max(st.mtimeMs, wal ? wal.mtimeMs : 0) < cutoff) continue;
        const id = e.name.slice(0, -3);
        sessions.push(toSession(id, file, st, wal, summaries.get(id) || null, sFile, env.now()));
      } catch { skipped++; }
    }
    return { sessions, skipped, notes: sSt ? [] : ['conversation_summaries.db not found: titles and projects unavailable'] };
  }
  return {
    tool: 'antigravity', label: 'Antigravity', toolShort: 'ag', adapterVersion: '1', experimental: true,
    async detect(env) {
      try { const m = await loadSqlite(); if (!m || !m.DatabaseSync) return false; } catch { return false; }
      return (await readdirSafe(convDirOf(env))).some(e => e.isFile() && isConvFile(e.name));
    },
    watchPaths(env) { return [{ path: convDirOf(env), recursive: false }]; },
    async scan(env, opts) {
      try { return await scan(env, { cache: (opts && opts.cache) || new Map() }); }
      catch (e) { return { sessions: [], skipped: 0, notes: ['antigravity scan failed: ' + (e && e.message)] }; }
    },
  };
}

export default createAntigravityAdapter();
