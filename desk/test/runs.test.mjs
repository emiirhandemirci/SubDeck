// desk/test/runs.test.mjs: SubDeck runs (adapter, API, run-log view helpers, roles settings group, badges)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { EventEmitter } from 'node:events';
import subdeckRun, { parseMeta } from '../adapters/subdeck-run.mjs';
import { createCore } from '../lib/core.mjs';
import { createApi } from '../lib/api.mjs';
import { createTasksReader, runBd } from '../lib/tasks.mjs';
import { validateAdapterSession } from '../lib/model.mjs';
import { runBadgeText, runUrl } from '../public/runs.js';
import { roleRows, roleFieldError, GROUPS, groupItems, ROLE_PRIVACY } from '../public/settings.js';

const FIX = fileURLToPath(new URL('../../plugins/subdeck/tests/fixtures/runs/state/', import.meta.url));
const NOW = Date.parse('2026-10-07T12:00:00Z');
const tmp = p => fs.mkdtempSync(path.join(os.tmpdir(), p));
const envOf = (stateRoot, over = {}) => ({ home: tmp('rn-home-'), platform: process.platform, vars: {}, stateRoot, now: () => NOW, days: 14, tmpDirs: [], disabled: [], ...over });
const haveFix = fs.existsSync(FIX);

// a private copy of the fixture so mtimes can be set freely
function copyFix() {
  const dst = tmp('rn-state-');
  fs.cpSync(FIX, dst, { recursive: true });
  return dst;
}

test('parseMeta: version, status, ids and bounds', () => {
  const ok = { version: 1, task: 't-0b02', status: 'ok', project: '/p', startedAt: '2026-10-07T09:00:00Z', role: 'worker', tool: 'codex', model: 'x', violations: ['a', 3] };
  const r = parseMeta(ok, 't-0b02', '20261007T090000Z');
  assert.equal(r.status, 'ok'); assert.deepEqual(r.violations, ['a']); assert.equal(r.exit, null);
  assert.equal(parseMeta({ ...ok, version: 2 }, 't-0b02', 'x'), null);
  assert.equal(parseMeta({ ...ok, status: 'weird' }, 't-0b02', 'x'), null);
  assert.equal(parseMeta({ ...ok, task: 't-9999' }, 't-0b02', 'x'), null);   // meta of another task in this dir
  assert.equal(parseMeta({ ...ok, project: '' }, 't-0b02', 'x'), null);
  assert.equal(parseMeta({ ...ok, startedAt: 'nope' }, 't-0b02', 'x'), null);
  assert.equal(parseMeta([], 't', 'x'), null);
});

test('adapter on the shared runs fixture: sessions, states, failure kinds, run field', { skip: !haveFix }, async () => {
  const root = copyFix();
  const dir = path.join(root, 'proj-00000000', 'runs', 't-0b02');
  const fresh = new Date(NOW - 20000);   // the running run wrote its log 20 s ago
  fs.utimesSync(path.join(dir, '20261007T103000Z.log'), fresh, fresh);
  fs.writeFileSync(path.join(dir, 'bad.json'), '{ nope');   // not a ts-named meta: ignored
  fs.writeFileSync(path.join(dir, '20261007T110000Z.json'), '{ nope');   // unreadable: skipped
  fs.writeFileSync(path.join(dir, '20261007T111500Z.json'), JSON.stringify({ version: 9, task: 't-0b02', status: 'ok', project: '/w/proj', startedAt: '2026-10-07T11:15:00Z' }));
  const env = envOf(root);
  assert.equal(await subdeckRun.detect(env), true);
  assert.equal(await subdeckRun.detect(envOf(tmp('rn-empty-'))), false);
  const r = await subdeckRun.scan(env, { cache: new Map() });
  assert.equal(r.sessions.length, 4);
  assert.equal(r.skipped, 2);
  for (const s of r.sessions) assert.deepEqual(validateAdapterSession(s), { ok: true }, s.nativeId);
  const by = id => r.sessions.find(s => s.nativeId === `t-0b02.${id}`);
  const ok = by('20261007T090000Z'), quota = by('20261007T093000Z'), viol = by('20261007T100000Z'), run = by('20261007T103000Z');
  assert.equal(ok.title, 'worker: In progress task');
  assert.equal(ok.agentType, 'worker'); assert.equal(ok.model, 'gpt-5-codex'); assert.equal(ok.projectPath, '/w/proj'); assert.equal(ok.tool, 'subdeck-run');
  assert.equal(ok.createdAt, '2026-10-07T09:00:00.000Z'); assert.equal(ok.endedAt, '2026-10-07T09:12:34.000Z');
  assert.deepEqual(ok.stateBasis, { kind: 'fixed', state: 'finished', stateSource: 'field' });
  assert.deepEqual(quota.stateBasis, { kind: 'fixed', state: 'failed', stateSource: 'field' });
  assert.equal(quota.failure.kind, 'quota'); assert.equal(viol.failure.kind, 'tool');
  assert.equal(run.stateBasis.kind, 'mtime'); assert.equal(run.stateBasis.at, fresh.toISOString()); assert.equal(run.failure, undefined);
  assert.equal(run.run.experimental, true); assert.equal(run.endedAt, null);
  assert.deepEqual(viol.run.violations, ['src/other.js', 'package.json']);
  assert.deepEqual(Object.keys(ok.run).sort(), ['base', 'branch', 'class', 'cliExit', 'exit', 'experimental', 'model', 'role', 'sessionId', 'status', 'taskId', 'tool', 'ts', 'violations', 'worktree', 'writableCheck']);
  assert.equal(ok.run.tool, 'codex'); assert.equal(ok.run.ts, '20261007T090000Z'); assert.equal(ok.run.exit, 0);
  assert.deepEqual(subdeckRun.watchPaths(env), [{ path: root, recursive: true }]);
});

