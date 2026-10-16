// desk/test/rule-events.test.mjs: rule events feed (guard_block, report_missing, needs_user, interrupted, verdict) and
// the resume info (Last done / Next, Handoff files) in the session detail.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import { createTasksReader, ruleRow } from '../lib/tasks.mjs';
import { createApi } from '../lib/api.mjs';
import { stateDirs } from '../lib/paths.mjs';
import { ruleEventRows } from '../public/tasks.js';
import './fixtures/tmpclean.mjs';

const tmp = p => fs.mkdtempSync(path.join(os.tmpdir(), p));
const PORT = 4917;
const call = async (api, url) => {
  const res = new EventEmitter(); res.chunks = [];
  res.writeHead = s => { res.status = s; return res; }; res.write = c => { res.chunks.push(String(c)); return true; }; res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  await api.handle({ method: 'GET', url, headers: { host: `127.0.0.1:${PORT}` } }, res);
  return JSON.parse(res.chunks.join(''));
};
const NOW = Date.parse('2026-10-13T12:00:00Z');
const ago = h => new Date(NOW - h * 3600000).toISOString();
const sess = (id, over = {}) => ({ id, nativeId: id, tool: 'claude-code', projectId: 'p_1', parentId: null, depth: 0, title: id, titleSource: 'summary', agentType: null,
  model: null, state: 'finished', stateSource: 'mtime', createdAt: ago(5), updatedAt: ago(5), endedAt: null, durationMs: 0,
  tokens: { context: null, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false, childCount: 0, ...over });
const ev = (ts, event, agent, payload) => JSON.stringify({ ts, event, agent_id: agent, agent_type: '', session_id: '', payload: { agent_id: agent, ...payload } });

function mk(lines, files = {}, sessions = []) {
  const dir = tmp('re-tasks-');
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(dir, name + '.md'), text);
  const env = { platform: process.platform, home: tmp('re-h-'), vars: { SUBDECK_TASKS_DIR: dir }, stateRoot: tmp('re-s-') };
  const sd = stateDirs('/proj/one', env)[0];
  fs.mkdirSync(sd, { recursive: true });
  fs.writeFileSync(path.join(sd, 'events.jsonl'), lines.join('\n') + '\n');
  const snap = { lastScanAt: null, sources: [], projects: [{ id: 'p_1', path: '/proj/one', name: 'one', tools: [] }], sessions };
  const tasks = createTasksReader({ env, beadsEnabled: false, now: () => NOW });
  return createApi({ core: { snapshot: () => snap }, getPort: () => PORT, startedAt: 'x', days: 14, version: '0', publicDir: tmp('re-p-'), tasks, env, now: () => NOW });
}

test('ruleRow: guard rules map to a one-line action, no command text, unknown kinds are not rule events', () => {
  const r = ruleRow({ event: 'guard_block', t: NOW, ts: ago(0), pl: { rule: 'force-push', decision: 'deny', agent_id: 'a1' } });
  assert.equal(r.text, 'force push blocked: use a normal push');
  assert.equal(r.agentId, 'a1');
  assert.match(ruleRow({ event: 'guard_block', t: NOW, ts: ago(0), pl: { rule: 'push', decision: 'ask' } }).text, /push needs your approval/);
  assert.match(ruleRow({ event: 'guard_block', t: NOW, ts: ago(0), pl: { rule: 'zzz', decision: 'ask' } }).text, /zzz rule fired \(needs your approval\)/);
  assert.equal(ruleRow({ event: 'tasks_cli', t: NOW, ts: ago(0), pl: {} }), null);
  assert.equal(ruleRow({ event: 'task_verify', t: NOW, ts: ago(0), pl: {} }), null);
});

