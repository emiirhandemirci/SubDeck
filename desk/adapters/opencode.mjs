// desk/adapters/opencode.mjs
// OpenCode source adapter (experimental). Reads opencode.db (SQLite) read-only and, for pre-1.2 installs,
// legacy storage/**/*.json. Only whitelisted metadata is extracted (json_extract on selected keys); message
// and part bodies (text, tool input/output) are never selected.
import fs from 'node:fs/promises';
import path from 'node:path';
import { clip, STALE_MS } from '../lib/model.mjs';

const RETRY_DELAYS = [100, 200, 400];
const LIVE_MS = STALE_MS; // an unfinished assistant message counts as running only while the session was touched this recently
const num = v => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const strOrNull = v => (typeof v === 'string' && v ? v : null);
const toIso = v => { const t = num(v); return t !== null ? new Date(t).toISOString() : null; };
const isBusy = e => e && (e.errcode === 5 || e.errcode === 6 || /busy|locked/i.test(String(e.message)));
async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }

/** xdg-basedir semantics on every platform (Windows included): $XDG_DATA_HOME or ~/.local/share, then /opencode. */
export function dataDirOf(env) {
  const p = env.platform === 'win32' ? path.win32 : path.posix;
  const vars = env.vars || process.env;
  const base = vars.XDG_DATA_HOME ? vars.XDG_DATA_HOME : p.join(env.home, '.local', 'share');
  return p.join(base, 'opencode');
}
const dbPathOf = env => (env.platform === 'win32' ? path.win32 : path.posix).join(dataDirOf(env), 'opencode.db');
const storageOf = env => (env.platform === 'win32' ? path.win32 : path.posix).join(dataDirOf(env), 'storage');

/** OpenCode stores Windows paths with forward slashes; show them natively. */
function displayPath(p, platform) {
  const s = strOrNull(p);
  if (!s) return null;
  return platform === 'win32' && /^[A-Za-z]:\//.test(s) ? s.replace(/\//g, '\\') : s;
}

/** Whitelisted facts of one assistant/user message, from selected JSON keys only. */
function pickMsg(m) {
  if (!m) return null;
  const tk = { input: num(m.tIn), output: num(m.tOut), reasoning: num(m.tReason), read: num(m.tRead), write: num(m.tWrite), total: num(m.tTotal) };
  const sum = (...k) => { const v = k.map(x => tk[x]).filter(x => x !== null); return v.length ? v.reduce((a, b) => a + b, 0) : null; };
  return {
    role: m.role === 'user' || m.role === 'assistant' ? m.role : null,
    created: num(m.created), completed: num(m.completed),
    errorName: strOrNull(m.errName), finish: strOrNull(m.finish),
    modelID: strOrNull(m.modelID), providerID: strOrNull(m.providerID),
    context: sum('input', 'read', 'write'),
    total: tk.total ?? sum('input', 'output', 'reasoning', 'read', 'write'),
  };
}

const MSG_SQL = `SELECT json_extract(data,'$.role') AS role, json_extract(data,'$.time.created') AS created, json_extract(data,'$.time.completed') AS completed,
  json_extract(data,'$.error.name') AS errName, json_extract(data,'$.finish') AS finish, json_extract(data,'$.modelID') AS modelID, json_extract(data,'$.providerID') AS providerID,
  json_extract(data,'$.tokens.input') AS tIn, json_extract(data,'$.tokens.output') AS tOut, json_extract(data,'$.tokens.reasoning') AS tReason,
  json_extract(data,'$.tokens.cache.read') AS tRead, json_extract(data,'$.tokens.cache.write') AS tWrite, json_extract(data,'$.tokens.total') AS tTotal,
  time_created AS tc FROM message WHERE session_id = ? AND json_valid(data)`;

