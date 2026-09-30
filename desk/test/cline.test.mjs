// desk/test/cline.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import cline from '../adapters/cline.mjs';
import { deriveState, validateAdapterSession } from '../lib/model.mjs';
import { buildClineFixture, storageRoot, apiReq, BODY } from './fixtures/cline-fixture.mjs';

const NOW = Date.now();
const mkHome = () => fs.mkdtempSync(path.join(os.tmpdir(), 'desk-cl-'));
const envOf = (home, vars) => ({ home, platform: process.platform, vars, now: () => NOW, days: 14 });
const st = s => deriveState(s.stateBasis, NOW);
const say = (ts, say, text = BODY) => ({ ts, type: 'say', say, text });

function scenario() {
  const home = mkHome();
  const cl = storageRoot(home, 'saoudrizwan.claude-dev');
  const roo = storageRoot(home, 'rooveterinaryinc.roo-cline');
  const proj = path.join(home, 'work', 'Alpha');
  const id1 = String(NOW - 3600000), id2 = String(NOW - 7200000);
  buildClineFixture(cl.dir, {
    history: [
      { id: id1, ts: NOW - 3600000, task: 'Fix the parser', tokensIn: 10, tokensOut: 5, cwdOnTaskInitialization: proj },
      { id: id2, ts: NOW - 7200000, task: 'Write docs', tokensIn: 100, tokensOut: 50, cacheReads: 7 },
      'garbage',
    ],
    tasks: {
      [id1]: { ui: [say(NOW - 3600000, 'text'), apiReq(NOW - 3000000, { tokensIn: 1000, tokensOut: 200, cacheWrites: 10, cacheReads: 500, cost: 0.1 }),
        apiReq(NOW - 3000, { tokensIn: 2000, tokensOut: 300, cacheReads: 100 }), { ts: NOW - 2000, type: 'say', say: 'tool', text: JSON.stringify({ tool: 'readFile', path: BODY }) }],
        meta: { files_in_context: [], model_usage: [{ ts: 1, model_id: 'claude-sonnet-x', model_provider_id: 'anthropic', mode: 'act' }] }, mtime: NOW - 2000 },
      [id2]: { ui: [say(NOW - 7200000, 'text'), say(NOW - 7100000, 'completion_result')], mtime: NOW - 7100000 },
      badjson: { ui: '{not json' },
      notarray: { ui: '{"a":1}' },
      empty: {},
    },
  });
  buildClineFixture(roo.dir, {
    history: [
      { id: 'roo-parent', ts: NOW - 5000, task: 'Orchestrate', workspace: proj, mode: 'orchestrator', status: 'delegated', childIds: ['roo-child'] },
      { id: 'roo-child', ts: NOW - 4000, task: 'Do subtask', workspace: proj, mode: 'code', parentTaskId: 'roo-parent', rootTaskId: 'roo-parent', status: 'active' },
    ],
    tasks: {
      'roo-parent': { ui: [say(NOW - 20000, 'text')], mtime: NOW - 20000 },
      'roo-child': { ui: [say(NOW - 4000, 'text')], mtime: NOW - 4000 },
      'roo-old': { ui: [say(NOW - 40 * 86400000, 'text')], mtime: NOW - 40 * 86400000 },
    },
  });
  return { home, env: envOf(home, cl.vars), proj, id1, id2 };
}

test('detect false without data, true with tasks dir', async () => {
  const home = mkHome();
  assert.equal(await cline.detect(envOf(home, storageRoot(home).vars)), false);
  const sc = scenario();
  assert.equal(await cline.detect(sc.env), true);
  assert.equal(cline.tool, 'cline'); assert.equal(cline.toolShort, 'cl'); assert.equal(cline.label, 'Cline/Roo');
  assert.equal(cline.experimental, true);
  assert.equal(await cline.detect({ home: null, platform: process.platform, vars: {} }), false);
});

test('scan maps Cline and Roo tasks', async () => {
  const sc = scenario();
  const r = await cline.scan(sc.env, { since: null, cache: new Map() });
  const by = Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));
  assert.deepEqual(Object.keys(by).sort(), [sc.id1, sc.id2, 'empty', 'roo-child', 'roo-parent'].sort());
  for (const s of r.sessions) assert.equal(validateAdapterSession(s).ok, true, s.nativeId);
  assert.equal(r.skipped >= 3, true); // bad history row, badjson, notarray

  const a = by[sc.id1];
  assert.equal(a.title, 'Fix the parser');
  assert.equal(a.projectPath, sc.proj);
  assert.equal(a.agentType, 'cline');
  assert.equal(a.model, 'claude-sonnet-x');
  assert.equal(a.tokens.total, 1000 + 200 + 10 + 500 + 2000 + 300 + 100);
  assert.equal(a.tokens.context, 2100);
  assert.deepEqual(st(a), { state: 'running', stateSource: 'mtime' });
  assert.equal(a.lastActivity.kind, 'tool');
  assert.equal(a.lastActivity.toolName, 'readFile');
  assert.equal(a.createdAt, new Date(NOW - 3600000).toISOString());

  const b = by[sc.id2];
  assert.deepEqual(st(b), { state: 'finished', stateSource: 'field' });
  assert.equal(b.endedAt, b.updatedAt);
  assert.equal(b.projectPath, null);
  assert.equal(b.projectLabel, 'Cline (no folder)');

  const p = by['roo-parent'], c = by['roo-child'];
  assert.equal(p.agentType, 'roo/orchestrator');
  assert.deepEqual(st(p), { state: 'idle', stateSource: 'field' });
  assert.equal(c.parentNativeId, 'roo-parent');
  assert.equal(c.depth, 1);
  assert.equal(p.depth, 0);
  assert.deepEqual(st(c), { state: 'running', stateSource: 'mtime' });
  assert.equal(c.tokens.total, null);
});

test('no content leakage', async () => {
  const sc = scenario();
  const r = await cline.scan(sc.env, { since: null, cache: new Map() });
  const j = JSON.stringify(r);
  assert.equal(j.includes(BODY), false);
  for (const s of r.sessions) { assert.ok(s.title.length <= 120); assert.equal(s.lastActivity && s.lastActivity.summary, null); }
});

test('cache reuses extraction and refreshes on change', async () => {
  const sc = scenario();
  const cache = new Map();
  const r1 = await cline.scan(sc.env, { since: null, cache });
  const r2 = await cline.scan(sc.env, { since: null, cache });
  assert.equal(r2.sessions.length, r1.sessions.length);
  const f = path.join(storageRoot(sc.home).dir, 'tasks', sc.id2, 'ui_messages.json');
  fs.writeFileSync(f, JSON.stringify([say(NOW - 100, 'text')]));
  const r3 = await cline.scan(sc.env, { since: null, cache });
  const s = r3.sessions.find(x => x.nativeId === sc.id2);
  assert.equal(deriveState(s.stateBasis, NOW).state, 'running');
});

test('scan never throws on unreadable env', async () => {
  const r = await cline.scan({ home: null, platform: 'linux', vars: {}, now: () => NOW, days: 14 }, { cache: new Map() });
  assert.deepEqual(r.sessions, []);
  assert.ok(Array.isArray(cline.watchPaths({ home: '/nonexistent', platform: 'linux', vars: {} })));
});
