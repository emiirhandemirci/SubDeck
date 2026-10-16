// desk/test/task138.test.mjs: task essentials in Sessions (row marker, Task group, waiting jump) and the optional Tasks tab.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import { createTasksReader } from '../lib/tasks.mjs';
import { createApi } from '../lib/api.mjs';
import { rowBadges } from '../public/format.js';
import './fixtures/tmpclean.mjs';

const tmp = p => fs.mkdtempSync(path.join(os.tmpdir(), p));
const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const rd = f => fs.readFileSync(path.join(pub, f), 'utf8').replace(/\r\n/g, '\n');
const call = async (api, url) => {
  const res = new EventEmitter(); res.chunks = [];
  res.writeHead = s => { res.status = s; return res; }; res.write = c => { res.chunks.push(String(c)); return true; }; res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  await api.handle({ method: 'GET', url, headers: { host: '127.0.0.1:4917' } }, res);
  return JSON.parse(res.chunks.join(''));
};
const sess = (id, over = {}) => ({ id, nativeId: id, tool: 'claude-code', projectId: 'p_1', parentId: null, depth: 0, title: id, titleSource: 'summary', agentType: null,
  model: null, state: 'finished', stateSource: 'mtime', createdAt: '2026-10-07T09:00:00.000Z', updatedAt: '2026-10-07T09:00:00.000Z', endedAt: null, durationMs: 0,
  tokens: { context: null, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false, childCount: 0, ...over });
const taskFile = (id, status, extra = '') => `---\nid: ${id}\ntitle: Job ${id}\nstatus: ${status}\nowner: worker-sonnet\nagent: a1\n${extra}created: 2026-10-07T08:00:00Z\nupdated: 2026-10-07T09:30:00Z\n---\n## Task\n\n## Report\n\n## Handoff\n`;
function mk(files, sessions) {
  const dir = tmp('t138-');
  for (const [n, t] of Object.entries(files)) fs.writeFileSync(path.join(dir, n + '.md'), t);
  const snap = { lastScanAt: null, sources: [], projects: [{ id: 'p_1', path: '/proj/one', name: 'one', tools: [] }], sessions };
  const env = { platform: process.platform, home: tmp('t138-h-'), vars: { SUBDECK_TASKS_DIR: dir }, stateRoot: tmp('t138-s-') };
  return createApi({ core: { snapshot: () => snap }, getPort: () => 4917, startedAt: 'x', days: 14, version: '0', publicDir: tmp('t138-p-'), tasks: createTasksReader({ env, beadsEnabled: false }), env });
}

test('rowBadges: one task marker, needs-you > interrupted > review; unlinked agents get none', () => {
  const t = status => ({ state: 'finished', task: { id: 't-aaaa', status } });
  assert.equal(rowBadges(t('needs-user')).secondary.text, 'needs you');
  assert.match(rowBadges(t('needs-user')).secondary.title, /Task t-aaaa: needs-user/);
  assert.equal(rowBadges(t('interrupted')).secondary.text, 'interrupted');
  assert.equal(rowBadges(t('review')).secondary.text, 'review');
  assert.equal(rowBadges(t('in-progress')).secondary, null);
  assert.equal(rowBadges(t('done')).secondary, null);
  // needs-you beats an existing interrupted notice; review never replaces one
  assert.equal(rowBadges({ ...t('needs-user'), interrupted: { errorType: 'quota', files: 1 } }).secondary.text, 'needs you');
  assert.equal(rowBadges({ ...t('review'), interrupted: { errorType: 'quota', files: 1 } }).secondary.text, 'interrupted');
  assert.equal(rowBadges({ state: 'finished', parentId: 'p', tracked: false }).secondary, null);
  assert.equal(rowBadges(t('needs-user')).secondary.cls, 'mark mark-need');   // plain text, no box
});

test('project tree: linked agents carry task key and status, unlinked ones do not', async () => {
  const api = mk({ 't-aaaa': taskFile('t-aaaa', 'needs-user', 'question: Which db?\n'), 't-bbbb': taskFile('t-bbbb', 'done') },
    [sess('top'), sess('k1', { parentId: 'top', taskId: 't-aaaa' }), sess('k2', { parentId: 'top', taskId: 't-bbbb' }), sess('k3', { parentId: 'top' })]);
  const r = await call(api, '/api/projects/p_1');
  const kids = Object.fromEntries(r.sessions[0].children.map(c => [c.id, c]));
  assert.deepEqual(kids.k1.task, { id: 't-aaaa', status: 'needs-user' });
  assert.equal(kids.k2.accepted, true);
  assert.equal(kids.k3.task, undefined);
});

test('session detail: resume carries question, title and checkpoints; waiting item names the agent session', async () => {
  const api = mk({ 't-aaaa': taskFile('t-aaaa', 'needs-user', 'question: Which db?\n') }, [sess('top'), sess('a1', { parentId: 'top', taskId: 't-aaaa' })]);
  const d = await call(api, '/api/sessions/a1');
  assert.equal(d.session.resume.question, 'Which db?');
  assert.equal(d.session.resume.title, 'Job t-aaaa');
  assert.ok(Array.isArray(d.session.resume.checkpoints));
  const w = await call(api, '/api/waiting');
  assert.equal(w.items[0].agentSessionId, 'a1');
});

test('UI wiring: Task group, waiting item jumps to the agent, Tasks tab hidden when empty', () => {
  const app = rd('app.js'), tasks = rd('tasks.js'), html = rd('index.html');
  assert.match(app, /function taskGroup\(r\)/);
  assert.match(app, /tasks\.sh answer \$\{r\.taskId\}/);
  assert.match(app, /checkpointRows\(\{ checkpoints: r\.checkpoints \}, 3\)/);
  assert.match(app, /selectSession\(it\.agentSessionId, true\)/);
  assert.match(tasks, /b\.hidden = !has/);
  assert.match(html, /id="tabTasks"[^>]*\bhidden\b/);
});
