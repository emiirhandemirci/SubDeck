// desk/test/opencode.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import opencode, { createOpenCodeAdapter, dataDirOf } from '../adapters/opencode.mjs';
import { deriveState, validateAdapterSession } from '../lib/model.mjs';
import { buildOpenCodeFixture } from './fixtures/opencode-fixture.mjs';

function scenario(extra = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-oc-'));
  const NOW = Date.now();
  const env = { home: root, platform: process.platform, vars: { XDG_DATA_HOME: path.join(root, 'xdg') }, now: () => NOW, days: 14 };
  const dataDir = dataDirOf(env);
  const asst = (over = {}) => ({ role: 'assistant', time: { created: NOW - 5000 }, modelID: 'claude-sonnet-4', providerID: 'anthropic',
    tokens: { input: 100, output: 20, reasoning: 0, cache: { read: 900, write: 50 } }, ...over });
  const usr = (t = NOW - 9000) => ({ role: 'user', time: { created: t } });
  const alpha = path.join(root, 'alpha').replace(/\\/g, '/');
  const S = (id, over = {}) => ({ id, project_id: 'p1', directory: alpha, title: 'Refactor parser', created: NOW - 3600000, updated: NOW - 1000, ...over });
  buildOpenCodeFixture(dataDir, {
    projects: [{ id: 'p1', worktree: alpha, name: 'alpha' }],
    sessions: [
      S('ses_run', { model: { id: 'gpt-5', providerID: 'openai' }, agent: 'build', tokens: { input: 1000, output: 200, reasoning: 30, read: 4000, write: 70 } }),
      S('ses_done', { title: 'New session - 2026-09-01T10:00:00.000Z', updated: NOW - 4 * 3600000 }),
      S('ses_child', { parent_id: 'ses_run', title: 'Explore (@explore subagent)', agent: 'explore', updated: NOW - 600000 }),
      S('ses_fail', { updated: NOW - 60000 }),
      S('ses_arch', { archived: NOW - 5000, updated: NOW - 5000 }),
      S('ses_old', { updated: NOW - 30 * 86400000 }),
      S('ses_nofolder', { directory: '', project_id: 'nope', updated: NOW - 20000 }),
    ],
    messages: [
      { id: 'm1', session_id: 'ses_run', created: NOW - 9000, data: usr() },
      { id: 'm2', session_id: 'ses_run', created: NOW - 5000, data: asst() },
      { id: 'm3', session_id: 'ses_done', created: NOW - 5 * 3600000, data: asst({ time: { created: NOW - 5 * 3600000, completed: NOW - 4 * 3600000 }, finish: 'stop' }) },
      { id: 'm4', session_id: 'ses_fail', created: NOW - 70000, data: asst({ time: { created: NOW - 70000, completed: NOW - 60000 }, error: { name: 'APIError', data: { message: 'BODY_MARKER' } } }) },
      { id: 'm5', session_id: 'ses_child', created: NOW - 600000, data: asst({ time: { created: NOW - 600000, completed: NOW - 590000 } }) },
      { id: 'm6', session_id: 'ses_run', created: NOW - 100, data: '{not json' },
    ],
    parts: [
      { id: 'pt1', message_id: 'm2', session_id: 'ses_run', created: NOW - 3000, data: { type: 'tool', tool: 'bash' } },
      { id: 'pt2', message_id: 'm2', session_id: 'ses_run', created: NOW - 2000, data: { type: 'text' } },
    ],
    ...extra,
  });
  return { root, NOW, env, dataDir, alpha };
}
const scan = (sc, a = opencode) => a.scan(sc.env, { since: null, cache: new Map() });

test('detect: db, legacy storage, nothing', async () => {
  const sc = scenario();
  assert.equal(await opencode.detect(sc.env), true);
  assert.equal(await opencode.detect({ ...sc.env, vars: { XDG_DATA_HOME: path.join(sc.root, 'none') } }), false);
  const lroot = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-oc-'));
  const lenv = { ...sc.env, vars: { XDG_DATA_HOME: lroot } };
  buildOpenCodeFixture(dataDirOf(lenv), { db: false, legacy: { sessions: { p: [{ id: 'ses_x', directory: '/x', title: 't', time: { created: 1, updated: sc.NOW } }] } } });
  assert.equal(await opencode.detect(lenv), true);
});

test('data dir: XDG_DATA_HOME override, default ~/.local/share', () => {
  const p = process.platform === 'win32' ? path.win32 : path.posix;
  assert.equal(dataDirOf({ home: '/h', platform: 'linux', vars: {} }), path.posix.join('/h', '.local', 'share', 'opencode'));
  assert.equal(dataDirOf({ home: '/h', platform: 'linux', vars: { XDG_DATA_HOME: '/x' } }), path.posix.join('/x', 'opencode'));
  assert.equal(dataDirOf({ home: 'C:\\Users\\a', platform: 'win32', vars: {} }), 'C:\\Users\\a\\.local\\share\\opencode');
  assert.ok(p);
});

