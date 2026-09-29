// desk/test/fixtures/claude-fixture.mjs
// Synthetic Claude Code transcript records mirroring the real layout (spec 5.1). No real content.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const tmpDir = prefix => fs.mkdtempSync(path.join(os.tmpdir(), prefix));
export const usage = (i, cc, cr, o) => ({ input_tokens: i, cache_creation_input_tokens: cc, cache_read_input_tokens: cr, output_tokens: o });
const msg = (content, u, model = 'claude-sonnet-4-5') => ({ role: 'assistant', model, content, ...(u ? { usage: u } : {}) });

export const rec = {
  user: (ts, cwd, text = 'USER_PROMPT_MARKER') => ({ type: 'user', timestamp: ts, cwd, sessionId: 's', message: { role: 'user', content: text } }),
  attachment: (ts, cwd) => ({ type: 'attachment', timestamp: ts, cwd, sessionId: 's', attachment: { type: 'x' } }),
  toolResult: ts => ({ type: 'user', timestamp: ts, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'TOOL_OUTPUT_MARKER' }] } }),
  text: (ts, text, u = null, model) => ({ type: 'assistant', timestamp: ts, requestId: 'r1', message: msg([{ type: 'text', text }], u, model) }),
  thinking: ts => ({ type: 'assistant', timestamp: ts, message: msg([{ type: 'thinking', thinking: 'THINKING_MARKER' }], null) }),
  tool: (ts, name, input, u = null) => ({ type: 'assistant', timestamp: ts, requestId: 'r2', message: msg([{ type: 'tool_use', id: 't1', name, input }], u) }),
  aiTitle: t => ({ type: 'ai-title', aiTitle: t, sessionId: 's' }),
  customTitle: t => ({ type: 'custom-title', customTitle: t, sessionId: 's' }),
};

export function setMtime(file, ms) { fs.utimesSync(file, ms / 1000, ms / 1000); }

/** records: objects or raw strings (raw strings are written verbatim, e.g. malformed lines). */
export function writeJsonl(file, records, { mtimeMs = null, crlf = false, trailer = '' } = {}) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const eol = crlf ? '\r\n' : '\n';
  fs.writeFileSync(file, records.map(r => (typeof r === 'string' ? r : JSON.stringify(r))).join(eol) + eol + trailer);
  if (mtimeMs) setMtime(file, mtimeMs);
}

export function writeMeta(transcriptFile, meta) {
  fs.writeFileSync(transcriptFile.replace(/\.jsonl$/, '.meta.json'), JSON.stringify(meta));
}
