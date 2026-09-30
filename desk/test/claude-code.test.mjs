// desk/test/claude-code.test.mjs  (reader part; Task B2 appends scan tests to this file)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { parseJsonl, summarizeRecords, readTranscript, TAIL_BYTES } from '../adapters/claude-code.mjs';
import { rec, usage, writeJsonl, tmpDir } from './fixtures/claude-fixture.mjs';

const T = '2026-09-29T10:00:00.000Z';

test('parseJsonl: CRLF, malformed counted, partial trailing line is not counted as skipped', () => {
  const r = parseJsonl('{"a":1}\r\nnot json\n{"b":2}\n{"c":');
  assert.equal(r.records.length, 2);
  assert.equal(r.bad, 1);
  const d = parseJsonl('tail-of-a-line"}\n{"a":1}\n', { dropFirst: true });
  assert.deepEqual(d, { records: [{ a: 1 }], bad: 0 });
});

test('summarizeRecords: last usage line wins (no summing), titles, model', () => {
  const s = summarizeRecords([
    rec.aiTitle('Old'), rec.text(T, 'a', usage(10, 100, 1000, 5)),
    rec.tool(T, 'Edit', { file_path: '/a/b.sh' }, usage(10, 100, 79000, 390)),
    rec.aiTitle('New title'), rec.customTitle('Renamed'),
  ]);
  assert.equal(s.tokens, 79500);
  assert.equal(s.aiTitle, 'New title');
  assert.equal(s.customTitle, 'Renamed');
  assert.equal(s.model, 'claude-sonnet-4-5');
});

test('summarizeRecords: last activity kinds and privacy', () => {
  const at = n => `2026-09-29T10:00:0${n}.000Z`;
  assert.deepEqual(summarizeRecords([rec.tool(at(1), 'Read', { file_path: 'C:\\x\\main.rs', limit: 5 })]).lastActivity,
    { at: at(1), kind: 'tool', toolName: 'Read', summary: 'Read C:\\x\\main.rs' });
  assert.deepEqual(summarizeRecords([rec.text(at(2), 'First line\nsecond line')]).lastActivity,
    { at: at(2), kind: 'assistant', toolName: null, summary: 'First line' });
  assert.deepEqual(summarizeRecords([rec.text(at(1), 'x'), rec.toolResult(at(3))]).lastActivity,
    { at: at(3), kind: 'tool', toolName: null, summary: null });
  assert.deepEqual(summarizeRecords([rec.user(at(4), '/p')]).lastActivity,
    { at: at(4), kind: 'user', toolName: null, summary: null });
  assert.deepEqual(summarizeRecords([rec.thinking(at(5))]).lastActivity,
    { at: at(5), kind: 'assistant', toolName: null, summary: null });
  assert.equal(summarizeRecords([rec.text(at(1), 'y'.repeat(200))]).lastActivity.summary.length, 80);
  assert.equal(summarizeRecords([{ type: 'assistant', message: { content: [] } }]).tokens, null);
});

test('readTranscript: head gives cwd/createdAt; tail grows to 256 KB when no usage in 64 KB', async () => {
  const dir = tmpDir('desk-cc-');
  const f = path.join(dir, 's.jsonl');
  const filler = rec.text(T, 'z'.repeat(1000));
  const lines = [rec.attachment(T, 'E:\\Work\\Alpha'), rec.tool(T, 'Bash', { command: 'npm test' }, usage(1, 2, 3, 4))];
  for (let i = 0; i < 100; i++) lines.push(filler);           // ~100 KB without usage after the usage line
  writeJsonl(f, lines);
  const st = fs.statSync(f);
  assert.ok(st.size > TAIL_BYTES);
  const cache = new Map();
  const r = await readTranscript(f, st, cache, { growIfNoUsage: true });
  assert.equal(r.cwd, 'E:\\Work\\Alpha');
  assert.equal(r.createdAt, T);
  assert.equal(r.tokens, 10);
  assert.equal(r.bad, 0);                                        // cut first line of the tail window is dropped, not counted
  assert.equal(cache.size, 1);
  const again = await readTranscript(f, st, cache, { growIfNoUsage: true });
  assert.equal(again, r);                                        // cached by path|size|mtime
});

