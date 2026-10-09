// 0.8.2 Desk clarity: one primary badge per row, one actionable secondary badge, quota banner, token chip.
import test from 'node:test';
import assert from 'node:assert/strict';
import { rowBadges, statusLegend, parseResetText, quotaText, laterSuccess, cumulativeTokensText, cumulativeTokensTitle } from '../public/format.js';

const FAIL = { quota: 'quota', test: 'tests failed', unknown: 'failed' };

test('rowBadges: finished agent with a missing report -> done + "no report"; bookkeeping only in details', () => {
  const r = rowBadges({ state: 'finished', parentId: 'p', reportMissing: { at: 'x', task: 't-1' }, accepted: true, taskId: 't-1', tracked: true }, FAIL);
  assert.equal(r.primary.text, 'done');
  assert.equal(r.secondary.text, 'no report');
  assert.deepEqual(r.details, ['Task t-1', 'Accepted: its task is done or approved; later notifications from it are stale']);
  assert.ok(r.primary.title && r.secondary.title);
});

test('rowBadges: failed appears once; interrupted/no report never join a failed row', () => {
  const r = rowBadges({ state: 'failed', failure: { kind: 'unknown' }, interrupted: { errorType: 'rate_limit', files: 2 }, reportMissing: { at: 'x' } }, FAIL);
  assert.equal(r.primary.text, 'failed');
  assert.equal(r.secondary, null);
  const q = rowBadges({ state: 'failed', failure: { kind: 'quota' }, interrupted: { errorType: 'rate_limit' } }, FAIL);
  assert.equal(q.secondary.text, 'quota');
});

test('rowBadges: only ONE secondary badge, interrupted wins; not tracked is a detail', () => {
  const r = rowBadges({ state: 'idle', interrupted: { errorType: 'quota', files: 1 }, reportMissing: { at: 'x' }, reportTooLong: { lines: 12 } }, FAIL);
  assert.equal(r.primary.text, 'stopped');
  assert.equal(r.secondary.text, 'interrupted');
  assert.match(r.secondary.title, /1 uncommitted file\./);
  const u = rowBadges({ state: 'finished', parentId: 'p', tracked: false }, FAIL);
  assert.equal(u.secondary, null);
  assert.match(u.details[0], /^Not tracked/);
  assert.equal(rowBadges({ state: 'running' }).secondary, null);
  assert.equal(rowBadges({ state: 'waiting' }).primary.text, 'waiting');
  assert.equal(rowBadges({ state: 'unknown' }).primary.text, 'stopped');
});

test('statusLegend lists every state and extra badge with a sentence', () => {
  const l = statusLegend();
  assert.deepEqual(l.filter(x => x.kind === 'state').map(x => x.word), ['running', 'waiting', 'done', 'failed', 'stopped']);
  assert.deepEqual(l.filter(x => x.kind === 'extra').map(x => x.word), ['interrupted', 'no report', 'long report']);
  assert.ok(l.every(x => x.tip.length > 20));
});

test('token chip: cached goes to the tooltip', () => {
  const s = { tokens: { total: 43000, cached: 2100000 } };
  assert.equal(cumulativeTokensText(s), '43.0k used');
  assert.match(cumulativeTokensTitle(s), /2\.1M more tokens were served from cache/);
  assert.equal(cumulativeTokensTitle({ tokens: { total: null } }), null);
});

test('quota banner: local reset time, unknown reset, 5 h expiry, later success, dismissal', () => {
  const at = '2026-10-07T04:42:00.000Z', now = Date.parse(at) + 600000;
  assert.match(quotaText({ at, reset: null, resetAt: null }, { now }), /^Quota limit hit at \d{1,2}:\d{2}.*\(local\); reset time unknown/);
  assert.match(quotaText({ at, reset: null, resetAt: '2026-10-07T09:00:00Z' }, { now }), /resets at \d{1,2}:\d{2}.* \(local\)/);
  assert.match(quotaText({ at, reset: '5pm (Nope/Zone)', resetAt: null }, { now }), /resets 5pm [(]Nope\/Zone[)]/);   // unparsable zone: the text
  assert.equal(parseResetText('5pm (UTC)', Date.parse(at)), Date.parse('2026-10-07T17:00:00Z'));
  assert.equal(parseResetText('3:30 PM (UTC)', Date.parse(at)), Date.parse('2026-10-07T15:30:00Z'));
  assert.equal(parseResetText('4am (Europe/Istanbul)', Date.parse(at)), Date.parse('2026-10-08T01:00:00Z'));   // next occurrence after the event
  assert.ok(Number.isNaN(parseResetText('11:20pm', Date.parse(at))));   // no zone: shown as text
  assert.match(quotaText({ at, reset: '5pm (UTC)', resetAt: null }, { now }), /resets at \d{1,2}:\d{2}.* \(local\)/);
  assert.equal(quotaText({ at, reset: null, resetAt: null }, { now: Date.parse(at) + 5.1 * 3600000 }), null);
  assert.notEqual(quotaText({ at, reset: null, resetAt: '2026-10-08T09:00:00Z' }, { now: Date.parse(at) + 6 * 3600000 }), null);   // known future reset keeps it
  assert.equal(quotaText({ at, reset: null, resetAt: null }, { now, laterRun: true }), null);
  assert.equal(quotaText({ at, reset: null, resetAt: null }, { now, dismissedAt: at }), null);
  assert.notEqual(quotaText({ at, reset: null, resetAt: null }, { now, dismissedAt: '2026-10-06T00:00:00.000Z' }), null);
  assert.equal(quotaText(null), null);
});

test('laterSuccess: a clean agent run finished after the quota event hides the banner', () => {
  const q = { at: '2026-10-07T04:42:00.000Z' };
  const done = { state: 'finished', updatedAt: '2026-10-07T05:10:00.000Z' };
  assert.equal(laterSuccess([{ state: 'idle', children: [done] }], q), true);
  assert.equal(laterSuccess([{ state: 'idle', children: [{ ...done, reportMissing: { at: 'x' } }] }], q), false);
  assert.equal(laterSuccess([{ state: 'finished', updatedAt: '2026-10-07T04:00:00.000Z', children: [] }], q), false);
  assert.equal(laterSuccess([], q), false);
});
