// desk/test/claude-scan-perf.test.mjs
// A big synthetic Claude Code history scans well under the first-scan budget, never touches the sub-agents of sessions
// outside the window, reports progress per project and keeps the event loop responsive.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { tmpDir } from './fixtures/claude-fixture.mjs';

const touched = [];
for (const k of ['stat', 'readdir', 'open', 'readFile']) { const o = fsp[k]; fsp[k] = (p, ...a) => { touched.push([k, String(p)]); return o(p, ...a); }; }
const { default: claude, scanStats, mayHaveSpawned } = await import('../adapters/claude-code.mjs');
const { validateAdapterSession } = await import('../lib/model.mjs');

const NOW = Date.now(), DAY = 86400000;
const PROJECTS = 60, SESSIONS = 20, RECENT = 4, SUBS = 3;
const iso = ms => new Date(ms).toISOString();
const filler = 'x'.repeat(1500);
function transcript(cwd, t0, bytes, head = [], tail = []) {
  const lines = [JSON.stringify({ type: 'user', timestamp: iso(t0), cwd, message: { role: 'user', content: 'p' } }), ...head];
  const u = { input_tokens: 5, cache_creation_input_tokens: 100, cache_read_input_tokens: 50000, output_tokens: 300 };
  for (let i = 1, size = 0; size < bytes; i++) {
    const l = i % 2 ? JSON.stringify({ type: 'assistant', timestamp: iso(t0 + i * 1000), message: { role: 'assistant', model: 'claude-sonnet-4-5', content: [{ type: 'tool_use', id: 't' + i, name: 'Read', input: { file_path: '/a' } }], usage: u } })
      : JSON.stringify({ type: 'user', timestamp: iso(t0 + i * 1000), message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't' + (i - 1), content: filler }] } });
    lines.push(l); size += l.length + 1;
  }
  return [...lines, ...tail].join('\n') + '\n';
}
const setM = (f, ms) => fs.utimesSync(f, ms / 1000, ms / 1000);

const root = tmpDir('subdeck-perf-');
const projectsDir = path.join(root, '.claude', 'projects');
const oldUuids = [];
for (let p = 0; p < PROJECTS; p++) {
  const cwd = path.join(root, 'work', 'proj' + p);
  const slugDir = path.join(projectsDir, 'proj-' + p);
  fs.mkdirSync(slugDir, { recursive: true });
  for (let s = 0; s < SESSIONS; s++) {
    const uuid = `${String(p).padStart(4, '0')}${String(s).padStart(4, '0')}-0000-4000-8000-000000000000`;
    const recent = s < RECENT;
    const t0 = NOW - (recent ? (s + 1) * DAY / 2 : (20 + s * 10) * DAY);
    if (!recent) oldUuids.push(uuid);
    const ids = s % 2 === 0 ? Array.from({ length: SUBS }, (_, k) => `a${p}x${s}x${k}`) : [];
    const head = ids.map(id => JSON.stringify({ type: 'user', timestamp: iso(t0 + 500), toolUseResult: { isAsync: true, status: 'async_launched', agentId: id }, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't', content: '…' }] } }));
    const tail = ids.map(id => JSON.stringify({ type: 'queue-operation', operation: 'enqueue', timestamp: iso(t0 + 60000), content: `<task-notification>\n<task-id>${id}</task-id>\n<status>completed</status>\n</task-notification>` }));
    const file = path.join(slugDir, uuid + '.jsonl');
    fs.writeFileSync(file, transcript(cwd, t0, recent ? 300000 : 20000, head, tail));
    setM(file, t0 + 60000);
    if (!ids.length) continue;
    const subDir = path.join(slugDir, uuid, 'subagents');
    fs.mkdirSync(subDir, { recursive: true });
    for (const id of ids) {
      const f = path.join(subDir, `agent-${id}.jsonl`);
      fs.writeFileSync(f, transcript(cwd, t0 + 1000, recent ? 100000 : 10000));
      setM(f, t0 + 50000);
    }
  }
}
const env = { platform: process.platform, home: root, now: () => NOW, days: 14, claudeProjectsDir: projectsDir, vars: {} };