function readDb(conn, env) {
  const cutoff = env.now() - env.days * 86400000;
  const cols = new Set(conn.prepare('PRAGMA table_info(session)').all().map(c => c.name));
  if (!cols.has('id') || !cols.has('time_updated')) throw new Error('unrecognised OpenCode session schema');
  const c = n => (cols.has(n) ? n : `NULL AS ${n}`);
  const mj = k => (cols.has('model') ? `json_extract(CASE WHEN json_valid(model) THEN model END, '$.${k}')` : 'NULL');
  const mid = mj('id'), mpr = mj('providerID');
  const sessions = conn.prepare(`SELECT id, ${c('project_id')}, ${c('parent_id')}, ${c('directory')}, ${c('title')}, ${c('agent')},
    ${mid} AS modelId, ${mpr} AS modelProvider,
    ${c('tokens_input')}, ${c('tokens_output')}, ${c('tokens_reasoning')}, ${c('tokens_cache_read')}, ${c('tokens_cache_write')},
    ${c('time_created')}, time_updated, ${c('time_archived')} FROM session WHERE time_updated >= ?`).all(cutoff);
  const projects = new Map();
  try { for (const p of conn.prepare('SELECT id, worktree, name FROM project').all()) projects.set(p.id, p); } catch { /* project table optional */ }
  const lastAny = conn.prepare(MSG_SQL + ' ORDER BY time_created DESC, id DESC LIMIT 1');
  const lastAsst = conn.prepare(MSG_SQL + " AND json_extract(data,'$.role') = 'assistant' ORDER BY time_created DESC, id DESC LIMIT 1");
  let lastTool = null;
  try { lastTool = conn.prepare("SELECT json_extract(data,'$.tool') AS tool, time_created AS tc FROM part WHERE session_id = ? AND json_valid(data) AND json_extract(data,'$.type') = 'tool' ORDER BY time_created DESC, id DESC LIMIT 1"); } catch { /* part table optional */ }
  const rows = [];
  let skipped = 0;
  for (const s of sessions) {
    try {
      if (typeof s.id !== 'string' || !s.id) throw new Error('no id');
      const any = pickMsg(lastAny.get(s.id));
      const asst = pickMsg(lastAsst.get(s.id));
      let tool = null;
      if (any && any.role === 'assistant' && any.completed === null && !any.errorName) { const t = lastTool && lastTool.get(s.id); tool = t && strOrNull(t.tool) ? { name: t.tool, at: num(t.tc) } : null; }
      const p = projects.get(s.project_id) || null;
      const tin = ['tokens_input', 'tokens_output', 'tokens_reasoning', 'tokens_cache_read', 'tokens_cache_write'].map(k => num(s[k]));
      const tokTotal = tin.some(v => v !== null) ? tin.reduce((a, v) => a + (v || 0), 0) : null;
      rows.push({
        id: s.id, parentId: strOrNull(s.parent_id), directory: strOrNull(s.directory) || (p && strOrNull(p.worktree)), projectName: p && strOrNull(p.name),
        title: strOrNull(s.title), agent: strOrNull(s.agent), model: strOrNull(s.modelId) || (asst && asst.modelID),
        created: num(s.time_created), updated: num(s.time_updated), archived: num(s.time_archived) !== null,
        any, asst, tool, tokTotal: tokTotal && tokTotal > 0 ? tokTotal : null, key: 'session:' + s.id,
      });
    } catch { skipped++; }
  }
  return { rows, skipped };
}

// ---- legacy storage/**/*.json (before OpenCode 1.2) ----
async function readJson(f) { return JSON.parse(await fs.readFile(f, 'utf8')); }

