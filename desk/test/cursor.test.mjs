// desk/test/cursor.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import cursor, { createCursorAdapter } from '../adapters/cursor.mjs';
import { DatabaseSync } from 'node:sqlite';
import { deriveState, validateAdapterSession } from '../lib/model.mjs';
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

function scenario2(trackingRows) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-cur2-'));
  const NOW = Date.now();
  const userDir = path.join(root, 'User');
  const home = path.join(root, 'home');
  const H = (composerId, over = {}) => ({ composerId, workspaceId: 'ws1', createdAt: NOW - 3600000, recency: NOW - 1000, value: { type: 'head', unifiedMode: 'agent' }, ...over });
  buildCursorFixture(userDir, {
    headers: [
      H('s-stale', { recency: NOW - 20 * 60000 }),
      H('s-fresh'),
      H('s-nb', { recency: NOW - 3000000 }),
      H('s-nb2', { recency: NOW - 3000000 }),
      H('s-sub', { value: { type: 'head', unifiedMode: 'agent', subtitle: 'Editing a.js, b.js' } }),
      H('s-trk'),
      H('s-name', { value: { type: 'head', unifiedMode: 'agent', name: 'Header name', subtitle: 'ignored subtitle' } }),
      H('s-wait', { value: { type: 'head', unifiedMode: 'agent', hasBlockingPendingActions: true } }),
      H('s-nowait', { value: { type: 'head', unifiedMode: 'agent', hasBlockingPendingActions: false } }),
    ],
    composers: {
      's-stale': { status: 'none', generatingBubbleIds: ['g1'] },
      's-fresh': { status: 'none', generatingBubbleIds: ['g1'] },
      's-nb': { status: 'none', generatingBubbleIds: ['n2'], fullConversationHeadersOnly: [] },
      's-nb2': { status: 'none', generatingBubbleIds: [], fullConversationHeadersOnly: [] },
      's-sub': {}, 's-trk': {}, 's-name': {}, 's-wait': {}, 's-nowait': {},
    },
    bubbles: {
      's-nb:n1': { type: 1, createdAt: new Date(NOW - 50000).toISOString() },
      's-nb:n2': { type: 2, createdAt: new Date(NOW - 4000).toISOString(), toolFormerData: { name: 'grep_search', result: 'BODY_MARKER' } },
      's-nb:n0': { type: 2, createdAt: new Date(NOW - 90000).toISOString(), toolFormerData: { name: 'old_tool' } },
      's-nb2:m1': { type: 1, createdAt: NOW - 70000 },
      's-nb2x:z1': { type: 2, createdAt: new Date(NOW - 1000).toISOString(), toolFormerData: { name: 'other_composer' } },
    },
  });
  if (trackingRows) {
    const dir = path.join(home, '.cursor', 'ai-tracking');
    fs.mkdirSync(dir, { recursive: true });
    const db = new DatabaseSync(path.join(dir, 'ai-code-tracking.db'));
    db.exec('CREATE TABLE conversation_summaries (conversationId TEXT PRIMARY KEY, title TEXT, tldr TEXT, overview TEXT, summaryBullets TEXT, model TEXT, mode TEXT, updatedAt INTEGER NOT NULL)');
    const ins = db.prepare('INSERT INTO conversation_summaries VALUES (?,?,?,?,?,?,?,?)');
    for (const [id, title] of Object.entries(trackingRows)) ins.run(id, title, 'BODY_MARKER', null, null, null, null, NOW);
    db.close();
  }
  const env = { now: () => NOW, days: 14, platform: process.platform, cursorUserDir: userDir, home };
  return { NOW, env, root };
}
const scan2 = async (sc, adapter = cursor) => {
  const r = await adapter.scan(sc.env, { since: null, cache: new Map() });
  return Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));
};

test('generating counts as running only within the stale window', async () => {
  const sc = scenario2();
  const by = await scan2(sc);
  assert.deepEqual(deriveState(by['s-fresh'].stateBasis, sc.NOW), { state: 'running', stateSource: 'field' });
  const st = deriveState(by['s-stale'].stateBasis, sc.NOW);
  assert.equal(st.stateSource, 'mtime');
  assert.notEqual(st.state, 'running');
});

test('empty header list: last activity comes from the newest bubble row, no text read', async () => {
  const sc = scenario2();
  const by = await scan2(sc);
  assert.deepEqual(by['s-nb'].lastActivity, { at: new Date(sc.NOW - 4000).toISOString(), kind: 'tool', toolName: 'grep_search', summary: null });
  assert.equal(by['s-nb2'].lastActivity.kind, 'user');          // s-nb2x rows must not leak into s-nb2
  assert.equal(by['s-nb2'].lastActivity.at, new Date(sc.NOW - 70000).toISOString());
  assert.equal(by['s-sub'].lastActivity, null);                 // no bubbles at all
  assert.equal(JSON.stringify(by).includes('BODY_MARKER'), false);
});

test('titles: name, header name, subtitle, tracking summary, fallback (no prompt-derived titles)', async () => {
  const sc = scenario2({ 's-trk': 'Tracked summary title', 's-sub': 'Tracking title loses to subtitle', 's-name': 'ignored' });
  const by = await scan2(sc);
  assert.deepEqual([by['s-name'].title, by['s-name'].titleSource], ['Header name', 'explicit']);
  assert.deepEqual([by['s-sub'].title, by['s-sub'].titleSource], ['Editing a.js, b.js', 'summary']);
  assert.deepEqual([by['s-trk'].title, by['s-trk'].titleSource], ['Tracked summary title', 'summary']);
  assert.deepEqual([by['s-fresh'].title, by['s-fresh'].titleSource], ['Cursor agent s-fresh', 'fallback']);
  assert.equal(JSON.stringify(by).includes('BODY_MARKER'), false);
});

test('tracking DB is optional: missing, wrong schema and garbage all fall back', async () => {
  const sc = scenario2();
  assert.equal((await scan2(sc))['s-trk'].titleSource, 'fallback');
  const dir = path.join(sc.env.home, '.cursor', 'ai-tracking');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'ai-code-tracking.db'), 'not sqlite');
  assert.equal((await scan2(sc))['s-trk'].titleSource, 'fallback');
  const sc3 = scenario2();
  const d3 = path.join(sc3.env.home, '.cursor', 'ai-tracking'); fs.mkdirSync(d3, { recursive: true });
  const db = new DatabaseSync(path.join(d3, 'ai-code-tracking.db')); db.exec('CREATE TABLE other (x)'); db.close();
  assert.equal((await scan2(sc3))['s-trk'].titleSource, 'fallback');
});

test('hasBlockingPendingActions true maps to waiting (field)', async () => {
  const sc = scenario2();
  const by = await scan2(sc);
  assert.deepEqual(deriveState(by['s-wait'].stateBasis, sc.NOW), { state: 'waiting', stateSource: 'field' });
  assert.notEqual(deriveState(by['s-nowait'].stateBasis, sc.NOW).state, 'waiting');
  for (const s of Object.values(by)) assert.deepEqual(validateAdapterSession(s), { ok: true }, s.nativeId);
});
