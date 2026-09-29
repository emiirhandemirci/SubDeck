// desk/test/cursor.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import cursor, { createCursorAdapter } from '../adapters/cursor.mjs';
import { deriveState } from '../lib/model.mjs';
import { buildCursorFixture } from './fixtures/cursor-fixture.mjs';

function scenario() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-cur-'));
  const NOW = Date.now();
  const userDir = path.join(root, 'User');
  const alpha = path.join(root, 'work', 'Alpha');
  const multi = path.join(root, 'work', 'Multi');
  fs.mkdirSync(alpha, { recursive: true }); fs.mkdirSync(multi, { recursive: true });
  const H = (composerId, over = {}) => ({ composerId, workspaceId: 'ws1', createdAt: NOW - 3600000, recency: NOW - 1000, value: { type: 'head', unifiedMode: 'agent' }, ...over });
  const dbPath = buildCursorFixture(userDir, {
    headers: [
      H('c-run', { value: { type: 'head', unifiedMode: 'agent', name: 'Refactor parser', workspaceIdentifier: { id: 'ws1', uri: { fsPath: alpha, scheme: 'file' } } } }),
      H('c-done', { workspaceId: 'ws2', recency: NOW - 7200000 }),
      H('c-child', { isSubagent: 1, subagentTypeName: 'explore' }),
      H('c-empty', { workspaceId: '1790685321220', value: { type: 'head', unifiedMode: 'chat' }, recency: NOW - 600000 }),
      H('c-arch', { isArchived: 1, workspaceId: 'ws3', recency: NOW - 60000 }),
      H('c-bad'),
      H('c-old', { recency: NOW - 30 * 86400000 }),
    ],
    composers: {
      'c-run': { status: 'none', generatingBubbleIds: ['b2'], modelConfig: { modelName: 'gpt-5' }, subagentComposerIds: ['c-child'],
        contextTokensUsed: 12345, fullConversationHeadersOnly: [{ bubbleId: 'b1', type: 1, createdAt: new Date(NOW - 9000).toISOString() }, { bubbleId: 'b2', type: 2, startedAtMs: NOW - 2000 }] },
      'c-done': { status: 'completed', generatingBubbleIds: [], promptTokenBreakdown: { totalUsedTokens: 999 }, lastUpdatedAt: NOW - 7000000, fullConversationHeadersOnly: [] },
      'c-child': { status: 'none', generatingBubbleIds: [], fullConversationHeadersOnly: [{ bubbleId: 'x', type: 2, completedAtMs: NOW - 60000 }] },
      'c-empty': { status: 'none', generatingBubbleIds: [] },
      'c-arch': { status: 'none', generatingBubbleIds: [] },
      'c-bad': '{not json',
    },
    bubbles: { 'c-run:b2': { type: 2, toolFormerData: { name: 'read_file', status: 'running', params: 'BODY_MARKER', result: 'BODY_MARKER' } } },
    workspaces: {
      ws1: { folder: pathToFileURL(alpha).href },
      ws2: { folder: pathToFileURL(alpha).href },
      ws3: { workspace: pathToFileURL(path.join(multi, 'multi.code-workspace')).href },
    },
  });
  const env = { now: () => NOW, days: 14, platform: process.platform, cursorUserDir: userDir };
  return { root, NOW, env, dbPath, alpha, multi, userDir };
}