// appended to desk/test/claude-code.test.mjs
import claude, { readHooks } from '../adapters/claude-code.mjs';
import { writeMeta, setMtime } from './fixtures/claude-fixture.mjs';
import { deriveState } from '../lib/model.mjs';

function buildScenario() {
  const root = tmpDir('desk-ccs-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString();
  const projects = path.join(root, 'claude', 'projects');
  const alpha = path.join(root, 'work', 'Alpha');
  fs.mkdirSync(path.join(alpha, '.subdeck', 'events.d'), { recursive: true });
  // slug deliberately disagrees with cwd: project path must come from cwd
  const slugA = path.join(projects, 'zz--not-the-path');
  const s1 = path.join(slugA, 'sess-1111.jsonl');
  writeJsonl(s1, [rec.attachment(ago(600000), alpha), rec.aiTitle('Old'), rec.user(ago(590000), alpha),
    rec.text(ago(60000), 'Working on it', usage(1, 2, 3, 4)), rec.aiTitle('Alpha manager')], { mtimeMs: NOW - 30000 });
  const sub = path.join(slugA, 'sess-1111', 'subagents');
  const a1 = path.join(sub, 'agent-aaaa1111.jsonl');           // hook Start+Stop -> finished
  writeJsonl(a1, [rec.user(ago(500000), alpha), rec.tool(ago(400000), 'Edit', { file_path: '/a/b.sh' }, usage(10, 100, 79000, 390))], { mtimeMs: NOW - 400000 });
  writeMeta(a1, { agentType: 'worker-sonnet', description: 'Write the parser', model: 'sonnet', spawnDepth: 1 });
  const a2 = path.join(sub, 'agent-bbbb2222.jsonl');           // hook Start only, fresh -> running
  writeJsonl(a2, [rec.user(ago(100000), alpha), rec.text(ago(5000), 'Now testing')], { mtimeMs: NOW - 5000 });
  writeMeta(a2, { agentType: 'researcher', description: 'Research formats' });
  const a3 = path.join(sub, 'agent-cccc3333.jsonl');           // hook Start only, old -> stale; meta missing
  writeJsonl(a3, [rec.user(ago(7200000), alpha), 'this is not json'], { mtimeMs: NOW - 7200000 });
  const a4 = path.join(sub, 'agent-dddd4444.jsonl');           // no hook data -> mtime rule (idle)
  writeJsonl(a4, [rec.user(ago(600000), alpha)], { mtimeMs: NOW - 600000 });
  writeMeta(a4, { agentType: 'verifier' });
  const ev = (ts, event, id, type) => JSON.stringify({ ts, event, agent_id: id, agent_type: type, transcript_path: s1, session_id: 'sess-1111',
    payload: { last_assistant_message: 'HOOK_MESSAGE_MARKER' } });
  fs.writeFileSync(path.join(alpha, '.subdeck', 'events.jsonl'), [
    ev(ago(500000), 'SubagentStart', 'aaaa1111', 'worker-sonnet'),
    ev(ago(100000), 'SubagentStart', 'bbbb2222', 'researcher'),
    ev(ago(7200000), 'SubagentStart', 'cccc3333', 'w'),
    '{broken',
  ].join('\n') + '\n');
  fs.writeFileSync(path.join(alpha, '.subdeck', 'events.d', '1-1-1.json'), ev(ago(300000), 'SubagentStop', 'aaaa1111', 'worker-sonnet'));
  fs.writeFileSync(path.join(alpha, '.subdeck', 'events.d', '2-2-2.json'), ev(ago(20000), 'SubagentStart', 'eeee5555', 'worker-opus') + '\n');
  // second project: custom title, CRLF, no hooks
  const beta = path.join(root, 'work', 'Beta');
  fs.mkdirSync(beta, { recursive: true });
  writeJsonl(path.join(projects, 'c--beta', 'sess-2222.jsonl'), [rec.user(ago(900000), beta), rec.aiTitle('AI'), rec.customTitle('Renamed beta')], { mtimeMs: NOW - 3600000, crlf: true });
  // old session outside retention
  writeJsonl(path.join(projects, 'c--beta', 'sess-old.jsonl'), [rec.user(ago(30 * 86400000), beta)], { mtimeMs: NOW - 30 * 86400000 });
  // session without cwd
  writeJsonl(path.join(projects, 'c--nocwd', 'sess-3333.jsonl'), [rec.aiTitle('No cwd')], { mtimeMs: NOW - 1000 });
  const env = { now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: projects };
  return { root, NOW, env, alpha, beta, s1, a1, projects };
}

test('scan: sessions, sub-agents, titles, tokens, hooks, retention', async () => {
  const sc = buildScenario();
  assert.equal(await claude.detect(sc.env), true);
  const r = await claude.scan(sc.env, { since: null, cache: new Map() });
  const by = Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));
  assert.deepEqual(Object.keys(by).sort(), ['aaaa1111', 'bbbb2222', 'cccc3333', 'dddd4444', 'eeee5555', 'sess-1111', 'sess-2222', 'sess-3333']);
  const st = s => deriveState(s.stateBasis, sc.NOW).state;

  assert.equal(by['sess-1111'].projectPath, sc.alpha);
  assert.equal(by['sess-1111'].title, 'Alpha manager');
  assert.equal(by['sess-1111'].titleSource, 'summary');
  assert.equal(by['sess-1111'].tokens.context, 10);
  assert.equal(st(by['sess-1111']), 'running');
  assert.equal(by['sess-1111'].refs.file, sc.s1);

  assert.equal(by.aaaa1111.parentNativeId, 'sess-1111');
  assert.equal(by.aaaa1111.title, 'Write the parser');
  assert.equal(by.aaaa1111.titleSource, 'meta');
  assert.equal(by.aaaa1111.agentType, 'worker-sonnet');
  assert.equal(by.aaaa1111.model, 'sonnet');
  assert.equal(by.aaaa1111.tokens.context, 79500);
  assert.deepEqual(by.aaaa1111.stateBasis, { kind: 'fixed', state: 'finished', stateSource: 'hook' });
  assert.ok(by.aaaa1111.endedAt);
  assert.equal(by.aaaa1111.lastActivity.summary, 'Edit /a/b.sh');

  assert.equal(st(by.bbbb2222), 'running');
  assert.equal(by.bbbb2222.stateBasis.stateSource, 'hook');
  assert.equal(st(by.cccc3333), 'stale');
  assert.equal(by.cccc3333.title, 'agent cccc3333');
  assert.equal(by.cccc3333.titleSource, 'fallback');
  assert.equal(st(by.dddd4444), 'idle');
  assert.equal(by.dddd4444.title, 'verifier');

  assert.equal(by.eeee5555.title, 'worker-opus');                // hook-only agent
  assert.equal(by.eeee5555.parentNativeId, 'sess-1111');
  assert.equal(st(by.eeee5555), 'running');

  assert.equal(by['sess-2222'].title, 'Renamed beta');
  assert.equal(by['sess-2222'].titleSource, 'explicit');
  assert.equal(st(by['sess-2222']), 'finished');
  assert.equal(by['sess-3333'].projectPath, null);
  assert.equal(by['sess-3333'].projectLabel, 'c--nocwd');

  assert.equal(r.skipped, 2);                                     // 'this is not json' + '{broken'
  assert.deepEqual(r.watchExtra, [path.join(sc.alpha, '.subdeck')]);
  const json = JSON.stringify(r);
  for (const m of ['USER_PROMPT_MARKER', 'HOOK_MESSAGE_MARKER', 'TOOL_OUTPUT_MARKER', 'THINKING_MARKER']) assert.ok(!json.includes(m), m);
});

