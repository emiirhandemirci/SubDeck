// desk/test/scan-budget.test.mjs
// Scan budgets: a slow scan never looks like "no sessions" (previous or partial data stays visible, warning not error).
import test from 'node:test';
import assert from 'node:assert/strict';
import { createCore } from '../lib/core.mjs';

const NOW = Date.parse('2026-09-29T12:00:00Z');
const iso = msAgo => new Date(NOW - msAgo).toISOString();
const env = { platform: 'linux', disabled: [], days: 14 };
const sess = (id, projectPath = '/p/' + id) => ({ nativeId: id, tool: 'claude-code', parentNativeId: null, depth: 0, projectPath, projectLabel: null,
  title: 'T ' + id, titleSource: 'summary', agentType: null, model: null, createdAt: iso(60000), updatedAt: iso(1000), endedAt: null,
  tokens: { context: null, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false,
  stateBasis: { kind: 'mtime', at: iso(1000), stateSource: 'mtime' } });
const ok = sessions => ({ sessions, skipped: 0, notes: [] });
const sleep = ms => new Promise(r => setTimeout(r, ms));
function gate() { let open; const p = new Promise(r => { open = r; }); return { p, open }; }
function adapter(scan, tool = 'claude-code') {
  return { tool, label: 'Claude Code', toolShort: 'claude', adapterVersion: '1', async detect() { return true; }, watchPaths() { return []; }, scan };
}
const src = core => core.snapshot().sources[0];

test('first scan gets the larger budget; rescans get the short one', async () => {
  let delay = 120;
  const core = createCore({ env, adapters: [adapter(async () => { await sleep(delay); return ok([sess('a')]); })], now: () => NOW, timeoutMs: 40, firstTimeoutMs: 2000 });
  await core.scanAll();
  assert.equal(src(core).health, 'ok');               // 120 ms > 40 ms, but the first scan may take up to 2 s
  assert.equal(src(core).scanning, false);
  assert.equal(core.snapshot().sessions.length, 1);
  await core.scanAll();                               // rescan: 120 ms > 40 ms budget
  assert.equal(src(core).slow, true);
  assert.equal(src(core).health, 'degraded');
  assert.match(src(core).lastError, /^slow scan, still running; showing previous data/);
  assert.equal(core.snapshot().sessions.length, 1);
  await sleep(200);
  assert.equal(src(core).health, 'ok');
  assert.equal(src(core).slow, false);
});

test('slow rescan keeps the previous snapshot and publishes the late result when it ends', async () => {
  let n = 0;
  const g = gate();
  const core = createCore({ env, adapters: [adapter(async () => { n++; if (n === 2) { await g.p; return ok([sess('a'), sess('b')]); } return ok([sess('a')]); })],
    now: () => NOW, timeoutMs: 30, firstTimeoutMs: 1000 });
  await core.scanAll();
  const events = [];
  core.onChanged(e => events.push(e));
  await core.scanAll();
  assert.deepEqual(core.snapshot().sessions.map(s => s.nativeId), ['a']);   // nothing discarded
  assert.equal(src(core).health, 'degraded');
  events.length = 0;
  g.open();
  await sleep(20);
  assert.deepEqual(core.snapshot().sessions.map(s => s.nativeId).sort(), ['a', 'b']);
  assert.equal(src(core).health, 'ok');
  assert.ok(events.some(e => e.sources && e.projects.length === 1), 'late result is broadcast');
});

test('first scan over budget shows partial data with progress; the final result replaces it', async () => {
  const g = gate();
  const scan = async (e, ctx) => {
    assert.equal(typeof ctx.partial, 'function');
    ctx.partial({ sessions: [sess('a')], skipped: 0, notes: [], progress: { projects: 1, total: 3 } });
    ctx.partial({ sessions: [sess('a'), sess('b')], skipped: 0, notes: [], progress: { projects: 2, total: 3 } });
    await g.p;
    return ok([sess('a'), sess('b'), sess('c')]);
  };
  const core = createCore({ env, adapters: [adapter(scan)], now: () => NOW, timeoutMs: 10, firstTimeoutMs: 50, publishMs: 0 });
  await core.scanAll();
  const s = src(core);
  assert.equal(s.detected, true);
  assert.equal(s.scanning, true);
  assert.equal(s.health, 'degraded');
  assert.equal(s.lastError, 'slow scan, still running; showing partial data (2 projects so far)');
  assert.equal(s.scanProgress, 2);
  assert.equal(core.snapshot().projects.length, 2);
  g.open();
  await sleep(20);
  assert.equal(core.snapshot().projects.length, 3);
  assert.equal(src(core).scanning, false);
  assert.equal(src(core).lastError, null);
});

test('partial data is visible while a first scan is still within budget', async () => {
  const g = gate();
  const scan = async (e, ctx) => { ctx.partial({ sessions: [sess('a')], progress: { projects: 1 } }); await g.p; return ok([sess('a')]); };
  const core = createCore({ env, adapters: [adapter(scan)], now: () => NOW, firstTimeoutMs: 5000, publishMs: 0 });
  const done = core.scanAll();
  await sleep(20);
  assert.equal(src(core).scanning, true);
  assert.equal(src(core).lastError, 'scanning… (1 project so far)');
  assert.equal(core.snapshot().sessions.length, 1);
  g.open();
  await done;
  assert.equal(src(core).scanning, false);
  assert.equal(src(core).health, 'ok');
});

test('rescans get no partial callback; a genuine exception is still an error', async () => {
  let n = 0, sawPartial = null;
  const core = createCore({ env, adapters: [adapter(async (e, ctx) => { n++; if (n === 2) { sawPartial = typeof ctx.partial; throw new Error('EACCES: permission denied\nstack'); } return ok([sess('a')]); })],
    now: () => NOW });
  await core.scanAll();
  await core.scanAll();
  assert.equal(sawPartial, 'undefined');
  assert.equal(src(core).health, 'error');
  assert.equal(src(core).lastError, 'EACCES: permission denied');
  assert.equal(core.snapshot().sessions.length, 1);   // previous data kept
});

test('changes before the first listener are replayed to it', async () => {
  const core = createCore({ env, adapters: [adapter(async () => ok([sess('a')]))], now: () => NOW });
  await core.scanAll();
  const events = [];
  core.onChanged(e => events.push(e));
  await sleep(5);
  assert.equal(events.length, 1);
  assert.equal(events[0].sources, true);
  assert.equal(events[0].projects.length, 1);
});
