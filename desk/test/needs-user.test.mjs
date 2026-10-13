// desk/test/needs-user.test.mjs: resume point (Last done / Next), needs-user tasks and the honest "N waiting" count.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import { parseTask, parseHandoff, parseProgress, createTasksReader } from '../lib/tasks.mjs';
import { createApi } from '../lib/api.mjs';
import { resumeLines, COLUMNS, groupTasks } from '../public/tasks.js';
import './fixtures/tmpclean.mjs';

const tmp = p => fs.mkdtempSync(path.join(os.tmpdir(), p));
const PORT = 4917;
const call = async (api, url) => {
  const res = new EventEmitter(); res.chunks = [];
  res.writeHead = s => { res.status = s; return res; }; res.write = c => { res.chunks.push(String(c)); return true; }; res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  await api.handle({ method: 'GET', url, headers: { host: `127.0.0.1:${PORT}` } }, res);
  return JSON.parse(res.chunks.join(''));
};
const sess = (id, over = {}) => ({ id, nativeId: id, tool: 'claude-code', projectId: 'p_1', parentId: null, depth: 0, title: id, titleSource: 'summary', agentType: null,
  model: null, state: 'finished', stateSource: 'mtime', createdAt: '2026-10-07T09:00:00.000Z', updatedAt: '2026-10-07T09:00:00.000Z', endedAt: null, durationMs: 0,
  tokens: { context: null, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false, childCount: 0, ...over });
const taskFile = (id, status, extra = '', body = '') => `---\nid: ${id}\ntitle: Job ${id}\nstatus: ${status}\nowner: worker-sonnet\nagent: a1\n${extra}created: 2026-10-07T08:00:00Z\nupdated: 2026-10-07T09:30:00Z\n---\n## Task\n\n## Report\n\n## Handoff\n${body}`;

function mk(files, sessions = []) {
  const dir = tmp('nu-tasks-');
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(dir, name + '.md'), text);
  const snap = { lastScanAt: null, sources: [], projects: [{ id: 'p_1', path: '/proj/one', name: 'one', tools: [] }], sessions };
  const env = { platform: process.platform, home: tmp('nu-h-'), vars: { SUBDECK_TASKS_DIR: dir }, stateRoot: tmp('nu-s-') };
  const tasks = createTasksReader({ env, beadsEnabled: false });
  return createApi({ core: { snapshot: () => snap }, getPort: () => PORT, startedAt: 'x', days: 14, version: '0', publicDir: tmp('nu-p-'), tasks, env });
}

test('parseHandoff: last done, next and the uncommitted file list', () => {
  const h = '### 2026-10-07T10:00:00Z interrupted (rate_limit)\nagent: a (worker-sonnet)\nlast done: parser written\nnext: wire the flag\nfiles: 2\nuncommitted (git status --porcelain -- f.txt):\n     M f.txt\n    ?? new.txt\ndiff --stat:\n     f.txt | 1 +\nResume: read this note.\n';
  const r = parseHandoff(h);
  assert.equal(r.lastDone, 'parser written');
  assert.equal(r.next, 'wire the flag');
  assert.deepEqual(r.fileList, [' M f.txt', '?? new.txt']);
  assert.equal(r.files, 2);
  const none = parseHandoff('### 2026-10-07T10:00:00Z interrupted (quota)\nfiles: 0\n');
  assert.deepEqual([none.lastDone, none.next, none.fileList], [null, null, []]);
});

test('parseProgress: latest step block; task carries lastStep and question', () => {
  const body = '## Progress\n### 2026-10-07T09:00:00Z step\ndone: one\nnext: two\n### 2026-10-07T09:10:00Z step\nnext: three\n\n## Question\n';
  assert.deepEqual(parseProgress('### 2026-10-07T09:00:00Z step\ndone: one\nnext: two\n### 2026-10-07T09:10:00Z step\nnext: three\n'), { at: '2026-10-07T09:10:00Z', done: null, next: 'three' });
  assert.equal(parseProgress(''), null);
  const t = parseTask(`---\nid: t-aaaa\ntitle: x\nstatus: needs-user\nquestion: Which db?\n---\n${body}`, 't-aaaa').task;
  assert.equal(t.status, 'needs-user');
  assert.equal(t.invalid, false);
  assert.equal(t.question, 'Which db?');
  assert.equal(t.lastStep.next, 'three');
  assert.equal(parseTask('---\nid: t-aaaa\nstatus: open\n---\n', 't-aaaa').task.question, '');
});

