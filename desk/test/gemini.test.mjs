// desk/test/gemini.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import gemini from '../adapters/gemini.mjs';
import { validateAdapterSession, deriveState } from '../lib/model.mjs';
import { msg, geminiMsg, writeJsonl, writeJson, setMtime, chatsDir } from './fixtures/gemini-fixture.mjs';

const mk = () => fs.mkdtempSync(path.join(os.tmpdir(), 'desk-gm-'));
const envOf = (home, NOW = Date.now()) => ({ home, platform: process.platform, vars: {}, now: () => NOW, days: 14 });

test('detect false without data and for Antigravity-only ~/.gemini', async () => {
  const home = mk();
  assert.equal(await gemini.detect(envOf(home)), false);
  fs.mkdirSync(path.join(home, '.gemini', 'antigravity', 'conversations'), { recursive: true });
  fs.writeFileSync(path.join(home, '.gemini', 'GEMINI.md'), 'x');
  assert.equal(await gemini.detect(envOf(home)), false);
  const r = await gemini.scan(envOf(home), { since: null, cache: new Map() });
  assert.deepEqual(r.sessions, []);
});

test('scan: jsonl upserts, $set, $rewindTo, legacy json, sub-agent, malformed, no leakage', async () => {
  const home = mk(); const NOW = Date.now();
  const proj = path.join(home, 'work', 'Alpha');
  const hashA = 'a'.repeat(64);
  const cA = chatsDir(home, hashA);
  const fA = path.join(cA, 'session-2026-09-30T10-00-abcd1234.jsonl');
  writeJsonl(fA, [
    { sessionId: 'sess-a', projectHash: hashA, startTime: new Date(NOW - 3600000).toISOString(), lastUpdated: new Date(NOW - 3000000).toISOString(), kind: 'main', directories: [proj] },
    msg('m1', 'user', NOW - 3500000),
    geminiMsg('m2', NOW - 3400000, { toolCalls: [{ id: 't', name: 'read_file', input: { p: 'BODY_MARKER' }, result: 'BODY_MARKER' }] }),
    msg('m3', 'user', NOW - 3300000),
    geminiMsg('m3b', NOW - 3200000),
    { $rewindTo: 'm3' },
    geminiMsg('m2', NOW - 3400000, { toolCalls: [{ id: 't', name: 'read_file', input: 'BODY_MARKER', result: 'BODY_MARKER' }], tokens: { input: 2000, total: 2100 } }),
    { $set: { lastUpdated: new Date(NOW - 1000).toISOString(), summary: 'Fix the parser' } },
    '{broken line',
    geminiMsg('m4', NOW - 1000, { tokens: { input: 3000, total: 3100 } }),
  ]);
  setMtime(fA, NOW - 1000);
  const fSub = path.join(cA, 'sess-a', 'sub-1.jsonl');
  writeJsonl(fSub, [{ sessionId: 'sub-1', projectHash: hashA, startTime: new Date(NOW - 900000).toISOString(), kind: 'subagent', directories: [proj] }, msg('s1', 'user', NOW - 900000)]);
  setMtime(fSub, NOW - 900000);
  // legacy json; path recovered via sha256 of a projects.json entry; older
  const other = path.join(home, 'work', 'Beta');
  const hashB = createHash('sha256').update(other).digest('hex');
  const fB = path.join(chatsDir(home, hashB), 'session-2026-09-01-ffff.json');
  writeJson(fB, { sessionId: 'sess-b', projectHash: hashB, startTime: new Date(NOW - 7200000).toISOString(), lastUpdated: new Date(NOW - 7000000).toISOString(), messages: [msg('b1', 'user', NOW - 7100000), geminiMsg('b2', NOW - 7000000)] });
  setMtime(fB, NOW - 7000000);
  writeJson(path.join(home, '.gemini', 'projects.json'), { projects: { [other]: 'beta' } });
  // unresolvable project
  const fC = path.join(chatsDir(home, 'c'.repeat(64)), 'session-x.jsonl');
  writeJsonl(fC, [{ sessionId: 'sess-c', startTime: new Date(NOW - 100000).toISOString() }, msg('c1', 'user', NOW - 90000)]);
  setMtime(fC, NOW - 90000);
  // fully malformed, and too old
  fs.writeFileSync(path.join(chatsDir(home, hashA), 'session-bad.jsonl'), 'nope\nnope\n');
  const fE = path.join(chatsDir(home, hashA), 'session-old.jsonl');
  writeJsonl(fE, [{ sessionId: 'sess-old', startTime: new Date(NOW - 30 * 86400000).toISOString() }]); setMtime(fE, NOW - 30 * 86400000);

  const env = envOf(home, NOW);
  assert.equal(await gemini.detect(env), true);
  const r = await gemini.scan(env, { since: null, cache: new Map() });
  const by = Object.fromEntries(r.sessions.map(s => [s.nativeId, s]));
  assert.deepEqual(Object.keys(by).sort(), ['sess-a', 'sess-b', 'sess-c', 'sub-1']);
  for (const s of r.sessions) assert.deepEqual(validateAdapterSession(s), { ok: true });
  assert.ok(r.skipped >= 3);

  const a = by['sess-a'];
  assert.equal(a.projectPath, proj);
  assert.equal(a.title, 'Fix the parser'); assert.equal(a.titleSource, 'summary');
  assert.equal(a.model, 'gemini-2.5-pro');
  assert.equal(a.tokens.context, 3000);
  assert.equal(a.tokens.total, 3100 + 2100);   // m3/m3b rewound away, m2 upserted
  assert.equal(a.lastActivity.kind, 'assistant');
  assert.equal(deriveState(a.stateBasis, NOW).state, 'running');
  assert.equal(by['sub-1'].parentNativeId, 'sess-a'); assert.equal(by['sub-1'].depth, 1);
  assert.equal(by['sess-b'].projectPath, other);
  assert.equal(by['sess-b'].titleSource, 'fallback');
  assert.equal(deriveState(by['sess-b'].stateBasis, NOW).state, 'finished');
  assert.equal(by['sess-c'].projectPath, null);
  assert.ok(by['sess-c'].projectLabel.startsWith('cccc'));
  assert.equal(JSON.stringify(r).includes('BODY_MARKER'), false);
  assert.equal(gemini.timeline, undefined);

  const cache = new Map();
  await gemini.scan(env, { cache }); assert.ok(cache.size >= 4);
});

test('metadata identity and watchPaths', () => {
  assert.equal(gemini.tool, 'gemini'); assert.equal(gemini.toolShort, 'gm'); assert.equal(gemini.label, 'Gemini');
  assert.equal(gemini.experimental, true);
  const w = gemini.watchPaths(envOf('/h'));
  assert.ok(w[0].path.includes('tmp') && w[0].recursive);
});

test('scan never throws', async () => {
  const r = await gemini.scan({ home: null, platform: 'linux', now: Date.now, days: 14 }, { cache: new Map() });
  assert.ok(Array.isArray(r.sessions));
});
