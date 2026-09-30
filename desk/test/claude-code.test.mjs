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