test('/api/waiting: a needs-user task is listed with its question, task, agent and age', async () => {
  const api = mk({ 't-aaaa': taskFile('t-aaaa', 'needs-user', 'question: Postgres or SQLite?\n'), 't-bbbb': taskFile('t-bbbb', 'open') });
  const r = await call(api, '/api/waiting');
  assert.equal(r.items.length, 1);
  const it = r.items[0];
  assert.deepEqual([it.kind, it.taskId, it.question, it.agent, it.waitingKind, it.projectName], ['task', 't-aaaa', 'Postgres or SQLite?', 'a1', 'needs-user', 'one']);
  assert.equal(it.since, '2026-10-07T09:30:00Z');
});

test('/api/waiting: only live waiting sessions and needs-user tasks; 100 finished/stale/noticed sessions add nothing (the "106 waiting" bug)', async () => {
  const many = [];
  for (let i = 0; i < 40; i++) many.push(sess('f' + i, { state: 'finished', reportMissing: { at: '2026-10-01T00:00:00.000Z', task: 't-0a01' } }));
  for (let i = 0; i < 40; i++) many.push(sess('i' + i, { state: 'finished', interrupted: { at: '2026-10-01T00:00:00.000Z', task: 't-0a01', errorType: 'rate_limit', files: 1 } }));
  for (let i = 0; i < 20; i++) many.push(sess('s' + i, { state: 'stale' }));
  many.push(sess('live', { state: 'waiting', waitingKind: 'permission', waitingSince: '2026-10-07T09:00:00.000Z' }));
  const api = mk({ 't-aaaa': taskFile('t-aaaa', 'needs-user', 'question: Go?\n') }, many);
  const r = await call(api, '/api/waiting');
  assert.deepEqual(r.items.map(i => i.id).sort(), ['live', 'task:p_1/t-aaaa']);
  const pr = await call(api, '/api/projects');
  assert.equal(pr.projects[0].needsUserCount, 1);
  // the header sums waitingCount + needsUserCount; stopped-without-report / interrupted notices are never part of it
  const app = fs.readFileSync(fileURLToPath(new URL('../public/app.js', import.meta.url)), 'utf8');
  assert.match(app, /waitingCount \|\| 0\) \+ \(p\.needsUserCount \|\| 0\)/);
  assert.doesNotMatch(app, /noticeCount/);
});

test('/api/waiting: negative control, in-progress and interrupted tasks are not listed', async () => {
  const api = mk({ 't-aaaa': taskFile('t-aaaa', 'in-progress'), 't-bbbb': taskFile('t-bbbb', 'interrupted') });
  assert.deepEqual((await call(api, '/api/waiting')).items, []);
  assert.equal((await call(api, '/api/projects')).projects[0].needsUserCount, 0);
});

test('/api/tasks carries question and lastStep; Needs you column; resume lines', async () => {
  const api = mk({ 't-aaaa': taskFile('t-aaaa', 'needs-user', 'question: Q?\n'),
    't-cccc': taskFile('t-cccc', 'interrupted', '', '### 2026-10-07T09:00:00Z interrupted (quota)\nlast done: A\nnext: B\nfiles: 1\nuncommitted:\n    M x\ndiff --stat:\n') });
  const t = (await call(api, '/api/tasks')).projects[0].tasks;
  assert.equal(t.find(x => x.id === 't-aaaa').question, 'Q?');
  const ci = t.find(x => x.id === 't-cccc');
  assert.deepEqual(resumeLines(ci), ['Last done: A', 'Next: B']);
  assert.deepEqual(ci.handoff.fileList, ['M x']);
  assert.deepEqual(resumeLines({ status: 'interrupted', handoff: null, lastStep: { done: 'D', next: 'N' } }), ['Last done: D', 'Next: N']);
  assert.deepEqual(resumeLines({ handoff: null }), []);
  assert.ok(COLUMNS.some(c => c[0] === 'needs-user'));
  assert.equal(groupTasks([{ id: 'a', status: 'needs-user', updated: '1' }]).find(g => g.id === 'needs-user').tasks.length, 1);
});
