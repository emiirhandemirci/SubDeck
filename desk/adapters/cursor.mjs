// desk/adapters/cursor.mjs
// Cursor source adapter (spec 5.2). Opens state.vscdb read-only; extracts whitelisted fields only.
import fs from 'node:fs/promises';
import path from 'node:path';
import { clip, STALE_MS } from '../lib/model.mjs';
import { fileUriToPath } from '../lib/paths.mjs';

const RETRY_DELAYS = [100, 200, 400];
const toIso = v => { const t = typeof v === 'number' ? v : Date.parse(v); return Number.isFinite(t) ? new Date(t).toISOString() : null; };
const text = v => (v === null || v === undefined ? null : typeof v === 'string' ? v : Buffer.from(v).toString('utf8'));
const isBusy = e => e && (e.errcode === 5 || e.errcode === 6 || /busy|locked/i.test(String(e.message)));
async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }
const trackingPathOf = env => path.join(env.home, '.cursor', 'ai-tracking', 'ai-code-tracking.db');
const dbPathOf = env => path.join(env.cursorUserDir, 'globalStorage', 'state.vscdb');

/** Whitelist: nothing else from composerData leaves this function. */
function pickComposer(o) {
  const arr = v => (Array.isArray(v) ? v : []);
  const fh = arr(o.fullConversationHeadersOnly);
  const last = fh.length ? fh[fh.length - 1] : null;
  return {
    status: typeof o.status === 'string' ? o.status : null,
    generating: arr(o.generatingBubbleIds).length,
    modelName: o.modelConfig && typeof o.modelConfig.modelName === 'string' ? o.modelConfig.modelName : null,
    subIds: [...arr(o.subagentComposerIds), ...arr(o.subComposerIds)].filter(x => typeof x === 'string'),
    context: Number.isFinite(o.contextTokensUsed) ? o.contextTokensUsed
      : (o.promptTokenBreakdown && Number.isFinite(o.promptTokenBreakdown.totalUsedTokens) ? o.promptTokenBreakdown.totalUsedTokens : null),
    lastUpdatedAt: Number.isFinite(o.lastUpdatedAt) ? o.lastUpdatedAt : null,
    name: typeof o.name === 'string' ? o.name : null,
    last: last && typeof last === 'object' ? { bubbleId: typeof last.bubbleId === 'string' ? last.bubbleId : null, type: last.type,
      at: last.completedAtMs ?? last.startedAtMs ?? last.createdAt ?? null } : null,
  };
}

function pickHeader(hv) {
  const uri = hv.workspaceIdentifier && hv.workspaceIdentifier.uri;
  return { name: typeof hv.name === 'string' ? hv.name : null, subtitle: typeof hv.subtitle === 'string' ? hv.subtitle : null,
    blocking: hv.hasBlockingPendingActions === true,
     unifiedMode: typeof hv.unifiedMode === 'string' ? hv.unifiedMode : null,
    fsPath: uri && typeof uri.fsPath === 'string' ? uri.fsPath : null, lastUpdatedAt: Number.isFinite(hv.lastUpdatedAt) ? hv.lastUpdatedAt : null };
}

async function workspacePath(env, workspaceId, memo) {
  if (!workspaceId) return null;
  if (memo.has(workspaceId)) return memo.get(workspaceId);
  let p = null;
  try {
    const w = JSON.parse(await fs.readFile(path.join(env.cursorUserDir, 'workspaceStorage', workspaceId, 'workspace.json'), 'utf8'));
    if (typeof w.folder === 'string') p = fileUriToPath(w.folder, env.platform);
    else if (typeof w.workspace === 'string') { const f = fileUriToPath(w.workspace, env.platform); p = f ? path.dirname(f) : null; }
  } catch { p = null; }
  memo.set(workspaceId, p);
  return p;
}

/** Newest bubble of a composer whose header list is empty. Reads type / createdAt / tool name only, never text fields.
 *  One indexed key-range query per such composer. */
