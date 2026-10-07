// desk/test/v081.test.mjs: Desk 0.8.1 (task keys, not-tracked state, waves, cumulative tokens, quota)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { EventEmitter } from 'node:events';
import { parseTask, createTasksReader } from '../lib/tasks.mjs';
import { createApi } from '../lib/api.mjs';
import { stateDirs } from '../lib/paths.mjs';
import { readHooks, taskFields, readUsage } from '../adapters/claude-code.mjs';
import { agentBadges, cumulativeTokensText, agentTokensText, quotaText, cliText, waveText } from '../public/format.js';
import './fixtures/tmpclean.mjs';

const tmp = p => fs.mkdtempSync(path.join(os.tmpdir(), p));
const USAGE = fileURLToPath(new URL('./fixtures/usage-agent.jsonl', import.meta.url));
const NOW = Date.parse('2026-10-07T12:00:00Z');

const VERIFIED = `---
id: t-4d4d
title: Docs
status: review
pack: w1
grants: [docs/x.md]
covers: [t-4d4d, t-4e4e]
---
## Task
x

## Verification
### 2026-10-07T10:00:00Z verify (v1)
Verdict: Needs fixes
Fingerprint: aaa+dirty
Covers: t-4d4d, t-4e4e

### 2026-10-07T11:02:00Z verify (a81c2e0f)
Verdict: Approved
Fingerprint: 3c1e9a2+clean
Covers: t-4d4d, t-4e4e
`;

test('parseTask: auto, pack, grants, covers, latest verdict, verifiedBy', () => {
  const t = parseTask(VERIFIED, 't-4d4d').task;
  assert.equal(t.auto, false); assert.equal(t.pack, 'w1');
  assert.deepEqual(t.grants, ['docs/x.md']); assert.deepEqual(t.covers, ['t-4d4d', 't-4e4e']);
  assert.equal(t.verdict, 'Approved');
  assert.deepEqual(t.verifiedBy, { by: 'a81c2e0f', fingerprint: '3c1e9a2+clean', at: '2026-10-07T11:02:00Z' });
  const a = parseTask('---\nid: t-3c3c\nauto: true\nstatus: in-progress\npack: Bad Name\n---\n', 't-3c3c').task;
  assert.equal(a.auto, true); assert.equal(a.pack, ''); assert.equal(a.verdict, ''); assert.equal(a.verifiedBy, undefined);
});

function writeEvents(proj, env, lines) {
  const sd = stateDirs(proj, env)[0]; fs.mkdirSync(sd, { recursive: true });
  fs.writeFileSync(path.join(sd, 'events.jsonl'), lines.map(l => JSON.stringify(l)).join('\n') + '\n');
}
const E = (event, ts, agent, payload) => ({ ts, event, agent_id: agent, agent_type: 'worker-sonnet', session_id: 'sess1', transcript_path: '', payload });

test('readHooks: not tracked, task_link / task_verify ids, report_missing without task, report_too_long', async () => {
  const proj = '/proj/v81'; const env = { platform: process.platform, home: tmp('v81-h-'), vars: {}, stateRoot: tmp('v81-s-') };
  writeEvents(proj, env, [
    E('SubagentStart', '2026-10-07T09:00:00Z', 'a1', {}), E('task_link', '2026-10-07T09:01:00Z', 'a1', { agent_id: 'a1', task: 't-1111', prevTask: null, by: 'cli' }),
    E('SubagentStop', '2026-10-07T09:10:00Z', 'a1', {}), E('report_too_long', '2026-10-07T09:10:01Z', 'a1', { task: 't-1111', lines: 14, limit: 9 }),
    E('SubagentStart', '2026-10-07T09:00:00Z', 'a2', {}), E('SubagentStop', '2026-10-07T09:05:00Z', 'a2', {}), E('report_missing', '2026-10-07T09:05:01Z', 'a2', { task: null }),
    E('SubagentStart', '2026-10-07T09:00:00Z', 'v1', {}), E('task_verify', '2026-10-07T09:20:00Z', 'v1', { agent_id: 'v1', task: 't-1111', covers: ['t-1111'], verdict: 'Approved', fingerprint: null }),
  ]);
  const info = await readHooks(proj, new Map(), env);
  const f = id => taskFields(info, 'a:' + id, info.agents.get(id), 0);
  assert.deepEqual(f('a1'), { reportTooLong: { at: '2026-10-07T09:10:01.000Z', lines: 14 }, taskId: 't-1111', tracked: true });
  assert.deepEqual(f('a2'), { taskId: null, tracked: false });   // task:null report_missing is not a missing report
  assert.equal(f('v1').taskId, 't-1111');
});

