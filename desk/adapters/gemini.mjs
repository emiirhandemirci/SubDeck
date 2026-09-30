// desk/adapters/gemini.mjs
// Gemini CLI (Google) source adapter, experimental. Reads ~/.gemini/tmp/<project_id>/chats/session-*.jsonl (v0.39+,
// append-only: header line, message lines upserted by id, {"$set":{...}} metadata/checkpoints, {"$rewindTo":id})
// and legacy session-*.json (one object with messages[]). Whitelisted fields only; no message bodies leave this file.
// Project path: header.directories[0] -> tmp/<id>/.project_root -> projects.json / sha256(path) reverse lookup -> null
// (then projectLabel = the hash/slug directory name; the path cannot be recovered from a bare SHA-256).
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { clip } from '../lib/model.mjs';

const toIso = v => { const t = typeof v === 'number' ? v : Date.parse(v); return Number.isFinite(t) ? new Date(t).toISOString() : null; };
const num = v => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const isObj = v => v && typeof v === 'object' && !Array.isArray(v);
async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }
async function readdirSafe(p) { try { return await fs.readdir(p, { withFileTypes: true }); } catch { return []; } }
const rootOf = env => {
  const vars = env.vars || {};
  if (vars.SUBDECK_GEMINI_DIR) return vars.SUBDECK_GEMINI_DIR;
  return path.join(vars.GEMINI_CLI_HOME || env.home || '', '.gemini');
};
const tmpOf = env => path.join(rootOf(env), 'tmp');
const isSessionFile = n => /^session-.*\.jsonl?$/.test(n);

/** Reduce a message to the whitelist; content/thoughts/toolCalls[].input|result are never touched. */
function slimMessage(m) {
  if (!isObj(m) || typeof m.id !== 'string') return null;
  const tc = Array.isArray(m.toolCalls) ? m.toolCalls.filter(isObj) : [];
  const last = tc.length ? tc[tc.length - 1] : null;
  const t = isObj(m.tokens) ? m.tokens : {};
  return { id: m.id, at: toIso(m.timestamp), type: typeof m.type === 'string' ? m.type : null,
    model: typeof m.model === 'string' ? m.model : null, input: num(t.input), total: num(t.total),
    tool: last && typeof last.name === 'string' ? last.name : null };
}

function reduceRecords(records) {
  const meta = { sessionId: null, projectHash: null, startTime: null, lastUpdated: null, kind: null, directories: null, summary: null };
  const msgs = new Map();
  const applyMeta = o => {
    for (const k of ['sessionId', 'projectHash', 'startTime', 'lastUpdated', 'kind', 'summary']) if (typeof o[k] === 'string') meta[k] = o[k];
    if (Array.isArray(o.directories)) meta.directories = o.directories.filter(d => typeof d === 'string');
  };
  const upsert = m => { const s = slimMessage(m); if (s) msgs.set(s.id, s); };
  for (const r of records) {
    if (!isObj(r)) continue;
    if (isObj(r.$set)) { applyMeta(r.$set); if (Array.isArray(r.$set.messages)) r.$set.messages.forEach(upsert); }
    else if (typeof r.$rewindTo === 'string') {
      // Drop the named message and everything after it (exact upstream semantics unverified).
      let cut = false;
      for (const id of [...msgs.keys()]) { if (id === r.$rewindTo) cut = true; if (cut) msgs.delete(id); }
    } else if (typeof r.id === 'string' && 'type' in r) upsert(r);
    else if (typeof r.sessionId === 'string') { applyMeta(r); if (Array.isArray(r.messages)) r.messages.forEach(upsert); }
  }
  return { meta, messages: [...msgs.values()] };
}

async function readSession(file, st, cache) {
  const key = 'f:' + file;
  const hit = cache.get(key);
  if (hit && hit.size === st.size && hit.mtimeMs === st.mtimeMs) return hit.value;
  let bad = 0;
  let records = [];
  try {
    const raw = await fs.readFile(file, 'utf8');
    if (file.endsWith('.jsonl')) {
      for (const line of raw.split('\n')) {
        if (!line.trim()) continue;
        try { records.push(JSON.parse(line)); } catch { bad++; }
      }
    } else {
      try { records = [JSON.parse(raw)]; } catch { bad++; }
    }
  } catch { bad++; }
  const value = { ...reduceRecords(records), bad };
  cache.set(key, { size: st.size, mtimeMs: st.mtimeMs, value });
  return value;
}

async function readJson(p) { try { return JSON.parse(await fs.readFile(p, 'utf8')); } catch { return null; } }