async function legacyLastMsgs(dir) {
  let names;
  try { names = (await fs.readdir(dir)).filter(n => n.endsWith('.json')).sort(); } catch { return { any: null, asst: null }; }
  let any = null, asst = null;
  for (let i = names.length - 1; i >= 0 && i >= names.length - 12 && !(any && asst); i--) {
    try {
      const o = await readJson(path.join(dir, names[i]));
      const tk = o.tokens && typeof o.tokens === 'object' ? o.tokens : {};
      const cache = tk.cache && typeof tk.cache === 'object' ? tk.cache : {};
      const m = pickMsg({ role: o.role, created: o.time && o.time.created, completed: o.time && o.time.completed, errName: o.error && o.error.name, finish: o.finish,
        modelID: o.modelID ?? (o.model && o.model.modelID), providerID: o.providerID ?? (o.model && o.model.providerID),
        tIn: tk.input, tOut: tk.output, tReason: tk.reasoning, tRead: cache.read, tWrite: cache.write, tTotal: tk.total });
      if (!any) any = m;
      if (!asst && m.role === 'assistant') asst = m;
    } catch { /* unreadable message file is skipped */ }
  }
  return { any, asst };
}

async function readLegacy(env, cache, seen) {
  const root = storageOf(env);
  const cutoff = env.now() - env.days * 86400000;
  const sessDir = path.join(root, 'session');
  const rows = [];
  let skipped = 0;
  let projDirs;
  try { projDirs = await fs.readdir(sessDir, { withFileTypes: true }); } catch { return { rows, skipped, sig: '' }; }
  const sigParts = [];
  for (const pd of projDirs) {
    if (!pd.isDirectory()) continue;
    let files;
    try { files = (await fs.readdir(path.join(sessDir, pd.name))).filter(n => n.endsWith('.json')); } catch { continue; }
    for (const fn of files) {
      const f = path.join(sessDir, pd.name, fn);
      const st = await statOrNull(f);
      if (!st) continue;
      const sid = fn.slice(0, -5);
      const mdir = path.join(root, 'message', sid);
      const mst = await statOrNull(mdir);
      const sig = [st.size, st.mtimeMs, mst && mst.mtimeMs].join('|');
      sigParts.push(f + sig);
      if (seen.has(sid)) continue;
      const hit = cache.get('lg:' + f);
      let row = hit && hit.sig === sig ? hit.row : undefined;
      if (row === undefined) {
        try {
          const o = await readJson(f);
          const t = o.time && typeof o.time === 'object' ? o.time : {};
          if (typeof o.id !== 'string' || !o.id) throw new Error('no id');
          const { any, asst } = await legacyLastMsgs(mdir);
          let pw = null;
          try { const pj = await readJson(path.join(root, 'project', pd.name + '.json')); pw = strOrNull(pj.worktree); } catch { /* project file optional */ }
          row = { id: o.id, parentId: strOrNull(o.parentID), directory: strOrNull(o.directory) || pw, projectName: null, title: strOrNull(o.title), agent: null,
            model: asst && asst.modelID, created: num(t.created), updated: num(t.updated) ?? st.mtimeMs, archived: num(t.archived) !== null,
            any, asst, tool: null, tokTotal: asst && asst.total && asst.total > 0 ? asst.total : null, key: null, file: f };
        } catch { row = null; }
        cache.set('lg:' + f, { sig, row });
      }
      if (row === null) { skipped++; continue; }
      if (row.updated >= cutoff) rows.push(row);
    }
  }
  return { rows, skipped, sig: sigParts.join(';') };
}