test('scan maps composers into sessions', async () => {
  const sc = scenario();
  assert.equal(await cursor.detect(sc.env), true);
  const r = await cursor.scan(sc.env, { since: null, cache: new Map() });
  const by = Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));
  assert.deepEqual(Object.keys(by).sort(), ['c-arch', 'c-child', 'c-done', 'c-empty', 'c-run']);
  const st = s => deriveState(s.stateBasis, sc.NOW);

  assert.equal(by['c-run'].projectPath, sc.alpha);
  assert.equal(by['c-run'].title, 'Refactor parser');
  assert.equal(by['c-run'].titleSource, 'explicit');
  assert.equal(by['c-run'].model, 'gpt-5');
  assert.equal(by['c-run'].tokens.context, 12345);
  assert.deepEqual(st(by['c-run']), { state: 'running', stateSource: 'field' });
  assert.deepEqual(by['c-run'].lastActivity, { at: new Date(sc.NOW - 2000).toISOString(), kind: 'tool', toolName: 'read_file', summary: null });
  assert.deepEqual(by['c-run'].refs, { file: null, db: sc.dbPath, key: 'composerData:c-run' });

  assert.equal(path.resolve(by['c-done'].projectPath), path.resolve(sc.alpha));      // via workspace.json folder URI
  assert.deepEqual(st(by['c-done']), { state: 'finished', stateSource: 'field' });
  assert.equal(by['c-done'].endedAt, by['c-done'].updatedAt);
  assert.equal(by['c-done'].tokens.context, 999);
  assert.equal(by['c-done'].title, 'Cursor agent c-done');
  assert.equal(by['c-done'].titleSource, 'fallback');

  assert.equal(by['c-child'].parentNativeId, 'c-run');
  assert.equal(by['c-child'].depth, 1);
  assert.equal(by['c-child'].agentType, 'explore');

  assert.equal(by['c-empty'].projectPath, null);
  assert.equal(by['c-empty'].projectLabel, 'Cursor (no folder)');
  assert.equal(by['c-empty'].agentType, 'chat');
  assert.equal(st(by['c-empty']).state, 'idle');                 // mtime basis on recency 10 min ago

  assert.equal(by['c-arch'].archived, true);
  assert.equal(path.resolve(by['c-arch'].projectPath), path.resolve(sc.multi));      // .code-workspace -> its folder
  assert.equal(r.skipped, 1);                                     // c-bad
});

test('no content or secret marker appears in output', async () => {
  const sc = scenario();
  const json = JSON.stringify(await cursor.scan(sc.env, { since: null, cache: new Map() }));
  assert.equal(json.includes('BODY_MARKER'), false);
  assert.equal(json.includes('KEY_MARKER'), false);
});

test('unchanged DB fingerprint returns the cached result', async () => {
  const sc = scenario();
  const cache = new Map();
  let opens = 0;
  const real = await import('node:sqlite');
  const a = createCursorAdapter({ loadSqlite: async () => ({ DatabaseSync: class extends real.DatabaseSync { constructor(...x) { opens++; super(...x); } } }) });
  const r1 = await a.scan(sc.env, { since: null, cache });
  const r2 = await a.scan(sc.env, { since: null, cache });
  assert.equal(opens, 1);
  assert.equal(r2, r1);
});

test('busy twice then succeeds; busy forever -> error', async () => {
  const sc = scenario();
  const real = await import('node:sqlite');
  const busy = () => Object.assign(new Error('database is locked'), { code: 'ERR_SQLITE_ERROR', errcode: 5 });
  let fails = 2;
  const flaky = createCursorAdapter({ sleep: async () => {}, loadSqlite: async () => ({ DatabaseSync: class extends real.DatabaseSync {
    constructor(...x) { if (fails-- > 0) throw busy(); super(...x); } } }) });
  assert.equal((await flaky.scan(sc.env, { since: null, cache: new Map() })).sessions.length, 5);
  const locked = createCursorAdapter({ sleep: async () => {}, loadSqlite: async () => ({ DatabaseSync: class { constructor() { throw busy(); } } }) });
  await assert.rejects(locked.scan(sc.env, { since: null, cache: new Map() }), /database is locked/);
});

test('missing node:sqlite -> clear error; detect false without DB', async () => {
  const sc = scenario();
  const none = createCursorAdapter({ loadSqlite: async () => { throw new Error('No such built-in module: node:sqlite'); } });
  await assert.rejects(none.scan(sc.env, { since: null, cache: new Map() }), /node:sqlite unavailable \(Node >= 22\.13 required\)/);
  assert.equal(await cursor.detect({ ...sc.env, cursorUserDir: path.join(sc.root, 'nope') }), false);
  assert.equal(await cursor.detect({ ...sc.env, cursorUserDir: null }), false);
  assert.deepEqual(cursor.watchPaths(sc.env), [{ path: path.join(sc.userDir, 'globalStorage'), recursive: false, filter: 'state.vscdb' }]);
});
