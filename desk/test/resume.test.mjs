// desk/test/resume.test.mjs  (task 090: a resumed sub-agent runs again; synthetic fixtures only, temp dirs)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import claude, { resumedAfterStop } from '../adapters/claude-code.mjs';
import { deriveState } from '../lib/model.mjs';
import { rec, writeJsonl, tmpDir } from './fixtures/claude-fixture.mjs';

// records: (ago, proj) => transcript records; hooks: (ago) => [[agoMs, event], ...]
async function run(records, hooks, mtimeAgo = 20000) {
  const root = tmpDir('desk-resume-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString();
  const proj = path.join(root, 'work', 'Resume');
  fs.mkdirSync(path.join(proj, '.subdeck'), { recursive: true });
  const dir = path.join(root, 'claude', 'projects', 'slug-r');
  writeJsonl(path.join(dir, 'sess-r', 'subagents', 'agent-rrrr.jsonl'), records(ago, proj), { mtimeMs: NOW - mtimeAgo });
  writeJsonl(path.join(dir, 'sess-r.jsonl'), [rec.user(ago(3600000), proj)], { mtimeMs: NOW - 1000 });
  const ev = (ts, event) => JSON.stringify({ ts, event, agent_id: 'rrrr', agent_type: 'w', session_id: 'sess-r', transcript_path: path.join(dir, 'sess-r.jsonl') });
  fs.writeFileSync(path.join(proj, '.subdeck', 'events.jsonl'), hooks(ago).map(([ms, e]) => ev(ago(ms), e)).join('\n') + '\n');
  const env = { now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: path.join(root, 'claude', 'projects') };
  const r = await claude.scan(env, { since: null, cache: new Map() });
  const s = r.sessions.find(x => x.nativeId === 'rrrr');
  return { s, ago, state: deriveState(s.stateBasis, NOW) };
}
const queued = ts => ({ type: 'attachment', timestamp: ts, attachment: { type: 'queued_command', commandMode: 'prompt', prompt: 'x' } });
const START = 'SubagentStart', STOP = 'SubagentStop';

test('plain stop stays finished', async () => {
  const { s, state } = await run((ago, p) => [rec.user(ago(300000), p), rec.endTurn(ago(200001))], () => [[300000, START], [200000, STOP]]);
  assert.equal(state.state, 'finished');
  assert.ok(s.endedAt);
});

test('stop then newer assistant records without a Start hook: running again, run starts at the first record after the Stop', async () => {
  const { s, state, ago } = await run(
    (ago, p) => [rec.user(ago(300000), p), rec.endTurn(ago(200001)), queued(ago(100000)), rec.tool(ago(99000), 'Bash', { command: 'x' }), rec.toolResult(ago(98000))],
    () => [[300000, START], [200000, STOP]]);
  assert.equal(state.state, 'running');
  assert.equal(s.runStartedAt, ago(100000));
  assert.equal(s.endedAt, null);
});

test('stop then a later Start hook (resume emits Start): running even without newer records', async () => {
  const { state } = await run((ago, p) => [rec.user(ago(300000), p), rec.endTurn(ago(200001))], () => [[300000, START], [200000, STOP], [150000, START]]);
  assert.equal(state.state, 'running');
});

test('stop -> resume -> stop: finished again', async () => {
  const { state } = await run(
    (ago, p) => [rec.user(ago(300000), p), rec.endTurn(ago(200001)), queued(ago(100000)), rec.tool(ago(99000), 'Bash', { command: 'x' }), rec.endTurn(ago(60001))],
    () => [[300000, START], [200000, STOP], [60000, STOP]]);
  assert.equal(state.state, 'finished');
});

test('resumed agent whose transcript went quiet becomes stale, not running forever', async () => {
  const { state } = await run(
    (ago, p) => [rec.user(ago(3 * 3600000), p), rec.endTurn(ago(3 * 3600000 - 1)), queued(ago(2 * 3600000)), rec.tool(ago(2 * 3600000 - 1000), 'Bash', { command: 'x' })],
    () => [[3 * 3600000, START], [3 * 3600000 - 2000, STOP]], 2 * 3600000);
  assert.equal(state.state, 'stale');
});

test('resumedAfterStop: margin and null cases', () => {
  const stop = '2026-01-01T10:00:00.000Z';
  assert.equal(resumedAfterStop(null, ['2026-01-01T10:05:00.000Z']), null);
  assert.equal(resumedAfterStop({ stop: null }, ['2026-01-01T10:05:00.000Z']), null);
  assert.equal(resumedAfterStop({ stop }, ['2026-01-01T09:59:59.000Z', '2026-01-01T10:00:01.000Z']), null);   // within the 2 s margin
  assert.equal(resumedAfterStop({ stop }, ['2026-01-01T10:00:05.000Z', '2026-01-01T10:01:00.000Z']), '2026-01-01T10:00:05.000Z');
  assert.equal(resumedAfterStop({ stop, lastStart: '2026-01-01T10:00:03.000Z' }, []), '2026-01-01T10:00:03.000Z');
});