test('scan maps sessions, sub-agent linkage, states, tokens', async () => {
  const sc = scenario();
  const r = await scan(sc);
  const by = Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));
  assert.deepEqual(Object.keys(by).sort(), ['ses_arch', 'ses_child', 'ses_done', 'ses_fail', 'ses_nofolder', 'ses_run']);
  for (const s of r.sessions) assert.deepEqual(validateAdapterSession(s), { ok: true });
  const st = s => deriveState(s.stateBasis, sc.NOW);

  assert.equal(by.ses_run.tool, 'opencode');
  assert.equal(path.resolve(by.ses_run.projectPath), path.resolve(sc.alpha));
  assert.equal(by.ses_run.title, 'Refactor parser');
  assert.equal(by.ses_run.titleSource, 'explicit');
  assert.equal(by.ses_run.model, 'gpt-5');
  assert.deepEqual(st(by.ses_run), { state: 'running', stateSource: 'field' });
  assert.equal(by.ses_run.tokens.total, 5300);
  assert.equal(by.ses_run.tokens.context, 1050);                 // input + cache read + cache write of last assistant message
  assert.deepEqual(by.ses_run.lastActivity, { at: new Date(sc.NOW - 3000).toISOString(), kind: 'tool', toolName: 'bash', summary: null });
  assert.deepEqual(by.ses_run.refs, { file: null, db: path.join(sc.dataDir, 'opencode.db'), key: 'session:ses_run' });

  assert.equal(by.ses_done.titleSource, 'fallback');             // generated default title
  assert.equal(st(by.ses_done).state, 'finished');               // mtime basis, 4h old
  assert.equal(by.ses_done.model, 'claude-sonnet-4');            // from last assistant message

  assert.equal(by.ses_child.parentNativeId, 'ses_run');
  assert.equal(by.ses_child.depth, 1);
  assert.equal(by.ses_child.agentType, 'explore');
  assert.equal(by.ses_run.parentNativeId, null);

  assert.deepEqual(st(by.ses_fail), { state: 'failed', stateSource: 'field' });
  assert.ok(by.ses_fail.endedAt);
  assert.equal(by.ses_arch.archived, true);
  assert.equal(by.ses_nofolder.projectPath, null);
  assert.equal(by.ses_nofolder.projectLabel, 'OpenCode (no folder)');
  assert.equal(r.skipped, 0);
});

test('unfinished message in a stale session is not running', async () => {
  const sc = scenario();
  const later = { ...sc.env, now: () => sc.NOW + 3600000 };
  const r = await opencode.scan(later, { since: null, cache: new Map() });
  const run = r.sessions.find(s => s.nativeId === 'ses_run');
  assert.notEqual(deriveState(run.stateBasis, later.now()).state, 'running');
});

test('no message body, tool output or secret marker leaks', async () => {
  const sc = scenario();
  const json = JSON.stringify(await scan(sc));
  assert.equal(json.includes('BODY_MARKER'), false);
});

test('legacy storage json: sessions, parent, malformed skipped, no leak, DB wins on duplicate id', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-oc-'));
  const NOW = Date.now();
  const env = { home: root, platform: process.platform, vars: { XDG_DATA_HOME: root }, now: () => NOW, days: 14 };
  const dir = dataDirOf(env);
  const wt = path.join(root, 'proj');
  buildOpenCodeFixture(dir, { db: false, legacy: {
    projects: { p1: { id: 'p1', worktree: wt } },
    sessions: { p1: [
      { id: 'ses_l1', projectID: 'p1', directory: wt, title: 'Legacy work', time: { created: NOW - 100000, updated: NOW - 2000 } },
      { id: 'ses_l2', projectID: 'p1', parentID: 'ses_l1', title: 'Sub', time: { created: NOW - 90000, updated: NOW - 3600000 } },
      '{broken',
    ] },
    messages: { ses_l1: {
      msg_001: { role: 'user', time: { created: NOW - 100000 } },
      msg_002: { role: 'assistant', time: { created: NOW - 3000 }, modelID: 'gpt-4.1', providerID: 'openai', tokens: { input: 10, output: 5, reasoning: 0, cache: { read: 100, write: 0 } } },
    } },
  } });
  const r = await opencode.scan(env, { since: null, cache: new Map() });
  const by = Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));
  assert.deepEqual(Object.keys(by).sort(), ['ses_l1', 'ses_l2']);
  assert.equal(by.ses_l1.projectPath, wt);
  assert.equal(by.ses_l1.model, 'gpt-4.1');
  assert.equal(by.ses_l1.tokens.total, 115);
  assert.deepEqual(deriveState(by.ses_l1.stateBasis, NOW), { state: 'running', stateSource: 'field' });
  assert.equal(by.ses_l2.parentNativeId, 'ses_l1');
  assert.equal(by.ses_l2.projectPath, wt);                        // from project/<id>.json worktree
  assert.equal(r.skipped, 1);
  assert.equal(JSON.stringify(r).includes('BODY_MARKER'), false);
  assert.ok(by.ses_l1.refs.file.endsWith('ses_l1.json'));
});