test('scan: second scan with unchanged files reuses the cache', async () => {
  const sc = buildScenario();
  const cache = new Map();
  await claude.scan(sc.env, { since: null, cache });
  const size = cache.size;
  const r = await claude.scan(sc.env, { since: sc.NOW, cache });
  assert.equal(cache.size, size);
  assert.equal(r.sessions.length, 8);
});

test('watchPaths and detect on a missing dir', async () => {
  const sc = buildScenario();
  assert.deepEqual(claude.watchPaths(sc.env, { watchExtra: ['/x/.subdeck'] }),
    [{ path: sc.projects, recursive: true }, { path: '/x/.subdeck', recursive: true }]);
  assert.equal(await claude.detect({ ...sc.env, claudeProjectsDir: path.join(sc.root, 'nope') }), false);
});

test('readHooks folds start/stop per agent and ignores payload', async () => {
  const sc = buildScenario();
  const h = await readHooks(sc.alpha, new Map());
  assert.equal(h.bad, 1);
  const a = h.agents.get('aaaa1111');
  assert.ok(a.start && a.stop && a.start < a.stop);
  assert.equal(a.sessionId, 'sess-1111');
  assert.equal(JSON.stringify([...h.agents.values()]).includes('HOOK_MESSAGE_MARKER'), false);
  assert.equal((await readHooks(sc.beta, new Map())).dir, null);
});