test('core: runs become sessions of their project with the run field and a running state from log activity', { skip: !haveFix }, async () => {
  const root = copyFix();
  const fresh = new Date(NOW - 20000);
  fs.utimesSync(path.join(root, 'proj-00000000', 'runs', 't-0b02', '20261007T103000Z.log'), fresh, fresh);
  const core = createCore({ env: envOf(root), adapters: [subdeckRun], now: () => NOW });
  await core.scanAll();
  const snap = core.snapshot();
  assert.equal(snap.projects.length, 1); assert.equal(snap.projects[0].path, '/w/proj');
  assert.equal(snap.sessions.length, 4);
  const s = snap.sessions.find(x => x.nativeId === 't-0b02.20261007T103000Z');
  assert.equal(s.id, 'run.t-0b02.20261007T103000Z');
  assert.equal(s.state, 'running'); assert.equal(s.taskId, 't-0b02'); assert.equal(s.run.tool, 'agy');
  assert.equal(snap.sessions.find(x => x.nativeId === 't-0b02.20261007T093000Z').failure.kind, 'quota');
  assert.equal(snap.sessions.find(x => x.nativeId === 't-0b02.20261007T090000Z').state, 'finished');
});

// ---- API ----
const P = 4917;
function call(api, url) {
  const res = new EventEmitter();
  res.chunks = [];
  res.writeHead = (s, h) => { res.status = s; res.headers = h; return res; };
  res.write = c => { res.chunks.push(String(c)); return true; };
  res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  return Promise.resolve(api.handle({ method: 'GET', url, headers: { host: `127.0.0.1:${P}` } }, res)).then(() => res);
}
const bodyOf = r => JSON.parse(r.chunks.join(''));

async function mkApi(root, { contentEnabled = true, tasksDir = null } = {}) {
  const env = envOf(root, { vars: tasksDir ? { SUBDECK_TASKS_DIR: tasksDir } : {} });
  const core = createCore({ env, adapters: [subdeckRun], now: () => NOW });
  await core.scanAll();
  const tasks = createTasksReader({ env, beadsEnabled: false });
  const api = createApi({ core, getPort: () => P, startedAt: 'x', days: 14, version: '0', publicDir: tmp('rn-pub-'), contentEnabled, tasks, env, adapters: [subdeckRun] });
  return { api, core, pid: core.snapshot().projects[0].id };
}

