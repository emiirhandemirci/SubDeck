// desk/adapters/cline.mjs
// Cline + Roo Code (VS Code extensions) adapter. Read-only; files are rewritten whole, so liveness comes from mtime
// unless the last UI row is an explicit completion. Only whitelisted, non-content fields leave this file.
import fs from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { clip } from '../lib/model.mjs';

const MAX_BYTES = 40 * 1024 * 1024;
const EXT = [
  { flavor: 'cline', id: 'saoudrizwan.claude-dev' },
  { flavor: 'roo', id: 'rooveterinaryinc.roo-cline' },
];
const CODE_DIRS = ['Code', 'Code - Insiders', 'VSCodium', 'Cursor', 'Windsurf'];
const SKIP_ROWS = new Set(['api_req_started', 'api_req_finished', 'checkpoint_created']);

const num = v => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const iso = ms => (Number.isFinite(ms) ? new Date(ms).toISOString() : null);
const short = (s, n) => (typeof s === 'string' ? clip(s, n) : null);
async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }
async function readJson(p, size) {
  if (size > MAX_BYTES) return undefined;
  return JSON.parse(await fs.readFile(p, 'utf8'));
}

/** All candidate storage roots: { flavor, dir, editor }. dir holds tasks/ and state/. */
export function candidateRoots(env) {
  const vars = env.vars || {};
  const home = env.home || '';
  const j = env.platform === 'win32' ? path.win32.join : path.posix.join;
  let base = null;
  if (env.platform === 'win32') base = vars.APPDATA || env.appData || null;
  else if (env.platform === 'darwin') base = home ? j(home, 'Library', 'Application Support') : null;
  else base = vars.XDG_CONFIG_HOME || (home ? j(home, '.config') : null);
  const roots = [];
  if (base) for (const ed of CODE_DIRS) for (const x of EXT) roots.push({ flavor: x.flavor, editor: ed, dir: j(base, ed, 'User', 'globalStorage', x.id) });
  const cl = vars.CLINE_DIR || (home ? j(home, '.cline') : null);
  if (cl) roots.push({ flavor: 'cline', editor: 'cli', dir: j(cl, 'data') });
  return roots;
}

/** Whitelisted extraction from ui_messages.json (array of rows). Numbers and short enums only. */
function pickUi(rows) {
  const out = { first: null, last: null, lastRow: null, completed: false, ctx: null, total: null, tool: null };
  if (!Array.isArray(rows)) return out;
  let total = 0, seenReq = false;
  for (const r of rows) {
    if (!r || typeof r !== 'object') continue;
    const ts = num(r.ts);
    if (ts !== null) { if (out.first === null || ts < out.first) out.first = ts; if (out.last === null || ts > out.last) out.last = ts; }
    if (r.say === 'api_req_started' && typeof r.text === 'string') {
      try {
        const o = JSON.parse(r.text);
        const a = ['tokensIn', 'tokensOut', 'cacheWrites', 'cacheReads'].map(k => num(o && o[k]) || 0);
        total += a[0] + a[1] + a[2] + a[3];
        seenReq = true;
        out.ctx = a[0] + a[2] + a[3];
      } catch { /* numbers only; ignore */ }
    }
  }
  if (seenReq) out.total = total;
  const last = [...rows].reverse().find(r => r && typeof r === 'object' && (r.say || r.ask) && !SKIP_ROWS.has(r.say));
  if (last) {
    const k = last.say || last.ask;
    out.lastRow = { kind: typeof k === 'string' ? k.slice(0, 40) : null, ts: num(last.ts) };
    out.completed = last.say === 'completion_result' || last.ask === 'completion_result';
    if ((last.say === 'tool' || last.ask === 'tool') && typeof last.text === 'string') {
      try { const t = JSON.parse(last.text); if (t && typeof t.tool === 'string') out.tool = clip(t.tool, 40); } catch { /* ignore */ }
    }
  }
  return out;
}