test('readHooks ignores a trailing partial line in events.jsonl (not malformed)', async () => {
  const proj = tmpDir('subdeck-hook-');
  const d = path.join(proj, '.subdeck');
  fs.mkdirSync(d);
  const line = JSON.stringify({ event: 'SubagentStart', agent_id: 'zz1', ts: '2026-01-01T00:00:00Z' });
  fs.writeFileSync(path.join(d, 'events.jsonl'), line + '\n{"event":"SubagentSt');
  const h = await readHooks(proj, new Map());
  assert.equal(h.bad, 0);
  assert.ok(h.agents.has('zz1'));
});

// ---- explicit completion signals (task 023) ----
function completionScenario(build) {
  const root = tmpDir('desk-cc-done-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString();
  const proj = path.join(root, 'work', 'Gamma');
  fs.mkdirSync(proj, { recursive: true });
  const dir = path.join(root, 'claude', 'projects', 'slug-g');
  const parent = path.join(dir, 'sess-g.jsonl');
  const subDir = path.join(dir, 'sess-g', 'subagents');
  const sub = (id, records, mtimeAgo) => writeJsonl(path.join(subDir, `agent-${id}.jsonl`), records, { mtimeMs: NOW - mtimeAgo });
  const parentRecs = build({ ago, sub, proj, NOW });
  writeJsonl(parent, [rec.user(ago(3600000), proj), ...parentRecs], { mtimeMs: NOW - 1000 });
  const env = { now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: path.join(root, 'claude', 'projects') };
  return { env, NOW, ago, proj, parent, subDir };
}
const scanBy = async (sc, cache = new Map()) => {
  const r = await claude.scan(sc.env, { since: null, cache });
  return { r, by: Object.fromEntries(r.sessions.map(s => [s.nativeId, s])) };
};
const st = (s, now) => deriveState(s.stateBasis, now);

test('completion: background notification (attachment) -> finished/field even with a fresh mtime', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('aaaa', [rec.user(ago(70000), proj), rec.tool(ago(60000), 'Edit', {}), rec.endTurn(ago(50000))], 5000);
    return [rec.launched(ago(80000), 'aaaa'), rec.notifyAttachment(ago(49000), 'aaaa', 'completed', 21000)];
  });
  const { by } = await scanBy(sc);
  assert.deepEqual(st(by.aaaa, sc.NOW), { state: 'finished', stateSource: 'field' });
  assert.equal(by.aaaa.endedAt, sc.ago(49000));
  assert.equal(by.aaaa.runStartedAt, sc.ago(49000 + 21000));   // notification durationMs preferred
});