test('GET /api/runs: shape, newest first, project filter, limit 200', { skip: !haveFix }, async () => {
  const { api, pid } = await mkApi(copyFix());
  const d = bodyOf(await call(api, '/api/runs'));
  assert.deepEqual(Object.keys(d).sort(), ['generatedAt', 'runs']);
  assert.deepEqual(d.runs.map(r => r.ts), ['20261007T103000Z', '20261007T100000Z', '20261007T093000Z', '20261007T090000Z']);
  assert.deepEqual(Object.keys(d.runs[0]).sort(), ['branch', 'endedAt', 'exit', 'model', 'projectId', 'role', 'sessionId', 'startedAt', 'status', 'taskId', 'tool', 'ts']);
  assert.equal(d.runs[0].tool, 'agy'); assert.equal(d.runs[0].sessionId, 'run.t-0b02.20261007T103000Z'); assert.equal(d.runs[3].exit, 0);
  assert.equal(bodyOf(await call(api, `/api/runs?project=${pid}`)).runs.length, 4);
  assert.equal((await call(api, '/api/runs?project=p_nope')).status, 404);

  const big = tmp('rn-big-'); const dir = path.join(big, 'k-1', 'runs', 't-0c03'); fs.mkdirSync(dir, { recursive: true });
  for (let i = 0; i < 230; i++) {
    const ts = `20261006T${String(10 + Math.floor(i / 3600)).padStart(2, '0')}${String(Math.floor(i / 60) % 60).padStart(2, '0')}${String(i % 60).padStart(2, '0')}Z`;
    fs.writeFileSync(path.join(dir, `${ts}.json`), JSON.stringify({ version: 1, task: 't-0c03', status: 'ok', project: '/w/p2', startedAt: '2026-10-06T10:00:00Z', role: 'worker', tool: 'codex' }));
  }
  const b = await mkApi(big);
  assert.equal(bodyOf(await call(b.api, '/api/runs')).runs.length, 200);
});

test('GET /api/runs/<project>/<task>/<ts>/log: tails, final, lines clamp, gating, id validation', { skip: !haveFix }, async () => {
  const root = copyFix();
  const dir = path.join(root, 'proj-00000000', 'runs', 't-0b02');
  fs.writeFileSync(path.join(dir, '20261007T090000Z.log'), Array.from({ length: 3000 }, (_, i) => `line ${i + 1}`).join('\n') + '\n');
  const { api, pid } = await mkApi(root);
  const u = (t, ts, q = '') => `/api/runs/${pid}/${t}/${ts}/log${q}`;
  let r = await call(api, u('t-0b02', '20261007T090000Z'));
  assert.equal(r.status, 200);
  let d = bodyOf(r);
  assert.deepEqual(Object.keys(d).sort(), ['final', 'log', 'out', 'truncated']);
  assert.equal(d.log.split('\n').length, 200); assert.ok(d.log.endsWith('line 3000')); assert.equal(d.truncated, true);
  assert.equal(typeof d.final, 'string'); assert.ok(d.final.length > 0);
  assert.equal(bodyOf(await call(api, u('t-0b02', '20261007T090000Z', '?lines=5'))).log, 'line 2996\nline 2997\nline 2998\nline 2999\nline 3000');
  assert.equal(bodyOf(await call(api, u('t-0b02', '20261007T090000Z', '?lines=99999'))).log.split('\n').length, 2000);
  assert.equal(bodyOf(await call(api, u('t-0b02', '20261007T090000Z', '?lines=zzz'))).log.split('\n').length, 200);
  d = bodyOf(await call(api, u('t-0b02', '20261007T103000Z')));   // running run: no final yet in the fixture, or a string
  assert.ok(d.final === null || typeof d.final === 'string');
  // ids are validated, nothing is a path
  for (const bad of [u('t-zz', '20261007T090000Z'), u('..', '20261007T090000Z'), u('t-0b02', '../../x'), u('t-0b02', '20261007T090001Z'), u('t-0c0c', '20261007T090000Z'),
    `/api/runs/p_nope/t-0b02/20261007T090000Z/log`, `/api/runs/${pid}/t-0b02/20261007T090000Z%2F..%2Fx/log`]) {
    assert.equal((await call(api, bad)).status, 404, bad);
  }
  const off = await mkApi(root, { contentEnabled: false });
  assert.equal((await call(off.api, `/api/runs/${off.pid}/t-0b02/20261007T090000Z/log`)).status, 404);
  assert.equal((await call(off.api, '/api/runs')).status, 200);   // metadata stays; only content is gated
});

