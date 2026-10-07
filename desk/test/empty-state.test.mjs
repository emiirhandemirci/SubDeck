// desk/test/empty-state.test.mjs
// The "No sessions in the last N days" empty state never shows while a source is still scanning or failed.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { emptyProjectsText, sourceStatus } from '../public/format.js';

const src = over => ({ id: 'claude-code', label: 'Claude Code', detected: true, health: 'ok', lastError: null, scanning: false, ...over });

test('empty project list: scanning, error, not detected, really empty', () => {
  assert.equal(emptyProjectsText([src({ scanning: true, health: 'degraded', lastError: 'scanning… (3 projects so far)' })], 14), 'Scanning Claude Code history…');
  assert.equal(emptyProjectsText([src({ health: 'error', lastError: 'EACCES: permission denied' })], 14), 'Claude Code: EACCES: permission denied');
  assert.equal(emptyProjectsText([src({ detected: false })], 14), 'No supported AI coding tool data found (looked for: Claude Code).');
  assert.equal(emptyProjectsText([src({})], 7), 'No sessions in the last 7 days.');
  assert.equal(emptyProjectsText([], 14), 'Scanning…');   // before the first scan published any source
  assert.equal(emptyProjectsText([src({}), src({ id: 'cursor', label: 'Cursor', scanning: true })], 14), 'Scanning Cursor history…');
});

test('badge status: scanning wins over health while a scan runs', () => {
  assert.equal(sourceStatus(src({ scanning: true, health: 'degraded' })), 'scanning…');
  assert.equal(sourceStatus(src({ health: 'degraded' })), 'degraded');
  assert.equal(sourceStatus(src({ health: 'error' })), 'error');
});

test('app.js uses the helpers for the empty list and the badges', () => {
  const app = fs.readFileSync(new URL('../public/app.js', import.meta.url), 'utf8');
  assert.match(app, /emptyProjectsText\(S\.sources/);
  assert.ok(!/`No sessions in the last \$\{/.test(app), 'the plain "no sessions" text is not hard-coded in app.js anymore');
  assert.match(app, /\$\{s\.label\}: \$\{sourceStatus\(s\)\}/);
});

test('noMatchText mentions hidden temporary projects', async () => {
  const { noMatchText } = await import('../public/format.js');
  assert.equal(noMatchText(0), 'No projects match.');
  assert.match(noMatchText(1), /1 temporary project is hidden/);
  assert.match(noMatchText(3), /3 temporary projects are hidden/);
});
