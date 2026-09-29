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