test('/api/tasks: ruleEvents are the last 24 h, newest first, agent resolved to its session, every kind covered', async () => {
  const api = mk([
    ev(ago(1), 'guard_block', 'a1', { rule: 'force-push', decision: 'deny', tool: 'Bash' }),
    ev(ago(2), 'report_missing', 'a1', { task: 't-aaaa', missing: [] }),
    ev(ago(3), 'needs_user', 'a2', { task: 't-aaaa', question: 'SECRET QUESTION' }),
    ev(ago(4), 'task_interrupted', 'a2', { task: 't-bbbb', error_type: 'rate_limit' }),
    ev(ago(5), 'task_verify', 'a3', { task: 't-aaaa', verdict: 'accept' }),
    ev(ago(30), 'guard_block', 'a1', { rule: 'push', decision: 'ask' }),   // older than 24 h
  ], {}, [sess('s1', { nativeId: 'a1', agentType: 'worker-sonnet', parentId: 'x' })]);
  const p = (await call(api, '/api/tasks')).projects[0];
  assert.deepEqual(p.ruleEvents.map(e => e.kind), ['guard_block', 'report_missing', 'needs_user', 'task_interrupted', 'task_verify']);
  assert.equal(p.ruleEvents[0].agentSessionId, 's1');
  assert.equal(p.ruleEvents[0].agent, 'worker-sonnet');
  assert.equal(p.ruleEvents[2].agentSessionId, null);
  assert.equal(p.ruleEvents[2].agent, 'a2');
  assert.ok(!JSON.stringify(p.ruleEvents).includes('SECRET QUESTION'));
});

test('/api/tasks: no rule events means an empty list', async () => {
  const api = mk([ev(ago(1), 'tasks_cli', 'a1', { bytes: 1 })]);
  assert.deepEqual((await call(api, '/api/tasks')).projects[0].ruleEvents, []);
});

test('session detail carries resume info of the linked task; none without a task', async () => {
  const tf = '---\nid: t-aaaa\ntitle: Job\nstatus: interrupted\nowner: worker-sonnet\nagent: a1\ncreated: 2026-10-13T08:00:00Z\nupdated: 2026-10-13T09:30:00Z\n---\n## Task\n\n## Report\n\n## Handoff\n### 2026-10-13T09:00:00Z interrupted (quota)\nlast done: A\nnext: B\nfiles: 1\nuncommitted:\n    M x\ndiff --stat:\n';
  const api = mk([], { 't-aaaa': tf }, [sess('s1', { nativeId: 'a1', taskId: 't-aaaa' }), sess('s2', { nativeId: 'a2' })]);
  const d = (await call(api, '/api/sessions/s1')).session;
  assert.equal(d.resume.taskId, 't-aaaa');
  assert.equal(d.resume.handoff.lastDone, 'A');
  assert.equal(d.resume.handoff.next, 'B');
  assert.deepEqual(d.resume.handoff.fileList, ['M x']);
  assert.equal((await call(api, '/api/sessions/s2')).session.resume, null);
});

test('ruleEventRows: UI list is newest first, drops stale rows, empty list stays empty', () => {
  const rows = ruleEventRows({ ruleEvents: [{ at: ago(30), rule: 'a', text: 'old' }, { at: ago(2), rule: 'b', text: 'two' }, { at: ago(1), rule: 'c', text: 'one', agentSessionId: 's' }] }, NOW);
  assert.deepEqual(rows.map(r => r.text), ['one', 'two']);
  assert.deepEqual(ruleEventRows({}, NOW), []);
});

test('UI wiring: collapsible details list in the Tasks tab, detail pane shows the resume rows', () => {
  const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
  const rd = f => fs.readFileSync(path.join(pub, f), 'utf8').replace(/\r\n/g, '\n');
  const tasks = rd('tasks.js'), app = rd('app.js');
  assert.match(tasks, /el\('details', 'sect revents'\)/);
  assert.match(tasks, /if \(!rows\.length\) return null/);
  assert.match(tasks, /showSessions\(\); openSession\(p\.projectId, r\.agentSessionId\)/);
  assert.match(app, /if \(s\.resume\) box\.append\(taskGroup\(s\.resume\)\)/);
  assert.match(app, /resumeLines\(rt\)/);
});