test('completion: failed notification (queue-operation + user forms, no usage) -> failed/field', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('bbbb', [rec.user(ago(70000), proj), rec.apiError(ago(60000))], 60000);
    return [rec.launched(ago(80000), 'bbbb'), rec.notifyQueue(ago(59000), 'bbbb', 'failed'), rec.notifyUser(ago(58000), 'bbbb', 'failed')];
  });
  const { by } = await scanBy(sc);
  assert.deepEqual(st(by.bbbb, sc.NOW), { state: 'failed', stateSource: 'field' });
  assert.equal(by.bbbb.endedAt, sc.ago(58000));
});

test('completion: killed -> finished; unknown task ids (bash tasks) are ignored', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('cccc', [rec.user(ago(70000), proj), rec.text(ago(60000), 'x')], 60000);
    return [rec.notifyQueue(ago(50000), 'cccc', 'killed'), rec.notifyAttachment(ago(40000), 'bash123', 'completed', 5)];
  });
  const { by, r } = await scanBy(sc);
  assert.deepEqual(st(by.cccc, sc.NOW), { state: 'finished', stateSource: 'field' });
  assert.equal(by.bash123, undefined);
  assert.equal(r.skipped, 0);
});

test('completion: sub-agent transcript ends with end_turn / API error and no parent record -> field', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('dd01', [rec.user(ago(70000), proj), rec.endTurn(ago(50000))], 50000);
    sub('dd02', [rec.user(ago(70000), proj), rec.text(ago(60000), 'x'), rec.apiError(ago(50000))], 50000);
    sub('dd03', [rec.user(ago(70000), proj), rec.tool(ago(50000), 'Bash', { command: 'ls' })], 50000);   // still running
    return [];
  });
  const { by } = await scanBy(sc);
  assert.deepEqual(st(by.dd01, sc.NOW), { state: 'finished', stateSource: 'field' });
  assert.equal(by.dd01.endedAt, sc.ago(50000));
  assert.deepEqual(st(by.dd02, sc.NOW), { state: 'failed', stateSource: 'field' });
  assert.deepEqual(st(by.dd03, sc.NOW), { state: 'running', stateSource: 'mtime' });
  assert.equal(by.dd03.endedAt, null);
});

test('completion: resumed after completion -> mtime state again, run duration from the resume', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('eeee', [rec.user(ago(900000), proj), rec.endTurn(ago(880000)), rec.resume(ago(20000)), rec.tool(ago(10000), 'Read', { file_path: 'x' })], 10000);
    return [rec.notifyAttachment(ago(879000), 'eeee', 'completed', 21000)];
  });
  const { by } = await scanBy(sc);
  assert.deepEqual(st(by.eeee, sc.NOW), { state: 'running', stateSource: 'mtime' });
  assert.equal(by.eeee.endedAt, null);
  assert.equal(by.eeee.runStartedAt, sc.ago(20000));
  assert.equal(by.eeee.createdAt, sc.ago(900000));
});

test('completion: resumed, second run also completed -> finished with the latest run window', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('ffff', [rec.user(ago(900000), proj), rec.endTurn(ago(880000)), rec.resume(ago(60000)), rec.endTurn(ago(44000))], 44000);
    return [rec.notifyAttachment(ago(879000), 'ffff', 'completed', 21000), rec.notifyAttachment(ago(43000), 'ffff', 'completed', 16000)];
  });
  const { by } = await scanBy(sc);
  assert.deepEqual(st(by.ffff, sc.NOW), { state: 'finished', stateSource: 'field' });
  assert.equal(by.ffff.endedAt, sc.ago(43000));
  assert.equal(by.ffff.runStartedAt, sc.ago(43000 + 16000));
});

test('completion: foreground Agent tool_result in the parent (status + agentId)', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('gggg', [rec.user(ago(70000), proj), rec.text(ago(50000), 'x')], 2000);
    sub('hhhh', [rec.user(ago(70000), proj), rec.text(ago(50000), 'x')], 2000);
    return [rec.foregroundResult(ago(40000), 'gggg', 'completed', 12000), rec.foregroundResult(ago(30000), 'hhhh', 'failed', 3000)];
  });
  const { by } = await scanBy(sc);
  assert.deepEqual(st(by.gggg, sc.NOW), { state: 'finished', stateSource: 'field' });
  assert.equal(by.gggg.endedAt, sc.ago(40000));
  assert.equal(by.gggg.runStartedAt, sc.ago(52000));
  assert.deepEqual(st(by.hhhh, sc.NOW), { state: 'failed', stateSource: 'field' });
});