/** hash|slug -> project path, from projects.json ({projects:{path:slug}}) when present. */
async function projectIndex(env) {
  const idx = new Map();
  const j = await readJson(path.join(rootOf(env), 'projects.json'));
  const projects = j && isObj(j.projects) ? j.projects : {};
  for (const [p, slug] of Object.entries(projects)) {
    if (typeof slug === 'string') idx.set(slug, p);
    idx.set(createHash('sha256').update(p).digest('hex'), p);
  }
  return idx;
}

async function collectFiles(chatsDir) {
  const out = [];   // { file, sub }  sub = parent directory name for files one level down (assumed parent session id)
  for (const e of await readdirSafe(chatsDir)) {
    if (e.isFile() && isSessionFile(e.name)) out.push({ file: path.join(chatsDir, e.name), sub: null });
    else if (e.isDirectory()) for (const s of await readdirSafe(path.join(chatsDir, e.name)))
      if (s.isFile() && /\.jsonl?$/.test(s.name)) out.push({ file: path.join(chatsDir, e.name, s.name), sub: e.name });
  }
  return out;
}

async function scan(env, { cache }) {
  const cutoff = env.now() - env.days * 86400000;
  let skipped = 0;
  const sessions = [];
  const index = await projectIndex(env);
  const seen = new Set();
  for (const d of await readdirSafe(tmpOf(env))) {
    if (!d.isDirectory()) continue;
    const dir = path.join(tmpOf(env), d.name);
    const files = await collectFiles(path.join(dir, 'chats'));
    if (!files.length) continue;
    let rootFile = null;
    try { rootFile = (await fs.readFile(path.join(dir, '.project_root'), 'utf8')).trim() || null; } catch { /* optional */ }
    for (const { file, sub } of files) {
      try {
        const st = await statOrNull(file);
        if (!st || st.mtimeMs < cutoff) continue;
        const r = await readSession(file, st, cache);
        skipped += r.bad;
        const m = r.meta;
        const nativeId = m.sessionId || path.basename(file).replace(/\.jsonl?$/, '');
        if (!m.sessionId && !r.messages.length) { skipped++; continue; }
        if (seen.has(nativeId)) continue;
        seen.add(nativeId);
        const projectPath = (m.directories && m.directories[0]) || rootFile || index.get(m.projectHash || d.name) || index.get(d.name) || null;
        const mt = new Date(st.mtimeMs).toISOString();
        const msgs = r.messages;
        const lastMsg = msgs.length ? msgs[msgs.length - 1] : null;
        const lastGem = [...msgs].reverse().find(x => x.type === 'gemini');
        const updated = [toIso(m.lastUpdated), lastMsg && lastMsg.at].filter(Boolean).sort().pop() || mt;
        const total = msgs.reduce((a, x) => a + (x.total || 0), 0);
        const title = clip(m.summary, 120);
        const isSub = m.kind === 'subagent';
        const parent = isSub && sub ? sub : null;
        sessions.push({
          nativeId, tool: 'gemini', parentNativeId: parent, depth: parent ? 1 : 0,
          projectPath, projectLabel: projectPath ? null : clip(d.name, 20),
          title: title || `Gemini ${nativeId.slice(0, 8)}`, titleSource: title ? 'summary' : 'fallback',
          agentType: isSub ? 'subagent' : null, model: (lastGem && lastGem.model) || null,
          createdAt: toIso(m.startTime) || (msgs[0] && msgs[0].at) || mt, updatedAt: updated, endedAt: null,
          tokens: { context: lastGem ? lastGem.input : null, total: total || null },
          lastActivity: lastMsg && lastMsg.at ? { at: lastMsg.at,
            kind: lastMsg.type === 'user' ? 'user' : lastMsg.type === 'gemini' ? (lastMsg.tool ? 'tool' : 'assistant') : 'other',
            toolName: lastMsg.type === 'gemini' ? lastMsg.tool : null, summary: null } : null,
          refs: { file, db: null, key: null }, archived: false,
          stateBasis: { kind: 'mtime', at: mt < updated ? updated : mt, stateSource: 'mtime' },
        });
      } catch { skipped++; }
    }
  }
  return { sessions, skipped, notes: [] };
}

async function detect(env) {
  try {
    for (const d of await readdirSafe(tmpOf(env)))
      if (d.isDirectory() && (await readdirSafe(path.join(tmpOf(env), d.name, 'chats'))).some(e => e.isFile() ? isSessionFile(e.name) : e.isDirectory())) return true;
  } catch { /* fall through */ }
  return false;
}

export default {
  tool: 'gemini', label: 'Gemini', toolShort: 'gm', adapterVersion: '1', experimental: true,
  detect,
  watchPaths(env) { return [{ path: tmpOf(env), recursive: true }]; },
  async scan(env, opts) {
    try { return await scan(env, { cache: (opts && opts.cache) || new Map() }); }
    catch (e) { return { sessions: [], skipped: 0, notes: ['gemini scan failed: ' + (e && e.message)] }; }
  },
};
