// desk/test/codex.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import codex, { createCodexAdapter } from '../adapters/codex.mjs';
import { deriveState, validateAdapterSession } from '../lib/model.mjs';
import { buildCodexFixture, meta, turnContext, started, complete, aborted, userMsg, agentMsg, tokens, toolCall, toolOut, assistantText, BODY } from './fixtures/codex-fixture.mjs';

function scenario(over = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-cx-'));
  const NOW = Date.now();
  const home = path.join(root, 'home');
  const codexHome = path.join(home, '.codex');
  const proj = path.join(root, 'work', 'Alpha');
  const T = (id, o) => ({ id, cwd: proj, title: 'Title ' + id, model: 'gpt-5-codex', created: NOW - 3600000, updated: NOW - 5000, ...o });
  const threads = [
    T('t-run', { tokens_used: 4200, rollout: [meta(NOW - 3600000, 't-run', proj), userMsg(NOW - 60000), started(NOW - 50000), turnContext(NOW - 49000, 'gpt-5.1'),
      tokens(NOW - 20000, 900, 4100), toolCall(NOW - 6000, 'shell'), toolOut(NOW - 5500)] }),
    T('t-idle', { updated: NOW - 600000, rollout: [meta(NOW - 3600000, 't-idle', proj), started(NOW - 700000), assistantText(NOW - 650000), complete(NOW - 600000)] }),
    T('t-done', { updated: NOW - 3 * 3600000, model: null, title: '', created: NOW - 4 * 3600000,
      rollout: [meta(NOW - 4 * 3600000, 't-done', proj), turnContext(NOW - 4 * 3600000, 'gpt-5-mini'), started(NOW - 4 * 3600000), tokens(NOW - 3 * 3600000, 500, 700), agentMsg(NOW - 3 * 3600000), complete(NOW - 3 * 3600000)] }),
    T('t-abort', { updated: NOW - 30000, rollout: [meta(NOW - 60000, 't-abort', proj), started(NOW - 50000), aborted(NOW - 30000)] }),
    T('t-child', { cwd: '\\\\?\\C:\\repo\\x', agent_nickname: 'Ada', agent_role: 'explorer', rollout: [meta(NOW - 3000000, 't-child', proj), started(NOW - 20000), toolCall(NOW - 10000, 'apply_patch')] }),
    T('t-grand', { rollout: [started(NOW - 20000)], updated: NOW - 10000 }),
    T('t-stale', { updated: NOW - 3 * 3600000, rollout: [meta(NOW - 4 * 3600000, 't-stale', proj), started(NOW - 3 * 3600000)] }),
    T('t-nofile', { rollout: null, updated: NOW - 10000 }),
    T('t-arch', { archived: true, rollout: null, updated: NOW - 4000 }),
    T('t-old', { rollout: null, updated: NOW - 30 * 86400000, created: NOW - 31 * 86400000 }),
    T('t-junk', { rollout: [meta(NOW - 10000, 't-junk', proj), '{not json', started(NOW - 9000), '{"timestamp":"x","type":"event_msg","payload":{"type":"task_comp'], rolloutNoNewline: true, updated: NOW - 8000 }),
  ];
  const edges = [{ parent: 't-run', child: 't-child', status: 'open' }, { parent: 't-child', child: 't-grand', status: 'open' }, { parent: 't-run', child: 't-arch', status: 'closed' }];
  const fx = buildCodexFixture(codexHome, { threads, edges, extraStates: ['state_3.sqlite'], ...over });
  const env = { now: () => NOW, days: 14, platform: process.platform, home, vars: {} };
  return { root, NOW, env, home, codexHome, proj, ...fx };
}
const scanOf = (sc, cache = new Map()) => codex.scan(sc.env, { since: null, cache });
const byId = r => Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));

test('detect and watchPaths', async () => {
  const sc = scenario();
  assert.equal(await codex.detect(sc.env), true);
  assert.equal(await codex.detect({ ...sc.env, home: path.join(sc.root, 'nowhere') }), false);
  assert.equal(codex.tool, 'codex'); assert.equal(codex.label, 'Codex'); assert.equal(codex.toolShort, 'cx'); assert.equal(codex.experimental, true);
  assert.equal(codex.timeline, undefined);
  assert.equal(codex.watchPaths(sc.env)[0].path, sc.codexHome);
});

