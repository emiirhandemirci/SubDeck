// desk/test/failure.test.mjs  (task 082: deterministic failure classifier; synthetic records only)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import claude from '../adapters/claude-code.mjs';
import { classifyFailure, FAILURE_DETAIL } from '../adapters/claude-failure.mjs';
import { createCore } from '../lib/core.mjs';
import { rec, writeJsonl, tmpDir } from './fixtures/claude-fixture.mjs';

const T = i => new Date(Date.UTC(2026, 8, 29, 10, 0, i)).toISOString();
const bash = (i, id, command) => ({ type: 'assistant', timestamp: T(i), message: { role: 'assistant', content: [{ type: 'tool_use', id, name: 'Bash', input: { command } }] } });
const res = (i, id, text, isError) => ({ type: 'user', timestamp: T(i), message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: text, ...(isError ? { is_error: true } : {}) }] } });
const apiErr = (i, text) => ({ ...rec.apiError(T(i)), error: text, message: { role: 'assistant', content: [{ type: 'text', text }] } });
const kind = recs => classifyFailure([rec.user(T(0), '/p'), ...recs]).kind;

test('classifier: test command failures', () => {
  assert.equal(kind([bash(1, 'a', 'npm test'), res(2, 'a', 'exit 1', true)]), 'test');
  assert.equal(kind([bash(1, 'a', 'pytest -q'), res(2, 'a', '3 failed, 10 passed', false)]), 'test');
  assert.equal(kind([bash(1, 'a', 'ls'), res(2, 'a', 'failed', false)]), 'unknown');   // not a test command, not an error
});

test('classifier: permission, timeout, api, quota', () => {
  assert.equal(kind([bash(1, 'a', 'rm x'), res(2, 'a', 'The user rejected this tool use', true)]), 'permission');
  assert.equal(kind([bash(1, 'a', 'sleep 9'), res(2, 'a', 'Command timed out after 120s', true)]), 'timeout');
  assert.equal(kind([apiErr(1, 'API Error: 500 internal')]), 'api');
  assert.equal(kind([apiErr(1, 'API Error: 429 rate limit exceeded')]), 'quota');
  assert.equal(kind([apiErr(1, 'Claude usage limit reached')]), 'quota');
  assert.equal(kind([apiErr(1, 'Request timed out')]), 'timeout');
});

test('classifier: repeated tool errors, stuck, unknown, and only the latest run counts', () => {
  const errs = [];
  for (let i = 0; i < 3; i++) errs.push(bash(1 + i * 2, 'e' + i, 'foo'), res(2 + i * 2, 'e' + i, 'boom', true));
  assert.equal(kind(errs), 'tool');
  const reads = [];
  for (let i = 0; i < 25; i++) reads.push(bash(1 + i * 2, 'r' + i, 'cat f'), res(2 + i * 2, 'r' + i, 'ok', false));
  assert.equal(kind(reads), 'stuck');
  const withEdit = [{ type: 'assistant', timestamp: T(1), message: { content: [{ type: 'tool_use', id: 'w', name: 'Edit', input: {} }] } }, ...reads];
  assert.equal(kind(withEdit), 'unknown');
  assert.equal(kind([]), 'unknown');
  // an old error before the latest prompt is ignored
  const old = [apiErr(1, 'API Error: 500'), rec.user(T(2), '/p')];
  assert.equal(classifyFailure(old).kind, 'unknown');
});

test('classifier: detail is a fixed phrase and never carries transcript text', () => {
  const r = classifyFailure([rec.user(T(0), '/p'), bash(1, 'a', 'npm test SECRET_CMD'), res(2, 'a', 'SECRET_OUTPUT failed', true)]);
  assert.equal(r.detail, FAILURE_DETAIL.test);
  assert.ok(!JSON.stringify(r).includes('SECRET'));
});

function setup(subRecords, mtimeAgo = 60000, notify = 'failed') {
  const root = tmpDir('desk-fail-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString();
  const proj = path.join(root, 'work', 'Delta');
  fs.mkdirSync(proj, { recursive: true });
  const dir = path.join(root, 'claude', 'projects', 'slug-d');
  writeJsonl(path.join(dir, 'sess-d', 'subagents', 'agent-ffff.jsonl'), subRecords(ago, proj), { mtimeMs: NOW - mtimeAgo });
  writeJsonl(path.join(dir, 'sess-d.jsonl'), [rec.user(ago(3600000), proj), rec.launched(ago(80000), 'ffff'), rec.notifyQueue(ago(59000), 'ffff', notify)], { mtimeMs: NOW - 1000 });
  const env = { now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: path.join(root, 'claude', 'projects') };
  return { env, NOW };
}

test('scan + core: failed agent carries failure; finished agent and the parent do not', async () => {
  const f = setup((ago, proj) => [rec.user(ago(70000), proj), bash(1, 'a', 'npm test'), res(2, 'a', 'FAIL x', true)]);
  const core = createCore({ env: f.env, adapters: [claude], now: () => f.NOW });
  await core.scanAll();
  const all = core.snapshot().sessions;
  const sub = all.find(s => s.nativeId === 'ffff');
  assert.equal(sub.state, 'failed');
  assert.deepEqual(sub.failure, { kind: 'test', detail: FAILURE_DETAIL.test });
  assert.equal(all.find(s => s.nativeId === 'sess-d').failure, undefined);

  const g = setup((ago, proj) => [rec.user(ago(70000), proj), bash(1, 'a', 'npm test'), res(2, 'a', 'FAIL x', true)], 60000, 'completed');
  const core2 = createCore({ env: g.env, adapters: [claude], now: () => g.NOW });
  await core2.scanAll();
  const s2 = core2.snapshot().sessions.find(s => s.nativeId === 'ffff');
  assert.equal(s2.state, 'finished');
  assert.equal('failure' in s2, false);
});
