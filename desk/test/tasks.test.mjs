// desk/test/tasks.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { EventEmitter } from 'node:events';
import { resolveBd, runBd, parseFrontmatter, parseList, parseHandoff, parseTask, resolveTasksDir, createTasksReader, createTasksWatcher, mapBeads } from '../lib/tasks.mjs';
import { createApi } from '../lib/api.mjs';
import { readHooks, taskFields } from '../adapters/claude-code.mjs';
import { groupTasks, handoffSummary, COLUMNS } from '../public/tasks.js';

const FIX = fileURLToPath(new URL('../../plugins/subdeck/tests/fixtures/tasks/', import.meta.url));
const tmp = p => fs.mkdtempSync(path.join(os.tmpdir(), p));
const env0 = (over = {}) => ({ platform: process.platform, home: tmp('tk-home-'), vars: {}, stateRoot: tmp('tk-state-'), ...over });

test('frontmatter: grammar, CRLF, duplicates, odd lines', () => {
  const r = parseFrontmatter('---\r\nid: t-1a1a\r\ntitle: a: b\r\nTitle: x\r\nbad line\r\nstatus:\r\nstatus: review\r\n---\r\n## Task\r\nhi\r\n');
  assert.deepEqual(r.fm, { id: 't-1a1a', title: 'a: b', status: 'review' });
  assert.equal(r.ok, true);
  assert.equal(r.body, '## Task\nhi\n');
  assert.equal(parseFrontmatter('no front\n').ok, false);
  assert.equal(parseFrontmatter('---\nid: x\n').ok, false);   // never closed
  assert.deepEqual(parseList('[a, b,, c ]'), ['a', 'b', 'c']);
  assert.deepEqual(parseList('a, b'), ['a', 'b']);
  assert.deepEqual(parseList('[]'), []);
  assert.deepEqual(parseList(''), []);
});

test('handoff: latest block header and files', () => {
  const h = '### 2026-10-07T09:00:00Z interrupted (quota)\nfiles: 1\n\n### 2026-10-07T10:02:11Z interrupted (rate_limit)\nagent: a\nfiles: 2\nuncommitted:\n    M x\n';
  assert.deepEqual(parseHandoff(h), { at: '2026-10-07T10:02:11Z', errorType: 'rate_limit', files: 2 });
  assert.equal(parseHandoff(''), null);
  assert.equal(parseHandoff('### 2026 note\nfiles: 3'), null);
});

test('shared fixtures: every valid file matches expected.tsv, bad ids are ignored', async t => {
  if (!fs.existsSync(path.join(FIX, 'expected.tsv'))) return t.skip('fixtures not present');
  const r = await createTasksReader({ env: env0({ vars: { SUBDECK_TASKS_DIR: FIX } }), beadsEnabled: false }).read('/nowhere');
  const rows = fs.readFileSync(path.join(FIX, 'expected.tsv'), 'utf8').trim().split('\n').slice(1).map(l => l.split('\t'));
  assert.equal(r.tasks.length, rows.length);
  assert.ok(!r.tasks.some(x => x.task.id === 't-0g07'));
  for (const [id, status, blockedBy, writable, archived, invalid] of rows) {
    const x = r.tasks.find(y => y.task.id === id);
    assert.ok(x, id);
    assert.equal(x.task.status, status, id);
    assert.equal(x.task.blockedBy.join(','), blockedBy, id);
    assert.equal(x.task.writable.join(','), writable, id);
    assert.equal(String(x.task.archived), archived, id);
    assert.equal(String(x.task.invalid), invalid, id);
  }
  const d = r.tasks.find(y => y.task.id === 't-0d04');
  assert.deepEqual(d.handoff, { at: '2026-10-07T10:02:11Z', errorType: 'rate_limit', files: 2 });
  assert.equal(r.tasks.find(y => y.task.id === 't-0a01').handoff, null);
});