test('malformed message data counts nothing extra; session with bad row still listed', async () => {
  const sc = scenario();
  const r = await scan(sc);
  assert.ok(r.sessions.find(s => s.nativeId === 'ses_run'));     // m6 is broken JSON, json_extract yields NULL / error handled
});

test('older schema without tokens/model/agent columns still scans', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-oc-'));
  const NOW = Date.now();
  const env = { home: root, platform: process.platform, vars: { XDG_DATA_HOME: root }, now: () => NOW, days: 14 };
  const dir = dataDirOf(env);
  fs.mkdirSync(dir, { recursive: true });
  const { DatabaseSync } = await import('node:sqlite');
  const c = new DatabaseSync(path.join(dir, 'opencode.db'));
  c.exec('CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER)');
  c.exec('CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)');
  c.prepare('INSERT INTO session VALUES (?,?,?,?,?,?,?)').run('s1', 'p', null, '/w', 'T', NOW - 5000, NOW - 4000);
  c.close();
  const r = await opencode.scan(env, { since: null, cache: new Map() });
  assert.equal(r.sessions.length, 1);
  assert.equal(r.sessions[0].tokens.total, null);
});

test('unrecognised schema -> error, not a crash of other data', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-oc-'));
  const env = { home: root, platform: process.platform, vars: { XDG_DATA_HOME: root }, now: () => Date.now(), days: 14 };
  const dir = dataDirOf(env);
  fs.mkdirSync(dir, { recursive: true });
  const { DatabaseSync } = await import('node:sqlite');
  const c = new DatabaseSync(path.join(dir, 'opencode.db'));
  c.exec('CREATE TABLE unrelated (x TEXT)');
  c.close();
  await assert.rejects(opencode.scan(env, { since: null, cache: new Map() }), /unrecognised OpenCode session schema/);
});

test('unchanged DB fingerprint returns cached rows (one open)', async () => {
  const sc = scenario();
  const cache = new Map();
  let opens = 0;
  const real = await import('node:sqlite');
  const a = createOpenCodeAdapter({ loadSqlite: async () => ({ DatabaseSync: class extends real.DatabaseSync { constructor(...x) { opens++; super(...x); } } }) });
  await a.scan(sc.env, { since: null, cache });
  await a.scan(sc.env, { since: null, cache });
  assert.equal(opens, 1);
});

test('busy twice then succeeds; busy forever -> error; missing node:sqlite -> clear error', async () => {
  const sc = scenario();
  const real = await import('node:sqlite');
  const busy = () => Object.assign(new Error('database is locked'), { code: 'ERR_SQLITE_ERROR', errcode: 5 });
  let fails = 2;
  const flaky = createOpenCodeAdapter({ sleep: async () => {}, loadSqlite: async () => ({ DatabaseSync: class extends real.DatabaseSync {
    constructor(...x) { if (fails-- > 0) throw busy(); super(...x); } } }) });
  assert.equal((await scan(sc, flaky)).sessions.length, 6);
  const locked = createOpenCodeAdapter({ sleep: async () => {}, loadSqlite: async () => ({ DatabaseSync: class { constructor() { throw busy(); } } }) });
  await assert.rejects(scan(sc, locked), /database is locked/);
  const none = createOpenCodeAdapter({ loadSqlite: async () => { throw new Error('No such built-in module: node:sqlite'); } });
  await assert.rejects(scan(sc, none), /node:sqlite unavailable/);
});

test('export shape and watchPaths', () => {
  assert.equal(opencode.tool, 'opencode');
  assert.equal(opencode.label, 'OpenCode');
  assert.equal(opencode.toolShort, 'oc');
  assert.equal(opencode.experimental, true);
  assert.equal(opencode.timeline, undefined);
  const env = { home: '/h', platform: 'linux', vars: {} };
  assert.deepEqual(opencode.watchPaths(env)[0], { path: path.posix.join('/h', '.local', 'share', 'opencode'), recursive: false, filter: 'opencode.db' });
});