test('completion: hook Stop keeps the top priority (stateSource hook)', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('iiii', [rec.user(ago(70000), proj), rec.endTurn(ago(50000))], 50000);
    fs.mkdirSync(path.join(proj, '.subdeck'), { recursive: true });
    const ev = (ts, event) => JSON.stringify({ ts, event, agent_id: 'iiii', agent_type: 'w', session_id: 'sess-g', transcript_path: '/x' });
    fs.writeFileSync(path.join(proj, '.subdeck', 'events.jsonl'), [ev(ago(70000), 'SubagentStart'), ev(ago(45000), 'SubagentStop')].join('\n') + '\n');
    return [rec.notifyAttachment(ago(49000), 'iiii', 'failed')];
  });
  const { by } = await scanBy(sc);
  assert.deepEqual(by.iiii.stateBasis, { kind: 'fixed', state: 'finished', stateSource: 'hook' });
});

test('completion: parent read is incremental and never leaks message content', async () => {
  const sc = completionScenario(({ ago, sub, proj }) => {
    sub('jjjj', [rec.user(ago(70000), proj), rec.text(ago(50000), 'x')], 1000);
    return [rec.launched(ago(60000), 'jjjj'), rec.foregroundResult(ago(59000), 'other', 'completed', 1)];
  });
  const cache = new Map();
  let { by } = await scanBy(sc, cache);
  assert.equal(st(by.jjjj, sc.NOW).state, 'running');
  fs.appendFileSync(sc.parent, JSON.stringify(rec.notifyAttachment(sc.ago(500), 'jjjj', 'completed', 9000)) + '\n');
  ({ by } = await scanBy(sc, cache));
  assert.deepEqual(st(by.jjjj, sc.NOW), { state: 'finished', stateSource: 'field' });
  const json = JSON.stringify(by);
  for (const m of ['NOTIFY_RESULT_MARKER', 'API_ERROR_MARKER', 'FG_RESULT_MARKER', 'RESUME_PROMPT_MARKER']) assert.ok(!json.includes(m), m);
});

// ---- on-demand content (task 024) ----
import { readContent, toolTarget, PROMPT_MAX, TOOL_CALLS_MAX } from '../adapters/claude-code.mjs';

test('readContent: sub-agent prompt, tool calls with targets and ok/error, thinking marker, final report', async () => {
  const f = path.join(tmpDir('desk-content-'), 'agent-a1.jsonl');
  const at = n => `2026-09-29T10:00:0${n}.000Z`;
  const res = (ts, id, err) => ({ type: 'user', timestamp: ts, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: 'OUT', ...(err ? { is_error: true } : {}) }] } });
  const use = (ts, id, name, input) => ({ type: 'assistant', timestamp: ts, message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } });
  writeJsonl(f, [
    { ...rec.user(at(0), '/p', 'Do the sub task\nsecond line'), isMeta: true },
    use(at(1), 'u1', 'Read', { file_path: '/a/b.txt', limit: 5 }),
    res(at(2), 'u1', false),
    use(at(3), 'u2', 'Grep', { pattern: 'foo.*bar', path: '/src' }),
    res(at(4), 'u2', true),
    use(at(5), 'u3', 'Bash', { command: 'npm test', description: 'run' }),
    rec.thinking(at(6)),
    use(at(7), 'u4', 'Edit', { file_path: '/a/c.txt', old_string: 'x', new_string: 'y' }),
    use(at(8), 'u5', 'Agent', { description: 'Sub helper', prompt: 'long prompt', subagent_type: 'w' }),
    rec.endTurn(at(9), 'Final words here'),
  ]);
  const c = await readContent(f, { subagent: true });
  assert.equal(c.prompt, 'Do the sub task\nsecond line');
  assert.equal(c.promptTruncated, false);
  assert.deepEqual(c.toolCalls.map(t => [t.tool, t.target, t.ok]), [
    ['Read', '/a/b.txt', true], ['Grep', 'foo.*bar', false], ['Bash', 'npm test', null], ['Thinking', '', null], ['Edit', '/a/c.txt', null], ['Agent', 'Sub helper', null]]);
  assert.equal(c.toolCalls[0].at, at(1));
  assert.equal(c.finalReport, 'Final words here');
  assert.equal(c.toolCallsTruncated, false);
  assert.ok(!JSON.stringify(c).includes('THINKING_MARKER'));
  assert.ok(!JSON.stringify(c).includes('"OUT"'));
});