test('log endpoint refuses a symlinked log', { skip: !haveFix || process.platform === 'win32' }, async () => {
  const root = copyFix();
  const dir = path.join(root, 'proj-00000000', 'runs', 't-0b02');
  const secret = path.join(tmp('rn-sec-'), 'secret.txt'); fs.writeFileSync(secret, 'TOPSECRET');
  fs.rmSync(path.join(dir, '20261007T090000Z.log')); fs.symlinkSync(secret, path.join(dir, '20261007T090000Z.log'));
  fs.rmSync(path.join(dir, '20261007T090000Z.final.txt')); fs.symlinkSync(secret, path.join(dir, '20261007T090000Z.final.txt'));
  const { api, pid } = await mkApi(root);
  const r = await call(api, `/api/runs/${pid}/t-0b02/20261007T090000Z/log`);
  assert.ok(!r.chunks.join('').includes('TOPSECRET'));
});

test('/api/tasks entries carry role, tool, model, branch, worktree, run and lastRun', { skip: !haveFix }, async () => {
  const tdir = tmp('rn-tasks-');
  const fixTask = fileURLToPath(new URL('../../plugins/subdeck/tests/fixtures/tasks/t-2b2b.md', import.meta.url));
  fs.writeFileSync(path.join(tdir, 't-2b2b.md'), fs.readFileSync(fixTask, 'utf8'));
  fs.writeFileSync(path.join(tdir, 't-0b02.md'), '---\nid: t-0b02\ntitle: In progress task\nstatus: in-progress\n---\n## Task\nx\n');
  const { api, pid } = await mkApi(copyFix(), { tasksDir: tdir });
  const d = bodyOf(await call(api, `/api/tasks?project=${pid}`));
  const t = d.projects[0].tasks.find(x => x.id === 't-2b2b');
  assert.equal(t.role, 'worker'); assert.equal(t.tool, 'codex'); assert.equal(t.model, 'gpt-5-codex'); assert.equal(t.branch, 'subdeck/t-2b2b');
  assert.match(t.worktree, /t-2b2b$/); assert.match(t.run, /\.log$/);
  assert.equal(t.lastRun, null);
  const b = d.projects[0].tasks.find(x => x.id === 't-0b02');
  assert.deepEqual(b.lastRun, { ts: '20261007T103000Z', status: 'running', role: 'worker', tool: 'agy', model: 'gemini-3-pro' });
  assert.equal(b.role, ''); assert.equal(b.branch, '');
});

// ---- UI helpers ----
test('badge text: role, tool/model, exp mark, empty model', () => {
  assert.equal(runBadgeText({ role: 'worker', tool: 'codex', model: 'gpt-5-codex' }), 'worker · codex/gpt-5-codex');
  assert.equal(runBadgeText({ role: 'verifier', tool: 'claude', model: '' }), 'verifier · claude');
  assert.equal(runBadgeText({ role: 'worker', tool: 'agy', model: 'gemini-3-pro' }), 'worker · agy/gemini-3-pro exp');
  assert.equal(runBadgeText({ role: 'worker', tool: 'x', model: 'm', experimental: true }), 'worker · x/m exp');
  assert.equal(runBadgeText({ role: 'worker', tool: '', model: '' }), 'worker');
  assert.equal(runBadgeText({ role: '', tool: '', model: '' }), null);
  assert.equal(runBadgeText(null), null);
  assert.equal(runUrl('p_1', 't-0b02', '20261007T090000Z', 50), '/api/runs/p_1/t-0b02/20261007T090000Z/log?lines=50');
});