test('dir resolution: env, project config, user config, default, relative and absolute', () => {
  const home = tmp('tk-h-'), proj = tmp('tk-p-'), root = tmp('tk-r-');
  const env = { platform: process.platform, home, vars: {}, stateRoot: root };
  const def = resolveTasksDir(proj, env);
  assert.ok(def.startsWith(root) && def.endsWith(path.sep + 'tasks'));
  fs.mkdirSync(path.join(home, '.subdeck'), { recursive: true });
  fs.writeFileSync(path.join(home, '.subdeck', 'config.json'), JSON.stringify({ tasks: { dir: 'user/tasks' } }));
  assert.equal(resolveTasksDir(proj, env), path.join(proj, 'user', 'tasks'));
  fs.mkdirSync(path.join(proj, '.subdeck'), { recursive: true });
  fs.writeFileSync(path.join(proj, '.subdeck', 'config.json'), JSON.stringify({ tasks: { dir: 'docs/tasks' } }));   // legacy project config beats user
  assert.equal(resolveTasksDir(proj, env), path.join(proj, 'docs', 'tasks'));
  const sd = path.dirname(def);
  fs.mkdirSync(sd, { recursive: true });
  fs.writeFileSync(path.join(sd, 'config.json'), JSON.stringify({ tasks: { dir: '/abs/tasks' } }));   // state config beats legacy
  assert.equal(resolveTasksDir(proj, env), path.normalize('/abs/tasks'));
  assert.equal(resolveTasksDir(proj, { ...env, vars: { SUBDECK_TASKS_DIR: '/envdir' } }), path.normalize('/envdir'));
  fs.writeFileSync(path.join(sd, 'config.json'), '{ not json');   // broken config is ignored
  assert.equal(resolveTasksDir(proj, env), path.join(proj, 'docs', 'tasks'));
});

function writeTask(dir, id, extra = {}, body = '## Task\nx\n') {
  const fm = { id, title: `Task ${id}`, status: 'open', owner: 'worker-sonnet', agent: '', session: '', transcript: '', 'blocked-by': '[]', writable: '[]', created: '2026-10-07T09:00:00Z', updated: '2026-10-07T09:00:00Z', ...extra };
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, id + '.md'), `---\n${Object.entries(fm).map(([k, v]) => `${k}: ${v}`).join('\n')}\n---\n${body}`);
}

test('reader: ignores dotfiles, tmp and odd names; cache follows size and mtime; archive and live', async () => {
  const dir = tmp('tk-d-');
  writeTask(dir, 't-aaaa');
  writeTask(path.join(dir, 'archive'), 't-bbbb', { status: 'done' });
  fs.writeFileSync(path.join(dir, '.t-cccc.md.tmp.123'), 'x');
  fs.writeFileSync(path.join(dir, 't-dddd.md.tmp.1'), 'x');
  fs.writeFileSync(path.join(dir, 'notes.md'), 'x');
  fs.writeFileSync(path.join(dir, 't-zzzz.md'), 'x');
  fs.mkdirSync(path.join(dir, '.lock'));
  const rd = createTasksReader({ env: env0({ vars: { SUBDECK_TASKS_DIR: dir } }), beadsEnabled: false });
  let r = await rd.read('/p');
  assert.deepEqual(r.tasks.map(x => x.task.id).sort(), ['t-aaaa', 't-bbbb']);
  assert.equal(r.tasks.find(x => x.task.id === 't-bbbb').task.archived, true);
  const sig1 = await rd.signature('/p');
  writeTask(dir, 't-aaaa', { status: 'review', updated: '2026-10-07T11:00:00Z' });
  r = await rd.read('/p');
  assert.equal(r.tasks.find(x => x.task.id === 't-aaaa').task.status, 'review');
  assert.notEqual(await rd.signature('/p'), sig1);
  assert.equal((await rd.get('/p', 't-bbbb')).body, '## Task\nx\n');
  assert.equal(await rd.get('/p', 't-9999'), null);
  assert.equal(await rd.get('/p', '../etc'), null);
  assert.deepEqual((await createTasksReader({ env: env0({ vars: { SUBDECK_TASKS_DIR: path.join(dir, 'nope') } }), beadsEnabled: false }).read('/p')).tasks, []);
});

test('unknown status maps to open and is flagged; missing frontmatter is tolerated', () => {
  const a = parseTask('---\nid: t-1111\nstatus: weird\n---\n', 't-1111');
  assert.equal(a.task.status, 'open'); assert.equal(a.task.invalid, true);
  const b = parseTask('just text', 't-2222');
  assert.equal(b.task.title, 't-2222'); assert.equal(b.task.invalid, true);
});