function pickMetadata(m) {
  const mu = m && Array.isArray(m.model_usage) ? m.model_usage : [];
  const last = mu.length ? mu[mu.length - 1] : null;
  return { model: last && typeof last.model_id === 'string' ? clip(last.model_id, 80) : null };
}

function pickHistoryItem(h) {
  if (!h || typeof h !== 'object' || typeof h.id !== 'string' || !h.id) return null;
  return {
    id: h.id, ts: num(h.ts), task: short(h.task, 120),
    tokensIn: num(h.tokensIn), tokensOut: num(h.tokensOut), cacheWrites: num(h.cacheWrites), cacheReads: num(h.cacheReads),
    workspace: typeof h.workspace === 'string' ? h.workspace : (typeof h.cwdOnTaskInitialization === 'string' ? h.cwdOnTaskInitialization : null),
    mode: short(h.mode, 40), status: typeof h.status === 'string' ? h.status : null,
    parent: typeof h.parentTaskId === 'string' && h.parentTaskId ? h.parentTaskId : null,
  };
}

async function readIndex(dir) {
  const items = new Map();
  let skipped = 0;
  const p = path.join(dir, 'state', 'taskHistory.json');
  const st = await statOrNull(p);
  if (st && st.isFile()) {
    try {
      const raw = await readJson(p, st.size);
      const arr = Array.isArray(raw) ? raw : raw && Array.isArray(raw.taskHistory) ? raw.taskHistory : raw && Array.isArray(raw.history) ? raw.history : [];
      for (const e of arr) { const it = pickHistoryItem(e); if (it) items.set(it.id, it); else skipped++; }
    } catch { skipped++; }
  }
  return { items, skipped };
}

async function statTask(taskDir) {
  const files = {};
  let mt = 0;
  for (const f of ['ui_messages.json', 'api_conversation_history.json', 'task_metadata.json', 'history_item.json']) {
    const st = await statOrNull(path.join(taskDir, f));
    if (st && st.isFile()) { files[f] = st; mt = Math.max(mt, st.mtimeMs); }
  }
  if (!Object.keys(files).length) return null;
  return { files, mt, fp: Object.entries(files).map(([k, s]) => `${k}:${s.size}:${s.mtimeMs}`).join('|') };
}

async function extract(td, t) {
  let ui = pickUi(null), meta = { model: null }, hist = null, bad = false;
  try {
    const f = t.files['ui_messages.json'];
    if (f) { const v = await readJson(path.join(td, 'ui_messages.json'), f.size); if (v !== undefined) { if (Array.isArray(v)) ui = pickUi(v); else bad = true; } }
  } catch { bad = true; }
  try { const f = t.files['task_metadata.json']; if (f) meta = pickMetadata(await readJson(path.join(td, 'task_metadata.json'), f.size)); } catch { /* optional */ }
  try { const f = t.files['history_item.json']; if (f) hist = pickHistoryItem(await readJson(path.join(td, 'history_item.json'), f.size)); } catch { /* optional */ }
  return { ui, meta, hist, bad };
}

