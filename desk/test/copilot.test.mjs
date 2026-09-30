// desk/test/copilot.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import copilot, { createCopilotAdapter, parseFlatYaml, vscodeUserDirs } from '../adapters/copilot.mjs';
import { deriveState, validateAdapterSession } from '../lib/model.mjs';
import { buildCopilotFixture, ev, BODY } from './fixtures/copilot-fixture.mjs';

const DEAD_PID = 999999991;
function envFor(root, NOW) {
  return { home: root, platform: process.platform, vars: { APPDATA: path.join(root, 'AppData', 'Roaming') }, now: () => NOW, days: 14 };
}

function scenario() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-gh-'));
  const NOW = Date.now();
  const env = envFor(root, NOW);
  const proj = path.join(root, 'work', 'Alpha');
  fs.mkdirSync(proj, { recursive: true });
  const t = ms => NOW - ms;
  const start = (ms, extra = {}) => ev('session.start', t(ms), { sessionId: 'x', version: 1, context: { cwd: proj }, ...extra });
  const fx = buildCopilotFixture(env, {
    cli: {
      'live-1': { locks: [process.pid], yaml: `id: live-1\ncwd: ${proj}\nsummary: Fix the parser\ncreated_at: ${new Date(t(600000)).toISOString()}\n`,
        events: [start(600000, { selectedModel: 'gpt-5' }), ev('user.message', t(500000), { content: BODY }), ev('assistant.turn_start', t(400000)),
          ev('subagent.started', t(300000), { toolCallId: 'tc1', agentName: 'explore', agentDisplayName: 'Explore agent' }),
          ev('subagent.completed', t(200000), { toolCallId: 'tc1', agentName: 'explore' }),
          ev('subagent.started', t(100000), { toolCallId: 'tc2', agentName: 'general-purpose' }),
          ev('tool.execution_start', t(5000), { toolCallId: 'x', toolName: 'view', arguments: { path: BODY } }),
          ev('session.compaction_complete', t(4000), { preCompactionTokens: 90000, postCompactionTokens: 12000 })] },
      'idle-1': { locks: [process.pid], events: [start(3600000), ev('assistant.turn_start', t(3500000)), ev('assistant.turn_end', t(3400000)), ev('assistant.message', t(3400000), { content: BODY })] },
      'done-1': { yaml: `id: done-1\ncwd: ${proj}\n`, events: [start(7200000), ev('assistant.message', t(7100000), { content: BODY }),
        ev('session.shutdown', t(7000000), { shutdownType: 'routine', currentModel: 'claude-sonnet', modelMetrics: { m: { usage: { inputTokens: 100, outputTokens: 50 } } } })] },
      'fail-1': { events: [ev('session.start', t(8000000), { sessionId: 'x' }), ev('session.shutdown', t(7900000), { shutdownType: 'error' })] },
      'crash-1': { locks: [DEAD_PID], events: [start(20 * 60000), ev('tool.execution_start', t(20 * 60000), { toolName: 'bash' })] },
      'bad-1': { events: 'not json\n{"nothing":1}\n' },
      'empty-1': {},
      'old-1': { events: [start(30 * 86400000)] },
      'mal-line': { events: [start(60000), '{broken', ev('assistant.message', t(50000), { content: BODY })] },
    },
    chat: {
      h1: { folder: pathToFileURL(proj).href, files: {
        'aaa.jsonl': [JSON.stringify({ kind: 0, v: { version: 3, creationDate: NOW - 90000, sessionId: 'aaa', requests: [{ timestamp: NOW - 80000, modelId: 'copilot/gpt-5', message: { text: BODY } }], pendingRequests: [] } }),
          JSON.stringify({ kind: 1, k: ['customTitle'], v: 'Chat about tests' }),
          JSON.stringify({ kind: 2, k: ['requests'], v: [{ timestamp: NOW - 20000, message: { text: BODY } }] }), 'garbage'],
        'bbb.jsonl': [JSON.stringify({ kind: 0, v: { creationDate: NOW - 5000, sessionId: 'bbb', requests: [] } })],
        'ccc.jsonl': 'not json at all\n' } },
      h2: { files: { 'ddd.jsonl': [JSON.stringify({ kind: 0, v: { sessionId: 'ddd', requests: [] } })], 'old.jsonl': [JSON.stringify({ kind: 0, v: { sessionId: 'old', requests: [] } })] },
        mtimeMs: { 'old.jsonl': NOW - 40 * 86400000 } },
    },
  });
  return { root, NOW, env, proj, fx };
}

