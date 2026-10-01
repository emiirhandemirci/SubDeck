// desk/adapters/claude-code.mjs
// Claude Code source adapter (spec 5.1). Reads transcript heads/tails only; keeps no message bodies.
import fs from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';
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

// Tools that block on the user; a trailing tool_use of one of these with no result yet means the session waits for an answer.
const BLOCKING_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode']);
const WAITING_NOTIFS = new Set(['permission_prompt', 'elicitation_dialog', 'agent_needs_input']);
const isToolResultUser = c => Array.isArray(c) && c.some(b => b && b.type === 'tool_result');

/** fromStart: the records begin at the top of the file, so the first user record opens run 1. */
export function summarizeRecords(records, { fromStart = true } = {}) {
  const out = { tokens: null, model: null, customTitle: null, aiTitle: null, lastActivity: null, runStartedAt: null, ended: null, pending: null };
  let prevEnded = fromStart;   // true: the next prompt-like user record starts a new run
  for (const r of records) {
    if (r.type === 'user' && r.message && typeof r.message === 'object') out.pending = null;   // any answer or new prompt clears a pending question
    else if (r.type === 'assistant' && r.message && typeof r.message === 'object') {
      const c = r.message.content;
      const last = Array.isArray(c) && c.length ? c[c.length - 1] : null;
      out.pending = last && last.type === 'tool_use' && BLOCKING_TOOLS.has(last.name) && toIso(r.timestamp) ? { at: toIso(r.timestamp), name: last.name } : null;
    }
    if (r.type === 'user' && r.message && typeof r.message === 'object' && !isToolResultUser(r.message.content)) {
      if (prevEnded) { out.runStartedAt = toIso(r.timestamp); out.ended = null; prevEnded = false; }
    } else if (r.type === 'assistant' && r.message && typeof r.message === 'object') {
      const at = toIso(r.timestamp);
      if (r.isApiErrorMessage === true) { out.ended = at ? { state: 'failed', at } : null; prevEnded = true; }
      else if (r.message.stop_reason === 'end_turn') { out.ended = at ? { state: 'finished', at } : null; prevEnded = true; }
      else { out.ended = null; prevEnded = false; }
    }
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
  return { cwd: cwdRec ? cwdRec.cwd : null, createdAt: tsRec ? toIso(tsRec.timestamp) : null,
    ...summarizeRecords(tail.records, { fromStart: size <= tailBytes || size <= headLen }), bad };
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

// ---- explicit completion records in the parent transcript ----
const DONE = { completed: 'finished', killed: 'finished', stopped: 'finished', cancelled: 'finished', canceled: 'finished', failed: 'failed', error: 'failed' };
const CHUNK = 8 * 1024 * 1024;
const tag = (text, name) => { const m = new RegExp('<' + name + '>([^<]*)</' + name + '>').exec(text); return m ? m[1].trim() : null; };

/** Pulls completion facts out of one parent-transcript record; returns [{agentId,status,at,durationMs}]. Reads ids/status/time only. */
export function completionsOf(o) {
  const at = toIso(o.timestamp);
  if (!at) return [];
  const out = [];
  let text = null, dur = null;
  if (o.type === 'attachment' && o.attachment && o.attachment.commandMode === 'task-notification' && typeof o.attachment.prompt === 'string') {
    text = o.attachment.prompt;
    const u = o.attachment.usage;
    if (u && Number.isFinite(u.durationMs)) dur = u.durationMs;
  } else if (o.type === 'queue-operation' && o.operation === 'enqueue' && typeof o.content === 'string') text = o.content;
  else if (o.type === 'user' && o.message && typeof o.message.content === 'string') text = o.message.content;
  if (text !== null) {
    if (!text.includes('<task-notification>')) return [];
    const agentId = tag(text, 'task-id');
    const status = tag(text, 'status');
    if (dur === null) { const d = tag(text, 'duration_ms'); if (d !== null && Number.isFinite(Number(d))) dur = Number(d); }
    if (agentId && DONE[status]) out.push({ agentId, status: DONE[status], at, durationMs: dur });
    return out;
  }
  const t = o.toolUseResult;
  if (o.type === 'user' && t && typeof t === 'object' && typeof t.agentId === 'string' && DONE[t.status]) {
    out.push({ agentId: t.agentId, status: DONE[t.status], at, durationMs: Number.isFinite(t.totalDurationMs) ? t.totalDurationMs : null });
  }
  return out;
}

/** Latest completion per agent id. Incremental: only bytes appended since the last scan are read (cache key c:<file>). */
export async function readCompletions(file, st, cache) {
  const key = 'c:' + file;
  let c = cache.get(key);
  if (!c || st.size < c.offset) c = { offset: 0, agents: new Map() };
  if (st.size > c.offset) {
    const fh = await fs.open(file, 'r');
    try {
      let pos = c.offset;
      let carry = Buffer.alloc(0);
      while (pos < st.size) {
        const len = Math.min(CHUNK, st.size - pos);
        const buf = Buffer.alloc(len);
        const { bytesRead } = await fh.read(buf, 0, len, pos);
        if (!bytesRead) break;
        pos += bytesRead;
        const all = carry.length ? Buffer.concat([carry, buf.subarray(0, bytesRead)]) : buf.subarray(0, bytesRead);
        const nl = all.lastIndexOf(0x0a);
        if (nl < 0) { carry = Buffer.from(all); continue; }
        for (const line of all.subarray(0, nl).toString('utf8').split('\n')) {
          if (!line.includes('task-notification') && !(line.includes('"toolUseResult"') && line.includes('"agentId"'))) continue;
          let o; try { o = JSON.parse(line); } catch { continue; }
          if (!o || typeof o !== 'object') continue;
          for (const d of completionsOf(o)) {
            const prev = c.agents.get(d.agentId);
            if (!prev || Date.parse(d.at) >= Date.parse(prev.at)) c.agents.set(d.agentId, d);
          }
        }
        carry = Buffer.from(all.subarray(nl + 1));
      }
      c.offset = pos - carry.length;
    } finally { await fh.close(); }
  }
  cache.set(key, c);
  return c.agents;
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
  const notifs = new Map();   // 's:<sessionId>' or 'a:<agentId>' -> latest waiting-type Notification time
  if (!dst || !dst.isDirectory()) return { agents, notifs, bad: 0, dir: null };
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
      if (text && !text.endsWith('\n')) {
        // events.jsonl: a trailing partial line is a half-written append, ignore it; events.d/*.json is one whole record
        if (f.endsWith('.json')) text += '\n'; else text = text.slice(0, text.lastIndexOf('\n') + 1);
      }
      const p = parseJsonl(text);
      const notes = p.records
        .filter(e => e.event === 'Notification' && toIso(e.ts) && e.payload && WAITING_NOTIFS.has(e.payload.notification_type))
        .map(e => ({ ts: toIso(e.ts), key: typeof e.agent_id === 'string' && e.agent_id ? 'a:' + e.agent_id : typeof e.session_id === 'string' && e.session_id ? 's:' + e.session_id : null }))
        .filter(e => e.key);
      const events = p.records
        .filter(e => typeof e.agent_id === 'string' && e.agent_id && (e.event === 'SubagentStart' || e.event === 'SubagentStop') && toIso(e.ts))
        .map(e => ({ event: e.event, ts: toIso(e.ts), agentId: e.agent_id,
          agentType: typeof e.agent_type === 'string' ? e.agent_type : null,
          sessionId: typeof e.session_id === 'string' ? e.session_id : null,
          transcriptPath: typeof e.transcript_path === 'string' ? e.transcript_path : null }));
      c = { sig, events, notes, bad: p.bad };
      cache.set('h:' + f, c);
    }
    bad += c.bad;
    for (const n of c.notes) if (!notifs.get(n.key) || n.ts > notifs.get(n.key)) notifs.set(n.key, n.ts);
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
  return { agents, notifs, bad, dir };
}

function subTitle(meta, agentId) {
  const d = clip(meta && meta.description, 120);
  if (d) return { title: d, titleSource: 'meta' };
  const t = clip(meta && meta.agentType, 120);
  if (t) return { title: t, titleSource: 'fallback' };
  return { title: `agent ${agentId.slice(0, 8)}`, titleSource: 'fallback' };
}

/** Explicit end of the latest run: parent record (if not older than the latest run start) else the sub-agent's own last record. */
export function latestCompletion(tr, notif) {
  let n = notif || null;
  if (n && tr.runStartedAt && Date.parse(n.at) < Date.parse(tr.runStartedAt)) n = null;   // belongs to an earlier run
  if (n) return { state: n.status, at: n.at, runStartedAt: n.durationMs !== null ? new Date(Date.parse(n.at) - n.durationMs).toISOString() : tr.runStartedAt };
  if (tr.ended) return { state: tr.ended.state, at: tr.ended.at, runStartedAt: tr.runStartedAt };
  return null;
}

/** Waiting: a pending blocking tool in the transcript (field), else a waiting-type Notification hook newer than the last transcript write (hook). null otherwise. */
export function waitingBasis(pending, notifIso, mtimeMs, mtimeIso) {
  if (pending) return { kind: 'waiting', at: pending.at, stateSource: 'field', fallbackAt: mtimeIso };
  const t = notifIso ? Date.parse(notifIso) : NaN;
  // the Notification fires after the tool_use was written and before any answer; a later transcript write means the prompt was resolved
  if (Number.isFinite(t) && mtimeMs < t + 2000) return { kind: 'waiting', at: notifIso, stateSource: 'hook', fallbackAt: mtimeIso };
  return null;
}

function subBasis(hook, mtimeIso, done, wait) {
  if (done && done.state === 'failed') return { kind: 'fixed', state: 'failed', stateSource: 'field' };   // explicit failure of the latest run wins over a Stop hook
  if (hook && hook.stop) return { kind: 'fixed', state: 'finished', stateSource: 'hook' };
  if (done) return { kind: 'fixed', state: done.state, stateSource: 'field' };
  if (wait) return wait;
  if (hook && hook.start) return { kind: 'hookOpen', at: mtimeIso || hook.start, stateSource: 'hook' };
  return { kind: 'mtime', at: mtimeIso, stateSource: 'mtime' };
}

// ---- on-demand content (decision 0020): read only when the user opens an agent; never cached, never listed ----
export const PROMPT_MAX = 20000;
export const REPORT_MAX = 20000;
export const TOOL_CALLS_MAX = 500;
export const TARGET_MAX = 200;
const TARGET_KEYS = ['file_path', 'notebook_path', 'pattern', 'command', 'url', 'path', 'description', 'query', 'prompt'];

export function toolTarget(input) {
  if (!input || typeof input !== 'object') return '';
  for (const k of TARGET_KEYS) if (typeof input[k] === 'string' && input[k].trim()) return clip(input[k], TARGET_MAX) || '';
  const v = Object.values(input).find(x => typeof x === 'string' && x.trim());
  return v ? (clip(v, TARGET_MAX) || '') : '';
}

const textOf = c => (typeof c === 'string' ? c : Array.isArray(c) ? c.filter(b => b && b.type === 'text' && typeof b.text === 'string').map(b => b.text).join('\n') : '');
const capText = (s, max) => { const a = Array.from(s); return a.length > max ? { text: a.slice(0, max).join(''), truncated: true } : { text: s, truncated: false }; };

/** Streams one transcript and returns { prompt, promptTruncated, toolCalls, toolCallsTruncated, toolCallTotal, finalReport } or null when the file is unreadable. */
export async function readContent(file, { subagent }) {
  let fh;
  try { fh = await fs.open(file, 'r'); } catch { return null; }
  let prompt = null, finalReport = null, total = 0;
  const calls = [];
  const byId = new Map();
  try {
    const rl = readline.createInterface({ input: fh.createReadStream({ encoding: 'utf8' }), crlfDelay: Infinity });
    for await (const line of rl) {
      if (!line.trim()) continue;
      let r; try { r = JSON.parse(line); } catch { continue; }
      if (!r || typeof r !== 'object' || !r.message || typeof r.message !== 'object') continue;
      const c = r.message.content;
      if (r.type === 'user') {
        if (isToolResultUser(c)) {
          for (const b of c) if (b && b.type === 'tool_result' && byId.has(b.tool_use_id)) byId.get(b.tool_use_id).ok = b.is_error !== true;
        } else if (prompt === null && (subagent || !r.isMeta)) {
          const t = textOf(c);
          if (t.trim() && (subagent || !t.startsWith('<local-command') && !t.startsWith('<command-name>'))) prompt = t;
        }
      } else if (r.type === 'assistant') {
        const at = toIso(r.timestamp);
        const blocks = typeof c === 'string' ? [{ type: 'text', text: c }] : Array.isArray(c) ? c : [];
        const t = textOf(blocks);
        if (t.trim()) finalReport = t;
        for (const b of blocks) {
          if (!b) continue;
          if (b.type === 'tool_use' || b.type === 'thinking') {
            total++;
            const e = b.type === 'thinking' ? { at, tool: 'Thinking', target: '', ok: null }
              : { at, tool: typeof b.name === 'string' ? b.name : 'tool', target: toolTarget(b.input), ok: null };
            calls.push(e);
            if (b.type === 'tool_use' && typeof b.id === 'string') byId.set(b.id, e);
            if (calls.length > TOOL_CALLS_MAX) { const old = calls.shift(); for (const [k, v] of byId) if (v === old) { byId.delete(k); break; } }
          }
        }
      }
    }
  } finally { await fh.close(); }
  const p = capText(prompt || '', PROMPT_MAX);
  return { prompt: prompt === null ? null : p.text, promptTruncated: p.truncated, toolCalls: calls, toolCallsTruncated: total > calls.length, toolCallTotal: total,
    finalReport: finalReport === null ? null : capText(finalReport, REPORT_MAX).text };
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
      const completions = subs.length ? await readCompletions(file, st, cache) : new Map();
      for (const s of subs) {
        s.tr = await readTranscript(s.file, s.st, cache, { growIfNoUsage: true });
        s.meta = await readMeta(s.file.replace(/\.jsonl$/, '.meta.json'), cache);
        skipped += s.tr.bad;
      }
      const projectPath = top.cwd || (subs.find(s => s.tr.cwd) || {}).tr?.cwd || null;
      groups.push({ uuid, file, st, top, subs, completions, projectPath, projectLabel: projectPath ? null : slug.name });
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
    const hookInfo = g.projectPath ? hooksByKey.get(projectKey(g.projectPath, env.platform)) : null;
    const hooks = hookInfo ? hookInfo.agents : new Map();
    const notifs = hookInfo ? hookInfo.notifs : new Map();
    const base = { tool: 'claude-code', projectPath: g.projectPath, projectLabel: g.projectLabel, archived: false };
    const mt = msToIso(g.st.mtimeMs);
    const title = clip(g.top.customTitle, 120) ? { title: clip(g.top.customTitle, 120), titleSource: 'explicit' }
      : clip(g.top.aiTitle, 120) ? { title: clip(g.top.aiTitle, 120), titleSource: 'summary' }
      : { title: `Session ${g.uuid.slice(0, 8)}`, titleSource: 'fallback' };
    sessions.push({ ...base, nativeId: g.uuid, parentNativeId: null, depth: 0, ...title, agentType: null, model: g.top.model,
      createdAt: g.top.createdAt || msToIso(g.st.birthtimeMs || g.st.mtimeMs), updatedAt: mt, endedAt: null,
      tokens: { context: g.top.tokens, total: null }, lastActivity: g.top.lastActivity,
      refs: { file: g.file, db: null, key: null },
      stateBasis: waitingBasis(g.top.pending, notifs.get('s:' + g.uuid), g.st.mtimeMs, mt) || { kind: 'mtime', at: mt, stateSource: 'mtime' } });
    const seen = new Set();
    for (const s of g.subs) {
      seen.add(s.agentId);
      const hook = hooks.get(s.agentId);
      const smt = msToIso(s.st.mtimeMs);
      const done = latestCompletion(s.tr, g.completions.get(s.agentId));
      const runStartedAt = (hook && hook.stop) ? null : ((done && done.runStartedAt) || s.tr.runStartedAt || null);
      sessions.push({ ...base, nativeId: s.agentId, parentNativeId: g.uuid, depth: 1, ...subTitle(s.meta, s.agentId),
        agentType: (s.meta && s.meta.agentType) || (hook && hook.agentType) || null,
        model: s.tr.model || (s.meta && s.meta.model) || null,
        createdAt: earlier(s.tr.createdAt, hook && hook.start) || smt, updatedAt: smt, endedAt: (hook && hook.stop) || (done && done.at) || null,
        ...(runStartedAt ? { runStartedAt } : {}),
        tokens: { context: s.tr.tokens, total: null }, lastActivity: s.tr.lastActivity,
        refs: { file: s.file, db: null, key: null }, stateBasis: subBasis(hook, smt, done, waitingBasis(s.tr.pending, notifs.get('a:' + s.agentId), s.st.mtimeMs, smt)) });
    }
    for (const [agentId, hook] of hooks) {
      if (seen.has(agentId) || hook.sessionId !== g.uuid) continue;
      // Stop-only hook events with no start, no agent type and no transcript file (seen is built from the files on disk) are not agents
      if (!hook.start && !hook.agentType) continue;
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
  async timeline(env, session) {
    const file = session && session.refs && session.refs.file;
    return file ? readContent(file, { subagent: session.depth > 0 }) : null;
  },
};
