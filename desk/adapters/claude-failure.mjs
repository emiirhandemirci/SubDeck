// desk/adapters/claude-failure.mjs
// Deterministic failure classifier for Claude Code transcripts (no model call). Reads the last records of the latest run and
// returns { kind, detail } where detail is a fixed phrase. Transcript text is only matched, never copied out.

export const FAILURE_KINDS = ['test', 'permission', 'api', 'quota', 'timeout', 'tool', 'stuck', 'unknown'];
export const FAILURE_DETAIL = {
  test: 'test command failed',
  permission: 'tool permission denied',
  api: 'API error',
  quota: 'rate or usage limit reached',
  timeout: 'operation timed out',
  tool: 'repeated tool errors',
  stuck: 'many turns without edits',
  unknown: 'cause not recorded',
};

const RE_QUOTA = /rate[\s_-]?limit|usage limit|limit reached|\b429\b|quota|too many requests/i;
const RE_TIMEOUT = /timed?[\s-]?out|timeout|deadline exceeded/i;
const RE_PERMISSION = /permission denied|user rejected|was rejected|doesn'?t want to proceed|requested permissions|not allowed to use|blocked by (a )?hook/i;
const RE_TEST_CMD = /\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b|\bpytest\b|\bjest\b|\bvitest\b|\bcargo\s+test\b|\bgo\s+test\b|\bnode\s+(\S+\s+)*--test\b|\bmocha\b|\bctest\b|\bphpunit\b|\bdotnet\s+test\b|\bmvn\s+(\S+\s+)*test\b|\bgradle\w*\s+test\b/i;
const RE_TEST_FAIL = /\bFAIL(ED)?\b|\bfailed\b|\bfailures?\b/i;
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);
const STUCK_TURNS = 20;
const TOOL_ERRORS = 3;

const textOf = c => (typeof c === 'string' ? c : Array.isArray(c) ? c.map(x => (x && typeof x.text === 'string' ? x.text : '')).join('\n') : '');
const isPrompt = r => r.type === 'user' && r.message && typeof r.message === 'object' && !r.isMeta
  && !(Array.isArray(r.message.content) && r.message.content.some(b => b && b.type === 'tool_result'));
const out = kind => ({ kind, detail: FAILURE_DETAIL[kind] });

/** records: parsed transcript records in file order (a tail is fine). Returns { kind, detail }. */
export function classifyFailure(records) {
  let start = 0;
  for (let i = records.length - 1; i >= 0; i--) if (isPrompt(records[i])) { start = i + 1; break; }
  const run = records.slice(start);

  // 1. the run ended with an API error record
  for (let i = run.length - 1; i >= 0; i--) {
    const r = run[i];
    if (r.type !== 'assistant') continue;
    if (r.isApiErrorMessage === true) {
      const t = textOf(r.message && r.message.content) + ' ' + (typeof r.error === 'string' ? r.error : '');
      return out(RE_QUOTA.test(t) ? 'quota' : RE_TIMEOUT.test(t) ? 'timeout' : 'api');
    }
    break;
  }

  // 2. tool calls and their results
  const uses = new Map();   // tool_use id -> { name, command }
  const results = [];       // in order: { id, isError, text }
  let edits = 0, turns = 0;
  for (const r of run) {
    const c = r.message && r.message.content;
    if (r.type === 'assistant' && Array.isArray(c)) {
      turns++;
      for (const b of c) if (b && b.type === 'tool_use') {
        uses.set(b.id, { name: b.name, command: b.input && typeof b.input.command === 'string' ? b.input.command : '' });
        if (EDIT_TOOLS.has(b.name)) edits++;
      }
    } else if (r.type === 'user' && Array.isArray(c)) {
      for (const b of c) if (b && b.type === 'tool_result') results.push({ id: b.tool_use_id, isError: b.is_error === true, text: textOf(b.content) });
    }
  }
  const last = results[results.length - 1];
  if (last) {
    const use = uses.get(last.id) || { name: null, command: '' };
    if (last.isError && RE_PERMISSION.test(last.text)) return out('permission');
    if (last.isError && RE_TIMEOUT.test(last.text)) return out('timeout');
    if (RE_TEST_CMD.test(use.command) && (last.isError || RE_TEST_FAIL.test(last.text))) return out('test');
    if (last.isError && RE_QUOTA.test(last.text)) return out('quota');
    let n = 0;
    for (let i = results.length - 1; i >= 0 && results[i].isError; i--) n++;
    if (n >= TOOL_ERRORS) return out('tool');
  }
  if (turns >= STUCK_TURNS && edits === 0) return out('stuck');
  return out('unknown');
}