const run = async (sc, adapter = copilot) => {
  const r = await adapter.scan(sc.env, { since: null, cache: new Map() });
  return { r, by: Object.fromEntries(r.sessions.map(s => [s.nativeId, s])) };
};

test('detect: false without data, true with session-state or chatSessions', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-gh-none-'));
  const env = envFor(root, Date.now());
  assert.equal(await copilot.detect(env), false);
  fs.mkdirSync(path.join(root, '.copilot', 'logs'), { recursive: true });
  assert.equal(await copilot.detect(env), false);            // logs only, like a CLI dir without sessions
  fs.mkdirSync(path.join(root, '.copilot', 'session-state'));
  assert.equal(await copilot.detect(env), true);
  const sc = scenario();
  fs.rmSync(sc.fx.stateDir, { recursive: true });
  assert.equal(await copilot.detect(sc.env), true);          // chat only
  assert.equal(copilot.tool, 'copilot'); assert.equal(copilot.toolShort, 'gh'); assert.equal(copilot.label, 'Copilot');
  assert.equal(copilot.experimental, true); assert.equal(copilot.timeline, undefined);
});

test('CLI: mapping, sub-agents, tokens, states', async () => {
  const sc = scenario();
  const { r, by } = await run(sc);
  const st = s => deriveState(s.stateBasis, sc.NOW);
  for (const s of r.sessions) assert.deepEqual(validateAdapterSession(s), { ok: true }, s.nativeId);

  const live = by['live-1'];
  assert.equal(live.projectPath, sc.proj);
  assert.equal(live.title, 'Fix the parser'); assert.equal(live.titleSource, 'summary');
  assert.equal(live.model, 'gpt-5');
  assert.equal(live.tokens.context, 12000);
  assert.deepEqual(st(live), { state: 'running', stateSource: 'lock' });         // live lock + open turn
  assert.deepEqual(live.lastActivity, { at: new Date(sc.NOW - 5000).toISOString(), kind: 'tool', toolName: 'view', summary: 'view' });
  assert.equal(live.refs.file, path.join(sc.fx.stateDir, 'live-1', 'events.jsonl'));

  const c1 = by['live-1#tc1'], c2 = by['live-1#tc2'];
  assert.equal(c1.parentNativeId, 'live-1'); assert.equal(c1.depth, 1);
  assert.equal(c1.title, 'Explore agent'); assert.equal(c1.agentType, 'explore');
  assert.deepEqual(st(c1), { state: 'finished', stateSource: 'field' });
  assert.equal(c1.endedAt, new Date(sc.NOW - 200000).toISOString());
  assert.deepEqual(st(c2), { state: 'running', stateSource: 'lock' });
  assert.equal(c2.agentType, 'general-purpose');

  assert.deepEqual(st(by['idle-1']), { state: 'idle', stateSource: 'lock' });    // lock alive, quiet > 30 min
  assert.equal(by['idle-1'].title, 'Copilot CLI idle-1'); assert.equal(by['idle-1'].titleSource, 'fallback');
  assert.deepEqual(st(by['done-1']), { state: 'finished', stateSource: 'field' });
  assert.equal(by['done-1'].endedAt, new Date(sc.NOW - 7000000).toISOString());
  assert.equal(by['done-1'].tokens.total, 150); assert.equal(by['done-1'].model, 'claude-sonnet');
  assert.equal(st(by['fail-1']).state, 'failed');
  assert.equal(by['fail-1'].projectPath, null); assert.equal(by['fail-1'].projectLabel, 'Copilot CLI (no folder)');
  assert.deepEqual(st(by['crash-1']), { state: 'idle', stateSource: 'mtime' });   // dead lock PID -> mtime basis, not running
  assert.equal(by['mal-line'].lastActivity.kind, 'assistant');                    // bad line in the middle ignored
  assert.equal(by['old-1'], undefined);                                           // outside the window
  assert.equal(by['bad-1'], undefined); assert.equal(by['empty-1'], undefined);
});