test('agentBadges: not tracked only for untracked sub-agents; accepted; long report', () => {
  assert.deepEqual(agentBadges({ parentId: 'x', tracked: false }).map(b => b.text), ['not tracked']);
  assert.deepEqual(agentBadges({ parentId: null, tracked: false }).map(b => b.text), []);
  assert.deepEqual(agentBadges({ parentId: 'x', tracked: true, accepted: true, reportTooLong: { at: 'a', lines: 12 } }).map(b => b.text), ['accepted', 'long report (12 lines)']);
  assert.deepEqual(agentBadges({ parentId: 'x' }).map(b => b.text), []);   // no hook info: nothing claimed
});

test('readUsage: cumulative per agent, streamed message ids once, cache reads apart, incremental', async () => {
  const cache = new Map();
  const f = path.join(tmp('v81-u-'), 'agent.jsonl');
  fs.copyFileSync(USAGE, f);
  assert.deepEqual(await readUsage(f, fs.statSync(f), cache), { billed: 175, cached: 2200 });   // m1 once (150) + m2 (25)
  fs.appendFileSync(f, JSON.stringify({ type: 'assistant', message: { id: 'm3', usage: { input_tokens: 1, output_tokens: 2, cache_read_input_tokens: 5 } } }) + '\n{"type":"assis');
  assert.deepEqual(await readUsage(f, fs.statSync(f), cache), { billed: 178, cached: 2205 });   // partial last line ignored
  assert.equal(await readUsage(path.join(tmp('v81-e-'), 'none.jsonl'), { size: 0 }, new Map()), null);
});

test('formatters', () => {
  assert.equal(cumulativeTokensText({ tokens: { total: 175, cached: 2200 } }), '175 used, 2.2k cached');
  assert.equal(cumulativeTokensText({ tokens: { total: null } }), null);
  assert.equal(agentTokensText({ agentTokens: 120000 }), 'agents 120.0k tokens');
  assert.equal(agentTokensText({ agentTokens: null }), null);
  assert.match(quotaText({ at: '2026-10-07T11:30:00.000Z', reset: '5pm (UTC)', resetAt: null }), /11:30Z; resets 5pm \(UTC\)/);
  assert.equal(quotaText(null), null);
  assert.equal(cliText({ calls: 12, bytes: 3481, since: 'x' }), 'tasks.sh: 12 calls, 3.4 KB (24 h)');
  assert.equal(cliText({ calls: 0, bytes: 0, since: null }), null);
  assert.equal(waveText({ id: 'w1', tasks: ['a', 'b'], tokens: 1500 }), 'w1: 2 tasks, 1.5k tokens');
});