function newestBubble(conn, composerId) {
  try {
    const rows = conn.prepare(`SELECT key, json_extract(value, '$.type') AS t, json_extract(value, '$.createdAt') AS c, json_extract(value, '$.toolFormerData.name') AS n
      FROM cursorDiskKV WHERE key >= ? AND key < ?`).all(`bubbleId:${composerId}:`, `bubbleId:${composerId};`);
    let best = null, bestAt = -Infinity;
    for (const r of rows) {
      const at = typeof r.c === 'number' ? r.c : Date.parse(r.c);
      if (!Number.isFinite(at)) continue;
      if (at > bestAt) { bestAt = at; best = { bubbleId: String(r.key).slice(`bubbleId:${composerId}:`.length), type: r.t, at, name: typeof r.n === 'string' ? r.n : null }; }
    }
    return best;
  } catch { return null; }
}

/** Optional read-only lookup of AI-generated conversation titles in Cursor's tracking DB; any error yields an empty map. */
async function trackingTitles(mod, env) {
  const out = new Map();
  if (!env.home) return out;
  const p = trackingPathOf(env);
  if (!(await statOrNull(p))) return out;
  let conn = null;
  try {
    conn = new mod.DatabaseSync(p, { readOnly: true });
    for (const r of conn.prepare('SELECT conversationId, title FROM conversation_summaries').all()) {
      if (typeof r.conversationId === 'string' && typeof r.title === 'string' && r.title.trim()) out.set(r.conversationId, r.title);
    }
  } catch { /* optional source */ } finally { if (conn) { try { conn.close(); } catch { /* already closed */ } } }
  return out;
}

function readRows(conn, env) {
  const cutoff = env.now() - env.days * 86400000;
  const headers = conn.prepare('SELECT composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, isSubagent, recency, subagentTypeName, value FROM composerHeaders WHERE COALESCE(recency, lastUpdatedAt, createdAt, 0) >= ?').all(cutoff);
  const kv = conn.prepare('SELECT value FROM cursorDiskKV WHERE key = ?');
  const rows = [];
  let skipped = 0;
  for (const h of headers) {
    try {
      const hv = pickHeader(JSON.parse(text(h.value) || '{}'));
      const raw = kv.get('composerData:' + h.composerId);
      const cd = raw ? pickComposer(JSON.parse(text(raw.value))) : pickComposer({});
      let toolName = null;
      if (!cd.last) {
        const nb = newestBubble(conn, h.composerId);
        if (nb) {
          cd.last = { bubbleId: nb.bubbleId, type: nb.type, at: nb.at };
          if (cd.generating > 0 && nb.type === 2) toolName = nb.name;
        }
      } else if (cd.generating > 0 && cd.last && cd.last.type === 2 && cd.last.bubbleId) {
        const b = kv.get(`bubbleId:${h.composerId}:${cd.last.bubbleId}`);
        if (b) { try { const o = JSON.parse(text(b.value)); toolName = o.toolFormerData && typeof o.toolFormerData.name === 'string' ? o.toolFormerData.name : null; } catch { /* body ignored */ } }
      }
      rows.push({ h: { composerId: h.composerId, workspaceId: h.workspaceId, createdAt: h.createdAt, lastUpdatedAt: h.lastUpdatedAt,
        isArchived: h.isArchived, isSubagent: h.isSubagent, recency: h.recency, subagentTypeName: h.subagentTypeName }, hv, cd, toolName });
    } catch { skipped++; }
  }
  return { rows, skipped };
}