test('readContent: top-level prompt skips meta/command records; caps', async () => {
  const f = path.join(tmpDir('desk-content-'), 's.jsonl');
  const big = 'x'.repeat(PROMPT_MAX + 50);
  const calls = Array.from({ length: TOOL_CALLS_MAX + 20 }, (_, i) => rec.tool(T, 'Read', { file_path: `/f${i}` }));
  writeJsonl(f, [{ ...rec.user(T, '/p', 'META'), isMeta: true }, rec.user(T, '/p', '<local-command-caveat>x'), rec.user(T, '/p', big), ...calls, rec.text(T, 'bye')]);
  const c = await readContent(f, { subagent: false });
  assert.equal(c.prompt.length, PROMPT_MAX);
  assert.equal(c.promptTruncated, true);
  assert.equal(c.toolCalls.length, TOOL_CALLS_MAX);
  assert.equal(c.toolCalls.at(-1).target, `/f${TOOL_CALLS_MAX + 19}`);
  assert.equal(c.toolCallsTruncated, true);
  assert.equal(c.toolCallTotal, TOOL_CALLS_MAX + 20);
  assert.equal(await readContent(path.join(tmpDir('x-'), 'none.jsonl'), { subagent: true }), null);
});

test('toolTarget: first meaningful argument, clipped to one line', () => {
  assert.equal(toolTarget({ pattern: 'a', path: '/b' }), 'a');
  assert.equal(toolTarget({ zzz: 'line1\nline2' }), 'line1 line2');
  assert.equal(toolTarget({ command: 'y'.repeat(300) }).length, 200);
  assert.equal(toolTarget(null), '');
  assert.equal(toolTarget({ n: 1 }), '');
});

// ---- waiting state (task 031) ----
test('summarizeRecords: trailing AskUserQuestion / ExitPlanMode without a result is pending; an answer clears it', () => {
  const at = n => `2026-09-29T10:00:0${n}.000Z`;
  assert.deepEqual(summarizeRecords([rec.user(at(1), '/p'), rec.ask(at(2))]).pending, { at: at(2), name: 'AskUserQuestion' });
  assert.deepEqual(summarizeRecords([rec.exitPlan(at(2))]).pending, { at: at(2), name: 'ExitPlanMode' });
  assert.equal(summarizeRecords([rec.ask(at(2)), rec.answer(at(3))]).pending, null);
  assert.equal(summarizeRecords([rec.ask(at(2)), rec.answer(at(3)), rec.text(at(4), 'ok')]).pending, null);
  assert.equal(summarizeRecords([rec.tool(at(2), 'Bash', { command: 'ls' })]).pending, null);   // ordinary tool: unknowable from the transcript
  assert.equal(JSON.stringify(summarizeRecords([rec.ask(at(2))])).includes('QUESTION_MARKER'), false);
});