const ROLE_DOC = [];
for (const r of ['manager', 'worker', 'worker-heavy', 'researcher', 'verifier', 'ui-worker']) {
  const set = r === 'worker' ? 'project' : 'default';
  ROLE_DOC.push({ key: `roles.${r}.tool`, value: r === 'worker' ? 'codex' : '', source: set, group: 'roles', type: 'enum', options: ['claude', 'codex', 'gemini', 'agy', 'opencode', 'copilot', 'custom'], description: 'd' });
  for (const f of ['model', 'args', 'cmd']) ROLE_DOC.push({ key: `roles.${r}.${f}`, value: '', source: set, group: 'roles', type: 'string', options: [], description: 'd' });
  ROLE_DOC.push({ key: `roles.${r}.timeout`, value: 1800, source: set, group: 'roles', type: 'int', options: [], description: 'd' });
}
test('roles settings group: after tasks, one row per role in settings order, source from the tool row', () => {
  const ids = GROUPS.map(g => g[0]);
  assert.equal(ids.indexOf('roles'), ids.indexOf('tasks') + 1);
  const rows = roleRows([{ key: 'mode', group: 'models', value: 'auto' }, ...ROLE_DOC]);
  assert.deepEqual(rows.map(r => r.role), ['manager', 'worker', 'worker-heavy', 'researcher', 'verifier', 'ui-worker']);
  assert.deepEqual(Object.keys(rows[1].fields), ['tool', 'model', 'args', 'cmd', 'timeout']);
  assert.equal(rows[1].source, 'project'); assert.equal(rows[0].source, 'default');
  assert.deepEqual(groupItems(ROLE_DOC).map(g => g.id), ['roles']);
  assert.deepEqual(roleRows([{ key: 'roles.bad_name.tool' }, { key: 'roles.x.other' }, { key: 'rolesx' }]), []);
});
test('roles field validation mirrors the contract', () => {
  assert.equal(roleFieldError('timeout', '60'), null); assert.equal(roleFieldError('timeout', '86400'), null);
  assert.ok(roleFieldError('timeout', '59')); assert.ok(roleFieldError('timeout', '86401')); assert.ok(roleFieldError('timeout', '1.5'));
  assert.equal(roleFieldError('model', ''), null); assert.equal(roleFieldError('model', 'anthropic/claude-sonnet-4'), null);
  assert.ok(roleFieldError('model', '-x')); assert.ok(roleFieldError('model', 'a b'));
  assert.equal(roleFieldError('args', '--flag value'), null);
  assert.ok(roleFieldError('args', '--a "b"')); assert.ok(roleFieldError('args', "--a 'b'")); assert.ok(roleFieldError('args', 'a\\b')); assert.ok(roleFieldError('args', 'x'.repeat(301)));
  assert.equal(roleFieldError('cmd', 'mytool --in {prompt_file}'), null);
  assert.ok(roleFieldError('cmd', 'mytool')); assert.ok(roleFieldError('cmd', '{prompt_file}\n'));
  assert.match(ROLE_PRIVACY, /sent to that tool's provider/);
});

test('public files: runs.js is served, uses textContent only, CSP unchanged, roles UI wiring', async () => {
  const pub = fileURLToPath(new URL('../public/', import.meta.url));
  const src = ['runs.js', 'tasks.js', 'settings.js', 'app.js'].map(f => fs.readFileSync(path.join(pub, f), 'utf8')).join('\n');
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function/.test(src));
  const api2 = createApi({ core: { snapshot: () => ({ projects: [], sessions: [], sources: [] }) }, getPort: () => P, startedAt: 'x', days: 14, version: '0', publicDir: pub });
  const r = await call(api2, '/runs.js');
  assert.equal(r.status, 200);
  assert.equal(r.headers['Content-Security-Policy'], "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:");
  const s = fs.readFileSync(path.join(pub, 'settings.js'), 'utf8');
  assert.match(s, /roles\.\$\{r\.role\}\.tool/);
  assert.match(s, /'\(in-session\)'/);
  assert.match(s, /informational: start this CLI yourself/);
  assert.match(s, /save\(toolItem, ''\)/);   // Clear = roles.<r>.tool=
});

// ---- Beads spawn environment (gap from 0.7.x) ----
test('beads: bd is spawned with BEADS_DOLT_AUTO_START=0', { skip: process.platform === 'win32' }, async () => {
  const proj = tmp('rn-bd-p-'), bin = tmp('rn-bd-b-');
  fs.writeFileSync(path.join(bin, 'bd'), '#!/bin/sh\nprintf \'[{"id":"bd-1","title":"auto=%s","status":"open"}]\' "${BEADS_DOLT_AUTO_START-unset}"\n', { mode: 0o755 });
  const prev = process.env.BEADS_DOLT_AUTO_START;
  process.env.BEADS_DOLT_AUTO_START = '1';   // an inherited value must be overridden
  try {
    const r = await runBd(proj, { cmd: 'bd', pathVar: bin });
    assert.equal(r[0].title, 'auto=0');
  } finally { if (prev === undefined) delete process.env.BEADS_DOLT_AUTO_START; else process.env.BEADS_DOLT_AUTO_START = prev; }
});