test('CODEX_HOME overrides ~/.codex', async () => {
  const sc = scenario();
  const alt = path.join(sc.root, 'alt');
  fs.cpSync(sc.codexHome, alt, { recursive: true });
  const env = { ...sc.env, home: path.join(sc.root, 'nowhere'), vars: { CODEX_HOME: alt } };
  assert.equal(await codex.detect(env), true);
  assert.ok((await codex.scan(env, { cache: new Map() })).sessions.length > 0);
});

test('scan maps threads, uses the highest state_N and honours the day window', async () => {
  const sc = scenario();
  const r = await scanOf(sc);
  const by = byId(r);
  assert.equal(by['t-old'], undefined);
  assert.equal(r.sessions.length, 10);
  for (const s of r.sessions) assert.deepEqual(validateAdapterSession(s), { ok: true }, s.nativeId);
  const st = s => deriveState(s.stateBasis, sc.NOW);

  assert.equal(by['t-run'].projectPath, sc.proj);
  assert.equal(by['t-run'].title, 'Title t-run');
  assert.equal(by['t-run'].titleSource, 'explicit');
  assert.equal(by['t-run'].model, 'gpt-5-codex');
  assert.deepEqual(by['t-run'].tokens, { context: 900, total: 4200 });
  assert.deepEqual(st(by['t-run']), { state: 'running', stateSource: 'field' });
  assert.deepEqual(by['t-run'].lastActivity, { at: new Date(sc.NOW - 6000).toISOString(), kind: 'tool', toolName: 'shell', summary: 'shell' });
  assert.equal(by['t-run'].refs.db, sc.dbPath);
  assert.equal(by['t-run'].refs.file, sc.rolloutOf('t-run'));
  assert.equal(by['t-run'].createdAt, new Date(sc.NOW - 3600000).toISOString());

  assert.deepEqual(st(by['t-idle']), { state: 'idle', stateSource: 'field' });
  assert.equal(by['t-idle'].endedAt, null);
  assert.deepEqual(st(by['t-done']), { state: 'finished', stateSource: 'field' });
  assert.equal(by['t-done'].endedAt, by['t-done'].updatedAt);
  assert.equal(by['t-done'].model, 'gpt-5-mini');            // fallback to turn_context
  assert.equal(by['t-done'].title, 'Codex t-done');
  assert.equal(by['t-done'].titleSource, 'fallback');
  assert.equal(st(by['t-abort']).state, 'idle');
  assert.equal(by['t-nofile'].lastActivity, null);
  assert.equal(st(by['t-nofile']).state, 'running');           // mtime basis, updated 10 s ago
  assert.equal(by['t-arch'].archived, true);
  assert.equal(by['t-nofile'].refs.file, sc.rolloutOf('t-nofile'));
});

test('sub-agent linkage via thread_spawn_edges, depth, closed edge', async () => {
  const sc = scenario();
  const by = byId(await scanOf(sc));
  assert.equal(by['t-child'].parentNativeId, 't-run');
  assert.equal(by['t-child'].depth, 1);
  assert.equal(by['t-child'].agentType, 'explorer');
  assert.equal(by['t-child'].projectPath, 'C:\\repo\\x');       // extended-length prefix stripped
  assert.equal(by['t-grand'].parentNativeId, 't-child');
  assert.equal(by['t-grand'].depth, 2);
  assert.equal(by['t-run'].parentNativeId, null);
  assert.equal(by['t-run'].depth, 0);
  assert.deepEqual(deriveState(by['t-arch'].stateBasis, sc.NOW), { state: 'finished', stateSource: 'field' });
});

test('running only while the open turn is fresh; stale open turn is not running', async () => {
  const sc = scenario();
  const by = byId(await scanOf(sc));
  const state = id => deriveState(by[id].stateBasis, sc.NOW).state;
  assert.equal(state('t-run'), 'running');
  assert.equal(state('t-child'), 'running');
  assert.equal(state('t-stale'), 'finished');                 // 3 h old, no completion record -> mtime basis
  assert.equal(state('t-junk'), 'running');                    // malformed lines ignored, open turn seen
});

test('bad rows are skipped and counted, never thrown', async () => {
  const sc = scenario();
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(sc.dbPath);
  db.exec("INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode) VALUES ('', 'x', 1, 2, 'cli', 'o', 'c', 't', 'x', 'y')");
  db.close();
  const r = await scanOf(sc);
  assert.equal(r.skipped, 1);
  assert.equal(r.sessions.length, 10);
});

