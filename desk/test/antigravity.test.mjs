// desk/test/antigravity.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL } from 'node:url';
import antigravity, { createAntigravityAdapter } from '../adapters/antigravity.mjs';
import { validateAdapterSession, deriveState } from '../lib/model.mjs';
import './fixtures/tmpclean.mjs';

const mk = () => fs.mkdtempSync(path.join(os.tmpdir(), 'desk-ag-'));
const envOf = (home, NOW = Date.now()) => ({ home, platform: process.platform, vars: { ANTIGRAVITY_HOME: path.join(home, 'agy') }, now: () => NOW, days: 14 });
const A = 'aaaaaaaa-1111-4111-8111-111111111111';
const B = 'bbbbbbbb-2222-4222-8222-222222222222';
const C = 'cccccccc-3333-4333-8333-333333333333';
const D = 'dddddddd-4444-4444-8444-444444444444';

function convDb(root, id, mtime) {
  fs.mkdirSync(path.join(root, 'conversations'), { recursive: true });
  const f = path.join(root, 'conversations', id + '.db');
  const db = new DatabaseSync(f);
  db.exec('CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_payload BLOB); INSERT INTO steps VALUES (1, x\'00\')');
  db.close();
  if (mtime) fs.utimesSync(f, mtime / 1000, mtime / 1000);
  return f;
}
function summaries(root, rows) {
  const db = new DatabaseSync(path.join(root, 'conversation_summaries.db'));
  db.exec(`CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT, step_count INT,
    workspace_uris TEXT, status TEXT, agent_name TEXT, parent_conversation_id TEXT, nesting_depth INT)`);
  const ins = db.prepare('INSERT INTO conversation_summaries VALUES (?,?,?,?,?,?,?,?,?)');
  for (const r of rows) ins.run(r.id, r.title || '', 'PREVIEW_MARKER', r.steps || 0, r.ws || '', r.status || '', r.agent || '', r.parent || '', r.depth || 0);
  db.close();
}

test('detect false without data', async () => {
  const home = mk();
  assert.equal(await antigravity.detect(envOf(home)), false);
  assert.deepEqual((await antigravity.scan(envOf(home), { cache: new Map() })).sessions, []);
});

test('scan: with and without summary row, sub-agent, unknown status, stale file, no leakage', async () => {
  const home = mk(); const NOW = Date.now(); const root = path.join(home, 'agy');
  const proj = path.join(home, 'work', 'Alpha');
  convDb(root, A, NOW - 600000);          // has a row, IDLE, recent
  convDb(root, B, NOW - 3600000);         // no summary row (index lag)
  convDb(root, C, NOW - 60000);           // sub-agent, unknown status
  convDb(root, D, NOW - 40 * 86400000);   // too old
  fs.writeFileSync(path.join(root, 'conversations', B + '.db-wal'), '');
  summaries(root, [
    { id: A, title: 'Fix the parser', ws: JSON.stringify([pathToFileURL(proj).href]), status: 'CASCADE_RUN_STATUS_IDLE', steps: 12 },
    { id: C, parent: A, depth: 1, agent: 'reviewer', status: 'CASCADE_RUN_STATUS_RUNNING' },
  ]);
  const before = fs.readdirSync(root, { recursive: true }).sort();
  const env = envOf(home, NOW);
  assert.equal(await antigravity.detect(env), true);
  const r = await antigravity.scan(env, { cache: new Map() });
  assert.equal(r.sessions.length, 3);
  for (const s of r.sessions) assert.deepEqual(validateAdapterSession(s), { ok: true }, s.nativeId);
  const by = Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));
  assert.equal(by[A].title, 'Fix the parser'); assert.equal(by[A].titleSource, 'summary');
  assert.equal(path.resolve(by[A].projectPath), path.resolve(proj));
  assert.equal(deriveState(by[A].stateBasis, NOW).state, 'idle');
  assert.equal(by[A].model, null); assert.equal(by[A].tokens.total, null);
  assert.equal(by[B].title, 'Antigravity bbbbbbbb'); assert.equal(by[B].titleSource, 'fallback');
  assert.equal(by[B].projectLabel, 'unknown'); assert.equal(by[B].projectPath, null);
  assert.equal(by[B].stateBasis.kind, 'mtime');
  assert.equal(by[C].parentNativeId, A); assert.equal(by[C].depth, 1); assert.equal(by[C].agentType, 'reviewer');
  assert.equal(deriveState(by[C].stateBasis, NOW).state, 'unknown');
  assert.match(by[C].lastActivity.summary, /CASCADE_RUN_STATUS_RUNNING/);
  assert.ok(!JSON.stringify(r).includes('PREVIEW_MARKER'));
  // nothing written under the root
  assert.deepEqual(fs.readdirSync(root, { recursive: true }).sort(), before);
});

test('missing summaries DB: sessions still show, with a note', async () => {
  const home = mk(); const NOW = Date.now();
  convDb(path.join(home, 'agy'), A, NOW - 1000);
  const r = await antigravity.scan(envOf(home, NOW), { cache: new Map() });
  assert.equal(r.sessions.length, 1);
  assert.equal(r.sessions[0].title, 'Antigravity aaaaaaaa');
  assert.ok(r.notes.length === 1);
});

test('corrupt summaries DB does not break the scan', async () => {
  const home = mk(); const NOW = Date.now(); const root = path.join(home, 'agy');
  convDb(root, A, NOW - 1000);
  fs.writeFileSync(path.join(root, 'conversation_summaries.db'), 'not a database');
  const r = await antigravity.scan(envOf(home, NOW), { cache: new Map() });
  assert.equal(r.sessions.length, 1);
});

test('node:sqlite missing -> unavailable, no throw', async () => {
  const home = mk(); const NOW = Date.now();
  convDb(path.join(home, 'agy'), A, NOW - 1000);
  const ad = createAntigravityAdapter({ loadSqlite: () => Promise.reject(new Error('ERR_UNKNOWN_BUILTIN_MODULE')) });
  assert.equal(await ad.detect(envOf(home, NOW)), false);
  const r = await ad.scan(envOf(home, NOW), { cache: new Map() });
  assert.deepEqual(r.sessions, []);
  assert.match(r.notes[0], /unavailable/);
  assert.equal(ad.experimental, true);
});

test('watchPaths points at the conversations dir', () => {
  const env = envOf('/h');
  assert.equal(antigravity.watchPaths(env)[0].path, path.join('/h', 'agy', 'conversations'));
});
