// desk/adapters/claude-code.mjs
// Claude Code source adapter (spec 5.1). Reads transcript heads/tails only; keeps no message bodies.
import fs from 'node:fs/promises';
import path from 'node:path';
import { clip } from '../lib/model.mjs';
import { projectKey } from '../lib/paths.mjs';

export const HEAD_BYTES = 65536;
export const TAIL_BYTES = 65536;
export const TAIL_MAX_BYTES = 262144;

export function parseJsonl(text, { dropFirst = false } = {}) {
  const parts = text.split('\n');
  if (dropFirst) parts.shift();
  const complete = text.endsWith('\n');
  const records = [];
  let bad = 0;
  parts.forEach((raw, i) => {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (!line.trim()) return;
    try {
      const o = JSON.parse(line);
      if (o && typeof o === 'object') records.push(o);
    } catch {
      if (!(i === parts.length - 1 && !complete)) bad++;   // a line still being written is not malformed
    }
  });
  return { records, bad };
}

const toIso = v => { const t = typeof v === 'number' ? v : Date.parse(v); return Number.isFinite(t) ? new Date(t).toISOString() : null; };

function usageSum(u) {
  if (!u || typeof u !== 'object') return null;
  const n = k => (Number.isFinite(u[k]) ? u[k] : 0);
  const t = n('input_tokens') + n('cache_read_input_tokens') + n('cache_creation_input_tokens') + n('output_tokens');
  return t > 0 ? t : null;
}

const firstLine = s => String(s).split('\n').find(l => l.trim()) || '';

function assistantActivity(r) {
  const c = r.message.content;
  const at = toIso(r.timestamp);
  if (typeof c === 'string') return { at, kind: 'assistant', toolName: null, summary: clip(firstLine(c), 80) };
  if (!Array.isArray(c) || !c.length) return null;
  const last = c[c.length - 1];
  if (last && last.type === 'tool_use') {
    const arg = last.input && typeof last.input === 'object' ? Object.values(last.input).find(v => typeof v === 'string') : undefined;
    const name = typeof last.name === 'string' ? last.name : null;
    return { at, kind: 'tool', toolName: name, summary: clip([name, arg].filter(Boolean).join(' '), 80) };
  }
  if (last && last.type === 'text') return { at, kind: 'assistant', toolName: null, summary: clip(firstLine(last.text || ''), 80) };
  return { at, kind: 'assistant', toolName: null, summary: null };
}

function userActivity(r) {
  if (r.isMeta) return null;
  const c = r.message.content;
  const at = toIso(r.timestamp);
  if (Array.isArray(c) && c.some(b => b && b.type === 'tool_result')) return { at, kind: 'tool', toolName: null, summary: null };
  return { at, kind: 'user', toolName: null, summary: null };   // user prompts are never summarized
}

export function summarizeRecords(records) {
  const out = { tokens: null, model: null, customTitle: null, aiTitle: null, lastActivity: null };
  for (const r of records) {
    if (r.type === 'custom-title' && typeof r.customTitle === 'string' && r.customTitle.trim()) out.customTitle = r.customTitle;
    else if (r.type === 'ai-title' && typeof r.aiTitle === 'string' && r.aiTitle.trim()) out.aiTitle = r.aiTitle;
    else if (r.type === 'assistant' && r.message && typeof r.message === 'object') {
      const t = usageSum(r.message.usage);
      if (t !== null) out.tokens = t;
      if (typeof r.message.model === 'string') out.model = r.message.model;
      const a = assistantActivity(r);
      if (a) out.lastActivity = a;
    } else if (r.type === 'user' && r.message && typeof r.message === 'object') {
      const a = userActivity(r);
      if (a) out.lastActivity = a;
    }
  }
  return out;
}

async function readRange(file, start, length) {
  const fh = await fs.open(file, 'r');
  try {
    const buf = Buffer.alloc(length);
    const { bytesRead } = await fh.read(buf, 0, length, start);
    return buf.subarray(0, bytesRead).toString('utf8');
  } finally { await fh.close(); }
}

async function readOnce(file, size, tailBytes) {
  const headLen = Math.min(size, HEAD_BYTES);
  const headText = await readRange(file, 0, headLen);
  const head = parseJsonl(headText);
  const tailText = size <= headLen ? headText : await readRange(file, Math.max(0, size - tailBytes), Math.min(size, tailBytes));
  const tail = size <= headLen ? head : parseJsonl(tailText, { dropFirst: size > tailBytes });
  const cwdRec = head.records.find(r => typeof r.cwd === 'string' && r.cwd);
  const tsRec = head.records.find(r => toIso(r.timestamp));
  const bad = tail.bad + (size > headLen + tailBytes ? head.bad : 0);
  return { cwd: cwdRec ? cwdRec.cwd : null, createdAt: tsRec ? toIso(tsRec.timestamp) : null, ...summarizeRecords(tail.records), bad };
}