// ---- API ----
const P = 4917;
function call(api, url) {
  const res = new EventEmitter(); res.chunks = [];
  res.writeHead = (s, h) => { res.status = s; return res; };
  res.write = c => { res.chunks.push(String(c)); return true; };
  res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  return Promise.resolve(api.handle({ method: 'GET', url, headers: { host: `127.0.0.1:${P}` } }, res)).then(() => ({ status: res.status, body: JSON.parse(res.chunks.join('')) }));
}
const sess = (id, nativeId, over = {}) => ({ id, nativeId, tool: 'claude-code', sourceId: 'claude-code', projectId: 'p_1', parentId: 'top', depth: 1, title: id, titleSource: 'summary', agentType: null,
  model: null, state: 'finished', stateSource: 'mtime', createdAt: '2026-10-07T09:00:00.000Z', updatedAt: '2026-10-07T09:00:00.000Z', endedAt: null, durationMs: 0,
  tokens: { context: 10, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false, childCount: 0, ...over });

test('/api/tasks: waves, tokens, verifiedBy, quota, cli; accepted marker on the project tree', async () => {
  const dir = tmp('v81-t-');
  const w = (id, text) => fs.writeFileSync(path.join(dir, id + '.md'), text);
  w('t-4d4d', VERIFIED);
  w('t-4e4e', VERIFIED.replace('id: t-4d4d', 'id: t-4e4e').replace(/## Verification[\s\S]*$/, '## Verification\n### 2026-10-07T10:00:00Z verify (v1)\nVerdict: Needs fixes\n'));
  w('t-3c3c', '---\nid: t-3c3c\nauto: true\nstatus: in-progress\nagent: c3c3c3c3\n---\n');
  w('t-5f5f', '---\nid: t-5f5f\nstatus: open\n---\n');
  const proj = '/proj/one';
  const env = { platform: process.platform, home: tmp('v81-ah-'), vars: { SUBDECK_TASKS_DIR: dir }, stateRoot: tmp('v81-as-') };
  writeEvents(proj, env, [
    E('quota_recent', '2026-10-07T11:30:00Z', 'q', { reset: '5pm (UTC)', resetAt: null }),
    E('quota_recent', '2026-10-07T08:00:00Z', 'q', { reset: 'old', resetAt: null }),
    E('tasks_cli', '2026-10-07T11:00:00Z', '', { cmd: 'list', bytes: 1024 }), E('tasks_cli', '2026-10-07T11:01:00Z', '', { cmd: 'show', bytes: 2048 }),
    E('tasks_cli', '2026-10-05T11:01:00Z', '', { cmd: 'show', bytes: 9999 }),
    E('task_verify', '2026-10-07T11:02:00Z', 'ver1', { agent_id: 'ver1', task: 't-4d4d', covers: ['t-4d4d', 't-4e4e'], verdict: 'Approved', fingerprint: 'fp1' }),
  ]);
  const sessions = [
    sess('top', 'top', { parentId: null, depth: 0 }),
    sess('s.w1', 'w1', { taskId: 't-4d4d', tokens: { context: 5, total: 1000, cached: 50 } }),
    sess('s.w2', 'w2', { taskId: 't-4e4e', tokens: { context: 5, total: 500 } }),
    sess('s.ver', 'ver1', { taskId: 't-4d4d', tokens: { context: 5, total: 300 } }),
    sess('s.auto', 'c3c3c3c3', { taskId: 't-3c3c', tracked: true, tokens: { context: 7, total: null } }),
  ];
  const snap = { lastScanAt: null, sources: [], projects: [{ id: 'p_1', path: proj, name: 'one', tools: [] }], sessions };
  const api = createApi({ core: { snapshot: () => snap }, getPort: () => P, startedAt: 'x', days: 14, version: '0', publicDir: tmp('v81-pub-'), now: () => NOW, tasks: createTasksReader({ env, now: () => NOW, beadsEnabled: false }), env });
  const d = (await call(api, '/api/tasks')).body.projects[0];
  const t = id => d.tasks.find(x => x.id === id);
  assert.deepEqual(d.waves, [{ id: 'w1', tasks: ['t-4d4d', 't-4e4e'], agents: 3, tokens: 1800 }]);
  assert.equal(t('t-4d4d').wave, 'w1'); assert.equal(t('t-4e4e').wave, 'w1'); assert.equal(t('t-5f5f').wave, null);
  assert.equal(t('t-4d4d').tokens, 1300); assert.equal(t('t-4e4e').tokens, 500); assert.equal(t('t-3c3c').tokens, 7); assert.equal(t('t-5f5f').tokens, null);
  assert.equal(t('t-3c3c').auto, true); assert.equal(t('t-4d4d').verdict, 'Approved'); assert.equal(t('t-4e4e').verdict, 'Needs fixes');
  assert.deepEqual(t('t-4d4d').grants, ['docs/x.md']);
  assert.deepEqual(t('t-4e4e').verifiedBy, { by: 'ver1', fingerprint: 'fp1', at: '2026-10-07T11:02:00.000Z' });   // the event is newer than the file's block
  assert.deepEqual(d.quota, { at: '2026-10-07T11:30:00.000Z', reset: '5pm (UTC)', resetAt: null });
  assert.deepEqual(d.cli, { calls: 2, bytes: 3072, since: '2026-10-07T11:00:00.000Z' });
  // accepted: only sessions of tasks that are approved or done
  const kids = (await call(api, '/api/projects/p_1')).body.sessions[0].children;
  assert.deepEqual(kids.filter(c => c.accepted).map(c => c.id).sort(), ['s.ver', 's.w1']);   // t-4d4d approved; t-4e4e needs fixes; auto task open
  assert.equal((await call(api, '/api/sessions/s.w2')).body.session.accepted, undefined);
  assert.equal((await call(api, '/api/sessions/s.w1')).body.session.accepted, true);
});