export function createClineAdapter() {
  async function scan(env, { cache }) {
    cache = cache || new Map();
    const cutoff = env.now() - env.days * 86400000;
    const sessions = [];
    let skipped = 0;
    const seen = new Set();
    for (const root of candidateRoots(env)) {
      const tasksDir = path.join(root.dir, 'tasks');
      let ids;
      try { ids = (await fs.readdir(tasksDir, { withFileTypes: true })).filter(d => d.isDirectory()).map(d => d.name); } catch { continue; }
      const { items, skipped: sk } = await readIndex(root.dir);
      skipped += sk;
      for (const id of ids) {
        const key = root.flavor + '|' + id;
        if (seen.has(key)) continue;
        seen.add(key);
        try {
          const td = path.join(tasksDir, id);
          const t = await statTask(td);
          if (!t) { skipped++; continue; }
          const ck = 'task:' + td;
          const hit = cache.get(ck);
          let ex;
          if (hit && hit.fp === t.fp) ex = hit.value;
          else { ex = await extract(td, t); cache.set(ck, { fp: t.fp, value: ex }); }
          const h = items.get(id) || ex.hist;
          if (ex.bad && !h) { skipped++; continue; }
          const updMs = Math.max(t.mt, ex.ui.last || 0);
          if (updMs < cutoff) continue;
          const idTs = /^\d{12,14}$/.test(id) ? Number(id) : null;
          const createdMs = ex.ui.first ?? idTs ?? (h && h.ts) ?? null;
          const updatedAt = iso(updMs);
          const flavorName = root.flavor === 'roo' ? 'Roo' : 'Cline';
          const title = h && h.task;
          const projectPath = h && h.workspace ? h.workspace : null;
          const completed = ex.ui.completed || (h && h.status === 'completed');
          const stateBasis = completed ? { kind: 'fixed', state: 'finished', stateSource: 'field' }
            : h && h.status === 'delegated' ? { kind: 'fixed', state: 'idle', stateSource: 'field' }
            : { kind: 'mtime', at: updatedAt, stateSource: 'mtime' };
          const lr = ex.ui.lastRow;
          const k = lr && lr.kind;
          const kind = !lr ? null : (ex.ui.tool || k === 'tool' || k === 'command') ? 'tool'
            : (k === 'user_feedback' || k === 'task') ? 'user'
            : (k === 'text' || k === 'completion_result' || k === 'followup') ? 'assistant' : 'other';
          const total = ex.ui.total ?? (h && h.tokensIn !== null && h.tokensOut !== null ? h.tokensIn + h.tokensOut + (h.cacheWrites || 0) + (h.cacheReads || 0) : null);
          sessions.push({
            nativeId: id, tool: 'cline', parentNativeId: h && h.parent ? h.parent : null, depth: h && h.parent ? 1 : 0,
            projectPath, projectLabel: projectPath ? null : `${flavorName} (no folder)`,
            title: title || `${flavorName} task ${id.slice(0, 8)}`, titleSource: title ? 'meta' : 'fallback',
            agentType: root.flavor === 'roo' && h && h.mode ? `roo/${h.mode}` : root.flavor, model: ex.meta.model,
            createdAt: iso(createdMs), updatedAt, endedAt: completed ? updatedAt : null,
            tokens: { context: ex.ui.ctx, total },
            lastActivity: lr ? { at: iso(lr.ts ?? updMs), kind, toolName: ex.ui.tool, summary: null } : null,
            refs: { file: path.join(td, 'ui_messages.json'), db: null, key: null }, archived: false, stateBasis,
          });
        } catch { skipped++; }
      }
    }
    // Depth from parent chains (Roo subtasks); dangling parents become top-level.
    const byId = new Map(sessions.map(s => [s.nativeId, s]));
    for (const s of sessions) {
      if (s.parentNativeId && !byId.has(s.parentNativeId)) { s.parentNativeId = null; s.depth = 0; continue; }
      let d = 0, cur = s;
      while (cur && cur.parentNativeId && d < 10) { cur = byId.get(cur.parentNativeId); d++; }
      s.depth = d;
    }
    return { sessions, skipped, notes: [] };
  }
  return {
    tool: 'cline', label: 'Cline/Roo', toolShort: 'cl', adapterVersion: '1', experimental: true,
    async detect(env) {
      try {
        for (const r of candidateRoots(env)) { const st = await statOrNull(path.join(r.dir, 'tasks')); if (st && st.isDirectory()) return true; }
      } catch { /* fall through */ }
      return false;
    },
    watchPaths(env) {
      const out = [];
      for (const r of candidateRoots(env)) {
        const t = path.join(r.dir, 'tasks');
        if (existsSync(t)) out.push({ path: t, recursive: true });
        const s = path.join(r.dir, 'state');
        if (existsSync(s)) out.push({ path: s, recursive: false, filter: 'taskHistory.json' });
      }
      return out;
    },
    async scan(env, opts) {
      try { return await scan(env, opts || {}); } catch { return { sessions: [], skipped: 0, notes: ['cline scan failed'] }; }
    },
  };
}

export default createClineAdapter();