/** Cached by file path; entry reused while size and mtime are unchanged. */
export async function readTranscript(file, st, cache, { growIfNoUsage }) {
  const sig = `${st.size}|${st.mtimeMs}`;
  const hit = cache.get('t:' + file);
  if (hit && hit.sig === sig) return hit.value;
  let value = await readOnce(file, st.size, growIfNoUsage ? TAIL_BYTES : TAIL_MAX_BYTES);
  if (growIfNoUsage && value.tokens === null && st.size > TAIL_BYTES) value = await readOnce(file, st.size, TAIL_MAX_BYTES);
  cache.set('t:' + file, { sig, value });
  return value;
}

// appended to desk/adapters/claude-code.mjs

async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }
async function readdirSafe(p) { try { return await fs.readdir(p, { withFileTypes: true }); } catch { return []; } }
const msToIso = ms => new Date(ms).toISOString();
const earlier = (a, b) => (!a ? b : !b ? a : (Date.parse(a) <= Date.parse(b) ? a : b));

async function readMeta(file, cache) {
  const st = await statOrNull(file);
  if (!st) return null;
  const sig = `${st.size}|${st.mtimeMs}`;
  const hit = cache.get('m:' + file);
  if (hit && hit.sig === sig) return hit.value;
  let value = null;
  try {
    const o = JSON.parse(await fs.readFile(file, 'utf8'));
    value = { agentType: typeof o.agentType === 'string' ? o.agentType : null,
      description: typeof o.description === 'string' ? o.description : null,
      model: typeof o.model === 'string' ? o.model : null };
  } catch { value = null; }
  cache.set('m:' + file, { sig, value });
  return value;
}

/** Reads <project>/.subdeck/events.jsonl + events.d/*.json; keeps only ids, types and timestamps. */
export async function readHooks(projectPath, cache) {
  const dir = path.join(projectPath, '.subdeck');
  const dst = await statOrNull(dir);
  const agents = new Map();
  if (!dst || !dst.isDirectory()) return { agents, bad: 0, dir: null };
  const files = [path.join(dir, 'events.jsonl')];
  for (const e of await readdirSafe(path.join(dir, 'events.d'))) if (e.isFile() && e.name.endsWith('.json')) files.push(path.join(dir, 'events.d', e.name));
  let bad = 0;
  for (const f of files) {
    const st = await statOrNull(f);
    if (!st) continue;
    const sig = `${st.size}|${st.mtimeMs}`;
    let c = cache.get('h:' + f);
    if (!c || c.sig !== sig) {
      let text = '';
      try { text = await fs.readFile(f, 'utf8'); } catch { continue; }
      const p = parseJsonl(text.endsWith('\n') ? text : text + '\n');
      const events = p.records
        .filter(e => typeof e.agent_id === 'string' && e.agent_id && (e.event === 'SubagentStart' || e.event === 'SubagentStop') && toIso(e.ts))
        .map(e => ({ event: e.event, ts: toIso(e.ts), agentId: e.agent_id,
          agentType: typeof e.agent_type === 'string' ? e.agent_type : null,
          sessionId: typeof e.session_id === 'string' ? e.session_id : null,
          transcriptPath: typeof e.transcript_path === 'string' ? e.transcript_path : null }));
      c = { sig, events, bad: p.bad };
      cache.set('h:' + f, c);
    }
    bad += c.bad;
    for (const e of c.events) {
      const a = agents.get(e.agentId) || { start: null, stop: null, agentType: null, sessionId: null, transcriptPath: null };
      if (e.event === 'SubagentStart') a.start = earlier(a.start, e.ts);
      else if (!a.stop || Date.parse(e.ts) > Date.parse(a.stop)) a.stop = e.ts;
      a.agentType = a.agentType || e.agentType;
      a.sessionId = a.sessionId || e.sessionId;
      a.transcriptPath = a.transcriptPath || e.transcriptPath;
      agents.set(e.agentId, a);
    }
  }
  return { agents, bad, dir };
}

function subTitle(meta, agentId) {
  const d = clip(meta && meta.description, 120);
  if (d) return { title: d, titleSource: 'meta' };
  const t = clip(meta && meta.agentType, 120);
  if (t) return { title: t, titleSource: 'fallback' };
  return { title: `agent ${agentId.slice(0, 8)}`, titleSource: 'fallback' };
}

function subBasis(hook, mtimeIso) {
  if (hook && hook.stop) return { kind: 'fixed', state: 'finished', stateSource: 'hook' };
  if (hook && hook.start) return { kind: 'hookOpen', at: mtimeIso || hook.start, stateSource: 'hook' };
  return { kind: 'mtime', at: mtimeIso, stateSource: 'mtime' };
}

