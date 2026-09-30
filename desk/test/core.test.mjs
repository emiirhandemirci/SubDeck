// desk/test/core.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { createCore } from '../lib/core.mjs';

const NOW = Date.parse('2026-09-29T12:00:00Z');
const iso = msAgo => new Date(NOW - msAgo).toISOString();
function sess(over = {}) {
  return { nativeId: 'n1', tool: 'fake', parentNativeId: null, depth: 0, projectPath: 'E:\\SubDeck', projectLabel: null,
    title: 'T', titleSource: 'summary', agentType: null, model: null, createdAt: iso(60000), updatedAt: iso(1000), endedAt: null,
    tokens: { context: 10, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false,
    stateBasis: { kind: 'mtime', at: iso(1000), stateSource: 'mtime' }, ...over };
}
function adapter(tool, toolShort, result, { detect = true } = {}) {
  return { tool, label: tool, toolShort, adapterVersion: '1',
    async detect() { return detect; },
    watchPaths() { return [{ path: '/w/' + tool, recursive: true }]; },
    async scan() { return typeof result === 'function' ? result() : result; } };
}
const env = { platform: 'win32', disabled: [], days: 14 };
const ok = sessions => ({ sessions, skipped: 0, notes: [] });

test('merges projects by path across tools', async () => {
  const a = adapter('claude-code', 'claude', ok([sess({ tool: 'claude-code' })]));
  const b = adapter('cursor', 'cursor', ok([sess({ tool: 'cursor', nativeId: 'c1', projectPath: 'e:/subdeck/' })]));
  const core = createCore({ env, adapters: [a, b], now: () => NOW });
  await core.scanAll();
  const s = core.snapshot();
  assert.equal(s.projects.length, 1);
  assert.deepEqual(s.projects[0].tools, ['claude-code', 'cursor']);
  assert.equal(s.projects[0].name, 'SubDeck');
  assert.equal(s.projects[0].path, 'E:\\SubDeck');
  assert.equal(s.projects[0].runningCount, 2);
  assert.deepEqual(s.sessions.map(x => x.id).sort(), ['claude.n1', 'cursor.c1']);
  assert.equal(s.sessions[0].stateBasis, undefined);
  assert.equal(s.sessions[0].durationMs, 60000);
});

test('parent links, orphan sub-agent becomes top-level, childCount', async () => {
  const a = adapter('claude-code', 'claude', ok([
    sess({ tool: 'claude-code', nativeId: 'p' }),
    sess({ tool: 'claude-code', nativeId: 'k', parentNativeId: 'p', depth: 1 }),
    sess({ tool: 'claude-code', nativeId: 'o', parentNativeId: 'missing', depth: 1 }),
  ]));
  const core = createCore({ env, adapters: [a], now: () => NOW });
  await core.scanAll();
  const by = Object.fromEntries(core.snapshot().sessions.map(x => [x.nativeId, x]));
  assert.equal(by.k.parentId, 'claude.p'); assert.equal(by.k.depth, 1);
  assert.equal(by.o.parentId, null); assert.equal(by.o.depth, 0);
  assert.equal(by.p.childCount, 1);
});

test('null path groups under a label project; invalid sessions counted', async () => {
  const a = adapter('cursor', 'cursor', { sessions: [sess({ tool: 'cursor', projectPath: null, projectLabel: 'Cursor (no folder)' }), sess({ title: '' })], skipped: 1, notes: [] });
  const core = createCore({ env, adapters: [a], now: () => NOW });
  await core.scanAll();
  const s = core.snapshot();
  assert.equal(s.projects[0].path, null);
  assert.equal(s.projects[0].name, 'Cursor (no folder)');
  assert.equal(s.sources[0].counts.skipped, 2);
  assert.equal(s.sources[0].health, 'degraded');
  assert.equal(s.sources[0].lastError, '2 malformed item(s) skipped');
});

test('timeout and throw are isolated; previous sessions kept', async () => {
  let slowNow = false;
  const slow = adapter('cursor', 'cursor', ok([sess({ tool: 'cursor' })]));
  const orig = slow.scan;
  slow.scan = async (...x) => { if (slowNow) await new Promise(r => setTimeout(r, 200)); return orig(...x); };
  const bad = adapter('claude-code', 'claude', null);
  bad.scan = async () => { throw new Error('boom\nsecond line'); };
  const core = createCore({ env, adapters: [slow, bad], now: () => NOW, timeoutMs: 50 });
  await core.scanAll();
  slowNow = true;
  await core.scanAll();
  const s = core.snapshot();
  const src = Object.fromEntries(s.sources.map(x => [x.id, x]));
  assert.equal(src['claude-code'].health, 'error');
  assert.equal(src['claude-code'].lastError, 'boom');
  assert.equal(src.cursor.health, 'error');
  assert.equal(src.cursor.lastError, 'scan timed out after 5 s');
  assert.equal(s.sessions.length, 1); // cursor session from the first scan kept
});

test('not detected and disabled adapters', async () => {
  const a = adapter('cursor', 'cursor', ok([]), { detect: false });
  const b = adapter('claude-code', 'claude', ok([sess()]));
  const core = createCore({ env: { ...env, disabled: ['claude-code'] }, adapters: [a, b], now: () => NOW });
  await core.scanAll();
  assert.deepEqual(core.snapshot().sources.map(x => [x.id, x.detected, x.health]), [['cursor', false, 'ok']]);
});

test('changed events carry only affected project ids; refreshStates flips running -> idle', async () => {
  let t = NOW;
  let second = false;
  const a = adapter('claude-code', 'claude', () => ok([
    sess({ tool: 'claude-code', nativeId: 'a', projectPath: '/x' }),
    sess({ tool: 'claude-code', nativeId: 'b', projectPath: '/y', title: second ? 'T2' : 'T' }),
  ]));
  const core = createCore({ env: { ...env, platform: 'linux' }, adapters: [a], now: () => t });
  const events = [];
  core.onChanged(e => events.push(e));
  await core.scanAll();
  events.length = 0;
  second = true;
  await core.scanAll();
  const y = core.snapshot().projects.find(p => p.path === '/y').id;
  assert.deepEqual(events.map(e => e.projects), [[y]]);
  events.length = 0;
  t = NOW + 5 * 60000;
  core.refreshStates();
  assert.equal(events.length, 1);
  assert.equal(events[0].projects.length, 2);
  assert.ok(core.snapshot().sessions.every(x => x.state === 'idle'));
});

test('setWatchNote shows in lastError without degrading health', async () => {
  const core = createCore({ env, adapters: [adapter('cursor', 'cursor', ok([]))], now: () => NOW });
  await core.scanAll();
  core.setWatchNote('cursor', 'watching unavailable, polling every 5 s');
  const src = core.snapshot().sources[0];
  assert.equal(src.health, 'ok');
  assert.equal(src.lastError, 'watching unavailable, polling every 5 s');
});

test('watchTargets unions adapter paths with tool', async () => {
  const core = createCore({ env, adapters: [adapter('cursor', 'cursor', ok([]))], now: () => NOW });
  await core.scanAll();
  assert.deepEqual(core.watchTargets(), [{ tool: 'cursor', path: '/w/cursor', recursive: true }]);
});

test('duration uses runStartedAt; failed and finished end at endedAt', async () => {
  const mk = (id, over) => sess({ nativeId: id, tool: 'claude-code', parentNativeId: null, ...over });
  const a = adapter('claude-code', 'claude', ok([
    mk('r1', { createdAt: iso(50000000), runStartedAt: iso(30000), stateBasis: { kind: 'mtime', at: iso(1000), stateSource: 'mtime' } }),
    mk('f1', { createdAt: iso(50000000), runStartedAt: iso(30000), endedAt: iso(10000), stateBasis: { kind: 'fixed', state: 'failed', stateSource: 'field' } }),
    mk('d1', { createdAt: iso(50000), endedAt: iso(20000), stateBasis: { kind: 'fixed', state: 'finished', stateSource: 'field' } }),
  ]));
  const core = createCore({ env, adapters: [a], now: () => NOW });
  await core.scanAll();
  const by = Object.fromEntries(core.snapshot().sessions.map(s => [s.nativeId, s]));
  assert.equal(by.r1.durationMs, 30000);
  assert.equal(by.f1.state, 'failed');
  assert.equal(by.f1.durationMs, 20000);
  assert.equal(by.d1.durationMs, 30000);
  assert.equal(by.r1.runStartedAt, iso(30000));
  assert.equal(by.d1.runStartedAt, null);
});

test('waiting counts per project and per source; waiting projects sort first', async () => {
  const w = (extra = {}) => sess({ stateBasis: { kind: 'fixed', state: 'waiting', stateSource: 'hook' }, ...extra });
  const a = adapter('claude-code', 'claude', ok([
    w({ nativeId: 'w1', projectPath: 'e:/A', updatedAt: iso(9000000) }),
    sess({ nativeId: 'r1', projectPath: 'e:/B' }),
    sess({ nativeId: 'r2', projectPath: 'e:/B', updatedAt: iso(500) }),
  ].map(s => ({ ...s, tool: 'claude-code' }))));
  const b = adapter('cursor', 'cursor', ok([w({ nativeId: 'w2', tool: 'cursor', projectPath: 'e:/A', parentNativeId: 'w1' })]));
  const core = createCore({ env, adapters: [a, b], now: () => NOW });
  await core.scanAll();
  const s = core.snapshot();
  const pa = s.projects.find(p => p.name === 'A'), pb = s.projects.find(p => p.name === 'B');
  assert.equal(pa.waitingCount, 2);
  assert.equal(pb.waitingCount, 0);
  assert.equal(s.projects[0].name, 'A');   // waiting first even though B is running
  assert.equal(s.sources.find(x => x.id === 'claude-code').counts.waiting, 1);
  assert.equal(s.sources.find(x => x.id === 'cursor').counts.waiting, 1);
  assert.equal(s.sources.find(x => x.id === 'claude-code').counts.running, 2);
});

test('experimental flag flows into the source', async () => {
  const a = { ...adapter('codex', 'cx', ok([])), experimental: true };
  const core = createCore({ env, adapters: [a, adapter('cursor', 'cursor', ok([]))], now: () => NOW });
  await core.scanAll();
  const s = core.snapshot().sources;
  assert.equal(s.find(x => x.id === 'codex').experimental, true);
  assert.equal(s.find(x => x.id === 'cursor').experimental, false);
});
