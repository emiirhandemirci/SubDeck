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
  // sub-agent transcript run boundaries
  endTurn: (ts, text = 'done') => ({ type: 'assistant', timestamp: ts, message: { role: 'assistant', model: 'claude-sonnet-4-5', stop_reason: 'end_turn', content: [{ type: 'text', text }] } }),
  apiError: ts => ({ type: 'assistant', timestamp: ts, isApiErrorMessage: true, error: 'API_ERROR_MARKER', message: { role: 'assistant', model: 'claude-sonnet-4-5', stop_reason: 'stop_sequence', content: [{ type: 'text', text: 'API_ERROR_MARKER' }] } }),
  resume: ts => ({ type: 'user', timestamp: ts, isMeta: true, message: { role: 'user', content: 'RESUME_PROMPT_MARKER' } }),
  // parent transcript completion records (real shapes, content replaced)
  notifyText: (id, status, dur) => ['<task-notification>', '<task-id>' + id + '</task-id>', '<tool-use-id>toolu_x</tool-use-id>', '<output-file>…</output-file>', '<status>' + status + '</status>', '<summary>…</summary>',
    ...(dur === null || dur === undefined ? [] : ['<result>NOTIFY_RESULT_MARKER</result>', '<usage><subagent_tokens>9</subagent_tokens><tool_uses>2</tool_uses><duration_ms>' + dur + '</duration_ms></usage>']), '</task-notification>'].join('\n'),
  notifyAttachment: (ts, id, status, dur) => ({ type: 'attachment', timestamp: ts, attachment: { type: 'queued_command', commandMode: 'task-notification',
    prompt: rec.notifyText(id, status, dur), source_uuid: 'u', origin: { kind: 'task-notification', producer: 'p' }, timestamp: ts,
    ...(dur === null || dur === undefined ? {} : { usage: { totalTokens: 999999, toolUses: 2, durationMs: dur } }) } }),
  notifyQueue: (ts, id, status, dur) => ({ type: 'queue-operation', operation: 'enqueue', timestamp: ts, sessionId: 's', content: rec.notifyText(id, status, dur) }),
  notifyUser: (ts, id, status, dur) => ({ type: 'user', timestamp: ts, origin: { kind: 'task-notification' }, message: { role: 'user', content: rec.notifyText(id, status, dur) } }),
  launched: (ts, id) => ({ type: 'user', timestamp: ts, toolUseResult: { isAsync: true, status: 'async_launched', agentId: id, description: '…', outputFile: '…' }, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: '…' }] } }),
  foregroundResult: (ts, id, status = 'completed', dur = 5000) => ({ type: 'user', timestamp: ts, toolUseResult: { status, agentId: id, agentType: 'worker-sonnet', content: [{ type: 'text', text: 'FG_RESULT_MARKER' }], totalDurationMs: dur, totalTokens: 999999, totalToolUseCount: 3, usage: {} }, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'FG_RESULT_MARKER' }] } }),
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