test('unreadable state db degrades to a note, never throws', async () => {
  const sc = scenario();
  fs.writeFileSync(path.join(sc.codexHome, 'state_99.sqlite'), 'this is not sqlite');
  const r = await scanOf(sc);
  assert.deepEqual(r.sessions, []);
  assert.match(r.notes[0], /codex state db unreadable/);
});

test('rollout-only fallback when there is no state db (session_meta, parent from source.subagent)', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-cx-'));
  const NOW = Date.now();
  const home = path.join(root, 'home'); const codexHome = path.join(home, '.codex');
  const proj = path.join(root, 'p');
  buildCodexFixture(codexHome, { rolloutOnly: true, threads: [
    { id: 'r-1', cwd: proj, created: NOW - 60000, updated: NOW - 3000, rollout: [meta(NOW - 60000, 'r-1', proj), started(NOW - 5000)] },
    { id: 'r-2', cwd: proj, created: NOW - 50000, updated: NOW - 3000, rollout: [meta(NOW - 50000, 'r-2', proj, { source: { subagent: { thread_spawn: { parent_thread_id: 'r-1' } } } }), started(NOW - 5000)] },
    { id: 'r-bad', cwd: proj, created: NOW - 50000, updated: NOW - 3000, rollout: ['garbage'] },
  ] });
  const env = { now: () => NOW, days: 14, platform: process.platform, home, vars: {} };
  assert.equal(await codex.detect(env), true);
  const r = await codex.scan(env, { cache: new Map() });
  assert.equal(r.skipped, 1);
  const by = byId(r);
  assert.deepEqual(Object.keys(by).sort(), ['r-1', 'r-2']);
  assert.equal(by['r-2'].parentNativeId, 'r-1');
  assert.equal(by['r-1'].projectPath, proj);
  assert.equal(by['r-1'].titleSource, 'fallback');
  assert.equal(deriveState(by['r-1'].stateBasis, NOW).state, 'running');
  assert.equal(JSON.stringify(r).includes(BODY), false);
});

test('no prompt or message content appears in output', async () => {
  const sc = scenario();
  assert.equal(JSON.stringify(await scanOf(sc)).includes(BODY), false);
});

test('fresh cache is reused; changed rollout is re-read', async () => {
  const sc = scenario();
  const cache = new Map();
  const r1 = await scanOf(sc, cache);
  assert.equal(await scanOf(sc, cache), r1);
  const later = { ...sc.env, now: () => sc.NOW + 60000 };
  fs.appendFileSync(sc.rolloutOf('t-idle'), started(sc.NOW + 1000) + '\n');
  const r2 = await codex.scan(later, { cache });
  assert.notEqual(r2, r1);
  assert.equal(deriveState(byId(r2)['t-idle'].stateBasis, sc.NOW + 60000).state, 'running');
});

test('busy twice then succeeds; missing node:sqlite -> note', async () => {
  const sc = scenario();
  const real = await import('node:sqlite');
  const busy = () => Object.assign(new Error('database is locked'), { errcode: 5 });
  let fails = 2;
  const flaky = createCodexAdapter({ sleep: async () => {}, loadSqlite: async () => ({ DatabaseSync: class extends real.DatabaseSync {
    constructor(...x) { if (fails-- > 0) throw busy(); super(...x); } } }) });
  assert.equal((await flaky.scan(sc.env, { cache: new Map() })).sessions.length, 10);
  const locked = createCodexAdapter({ sleep: async () => {}, loadSqlite: async () => ({ DatabaseSync: class { constructor() { throw busy(); } } }) });
  assert.match((await locked.scan(sc.env, { cache: new Map() })).notes[0], /locked/);
  const none = createCodexAdapter({ loadSqlite: async () => { throw new Error('no'); } });
  assert.match((await none.scan(sc.env, { cache: new Map() })).notes[0], /node:sqlite unavailable/);
});

test('readThreads selects an explicit column list, never SELECT * or content columns', async () => {
  const sc = scenario();
  const real = await import('node:sqlite');
  const sqls = [];
  const a = createCodexAdapter({ loadSqlite: async () => ({ DatabaseSync: class extends real.DatabaseSync {
    prepare(sql) { sqls.push(sql); return super.prepare(sql); } } }) });
  const r = await a.scan(sc.env, { since: null, cache: new Map() });
  assert.equal(r.sessions.length, 10);
  const q = sqls.find(s => /FROM threads$/.test(s.trim()));
  assert.ok(q, 'threads query issued');
  assert.equal(/\*/.test(q), false);
  assert.equal(/first_user_message|preview/.test(q), false);
  assert.match(q, /\bid\b.*\brollout_path\b/);
});