export function createCursorAdapter({ loadSqlite = () => import('node:sqlite'), sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  async function scan(env, { cache }) {
    const dbPath = dbPathOf(env);
    const st = await statOrNull(dbPath);
    const tst = env.home ? await statOrNull(trackingPathOf(env)) : null;
    const wal = await statOrNull(dbPath + '-wal');
    const fp = [st && st.size, st && st.mtimeMs, wal && wal.size, wal && wal.mtimeMs, tst && tst.size, tst && tst.mtimeMs, env.days].join('|');
    const hit = cache.get('result');
    if (hit && hit.fp === fp) return hit.value;
    let mod;
    try { mod = await loadSqlite(); } catch { throw new Error('node:sqlite unavailable (Node >= 22.13 required)'); }
    let read;
    for (let attempt = 0; ; attempt++) {
      let conn = null;
      try {
        conn = new mod.DatabaseSync(dbPath, { readOnly: true });
        read = readRows(conn, env);
        break;
      } catch (e) {
        if (!isBusy(e) || attempt >= RETRY_DELAYS.length) throw e;
        await sleep(RETRY_DELAYS[attempt]);
      } finally { if (conn) { try { conn.close(); } catch { /* already closed */ } } }
    }
    const tracked = await trackingTitles(mod, env);
    const parentOf = new Map();
    for (const r of read.rows) for (const id of r.cd.subIds) parentOf.set(id, r.h.composerId);
    const memo = new Map();
    const sessions = [];
    for (const { h, hv, cd, toolName } of read.rows) {
      const projectPath = hv.fsPath || await workspacePath(env, h.workspaceId, memo);
      const updatedMs = Math.max(...[h.lastUpdatedAt, cd.lastUpdatedAt, h.recency, hv.lastUpdatedAt,
        cd.last && (typeof cd.last.at === 'number' ? cd.last.at : Date.parse(cd.last.at)), h.createdAt].filter(Number.isFinite));
      const updatedAt = Number.isFinite(updatedMs) ? new Date(updatedMs).toISOString() : null;
      const name = clip(cd.name || hv.name, 120);
      const sub = name ? null : clip(hv.subtitle || tracked.get(h.composerId), 120);
      const mode = hv.unifiedMode || 'chat';
      const parent = parentOf.get(h.composerId) || null;
      const stateBasis = hv.blocking ? { kind: 'waiting', at: updatedAt, stateSource: 'field', fallbackAt: updatedAt }
        : cd.generating > 0 && Number.isFinite(updatedMs) && env.now() - updatedMs < STALE_MS ? { kind: 'fixed', state: 'running', stateSource: 'field' }
        : cd.status === 'completed' ? { kind: 'fixed', state: 'finished', stateSource: 'field' }
        : { kind: 'mtime', at: updatedAt, stateSource: 'mtime' };
      const lastActivity = cd.last && (cd.last.type === 1 || cd.last.type === 2)
        ? { at: toIso(cd.last.at), kind: toolName ? 'tool' : cd.last.type === 1 ? 'user' : 'assistant', toolName, summary: null } : null;
      sessions.push({
        nativeId: h.composerId, tool: 'cursor', parentNativeId: parent, depth: parent ? 1 : 0,
        projectPath: projectPath || null, projectLabel: projectPath ? null : 'Cursor (no folder)',
        title: name || sub || `Cursor ${mode} ${h.composerId.slice(0, 8)}`, titleSource: name ? 'explicit' : sub ? 'summary' : 'fallback',
        agentType: (h.subagentTypeName && String(h.subagentTypeName)) || mode, model: cd.modelName,
        createdAt: toIso(h.createdAt), updatedAt, endedAt: cd.status === 'completed' ? updatedAt : null,
        tokens: { context: cd.context, total: null }, lastActivity,
        refs: { file: null, db: dbPath, key: 'composerData:' + h.composerId }, archived: h.isArchived === 1, stateBasis,
      });
    }
    const value = { sessions, skipped: read.skipped, notes: [] };
    cache.set('result', { fp, value });
    return value;
  }
  return {
    tool: 'cursor', label: 'Cursor', toolShort: 'cursor', adapterVersion: '1',
    async detect(env) { if (!env.cursorUserDir) return false; const st = await statOrNull(dbPathOf(env)); return !!(st && st.isFile()); },
    watchPaths(env) { return [{ path: path.join(env.cursorUserDir, 'globalStorage'), recursive: false, filter: 'state.vscdb' }]; },
    scan,
  };
}

export default createCursorAdapter();