// ---- API ----
const P = 4917;
function call(api, url, { host = `127.0.0.1:${P}` } = {}) {
  const res = new EventEmitter();
  res.chunks = [];
  res.writeHead = (s, h) => { res.status = s; res.headers = h; return res; };
  res.write = c => { res.chunks.push(String(c)); return true; };
  res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  return Promise.resolve(api.handle({ method: 'GET', url, headers: { host } }, res)).then(() => res);
}
const bodyOf = r => JSON.parse(r.chunks.join(''));
const sess = (id, over = {}) => ({ id, nativeId: id, tool: 'claude-code', sourceId: 'claude-code', projectId: 'p_1', parentId: null, depth: 0, title: id, titleSource: 'summary', agentType: null,
  model: null, state: 'finished', stateSource: 'mtime', createdAt: '2026-10-07T09:00:00.000Z', updatedAt: '2026-10-07T09:00:00.000Z', endedAt: null, durationMs: 0,
  tokens: { context: null, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false, childCount: 0, ...over });

function mkApi(dir, { contentEnabled = true, sessions = [] } = {}) {
  const snap = { lastScanAt: null, sources: [], projects: [{ id: 'p_1', path: '/proj/one', name: 'one', tools: [] }, { id: 'p_2', path: null, name: 'nopath', tools: [] }], sessions };
  const env = env0({ vars: { SUBDECK_TASKS_DIR: dir } });
  const tasks = createTasksReader({ env, beadsEnabled: false });
  return { api: createApi({ core: { snapshot: () => snap }, getPort: () => P, startedAt: 'x', days: 14, version: '0', publicDir: tmp('tk-pub-'), contentEnabled, tasks, env }), tasks };
}

test('GET /api/tasks and /api/tasks/<project>/<id>', async () => {
  const dir = tmp('tk-api-');
  writeTask(dir, 't-0d04', { status: 'interrupted', agent: 'a81c2e0f', 'blocked-by': '[t-07be]' }, '## Task\nx\n\n## Handoff\n### 2026-10-07T10:02:11Z interrupted (rate_limit)\nfiles: 2\n');
  const { api } = mkApi(dir, { sessions: [sess('claude.a1', { parentId: 'claude.top', nativeId: 'a81c2e0f', depth: 1 })] });
  const r = await call(api, '/api/tasks');
  assert.equal(r.status, 200);
  const d = bodyOf(r);
  assert.equal(d.projects.length, 1);   // only projects with a path
  assert.equal(d.projects[0].projectId, 'p_1'); assert.equal(d.projects[0].projectName, 'one'); assert.equal(d.projects[0].dir, dir);
  const t = d.projects[0].tasks[0];
  assert.equal(t.id, 't-0d04'); assert.equal(t.source, 'subdeck'); assert.equal(t.agentSessionId, 'claude.a1');
  assert.deepEqual(t.blockedBy, ['t-07be']);
  assert.deepEqual(t.handoff, { at: '2026-10-07T10:02:11Z', errorType: 'rate_limit', files: 2 });
  assert.equal(t.file, path.join(dir, 't-0d04.md'));
  assert.equal(bodyOf(await call(api, '/api/tasks?project=p_1')).projects.length, 1);
  assert.equal((await call(api, '/api/tasks?project=p_9')).status, 404);
  const one = await call(api, '/api/tasks/p_1/t-0d04');
  assert.equal(one.status, 200);
  assert.ok(bodyOf(one).task.body.includes('## Handoff'));
  assert.equal((await call(api, '/api/tasks/p_1/t-ffff')).status, 404);
  assert.equal((await call(api, '/api/tasks/p_2/t-0d04')).status, 404);
  assert.equal((await call(api, '/api/tasks', { host: 'evil.example' })).status, 403);
});

test('--no-content: detail is 404, list still works', async () => {
  const dir = tmp('tk-nc-'); writeTask(dir, 't-aaaa');
  const { api } = mkApi(dir, { contentEnabled: false });
  assert.equal((await call(api, '/api/tasks')).status, 200);
  assert.equal((await call(api, '/api/tasks/p_1/t-aaaa')).status, 404);
});

test('SSE tasks event', async () => {
  const { api } = mkApi(tmp('tk-sse-'));
  const res = new EventEmitter(); res.chunks = [];
  res.writeHead = () => res; res.write = c => { res.chunks.push(String(c)); return true; }; res.end = () => {};
  await api.handle({ method: 'GET', url: '/api/stream', headers: { host: `127.0.0.1:${P}` } }, res);
  api.broadcastTasks(['p_1']);
  const m = /event: tasks\ndata: (.*)\n/.exec(res.chunks.join(''));
  assert.ok(m);
  const ev = JSON.parse(m[1]);
  assert.deepEqual(ev.projects, ['p_1']); assert.ok(ev.at);
  api.closeAll();
});

test('/api/waiting lists no-report and interrupted sessions, state unchanged', async () => {
  const sessions = [
    sess('s.mis', { parentId: 'top', depth: 1, reportMissing: { at: '2026-10-07T10:00:00.000Z', task: 't-0a01' } }),
    sess('s.int', { parentId: 'top', depth: 1, interrupted: { at: '2026-10-07T09:30:00.000Z', task: 't-0b02', errorType: 'rate_limit', files: 2 } }),
    sess('s.wait', { state: 'waiting', waitingKind: 'question', waitingSince: '2026-10-07T09:00:00.000Z' }),
    sess('s.plain'),
  ];
  const { api } = mkApi(tmp('tk-w-'), { sessions });
  const items = bodyOf(await call(api, '/api/waiting')).items;
  assert.deepEqual(items.map(i => [i.id, i.waitingKind]), [['s.wait', 'question'], ['s.int', 'interrupted'], ['s.mis', 'no-report']]);
  assert.equal(items[2].since, '2026-10-07T10:00:00.000Z');
  assert.equal(items[2].taskId, 't-0a01');
  assert.equal(sessions[0].state, 'finished');
});

// ---- adapter data ----
test('readHooks: report_missing / task_interrupted / task_status only count while newer than the latest SubagentStart', async () => {
  const root = tmp('tk-ev-'); const proj = '/proj/ev';
  const env = { platform: process.platform, home: tmp('tk-eh-'), vars: {}, stateRoot: root };
  const { stateDirs } = await import('../lib/paths.mjs');
  const sd = stateDirs(proj, env)[0]; fs.mkdirSync(sd, { recursive: true });
  const ev = (event, ts, agent, payload = {}, extra = {}) => JSON.stringify({ ts, event, agent_id: agent, agent_type: 'worker-sonnet', session_id: 'sess1', transcript_path: '', payload, ...extra });
  fs.writeFileSync(path.join(sd, 'events.jsonl'), [
    ev('SubagentStart', '2026-10-07T09:00:00Z', 'a1'),
    ev('task_status', '2026-10-07T09:00:01Z', 'a1', { task: 't-0a01', from: 'open', to: 'in-progress', by: 'hook' }),
    ev('SubagentStop', '2026-10-07T09:10:00Z', 'a1'),
    ev('report_missing', '2026-10-07T09:10:01Z', 'a1', { task: 't-0a01', missing: ['Stop'] }),
    ev('SubagentStart', '2026-10-07T09:00:00Z', 'a2'),
    ev('task_interrupted', '2026-10-07T09:20:00Z', 'a2', { task: 't-0b02', error_type: 'rate_limit', files: 2 }),
    ev('SubagentStart', '2026-10-07T09:30:00Z', 'a2'),   // resumed: the interruption is stale now
    ev('task_interrupted', '2026-10-07T09:40:00Z', '', { task: 't-0c03', error_type: 'billing', files: 0, session_id: 'sess1' }),
  ].join('\n') + '\n');
  const info = await readHooks(proj, new Map(), env);
  const hook = id => info.agents.get(id);
  assert.deepEqual(taskFields(info, 'a:a1', hook('a1'), 0), { reportMissing: { at: '2026-10-07T09:10:01.000Z', task: 't-0a01' }, taskId: 't-0a01' });
  assert.deepEqual(taskFields(info, 'a:a2', hook('a2'), 0), { taskId: null });
  const s = taskFields(info, 's:sess1', null, 0);
  assert.deepEqual(s.interrupted, { at: '2026-10-07T09:40:00.000Z', task: 't-0c03', errorType: 'billing', files: 0 });
  assert.equal(taskFields(info, 's:sess1', null, Date.parse('2026-10-07T09:50:00Z')).interrupted, undefined);   // the session wrote on afterwards
  // a new start after the report_missing clears it
  fs.appendFileSync(path.join(sd, 'events.jsonl'), ev('SubagentStart', '2026-10-07T09:20:00Z', 'a1') + '\n');
  const info2 = await readHooks(proj, new Map(), env);
  assert.equal(taskFields(info2, 'a:a1', info2.agents.get('a1'), 0).reportMissing, undefined);
});

// ---- watcher ----
test('watcher: baseline is silent, a change fires once with the project id', async () => {
  const dir = tmp('tk-wt-'); writeTask(dir, 't-aaaa');
  const rd = createTasksReader({ env: env0({ vars: { SUBDECK_TASKS_DIR: dir } }), beadsEnabled: false });
  const got = [];
  const w = createTasksWatcher({ reader: rd, getProjects: () => [{ id: 'p_1', path: '/p' }], onChange: ids => got.push(ids), pollMs: 50, debounceMs: 20, watchFn: () => { throw new Error('no fs.watch'); } });
  await new Promise(r => setTimeout(r, 150));
  assert.deepEqual(got, []);
  writeTask(dir, 't-bbbb');
  await new Promise(r => setTimeout(r, 300));
  w.close();
  assert.deepEqual(got, [['p_1']]);
});

// ---- beads ----
test('beads: only with .beads dir, mapped read-only, failure is silent', async () => {
  const proj = tmp('tk-bd-');
  const raw = [{ id: 'bd-1a2b', title: 'Fix it', status: 'in_progress', assignee: 'me', updated_at: '2026-10-07T10:00:00Z', description: 'details' }, { id: 'bad id', title: 'x' }];
  assert.deepEqual(mapBeads(raw).map(x => [x.task.id, x.task.status, x.task.source]), [['bd-1a2b', 'in-progress', 'beads']]);
  let calls = 0;
  const env = env0({ vars: { SUBDECK_TASKS_DIR: path.join(proj, 'none') } });
  const rd = createTasksReader({ env, beadsEnabled: true, beads: async () => { calls++; return raw; } });
  assert.deepEqual((await rd.read(proj)).tasks, []);   // no .beads
  assert.equal(calls, 0);
  fs.mkdirSync(path.join(proj, '.beads'));
  const r = await rd.read(proj);
  assert.equal(r.tasks.length, 1); assert.equal(r.tasks[0].task.source, 'beads');
  assert.equal((await rd.get(proj, 'bd-1a2b')).body, 'details');
  await rd.read(proj); assert.equal(calls, 1);   // cached
  const bad = createTasksReader({ env, beadsEnabled: true, beads: async () => { throw new Error('boom'); } });
  assert.deepEqual((await bad.read(proj)).tasks, []);
});

// ---- UI helpers and rules ----
test('UI: columns, handoff summary', () => {
  assert.deepEqual(COLUMNS.map(c => c[1]), ['Open', 'In progress', 'Blocked', 'Interrupted', 'Review', 'Done']);
  const g = groupTasks([{ id: 'a', status: 'weird', updated: '1' }, { id: 'b', status: 'open', updated: '2' }, { id: 'c', status: 'done', updated: '1' }]);
  assert.deepEqual(g[0].tasks.map(t => t.id), ['b', 'a']);
  assert.equal(g[5].tasks.length, 1);
  assert.equal(handoffSummary({ status: 'interrupted', handoff: { files: 2 } }), 'interrupted: 2 uncommitted files');
  assert.equal(handoffSummary({ status: 'interrupted', handoff: { files: 1 } }), 'interrupted: 1 uncommitted file');
  assert.equal(handoffSummary({ status: 'open', handoff: { files: 1 } }), null);
});

test('Desk stays textContent-only and read-only for tasks', () => {
  for (const f of ['public/tasks.js', 'public/app.js', 'lib/tasks.mjs']) {
    const s = fs.readFileSync(fileURLToPath(new URL('../' + f, import.meta.url)), 'utf8');
    assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(s), f);
  }
  const t = fs.readFileSync(fileURLToPath(new URL('../lib/tasks.mjs', import.meta.url)), 'utf8');
  assert.ok(!/writeFile|appendFile|unlink|rename\(|mkdir|rm\(/.test(t));
});

test('core passes reportMissing / interrupted / taskId through, state unchanged, and counts notices per project', async () => {
  const { createCore } = await import('../lib/core.mjs');
  const NOW = Date.parse('2026-10-07T12:00:00Z');
  const base = { tool: 'claude-code', parentNativeId: null, projectPath: '/p', projectLabel: null, title: 'T', titleSource: 'summary', agentType: null, model: null,
    createdAt: new Date(NOW - 60000).toISOString(), updatedAt: new Date(NOW - 1000).toISOString(), endedAt: null, tokens: { context: 1, total: null }, lastActivity: null,
    refs: { file: null, db: null, key: null }, archived: false, stateBasis: { kind: 'fixed', state: 'finished', stateSource: 'hook' } };
  const list = [
    { ...base, nativeId: 'a', reportMissing: { at: '2026-10-07T11:00:00.000Z', task: 't-0a01' }, taskId: 't-0a01' },
    { ...base, nativeId: 'b', interrupted: { at: '2026-10-07T11:00:00.000Z', task: null, errorType: 'quota', files: 3 }, taskId: null },
    { ...base, nativeId: 'c', reportMissing: 'junk' },
  ];
  const core = createCore({ env: { platform: 'linux', disabled: [], days: 14 }, adapters: [{ tool: 'claude-code', label: 'c', toolShort: 'claude', adapterVersion: '1', detect: async () => true, watchPaths: () => [], scan: async () => ({ sessions: list, skipped: 0, notes: [] }) }], now: () => NOW });
  await core.scanAll();
  const s = core.snapshot();
  const a = s.sessions.find(x => x.nativeId === 'a'), b = s.sessions.find(x => x.nativeId === 'b'), c = s.sessions.find(x => x.nativeId === 'c');
  assert.deepEqual(a.reportMissing, { at: '2026-10-07T11:00:00.000Z', task: 't-0a01' }); assert.equal(a.taskId, 't-0a01'); assert.equal(a.state, 'finished');
  assert.deepEqual(b.interrupted, { at: '2026-10-07T11:00:00.000Z', task: null, errorType: 'quota', files: 3 }); assert.equal(b.taskId, null);
  assert.equal(c.reportMissing, undefined); assert.equal(c.taskId, undefined);
  assert.equal(s.projects[0].noticeCount, 2);
});

test('beads: off by default (no spawn), on with SUBDECK_BEADS=1', async () => {
  const proj = tmp('tk-bo-'); fs.mkdirSync(path.join(proj, '.beads'));
  let calls = 0;
  const beads = async () => { calls++; return [{ id: 'bd-1', title: 'x', status: 'open' }]; };
  const off = createTasksReader({ env: env0({ vars: { SUBDECK_TASKS_DIR: path.join(proj, 'n') } }), beads });
  assert.deepEqual((await off.read(proj)).tasks, []); assert.equal(calls, 0);
  const on = createTasksReader({ env: env0({ vars: { SUBDECK_TASKS_DIR: path.join(proj, 'n'), SUBDECK_BEADS: '1' } }), beads });
  assert.equal((await on.read(proj)).tasks.length, 1); assert.equal(calls, 1);
});

test('beads: bd is resolved from PATH only, never from the project or a relative PATH entry', () => {
  const have = new Set(['/usr/bin/bd', '/proj/bd', '/proj/bin/bd', '/work/bd']);
  const exists = f => have.has(f);
  const o = { platform: 'linux', exists, projectPath: '/proj' };
  assert.equal(resolveBd('bd', { ...o, pathVar: '/proj/bin:.:bin:/usr/bin' }), '/usr/bin/bd');
  assert.equal(resolveBd('bd', { ...o, pathVar: '/proj/bin:.:bin' }), null);
  assert.equal(resolveBd('./bd', { ...o, pathVar: '/usr/bin' }), null);
  assert.equal(resolveBd('/proj/bd', { ...o, pathVar: '/usr/bin' }), null);   // absolute but inside the project
  assert.equal(resolveBd('/work/bd', { ...o, pathVar: '' }), '/work/bd');
  assert.equal(resolveBd('/nope/bd', { ...o, pathVar: '' }), null);
  const w = { platform: 'win32', projectPath: 'C:\\proj', exists: f => ['C:\\tools\\bd.exe', 'C:\\proj\\bd.exe'].includes(f) };
  assert.equal(resolveBd('bd', { ...w, pathVar: 'C:\\proj;bd;C:\\tools' }), 'C:\\tools\\bd.exe');
  assert.equal(resolveBd('bd', { ...w, pathVar: 'C:\\proj' }), null);
});

test('beads: a bd planted in the project is never executed', { skip: process.platform === 'win32' }, async () => {
  const proj = tmp('tk-bp-'); const mark = path.join(proj, 'ran');
  fs.writeFileSync(path.join(proj, 'bd'), `#!/bin/sh\ntouch "${mark}"\necho '[]'\n`, { mode: 0o755 });
  assert.equal(await runBd(proj, { cmd: 'bd', pathVar: `${proj}:.` }), null);
  assert.ok(!fs.existsSync(mark));
});

test('report_missing / task_interrupted in the same second as the SubagentStart still show', async () => {
  const root = tmp('tk-ss-'); const proj = '/proj/ss';
  const env = { platform: process.platform, home: tmp('tk-sh-'), vars: {}, stateRoot: root };
  const { stateDirs } = await import('../lib/paths.mjs');
  const sd = stateDirs(proj, env)[0]; fs.mkdirSync(sd, { recursive: true });
  const ev = (event, agent, payload) => JSON.stringify({ ts: '2026-10-07T09:00:00Z', event, agent_id: agent, agent_type: 'worker-sonnet', session_id: 's1', payload });
  fs.writeFileSync(path.join(sd, 'events.jsonl'), [ev('SubagentStart', 'a1', {}), ev('report_missing', 'a1', { task: 't-0a01' }), ev('SubagentStart', 'a2', {}), ev('task_interrupted', 'a2', { task: 't-0b02', error_type: 'quota', files: 1 })].join('\n') + '\n');
  const info = await readHooks(proj, new Map(), env);
  assert.deepEqual(taskFields(info, 'a:a1', info.agents.get('a1'), 0).reportMissing, { at: '2026-10-07T09:00:00.000Z', task: 't-0a01' });
  assert.equal(taskFields(info, 'a:a2', info.agents.get('a2'), 0).interrupted.files, 1);
});

test('runBd spawns exactly the PATH-resolved bd, not the planted one in the project', { skip: process.platform === 'win32' }, async () => {
  const proj = tmp('tk-bq-'), bin = tmp('tk-bin-');
  const mk = (f, who) => fs.writeFileSync(f, `#!/bin/sh\necho '[{"id":"bd-${who}","title":"${who}","status":"open"}]'\n`, { mode: 0o755 });
  mk(path.join(proj, 'bd'), 'planted'); mk(path.join(bin, 'bd'), 'real');
  const r = await runBd(proj, { cmd: 'bd', pathVar: `${proj}:${bin}` });
  assert.deepEqual(r.map(x => x.id), ['bd-real']);
});

test('tab label shows the total and a separate attention marker', async () => {
  const { tabLabel } = await import('../public/tasks.js');
  const P = (...st) => ({ tasks: st.map(status => ({ status })) });
  assert.deepEqual(tabLabel([]), { text: 'Tasks', title: '' });
  assert.equal(tabLabel([P('open', 'done')]).text, 'Tasks (2)');
  const l = tabLabel([P('open', 'blocked'), P('interrupted', 'done', 'review')]);
  assert.equal(l.text, 'Tasks (5) !2');
  assert.equal(l.title, '5 tasks, 2 blocked or interrupted');
});