test('Chat: title, request count, workspace mapping, skipped', async () => {
  const sc = scenario();
  const { r, by } = await run(sc);
  const a = by['vsc-aaa'];
  assert.equal(a.title, 'Chat about tests'); assert.equal(a.titleSource, 'explicit');
  assert.equal(a.projectPath, sc.proj);
  assert.equal(a.lastActivity.summary, '2 requests');
  assert.equal(a.model, 'copilot/gpt-5');
  assert.equal(a.createdAt, new Date(sc.NOW - 90000).toISOString());
  assert.equal(a.agentType, 'vscode-chat');
  assert.equal(deriveState(a.stateBasis, Date.now()).stateSource, 'mtime');
  assert.equal(by['vsc-bbb'].lastActivity, null);
  assert.equal(by['vsc-bbb'].title, 'Copilot Chat bbb');
  assert.equal(by['vsc-ddd'].projectLabel, 'Copilot Chat (no folder)');
  assert.equal(by['vsc-old'], undefined);
  assert.equal(by['vsc-ccc'], undefined);
  assert.equal(r.skipped, 3);                          // bad-1, empty-1, ccc
  for (const s of r.sessions) assert.deepEqual(validateAdapterSession(s), { ok: true }, s.nativeId);
});

test('no message body appears in output', async () => {
  const sc = scenario();
  const json = JSON.stringify((await run(sc)).r);
  assert.equal(json.includes(BODY), false);
});

test('watchPaths; appended events are read incrementally, partial line waits', async () => {
  const sc = scenario();
  const cache = new Map();
  const r1 = await copilot.scan(sc.env, { since: null, cache });
  const wp = copilot.watchPaths(sc.env, r1);
  assert.deepEqual(wp[0], { path: sc.fx.stateDir, recursive: true });
  assert.equal(wp.length, 3);                                   // two chatSessions dirs
  const f = path.join(sc.fx.stateDir, 'done-1', 'events.jsonl');
  fs.appendFileSync(f, ev('session.resume', sc.NOW - 1000, { context: { cwd: sc.proj } }) + '\n{"type":"assistant.mess');
  const r2 = await copilot.scan(sc.env, { since: null, cache });
  const d = r2.sessions.find(s => s.nativeId === 'done-1');
  assert.equal(d.endedAt, null);                                // resumed: shutdown cleared
  assert.equal(r2.skipped, r1.skipped);                         // partial trailing line is not malformed
});

test('lock liveness is injectable; exceptions never escape scan', async () => {
  const sc = scenario();
  const { by } = await run(sc, createCopilotAdapter({ isAlive: () => false }));
  assert.equal(deriveState(by['live-1'].stateBasis, sc.NOW).stateSource, 'mtime');
  const broken = await copilot.scan({ ...sc.env, home: path.join(sc.root, 'nope'), vars: {} }, { since: null, cache: new Map() });
  assert.deepEqual(broken.sessions, []);
});

test('platform paths and flat yaml', () => {
  assert.equal(parseFlatYaml('a: "x y"\nb: |\n  body\nc: 3\nsummary:  \n').a, 'x y');
  assert.deepEqual(Object.keys(parseFlatYaml('a: 1\nb: |\n  text\n')), ['a']);
  const h = '/home/u';
  assert.deepEqual(vscodeUserDirs({ home: h, platform: 'linux', vars: {} }), ['/home/u/.config/Code/User', '/home/u/.config/Code - Insiders/User']);
  assert.equal(vscodeUserDirs({ home: h, platform: 'darwin', vars: {} })[1], '/home/u/Library/Application Support/Code - Insiders/User');
  assert.equal(vscodeUserDirs({ home: 'C:\\Users\\u', platform: 'win32', vars: { APPDATA: 'C:\\Users\\u\\AppData\\Roaming' } })[0], 'C:\\Users\\u\\AppData\\Roaming\\Code\\User');
});
