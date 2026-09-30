// desk/test/model.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { clip, deriveState, validateAdapterSession, makeSource, sessionIdOf, projectIdOf, RUNNING_MS, IDLE_MS, STALE_MS } from '../lib/model.mjs';

test('clip: code points, single line, ellipsis', () => {
  assert.equal(clip('a\nb\tc', 80), 'a b c');
  assert.equal(clip('x'.repeat(81), 80), 'x'.repeat(79) + '…');
  assert.equal(clip('x'.repeat(80), 80), 'x'.repeat(80));
  assert.equal(Array.from(clip('😀'.repeat(81), 80)).length, 80); // no split surrogate
  assert.equal(clip('   ', 80), null);
  assert.equal(clip(null, 80), null);
});

test('deriveState thresholds', () => {
  const now = Date.parse('2026-09-29T12:00:00Z');
  const at = ms => new Date(now - ms).toISOString();
  assert.deepEqual(deriveState({ kind: 'mtime', at: at(RUNNING_MS - 1000), stateSource: 'mtime' }, now), { state: 'running', stateSource: 'mtime' });
  assert.equal(deriveState({ kind: 'mtime', at: at(RUNNING_MS + 1000) }, now).state, 'idle');
  assert.equal(deriveState({ kind: 'mtime', at: at(IDLE_MS - 1000) }, now).state, 'idle');
  assert.equal(deriveState({ kind: 'mtime', at: at(IDLE_MS + 1000) }, now).state, 'finished');
  assert.equal(deriveState({ kind: 'hookOpen', at: at(STALE_MS - 1000) }, now).state, 'running');
  assert.deepEqual(deriveState({ kind: 'hookOpen', at: at(STALE_MS + 1000) }, now), { state: 'stale', stateSource: 'hook' });
  assert.deepEqual(deriveState({ kind: 'fixed', state: 'finished', stateSource: 'field' }, now), { state: 'finished', stateSource: 'field' });
  assert.deepEqual(deriveState({ kind: 'mtime', at: null }, now), { state: 'unknown', stateSource: 'none' });
  assert.deepEqual(deriveState(undefined, now), { state: 'unknown', stateSource: 'none' });
});

const good = () => ({
  nativeId: 'abc', tool: 'claude-code', parentNativeId: null, depth: 0, projectPath: '/p', projectLabel: null,
  title: 'T', titleSource: 'summary', agentType: null, model: null, createdAt: null, updatedAt: null, endedAt: null,
  tokens: { context: null, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false,
  stateBasis: { kind: 'mtime', at: null, stateSource: 'mtime' },
});

test('validateAdapterSession', () => {
  assert.equal(validateAdapterSession(good()).ok, true);
  assert.equal(validateAdapterSession({ ...good(), nativeId: '' }).ok, false);
  assert.equal(validateAdapterSession({ ...good(), title: '' }).ok, false);
  assert.equal(validateAdapterSession({ ...good(), projectPath: null, projectLabel: null }).ok, false);
  assert.equal(validateAdapterSession({ ...good(), stateBasis: { kind: 'x' } }).ok, false);
  assert.equal(validateAdapterSession({ ...good(), lastActivity: { at: null, kind: 'bogus' } }).ok, false);
});

test('ids are URL-safe and stable', () => {
  assert.equal(sessionIdOf('claude', 'a/b:c'), 'claude.a_b_c');
  assert.match(projectIdOf('e:/subdeck'), /^p_[0-9a-f]{12}$/);
  assert.equal(projectIdOf('e:/subdeck'), projectIdOf('e:/subdeck'));
});

test('makeSource defaults', () => {
  assert.deepEqual(makeSource({ tool: 'cursor', label: 'Cursor', adapterVersion: '1' }), {
    id: 'cursor', tool: 'cursor', label: 'Cursor', adapterVersion: '1', detected: false, health: 'ok', lastError: null,
    lastScanAt: null, scanMs: null, counts: { projects: 0, sessions: 0, running: 0, skipped: 0 } });
});

test('failed is a supported fixed state; runStartedAt is an optional string', () => {
  const base = { nativeId: 'a', tool: 't', title: 'x', titleSource: 'meta', projectPath: '/p', tokens: { context: null, total: null },
    stateBasis: { kind: 'fixed', state: 'failed', stateSource: 'field' } };
  assert.equal(validateAdapterSession(base).ok, true);
  assert.equal(validateAdapterSession({ ...base, runStartedAt: '2026-09-29T10:00:00.000Z' }).ok, true);
  assert.equal(validateAdapterSession({ ...base, runStartedAt: 5 }).ok, false);
  assert.deepEqual(deriveState(base.stateBasis, 0), { state: 'failed', stateSource: 'field' });
});