function waitingScenario({ notif = null, transcript }) {
  const root = tmpDir('desk-cc-wait-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString();
  const proj = path.join(root, 'work', 'Delta');
  fs.mkdirSync(path.join(proj, '.subdeck'), { recursive: true });
  const projects = path.join(root, 'claude', 'projects');
  const f = path.join(projects, 'slug-d', 'sess-d.jsonl');
  writeJsonl(f, [rec.user(ago(120000), proj), ...transcript({ ago, proj })], { mtimeMs: NOW - 30000 });
  if (notif) fs.writeFileSync(path.join(proj, '.subdeck', 'events.jsonl'), JSON.stringify({ ts: notif.ts(ago), event: 'Notification', agent_id: '', agent_type: '', transcript_path: f, session_id: 'sess-d',
    payload: { notification_type: notif.type, message: 'NOTIF_MESSAGE_MARKER' } }) + '\n');
  return { env: { now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: projects }, NOW };
}
const waitState = async sc => { const r = await claude.scan(sc.env, { since: null, cache: new Map() }); return { s: r.sessions[0], d: deriveState(r.sessions[0].stateBasis, sc.NOW) }; };

test('waiting: pending question / plan approval -> waiting (field)', async () => {
  for (const mk of [rec.ask, rec.exitPlan]) {
    const { d } = await waitState(waitingScenario({ transcript: ({ ago }) => [mk(ago(30000))] }));
    assert.deepEqual(d, { state: 'waiting', stateSource: 'field' });
  }
});

test('waiting: answered question -> running by mtime again', async () => {
  const { d } = await waitState(waitingScenario({ transcript: ({ ago }) => [rec.ask(ago(60000)), rec.answer(ago(30000))] }));
  assert.deepEqual(d, { state: 'running', stateSource: 'mtime' });
});

test('waiting: a very old pending question expires to the mtime rule', async () => {
  const sc = waitingScenario({ transcript: ({ ago }) => [rec.ask(ago(30000))] });
  const later = deriveState((await claude.scan(sc.env, { since: null, cache: new Map() })).sessions[0].stateBasis, sc.NOW + 7 * 3600000);
  assert.equal(later.state, 'finished');
});

test('waiting: Notification permission_prompt newer than the last transcript write -> waiting (hook)', async () => {
  const sc = waitingScenario({ notif: { type: 'permission_prompt', ts: ago => ago(29000) }, transcript: ({ ago }) => [rec.tool(ago(31000), 'Bash', { command: 'ls' })] });
  const { s, d } = await waitState(sc);
  assert.deepEqual(d, { state: 'waiting', stateSource: 'hook' });
  assert.equal(JSON.stringify(s).includes('NOTIF_MESSAGE_MARKER'), false);
});

test('waiting: Notification older than later activity, or idle_prompt, does not mean waiting', async () => {
  const old = await waitState(waitingScenario({ notif: { type: 'permission_prompt', ts: ago => ago(100000) }, transcript: ({ ago }) => [rec.tool(ago(31000), 'Bash', {})] }));
  assert.equal(old.d.state, 'running');
  const idle = await waitState(waitingScenario({ notif: { type: 'idle_prompt', ts: ago => ago(29000) }, transcript: ({ ago }) => [rec.text(ago(31000), 'hi')] }));
  assert.equal(idle.d.state, 'running');
});

test('readHooks: Notification events are kept per session for waiting types only', async () => {
  const proj = tmpDir('subdeck-notif-');
  const d = path.join(proj, '.subdeck');
  fs.mkdirSync(d);
  const n = (ts, type, sid) => JSON.stringify({ ts, event: 'Notification', agent_id: '', session_id: sid, payload: { notification_type: type } });
  fs.writeFileSync(path.join(d, 'events.jsonl'), [n('2026-01-01T00:00:00Z', 'permission_prompt', 's1'), n('2026-01-01T00:00:09Z', 'elicitation_dialog', 's1'),
    n('2026-01-01T00:00:20Z', 'idle_prompt', 's1'), n('2026-01-01T00:00:05Z', 'agent_needs_input', 's2')].join('\n') + '\n');
  const h = await readHooks(proj, new Map());
  assert.equal(h.notifs.get('s:s1'), '2026-01-01T00:00:09.000Z');
  assert.equal(h.notifs.get('s:s2'), '2026-01-01T00:00:05.000Z');
  assert.equal(h.agents.size, 0);
});