test('big history: first scan well under the budget; old sessions cost one stat; progress per project', async t => {
  let maxGap = 0, last = performance.now();
  const iv = setInterval(() => { const t = performance.now(); maxGap = Math.max(maxGap, t - last - 5); last = t; }, 5);
  const progress = [];
  let lastPartial = null;
  touched.length = 0;
  const t0 = performance.now();
  const r = await claude.scan(env, { since: null, cache: new Map(), partial: x => { progress.push(x.progress.projects); lastPartial = x; } });
  const ms = performance.now() - t0;
  clearInterval(iv);
  const recentWithSubs = Math.ceil(RECENT / 2);
  assert.equal(r.sessions.length, PROJECTS * (RECENT + recentWithSubs * SUBS));
  assert.ok(r.sessions.filter(s => s.depth === 1).every(s => s.endedAt), 'parent completion records were read (phase 2)');
  assert.ok(ms < 15000, `first scan took ${Math.round(ms)} ms (first-scan budget 60 s)`);
  assert.ok(scanStats.lastFirstPhaseMs <= scanStats.lastMs);
  // sessions outside the window: one stat each, their sub-agent folders are never listed or opened
  const oldHits = touched.filter(([, p]) => oldUuids.some(u => p.includes(u)));
  assert.equal(oldHits.length, oldUuids.length);
  assert.ok(oldHits.every(([k, p]) => k === 'stat' && p.endsWith('.jsonl')));
  // progress: monotonic, ends at all projects
  assert.ok(progress.length >= 2);
  assert.deepEqual(progress, [...progress].sort((a, b) => a - b));
  assert.equal(progress[progress.length - 1], PROJECTS);
  // the last partial result (end of phase 1) already lists every session, as valid adapter sessions
  assert.equal(lastPartial.sessions.length, r.sessions.length);
  assert.ok(lastPartial.sessions.every(x => validateAdapterSession(x).ok));
  assert.ok(maxGap < 1000, `event loop blocked for ${Math.round(maxGap)} ms`);
  t.diagnostic(`big history: ${PROJECTS} projects x ${SESSIONS} sessions, first scan ${Math.round(ms)} ms (phase 1 ${scanStats.lastFirstPhaseMs} ms), max event-loop gap ${Math.round(maxGap)} ms`);
});

test('rescan with a warm cache reads no transcript bytes', async () => {
  const cache = new Map();
  await claude.scan(env, { since: null, cache });
  touched.length = 0;
  const t0 = performance.now();
  const r = await claude.scan(env, { since: NOW, cache });
  const ms = performance.now() - t0;
  assert.ok(r.sessions.length > 0);
  assert.equal(touched.filter(([k]) => k === 'open').length, 0);
  assert.ok(ms < 5000, `rescan took ${Math.round(ms)} ms (rescan budget 5 s)`);
});

test('mayHaveSpawned: only sub-agents that started within the other one\'s lifetime', () => {
  const sub = (startIso, mtimeMs) => ({ tr: { createdAt: startIso }, st: { mtimeMs } });
  const T = Date.parse('2026-10-01T10:00:00Z');
  const p = sub(iso(T), T + 600000);
  assert.equal(mayHaveSpawned(p, sub(iso(T + 60000), 0)), true);
  assert.equal(mayHaveSpawned(p, sub(iso(T - 3600000), 0)), false);    // started before p
  assert.equal(mayHaveSpawned(p, sub(iso(T + 3600000), 0)), false);    // started after p's last write
  assert.equal(mayHaveSpawned(p, sub(null, 0)), true);                  // unknown start never rules it out
});

test.after(() => fs.rmSync(root, { recursive: true, force: true }));