function toSession(r, env, refs) {
  const now = env.now();
  const updatedMs = Math.max(...[r.updated, r.created, r.any && r.any.created].filter(Number.isFinite));
  const updatedAt = Number.isFinite(updatedMs) ? toIso(updatedMs) : null;
  const projectPath = displayPath(r.directory, env.platform);
  const a = r.any;
  const fresh = Number.isFinite(updatedMs) && now - updatedMs < LIVE_MS;
  let stateBasis;
  let endedAt = null;
  if (a && a.role === 'assistant' && a.completed === null && !a.errorName && fresh) stateBasis = { kind: 'fixed', state: 'running', stateSource: 'field' };
  else if (a && a.role === 'assistant' && a.errorName && a.errorName !== 'MessageAbortedError' && a.errorName !== 'AbortError') {
    stateBasis = { kind: 'fixed', state: 'failed', stateSource: 'field' }; endedAt = toIso(a.completed) || updatedAt;
  } else stateBasis = { kind: 'mtime', at: updatedAt, stateSource: 'mtime' };
  const lastAt = toIso(a && (a.completed ?? a.created));
  const lastActivity = a && a.role && lastAt
    ? { at: r.tool && r.tool.at ? toIso(r.tool.at) : lastAt, kind: r.tool ? 'tool' : a.role, toolName: r.tool ? clip(r.tool.name, 60) : null, summary: null } : null;
  const title = clip(r.title, 120);
  const generic = !title || /^(new session|child session) - \d{4}-\d{2}-\d{2}t/i.test(title);
  const parent = r.parentId;
  return {
    nativeId: r.id, tool: 'opencode', parentNativeId: parent, depth: parent ? 1 : 0,
    projectPath: projectPath || null, projectLabel: projectPath ? null : 'OpenCode (no folder)',
    title: title || `OpenCode ${r.id.slice(0, 12)}`, titleSource: title && !generic ? 'explicit' : 'fallback',
    agentType: clip(r.agent, 40) || (parent ? 'subagent' : 'build'), model: clip(r.model, 80),
    createdAt: toIso(r.created), updatedAt, endedAt,
    tokens: { context: r.asst ? r.asst.context : null, total: r.tokTotal }, lastActivity,
    refs: refs(r), archived: r.archived, stateBasis,
  };
}

export function createOpenCodeAdapter({ loadSqlite = () => import('node:sqlite'), sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  async function scan(env, { cache }) {
    const dbPath = dbPathOf(env);
    const st = await statOrNull(dbPath);
    const wal = await statOrNull(dbPath + '-wal');
    let notes = [];
    const sessions = [];
    let skipped = 0;
    const seen = new Set();
    const dbSig = [st && st.size, st && st.mtimeMs, wal && wal.size, wal && wal.mtimeMs, env.days].join('|');
    let dbPart = null;
    if (st && st.isFile()) {
      const hit = cache.get('db');
      if (hit && hit.sig === dbSig) dbPart = hit.value;
      else {
        let mod;
        try { mod = await loadSqlite(); } catch { throw new Error('node:sqlite unavailable (Node >= 22.13 required)'); }
        let read;
        for (let attempt = 0; ; attempt++) {
          let conn = null;
          try { conn = new mod.DatabaseSync(dbPath, { readOnly: true }); read = readDb(conn, env); break; }
          catch (e) {
            if (!isBusy(e) || attempt >= RETRY_DELAYS.length) throw e;
            await sleep(RETRY_DELAYS[attempt]);
          } finally { if (conn) { try { conn.close(); } catch { /* already closed */ } } }
        }
        dbPart = read;
        cache.set('db', { sig: dbSig, value: read });
      }
      for (const r of dbPart.rows) { seen.add(r.id); sessions.push(toSession(r, env, x => ({ file: null, db: dbPath, key: x.key }))); }
      skipped += dbPart.skipped;
    }
    const lg = await readLegacy(env, cache, seen);
    skipped += lg.skipped;
    for (const r of lg.rows) sessions.push(toSession(r, env, x => ({ file: x.file, db: null, key: null })));
    if (lg.rows.length) notes = ['legacy storage json included'];
    return { sessions, skipped, notes };
  }
  return {
    tool: 'opencode', label: 'OpenCode', toolShort: 'oc', adapterVersion: '1', experimental: true,
    async detect(env) {
      const st = await statOrNull(dbPathOf(env));
      if (st && st.isFile()) return true;
      const ls = await statOrNull(path.join(storageOf(env), 'session'));
      return !!(ls && ls.isDirectory());
    },
    watchPaths(env) {
      return [{ path: dataDirOf(env), recursive: false, filter: 'opencode.db' }, { path: path.join(storageOf(env), 'session'), recursive: true }];
    },
    scan,
  };
}

export default createOpenCodeAdapter();
