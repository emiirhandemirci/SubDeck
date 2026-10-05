// desk/adapters/claude-code.mjs
// Claude Code source adapter (spec 5.1). Reads transcript heads/tails only; keeps no message bodies.
import fs from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';
import { clip } from '../lib/model.mjs';
import { projectKey, stateDirs } from '../lib/paths.mjs';
import { classifyFailure, FAILURE_DETAIL } from './claude-failure.mjs';

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
const NOTIF_KIND = { permission_prompt: 'permission', elicitation_dialog: 'question' };   // agent_needs_input does not say which
const isToolResultUser = c => Array.isArray(c) && c.some(b => b && b.type === 'tool_result');

/** fromStart: the records begin at the top of the file, so the first user record opens run 1. */
export function summarizeRecords(records, { fromStart = true } = {}) {
  const out = { tokens: null, model: null, customTitle: null, aiTitle: null, lastActivity: null, runStartedAt: null, ended: null, pending: null, stamps: [] };
  let prevEnded = fromStart;   // true: the next prompt-like user record starts a new run
  for (const r of records) {
    if (r.type === 'user' || r.type === 'assistant' || (r.type === 'attachment' && r.attachment && r.attachment.type === 'queued_command')) {
      const sa = toIso(r.timestamp);
      if (sa) out.stamps.push(sa);   // timestamps only; used to see whether work continued after a Stop hook
    }
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
  if (out.stamps.length > 400) out.stamps = out.stamps.slice(-400);
  out.failure = classifyFailure(records);   // only served when the session state is failed (core drops it otherwise)
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

/** Incremental parent/agent transcript scan (cache key c:<file>): completions per agent id plus ids of agents it spawned. */
async function scanSpawns(file, st, cache) {
  const key = 'c:' + file;
  let c = cache.get(key);
  if (!c || st.size < c.offset) c = { offset: 0, agents: new Map(), children: new Set() };
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
          if (o.toolUseResult && typeof o.toolUseResult === 'object' && typeof o.toolUseResult.agentId === 'string') c.children.add(o.toolUseResult.agentId);
          for (const d of completionsOf(o)) {
            c.children.add(d.agentId);
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
  return c;
}

/** Latest completion per agent id. Incremental: only bytes appended since the last scan are read (cache key c:<file>). */
export async function readCompletions(file, st, cache) { return (await scanSpawns(file, st, cache)).agents; }

/** Ids of the agents a transcript spawned (Agent tool results and task notifications); used to find the real parent of a nested sub-agent. */
export async function readSpawned(file, st, cache) { return (await scanSpawns(file, st, cache)).children; }

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

/** Reasoning effort from a hook payload: `effort.level` (documented object form) or a plain string. null when absent or unusable. */
export function effortOf(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const v = payload.effort;
  const level = typeof v === 'string' ? v : v && typeof v === 'object' && typeof v.level === 'string' ? v.level : null;
  return clip(level, 20);
}

/**
 * Reads events.jsonl + events.d/*.json from the project's state dir (~/.subdeck/projects/<key>/, see
 * lib/paths.mjs stateDirs) and from a legacy <project>/.subdeck/; events of both are merged.
 * Keeps only ids, types and timestamps. Without env only the legacy dir is read.
 */
export async function readHooks(projectPath, cache, env) {
  const candidates = env ? stateDirs(projectPath, env) : [path.join(projectPath, '.subdeck')];
  const agents = new Map();
  const notifs = new Map();   // 's:<sessionId>' or 'a:<agentId>' -> latest waiting-type Notification time
  const notifTypes = new Map();   // same keys -> notification_type of that latest one
  const fails = new Map();   // same keys -> latest StopFailure { ts, errorType }
  const efforts = new Map();   // same keys -> latest effort level seen in a hook payload
  const dirs = [];
  for (const d of candidates) { const st = await statOrNull(d); if (st && st.isDirectory()) dirs.push(d); }
  if (!dirs.length) return { agents, notifs, notifTypes, fails, efforts, bad: 0, dir: null, dirs };
  const files = [];
  for (const dir of dirs) {
    files.push(path.join(dir, 'events.jsonl'));
    for (const e of await readdirSafe(path.join(dir, 'events.d'))) if (e.isFile() && e.name.endsWith('.json')) files.push(path.join(dir, 'events.d', e.name));
  }
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
        .map(e => ({ ts: toIso(e.ts), type: e.payload.notification_type, key: typeof e.agent_id === 'string' && e.agent_id ? 'a:' + e.agent_id : typeof e.session_id === 'string' && e.session_id ? 's:' + e.session_id : null }))
        .filter(e => e.key);
      const events = p.records
        .filter(e => typeof e.agent_id === 'string' && e.agent_id && (e.event === 'SubagentStart' || e.event === 'SubagentStop') && toIso(e.ts))
        .map(e => ({ event: e.event, ts: toIso(e.ts), agentId: e.agent_id,
          agentType: typeof e.agent_type === 'string' ? e.agent_type : null,
          sessionId: typeof e.session_id === 'string' ? e.session_id : null,
          transcriptPath: typeof e.transcript_path === 'string' ? e.transcript_path : null }));
      const keyOf = e => (typeof e.agent_id === 'string' && e.agent_id ? 'a:' + e.agent_id : typeof e.session_id === 'string' && e.session_id ? 's:' + e.session_id : null);
      const failed = p.records.filter(e => e.event === 'StopFailure' && toIso(e.ts) && keyOf(e))
        .map(e => ({ key: keyOf(e), ts: toIso(e.ts), errorType: e.payload && typeof e.payload.error_type === 'string' ? e.payload.error_type : null }));
      const effs = p.records.filter(e => toIso(e.ts) && keyOf(e) && effortOf(e.payload)).map(e => ({ key: keyOf(e), ts: toIso(e.ts), level: effortOf(e.payload) }));
      c = { sig, events, notes, failed, effs, bad: p.bad };
      cache.set('h:' + f, c);
    }
    bad += c.bad;
    for (const n of c.notes) if (!notifs.get(n.key) || n.ts > notifs.get(n.key)) { notifs.set(n.key, n.ts); notifTypes.set(n.key, n.type); }
    for (const f of c.failed) if (!fails.get(f.key) || f.ts > fails.get(f.key).ts) fails.set(f.key, { ts: f.ts, errorType: f.errorType });
    for (const f of c.effs) if (!efforts.get(f.key) || f.ts >= efforts.get(f.key).ts) efforts.set(f.key, { ts: f.ts, level: f.level });
    for (const e of c.events) {
      const a = agents.get(e.agentId) || { start: null, lastStart: null, stop: null, agentType: null, sessionId: null, transcriptPath: null };
      if (e.event === 'SubagentStart') { a.start = earlier(a.start, e.ts); if (!a.lastStart || Date.parse(e.ts) > Date.parse(a.lastStart)) a.lastStart = e.ts; }
      else if (!a.stop || Date.parse(e.ts) > Date.parse(a.stop)) a.stop = e.ts;
      a.agentType = a.agentType || e.agentType;
      a.sessionId = a.sessionId || e.sessionId;
      a.transcriptPath = a.transcriptPath || e.transcriptPath;
      agents.set(e.agentId, a);
    }
  }
  return { agents, notifs, notifTypes, fails, efforts: new Map([...efforts].map(([k, v]) => [k, v.level])), bad, dir: dirs[0], dirs };
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
export function waitingBasis(pending, notifIso, mtimeMs, mtimeIso, notifType = null) {
  if (pending) return { kind: 'waiting', at: pending.at, stateSource: 'field', fallbackAt: mtimeIso, waitingKind: pending.name === 'ExitPlanMode' ? 'plan' : 'question' };
  const t = notifIso ? Date.parse(notifIso) : NaN;
  // the Notification fires after the tool_use was written and before any answer; a later transcript write means the prompt was resolved
  if (Number.isFinite(t) && mtimeMs < t + 2000) return { kind: 'waiting', at: notifIso, stateSource: 'hook', fallbackAt: mtimeIso, ...(NOTIF_KIND[notifType] ? { waitingKind: NOTIF_KIND[notifType] } : {}) };
  return null;
}

const RESUME_MARGIN_MS = 2000;   // hook timestamps have whole-second resolution

/** A Stop only ends the run when nothing newer happened: a later Start hook or newer transcript records mean the agent was resumed (e.g. SendMessage). Returns the resume start (ISO) or null. */
export function resumedAfterStop(hook, stamps) {
  if (!hook || !hook.stop) return null;
  const stop = Date.parse(hook.stop);
  let best = null;
  for (const t of stamps || []) if (Date.parse(t) > stop + RESUME_MARGIN_MS) { best = t; break; }
  if (hook.lastStart && Date.parse(hook.lastStart) > stop) best = best ? earlier(best, hook.lastStart) : hook.lastStart;
  return best;
}

/** A StopFailure hook event newer than the last transcript write means the turn ended in an error (rate limit, billing, ...). */
export function failedBasis(fail, mtimeMs) {
  if (!fail) return null;
  const t = Date.parse(fail.ts);
  return Number.isFinite(t) && mtimeMs < t + 2000 ? { kind: 'fixed', state: 'failed', stateSource: 'hook' } : null;
}

/** Failure reason from a StopFailure hook's error_type (rate_limit, billing_error, server_error, ...). */
export function hookFailure(fail) {
  const t = String((fail && fail.errorType) || '');
  const kind = /rate|limit|billing|quota|overload/i.test(t) ? 'quota' : /time.?out/i.test(t) ? 'timeout' : 'api';
  return { kind, detail: FAILURE_DETAIL[kind] };
}

function subBasis(hook, mtimeIso, done, wait, fail = null) {
  if (fail) return fail;
  if (done && done.state === 'failed') return { kind: 'fixed', state: 'failed', stateSource: 'field' };   // explicit failure of the latest run wins over a Stop hook
  if (hook && hook.stop) return { kind: 'fixed', state: 'finished', stateSource: 'hook' };
  if (done) return { kind: 'fixed', state: done.state, stateSource: 'field' };
  if (wait) return wait;
  if (hook && hook.start) return { kind: 'hookOpen', at: mtimeIso || hook.start, stateSource: 'hook' };
  return { kind: 'mtime', at: mtimeIso, stateSource: 'mtime' };
}

// ---- on-demand content: read only when the user opens an agent; never listed; parsed state cached per file, bounded ----
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

const CONTENT_CACHE_MAX = 20;
const CONTENT_CHUNK = 1 << 20;
const contentCache = new Map();   // `${subagent}|${file}` -> { dev, ino, offset, state }; Map order = LRU order

const newContentState = () => ({ prompt: null, finalReport: null, total: 0, calls: [], byId: new Map() });
function cloneContentState(st) {
  const calls = st.calls.map(e => ({ ...e }));
  const byId = new Map();
  for (const [k, v] of st.byId) { const i = st.calls.indexOf(v); if (i >= 0) byId.set(k, calls[i]); }
  return { prompt: st.prompt, finalReport: st.finalReport, total: st.total, calls, byId };
}

/** Folds one transcript line into the parsed state. */
function applyContentLine(st, line, subagent) {
  if (!line.trim()) return;
  let r; try { r = JSON.parse(line); } catch { return; }
  if (!r || typeof r !== 'object' || !r.message || typeof r.message !== 'object') return;
  const c = r.message.content;
  if (r.type === 'user') {
    if (isToolResultUser(c)) {
      for (const b of c) if (b && b.type === 'tool_result' && st.byId.has(b.tool_use_id)) st.byId.get(b.tool_use_id).ok = b.is_error !== true;
    } else if (st.prompt === null && (subagent || !r.isMeta)) {
      const t = textOf(c);
      if (t.trim() && (subagent || !t.startsWith('<local-command') && !t.startsWith('<command-name>'))) st.prompt = t;
    }
  } else if (r.type === 'assistant') {
    const at = toIso(r.timestamp);
    const blocks = typeof c === 'string' ? [{ type: 'text', text: c }] : Array.isArray(c) ? c : [];
    const t = textOf(blocks);
    if (t.trim()) st.finalReport = t;
    for (const b of blocks) {
      if (!b) continue;
      if (b.type === 'tool_use' || b.type === 'thinking') {
        st.total++;
        const e = b.type === 'thinking' ? { at, tool: 'Thinking', target: '', ok: null }
          : { at, tool: typeof b.name === 'string' ? b.name : 'tool', target: toolTarget(b.input), ok: null };
        st.calls.push(e);
        if (b.type === 'tool_use' && typeof b.id === 'string') st.byId.set(b.id, e);
        if (st.calls.length > TOOL_CALLS_MAX) { const old = st.calls.shift(); for (const [k, v] of st.byId) if (v === old) { st.byId.delete(k); break; } }
      }
    }
  }
}

function contentResult(st) {
  const p = capText(st.prompt || '', PROMPT_MAX);
  return { prompt: st.prompt === null ? null : p.text, promptTruncated: p.truncated, toolCalls: st.calls.map(e => ({ ...e })), toolCallsTruncated: st.total > st.calls.length, toolCallTotal: st.total,
    finalReport: st.finalReport === null ? null : capText(st.finalReport, REPORT_MAX).text };
}

/** Parses one transcript and returns { prompt, promptTruncated, toolCalls, toolCallsTruncated, toolCallTotal, finalReport } or null when the file is unreadable.
 *  Incremental: the parsed state and the byte offset after the last complete line are cached per file (bounded LRU); a call reads only appended bytes.
 *  The cache entry is dropped when the file shrank or was replaced (different dev/ino). A trailing unterminated line is parsed for the result but not committed. */
export const contentReadStats = { bytes: 0 };   // test observable: transcript bytes read by readContent (excludes the small guard probes)
const GUARD = 64;
async function probe(fh, from, to) {
  const n = Math.max(0, to - from);
  if (!n) return Buffer.alloc(0);
  const b = Buffer.alloc(n);
  const { bytesRead } = await fh.read(b, 0, n, from);
  return b.subarray(0, bytesRead);
}
export async function readContent(file, { subagent }) {
  let fh;
  try { fh = await fs.open(file, 'r'); } catch { return null; }
  try {
    const key = `${subagent ? 1 : 0}|${file}`;
    const stat = await fh.stat();
    let ent = contentCache.get(key);
    contentCache.delete(key);
    if (ent && (ent.dev !== stat.dev || ent.ino !== stat.ino || stat.size < ent.offset)) ent = null;
    // same-inode rewrite guard: the first and last GUARD bytes before the cached offset must be unchanged
    if (ent && ent.offset > 0 && !(ent.head.equals(await probe(fh, 0, ent.head.length)) && ent.tail.equals(await probe(fh, ent.offset - ent.tail.length, ent.offset)))) ent = null;
    if (!ent) ent = { dev: stat.dev, ino: stat.ino, offset: 0, head: Buffer.alloc(0), tail: Buffer.alloc(0), state: newContentState() };
    let pos = ent.offset, carry = Buffer.alloc(0);
    const buf = Buffer.allocUnsafe(CONTENT_CHUNK);
    while (pos < stat.size) {
      const { bytesRead } = await fh.read(buf, 0, Math.min(CONTENT_CHUNK, stat.size - pos), pos);
      if (bytesRead <= 0) break;
      pos += bytesRead;
      contentReadStats.bytes += bytesRead;
      let data = carry.length ? Buffer.concat([carry, buf.subarray(0, bytesRead)]) : Buffer.from(buf.subarray(0, bytesRead));
      const nl = data.lastIndexOf(0x0a);
      if (nl < 0) { carry = data; continue; }
      const complete = data.subarray(0, nl + 1);
      carry = Buffer.from(data.subarray(nl + 1));
      for (const line of complete.toString('utf8').split('\n')) applyContentLine(ent.state, line, subagent);
      ent.offset = pos - carry.length;
    }
    if (ent.offset > 0) { ent.head = await probe(fh, 0, Math.min(GUARD, ent.offset)); ent.tail = await probe(fh, Math.max(0, ent.offset - GUARD), ent.offset); }
    let state = ent.state;
    if (carry.length) { state = cloneContentState(ent.state); applyContentLine(state, carry.toString('utf8'), subagent); }
    contentCache.set(key, ent);
    while (contentCache.size > CONTENT_CACHE_MAX) contentCache.delete(contentCache.keys().next().value);
    return contentResult(state);
  } finally { await fh.close(); }
}

// ---- changed files (on demand like readContent: read only when requested, never cached, stored or logged) ----
export const CHANGE_STR_MAX = 20000;     // per old/new/content string, in characters
export const CHANGE_TOTAL_MAX = 200000;  // all strings of one file response
export const CHANGE_EDITS_MAX = 200;
const CHANGE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);
const pathOfInput = i => { for (const k of ['file_path', 'notebook_path', 'path']) if (typeof i[k] === 'string' && i[k].trim()) return i[k]; return null; };
const str = v => (typeof v === 'string' ? v : '');

/** Expands one tool_use block into ops [{kind, at, ...payload}]; kind is write | edit | notebook. */
function opsOf(name, input, at) {
  if (name === 'Write') return [{ kind: 'write', at, content: str(input.content ?? input.file_text) }];
  if (name === 'Edit') return [{ kind: 'edit', at, old: str(input.old_string), new: str(input.new_string), replaceAll: input.replace_all === true }];
  if (name === 'MultiEdit') return (Array.isArray(input.edits) ? input.edits : []).filter(e => e && typeof e === 'object')
    .map(e => ({ kind: 'edit', at, old: str(e.old_string), new: str(e.new_string), replaceAll: e.replace_all === true }));
  return [{ kind: 'notebook', at, editMode: str(input.edit_mode) || 'replace', cellId: str(input.cell_id) || null, cellType: str(input.cell_type) || null, new: str(input.new_source) }];
}

/** Streams one transcript; returns [{path, ops}] in first-touch order. Calls whose result is an error are dropped. */
async function streamChanges(file) {
  let fh;
  try { fh = await fs.open(file, 'r'); } catch { return null; }
  const files = new Map();   // exact path -> { path, ops }
  const byId = new Map();    // tool_use id -> ops (to drop failed calls)
  try {
    const rl = readline.createInterface({ input: fh.createReadStream({ encoding: 'utf8' }), crlfDelay: Infinity });
    for await (const line of rl) {
      if (!line.includes('"tool_use"') && !line.includes('"tool_result"')) continue;
      let r; try { r = JSON.parse(line); } catch { continue; }
      if (!r || typeof r !== 'object' || !r.message || typeof r.message !== 'object' || !Array.isArray(r.message.content)) continue;
      if (r.type === 'user') {
        for (const b of r.message.content) if (b && b.type === 'tool_result' && b.is_error === true && byId.has(b.tool_use_id)) for (const op of byId.get(b.tool_use_id)) op.failed = true;
      } else if (r.type === 'assistant') {
        const at = toIso(r.timestamp);
        for (const b of r.message.content) {
          if (!b || b.type !== 'tool_use' || !CHANGE_TOOLS.has(b.name) || !b.input || typeof b.input !== 'object') continue;
          const p = pathOfInput(b.input);
          if (!p) continue;
          const ops = opsOf(b.name, b.input, at);
          if (!ops.length) continue;
          let f = files.get(p); if (!f) { f = { path: p, ops: [] }; files.set(p, f); }
          f.ops.push(...ops);
          if (typeof b.id === 'string') byId.set(b.id, ops);
        }
      }
    }
  } finally { await fh.close(); }
  return [...files.values()].map(f => ({ path: f.path, ops: f.ops.filter(o => !o.failed) })).filter(f => f.ops.length);
}

const later = (a, b) => (!a ? b : !b ? a : (Date.parse(a) >= Date.parse(b) ? a : b));
const keyOf = (p, env) => projectKey(p, env && env.platform);

/** File list of one agent: paths, counts and times only (no old/new/content), merged by normalized path. */
export async function readChangeList(file, env) {
  const raw = await streamChanges(file);
  if (!raw) return null;
  const merged = new Map();
  for (const f of raw) {
    const k = keyOf(f.path, env);
    let m = merged.get(k);
    if (!m) { m = { path: f.path, count: 0, firstAt: null, lastAt: null, kinds: new Set() }; merged.set(k, m); }
    for (const o of f.ops) { m.count++; m.kinds.add(o.kind); m.firstAt = earlier(m.firstAt, o.at); m.lastAt = later(m.lastAt, o.at); }
  }
  return { files: [...merged.values()].map(m => ({ ...m, kinds: [...m.kinds].sort() })).sort((a, b) => String(a.firstAt).localeCompare(String(b.firstAt))) };
}

/** Edits of one file (matched by normalized path), strings clipped; truncated:true when anything was cut or omitted. */
export async function readChangeFile(file, env, filePath) {
  const raw = await streamChanges(file);
  if (!raw) return null;
  const want = keyOf(filePath, env);
  const hits = raw.filter(f => keyOf(f.path, env) === want);
  const ops = hits.flatMap(f => f.ops).sort((a, b) => String(a.at).localeCompare(String(b.at)));
  if (!ops.length) return null;
  let budget = CHANGE_TOTAL_MAX, truncated = false;
  const cut = s => { const c = capText(s, Math.min(CHANGE_STR_MAX, Math.max(0, budget))); budget -= Array.from(c.text).length; if (c.truncated) truncated = true; return c.text; };
  const edits = [];
  for (const o of ops) {
    if (edits.length >= CHANGE_EDITS_MAX || budget <= 0) { truncated = true; break; }
    const e = { kind: o.kind, at: o.at };
    if (o.kind === 'write') e.content = cut(o.content);
    else if (o.kind === 'edit') { e.old = cut(o.old); e.new = cut(o.new); e.replaceAll = o.replaceAll; }
    else { e.editMode = o.editMode; e.cellId = o.cellId; e.cellType = o.cellType; e.new = cut(o.new); }
    edits.push(e);
  }
  return { path: hits[0].path, edits, total: ops.length, truncated };
}

/** Agent Team members from <claude dir>/teams/<team>/config.json: agentId -> { name, agentType, team }. Only ids and names are kept. */
export async function readTeams(dir) {
  const members = new Map();
  for (const t of await readdirSafe(dir)) {
    if (!t.isDirectory()) continue;
    let o; try { o = JSON.parse(await fs.readFile(path.join(dir, t.name, 'config.json'), 'utf8')); } catch { continue; }
    if (!o || typeof o !== 'object' || !Array.isArray(o.members)) continue;
    for (const m of o.members) {
      if (!m || typeof m !== 'object' || typeof m.agentId !== 'string' || !m.agentId) continue;
      members.set(m.agentId, { name: typeof m.name === 'string' ? m.name : null, agentType: typeof m.agentType === 'string' ? m.agentType : null, team: t.name });
    }
  }
  return members;
}
const isLead = (agentType, member) => agentType === 'team-lead' || (member && member.agentType === 'team-lead');

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
      const byAgent = new Map(subs.map(s => [s.agentId, s]));
      for (const s of subs) {
        // nested sub-agents: the transcript that spawned an agent (Agent tool result / task notification) is its real parent
        s.spawned = await readSpawned(s.file, s.st, cache);
        s.comps = await readCompletions(s.file, s.st, cache);
      }
      for (const s of subs) {
        s.parentAgent = null;
        for (const p of subs) if (p !== s && p.spawned.has(s.agentId)) { s.parentAgent = p.agentId; break; }
      }
      for (const s of subs) {   // a cycle (should never happen) falls back to the session as parent
        const seenIds = new Set([s.agentId]);
        for (let p = s.parentAgent; p; p = byAgent.get(p).parentAgent) {
          if (seenIds.has(p)) { s.parentAgent = null; break; }
          seenIds.add(p);
        }
      }
      for (const s of subs) {
        s.tr = await readTranscript(s.file, s.st, cache, { growIfNoUsage: true });
        s.meta = await readMeta(s.file.replace(/\.jsonl$/, '.meta.json'), cache);
        skipped += s.tr.bad;
      }
      const projectPath = top.cwd || (subs.find(s => s.tr.cwd) || {}).tr?.cwd || null;
      groups.push({ uuid, file, st, top, subs, completions, byAgent, projectPath, projectLabel: projectPath ? null : slug.name });
    }
  }
  // hook events, once per project
  const hooksByKey = new Map();
  const watchExtra = [];
  for (const g of groups) {
    if (!g.projectPath) continue;
    const key = projectKey(g.projectPath, env.platform);
    if (hooksByKey.has(key)) continue;
    const h = await readHooks(g.projectPath, cache, env);
    hooksByKey.set(key, h);
    skipped += h.bad;
    for (const d of h.dirs) watchExtra.push(d);
  }
  const teams = await readTeams(path.join(path.dirname(env.claudeProjectsDir), 'teams'));
  const sessions = [];
  for (const g of groups) {
    const hookInfo = g.projectPath ? hooksByKey.get(projectKey(g.projectPath, env.platform)) : null;
    const hooks = hookInfo ? hookInfo.agents : new Map();
    const notifs = hookInfo ? hookInfo.notifs : new Map();
    const notifTypes = hookInfo ? hookInfo.notifTypes : new Map();
    const fails = hookInfo ? hookInfo.fails : new Map();
    const efforts = hookInfo ? hookInfo.efforts : new Map();
    const base = { tool: 'claude-code', projectPath: g.projectPath, projectLabel: g.projectLabel, archived: false };
    const mt = msToIso(g.st.mtimeMs);
    const title = clip(g.top.customTitle, 120) ? { title: clip(g.top.customTitle, 120), titleSource: 'explicit' }
      : clip(g.top.aiTitle, 120) ? { title: clip(g.top.aiTitle, 120), titleSource: 'summary' }
      : { title: `Session ${g.uuid.slice(0, 8)}`, titleSource: 'fallback' };
    sessions.push({ ...base, nativeId: g.uuid, parentNativeId: null, depth: 0, ...title, agentType: null, model: g.top.model, effort: efforts.get('s:' + g.uuid) || null,
      createdAt: g.top.createdAt || msToIso(g.st.birthtimeMs || g.st.mtimeMs), updatedAt: mt, endedAt: null,
      tokens: { context: g.top.tokens, total: null }, lastActivity: g.top.lastActivity,
      refs: { file: g.file, db: null, key: null }, ...(failedBasis(fails.get('s:' + g.uuid), g.st.mtimeMs) ? { failure: hookFailure(fails.get('s:' + g.uuid)) } : {}),
      stateBasis: failedBasis(fails.get('s:' + g.uuid), g.st.mtimeMs) || waitingBasis(g.top.pending, notifs.get('s:' + g.uuid), g.st.mtimeMs, mt, notifTypes.get('s:' + g.uuid)) || { kind: 'mtime', at: mt, stateSource: 'mtime' } });
    const seen = new Set();
    for (const s of g.subs) {
      seen.add(s.agentId);
      const member = teams.get(s.agentId) || null;
      if (isLead(s.meta && s.meta.agentType, member)) continue;   // the team lead is the main session, not an agent
      const rawHook = hooks.get(s.agentId);
      const resumed = resumedAfterStop(rawHook, s.tr.stamps);
      const hook = resumed ? { ...rawHook, stop: null } : rawHook;
      const smt = msToIso(s.st.mtimeMs);
      const parentSub = s.parentAgent ? g.byAgent.get(s.parentAgent) : null;
      let notif = [g.completions.get(s.agentId), parentSub && parentSub.comps.get(s.agentId)].filter(Boolean).sort((a, b) => Date.parse(b.at) - Date.parse(a.at))[0];
      if (resumed && notif && Date.parse(notif.at) < Date.parse(resumed)) notif = null;   // belongs to the run before the resume
      let done = latestCompletion(s.tr, notif);
      if (resumed && done && Date.parse(done.at) < Date.parse(resumed)) done = null;   // that end belongs to the run before the resume
      const runStartedAt = (hook && hook.stop) ? null : (resumed && !(done && done.state)) ? resumed : ((done && done.runStartedAt) || (resumed) || s.tr.runStartedAt || null);
      const fail = fails.get('a:' + s.agentId);
      const failB = failedBasis(fail, s.st.mtimeMs);
      sessions.push({ ...base, nativeId: s.agentId, parentNativeId: s.parentAgent || g.uuid, depth: 1, ...(member && member.name ? { title: clip(member.name, 120), titleSource: 'meta' } : subTitle(s.meta, s.agentId)),
        agentType: (s.meta && s.meta.agentType) || (hook && hook.agentType) || (member && member.agentType) || null,
        effort: efforts.get('a:' + s.agentId) || null,
        model: s.tr.model || (s.meta && s.meta.model) || null,
        createdAt: earlier(s.tr.createdAt, hook && hook.start) || smt, updatedAt: smt, endedAt: (hook && hook.stop) || (done && done.at) || null,
        ...(runStartedAt ? { runStartedAt } : {}),
        tokens: { context: s.tr.tokens, total: null }, lastActivity: s.tr.lastActivity,
        refs: { file: s.file, db: null, key: null }, failure: failB && (!s.tr.failure || s.tr.failure.kind === 'unknown') ? hookFailure(fail) : s.tr.failure,
        stateBasis: subBasis(hook, smt, done, waitingBasis(s.tr.pending, notifs.get('a:' + s.agentId), s.st.mtimeMs, smt, notifTypes.get('a:' + s.agentId)), failB) });
    }
    for (const [agentId, hook] of hooks) {
      if (seen.has(agentId) || hook.sessionId !== g.uuid) continue;
      // Stop-only hook events with no start, no agent type and no transcript file (seen is built from the files on disk) are not agents
      if (!hook.start && !hook.agentType) continue;
      const member = teams.get(agentId) || null;
      if (isLead(hook.agentType, member)) continue;   // lead events carry no sub-agent of their own
      const derived = hook.transcriptPath ? path.join(path.dirname(hook.transcriptPath), g.uuid, 'subagents', `agent-${agentId}.jsonl`) : null;
      sessions.push({ ...base, nativeId: agentId, parentNativeId: g.uuid, depth: 1,
        ...(member && member.name ? { title: clip(member.name, 120), titleSource: 'meta' } : { title: clip(hook.agentType, 120) || `agent ${agentId.slice(0, 8)}`, titleSource: 'fallback' }),
        agentType: hook.agentType || (member && member.agentType) || null, effort: efforts.get('a:' + agentId) || null, model: null, createdAt: hook.start || hook.stop, updatedAt: hook.stop || hook.start,
        endedAt: hook.stop || null, tokens: { context: null, total: null }, lastActivity: null,
        refs: { file: derived, db: null, key: null }, ...(fails.get('a:' + agentId) ? { failure: hookFailure(fails.get('a:' + agentId)) } : {}),
        stateBasis: subBasis(hook, null, null, null, failedBasis(fails.get('a:' + agentId), 0)) });
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
  async changes(env, session) {
    const file = session && session.refs && session.refs.file;
    return file ? readChangeList(file, env) : null;
  },
  async changeFile(env, session, filePath) {
    const file = session && session.refs && session.refs.file;
    return file ? readChangeFile(file, env, filePath) : null;
  },
  async commits(env, session) {
    const file = session && session.refs && session.refs.file;
    return file ? readCommitList(file) : null;
  },
};

// ---- agent commits: Bash `git commit` calls and their results (hash + subject; the pathspec after `--` gives the paths) ----
export const COMMITS_MAX = 100;
const resultText = c => (typeof c === 'string' ? c : Array.isArray(c) ? c.map(x => (x && typeof x.text === 'string' ? x.text : '')).join('\n') : '');

/** Splits a shell command into words and operators (outside quotes); quoted text stays inside one word. */
function shellWords(command) {
  const out = []; let cur = '', q = null, had = false, quoted = false;
  const push = () => { if (had) out.push({ w: cur, quoted }); cur = ''; had = false; quoted = false; };
  const chars = Array.from(String(command));
  for (let i = 0; i < chars.length; i++) {
    const ch = chars[i];
    if (q) { if (ch === q) q = null; else cur += ch; continue; }
    if (ch === '"' || ch === "'") { q = ch; had = true; quoted = true; continue; }
    if (ch === ';' || ch === '&' || ch === '|' || ch === '\n' || ch === '>' || ch === '<') { push(); out.push({ op: true }); continue; }
    if (ch === '#' && !had) { while (i < chars.length && chars[i] !== '\n') i++; continue; }
    if (/\s/.test(ch)) { push(); continue; }
    cur += ch; had = true;
  }
  push();
  return out;
}

/** Paths after a lone `--` in the last `git ... commit` of a command. [] when there is no pathspec. */
export function pathspecOf(command) {
  const words = shellWords(command);
  const segs = []; let seg = [];
  for (const x of words) { if (x.op) { segs.push(seg); seg = []; } else seg.push(x); }
  segs.push(seg);
  for (let i = segs.length - 1; i >= 0; i--) {
    const sg = segs[i];
    if (!sg.length || sg[0].w !== 'git' || !sg.some(x => !x.quoted && x.w === 'commit')) continue;
    const d = sg.findIndex(x => !x.quoted && x.w === '--');
    return d < 0 ? [] : sg.slice(d + 1).map(x => x.w).filter(x => x && !x.startsWith('-')).slice(0, 200);
  }
  return [];
}

/** Commits made by one transcript: [{hash, subject, at, paths}] in order. Only calls whose result shows a commit line count. */
export async function readCommitList(file) {
  let fh;
  try { fh = await fs.open(file, 'r'); } catch { return null; }
  const calls = new Map();   // tool_use id -> { at, paths }
  const commits = [];
  try {
    const rl = readline.createInterface({ input: fh.createReadStream({ encoding: 'utf8' }), crlfDelay: Infinity });
    for await (const line of rl) {
      const isUse = line.includes('git') && line.includes('commit') && line.includes('"tool_use"');
      if (!isUse && !line.includes('"tool_result"')) continue;
      let r; try { r = JSON.parse(line); } catch { continue; }
      if (!r || typeof r !== 'object' || !r.message || !Array.isArray(r.message.content)) continue;
      if (r.type === 'assistant') {
        for (const b of r.message.content) {
          if (!b || b.type !== 'tool_use' || b.name !== 'Bash' || !b.input || typeof b.input.command !== 'string' || typeof b.id !== 'string') continue;
          if (!/\bgit\b[^\n]*\bcommit\b/.test(b.input.command)) continue;
          calls.set(b.id, { at: toIso(r.timestamp), paths: pathspecOf(b.input.command) });
        }
      } else if (r.type === 'user') {
        for (const b of r.message.content) {
          if (!b || b.type !== 'tool_result' || b.is_error === true || !calls.has(b.tool_use_id)) continue;
          const m = /^\[[^\]\n]*\s([0-9a-f]{7,40})\][ \t]*(.*)$/m.exec(resultText(b.content));
          if (!m) continue;
          const c = calls.get(b.tool_use_id);
          commits.push({ hash: m[1], subject: capText(m[2], 300).text, at: c.at, paths: c.paths });
        }
      }
    }
  } finally { await fh.close(); }
  return commits.slice(-COMMITS_MAX);
}