async function scan(env, { cache }) {
  const cutoff = env.now() - env.days * 86400000;
  let skipped = 0;
  const groups = [];   // { top, subs, projectPath, projectLabel }
  for (const slug of await readdirSafe(env.claudeProjectsDir)) {
    if (!slug.isDirectory()) continue;
    const slugDir = path.join(env.claudeProjectsDir, slug.name);
    for (const e of await readdirSafe(slugDir)) {
      if (!e.isFile() || !e.name.endsWith('.jsonl')) continue;
      const uuid = e.name.slice(0, -'.jsonl'.length);
      const file = path.join(slugDir, e.name);
      const st = await statOrNull(file);
      if (!st) continue;
      const subDir = path.join(slugDir, uuid, 'subagents');
      const subs = [];
      for (const s of await readdirSafe(subDir)) {
        const m = /^agent-(.+)\.jsonl$/.exec(s.name);
        if (!m || !s.isFile()) continue;
        const f = path.join(subDir, s.name);
        const sst = await statOrNull(f);
        if (sst) subs.push({ agentId: m[1], file: f, st: sst });
      }
      if (Math.max(st.mtimeMs, ...subs.map(s => s.st.mtimeMs)) < cutoff) continue;
      const top = await readTranscript(file, st, cache, { growIfNoUsage: false });
      skipped += top.bad;
      for (const s of subs) {
        s.tr = await readTranscript(s.file, s.st, cache, { growIfNoUsage: true });
        s.meta = await readMeta(s.file.replace(/\.jsonl$/, '.meta.json'), cache);
        skipped += s.tr.bad;
      }
      const projectPath = top.cwd || (subs.find(s => s.tr.cwd) || {}).tr?.cwd || null;
      groups.push({ uuid, file, st, top, subs, projectPath, projectLabel: projectPath ? null : slug.name });
    }
  }
  // hook events, once per project
  const hooksByKey = new Map();
  const watchExtra = [];
  for (const g of groups) {
    if (!g.projectPath) continue;
    const key = projectKey(g.projectPath, env.platform);
    if (hooksByKey.has(key)) continue;
    const h = await readHooks(g.projectPath, cache);
    hooksByKey.set(key, h);
    skipped += h.bad;
    if (h.dir) watchExtra.push(h.dir);
  }
  const sessions = [];
  for (const g of groups) {
    const hooks = g.projectPath ? hooksByKey.get(projectKey(g.projectPath, env.platform)).agents : new Map();
    const base = { tool: 'claude-code', projectPath: g.projectPath, projectLabel: g.projectLabel, archived: false };
    const mt = msToIso(g.st.mtimeMs);
    const title = clip(g.top.customTitle, 120) ? { title: clip(g.top.customTitle, 120), titleSource: 'explicit' }
      : clip(g.top.aiTitle, 120) ? { title: clip(g.top.aiTitle, 120), titleSource: 'summary' }
      : { title: `Session ${g.uuid.slice(0, 8)}`, titleSource: 'fallback' };
    sessions.push({ ...base, nativeId: g.uuid, parentNativeId: null, depth: 0, ...title, agentType: null, model: g.top.model,
      createdAt: g.top.createdAt || msToIso(g.st.birthtimeMs || g.st.mtimeMs), updatedAt: mt, endedAt: null,
      tokens: { context: g.top.tokens, total: null }, lastActivity: g.top.lastActivity,
      refs: { file: g.file, db: null, key: null }, stateBasis: { kind: 'mtime', at: mt, stateSource: 'mtime' } });
    const seen = new Set();
    for (const s of g.subs) {
      seen.add(s.agentId);
      const hook = hooks.get(s.agentId);
      const smt = msToIso(s.st.mtimeMs);
      sessions.push({ ...base, nativeId: s.agentId, parentNativeId: g.uuid, depth: 1, ...subTitle(s.meta, s.agentId),
        agentType: (s.meta && s.meta.agentType) || (hook && hook.agentType) || null,
        model: (s.meta && s.meta.model) || s.tr.model,
        createdAt: earlier(s.tr.createdAt, hook && hook.start) || smt, updatedAt: smt, endedAt: (hook && hook.stop) || null,
        tokens: { context: s.tr.tokens, total: null }, lastActivity: s.tr.lastActivity,
        refs: { file: s.file, db: null, key: null }, stateBasis: subBasis(hook, smt) });
    }
    for (const [agentId, hook] of hooks) {
      if (seen.has(agentId) || hook.sessionId !== g.uuid) continue;
      const derived = hook.transcriptPath ? path.join(path.dirname(hook.transcriptPath), g.uuid, 'subagents', `agent-${agentId}.jsonl`) : null;
      sessions.push({ ...base, nativeId: agentId, parentNativeId: g.uuid, depth: 1,
        title: clip(hook.agentType, 120) || `agent ${agentId.slice(0, 8)}`, titleSource: 'fallback',
        agentType: hook.agentType, model: null, createdAt: hook.start || hook.stop, updatedAt: hook.stop || hook.start,
        endedAt: hook.stop || null, tokens: { context: null, total: null }, lastActivity: null,
        refs: { file: derived, db: null, key: null }, stateBasis: subBasis(hook, null) });
    }
  }
  return { sessions, skipped, notes: [], watchExtra };
}

export default {
  tool: 'claude-code', label: 'Claude Code', toolShort: 'claude', adapterVersion: '1',
  async detect(env) { const st = await statOrNull(env.claudeProjectsDir); return !!(st && st.isDirectory()); },
  watchPaths(env, last) {
    return [{ path: env.claudeProjectsDir, recursive: true }, ...((last && last.watchExtra) || []).map(p => ({ path: p, recursive: true }))];
  },
  scan,
};
