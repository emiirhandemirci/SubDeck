// desk/test/crosscheck.test.mjs
// Same fixtures through status.sh (bash+awk) and the Desk Claude adapter must agree on state, title, tokens.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import claude from '../adapters/claude-code.mjs';
import { deriveState } from '../lib/model.mjs';
import { rec, usage, writeJsonl, writeMeta, tmpDir } from './fixtures/claude-fixture.mjs';

const STATUS = fileURLToPath(new URL('../../plugins/subdeck/scripts/status.sh', import.meta.url));
const hasBash = spawnSync('bash', ['-c', 'exit 0']).status === 0;
const fmt = n => (n === null ? '-' : n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n));
const clip30 = s => (Array.from(s).length > 30 ? Array.from(s).slice(0, 27).join('') + '...' : s);
const MAP = { running: 'running', stale: 'stale?', finished: 'done' };

test('Desk and status.sh agree on state, title and tokens', { skip: hasBash ? false : 'bash not on PATH' }, async () => {
  const root = tmpDir('desk-x-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const proj = path.join(root, 'proj');
  fs.mkdirSync(path.join(proj, '.subdeck'), { recursive: true });
  const projects = path.join(root, 'claude', 'projects');
  const parent = path.join(projects, 'slug', 'sid1.jsonl');
  writeJsonl(parent, [rec.user(ago(600000), proj), rec.aiTitle('Cross check')], { mtimeMs: NOW - 1000 });
  const sub = path.join(projects, 'slug', 'sid1', 'subagents');
  const f = id => path.join(sub, `agent-${id}.jsonl`);
  writeJsonl(f('x1x1x1x1'), [rec.tool(ago(5000), 'Edit', { file_path: '/a' }, usage(10, 100, 79000, 390))], { mtimeMs: NOW - 5000 });
  writeMeta(f('x1x1x1x1'), { agentType: 'worker-sonnet', description: 'Türkçe başlık: şğıİöüç uzun bir açıklama metni burada' });
  writeJsonl(f('x2x2x2x2'), [rec.text(ago(9000), 'b', usage(1, 0, 1100000, 1))], { mtimeMs: NOW - 7200000 });
  writeMeta(f('x2x2x2x2'), { agentType: 'researcher', description: 'Short title' });
  writeJsonl(f('x3x3x3x3'), [rec.text(ago(9000), 'c', usage(100, 0, 0, 23))], { mtimeMs: NOW - 60000 });
  writeMeta(f('x3x3x3x3'), { agentType: 'verifier', description: 'Done agent' });
  const ev = (ts, event, id, type) => JSON.stringify({ ts, event, agent_id: id, agent_type: type, transcript_path: parent, session_id: 'sid1', payload: { agent_id: id } });
  fs.writeFileSync(path.join(proj, '.subdeck', 'events.jsonl'), [
    ev(ago(60000), 'SubagentStart', 'x1x1x1x1', 'worker-sonnet'),
    ev(ago(7300000), 'SubagentStart', 'x2x2x2x2', 'researcher'),
    ev(ago(120000), 'SubagentStart', 'x3x3x3x3', 'verifier'),
    ev(ago(60000), 'SubagentStop', 'x3x3x3x3', 'verifier'),
  ].join('\n') + '\n');

  const out = spawnSync('bash', [STATUS, '--all', proj], { encoding: 'utf8', env: { ...process.env, TZ: 'UTC', COLUMNS: '200' } }).stdout;
  const rows = {};
  for (const line of out.split('\n')) {
    const m = /^(\S{8})  (.{30})  (.{16})  (\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/u.exec(line);
    if (m && m[1] !== 'AGENT') rows[m[1]] = { title: m[2].trimEnd(), tokens: m[6], state: m[7], model: m[8] };
  }
  const r = await claude.scan({ now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: projects }, { since: null, cache: new Map() });
  for (const s of r.sessions.filter(x => x.depth === 1)) {
    const row = rows[s.nativeId.slice(0, 8)];
    assert.ok(row, `status.sh row for ${s.nativeId}`);
    assert.equal(row.state, MAP[deriveState(s.stateBasis, NOW).state], `state ${s.nativeId}`);
    assert.equal(row.title, clip30(s.title), `title ${s.nativeId}`);
    assert.equal(row.tokens, fmt(s.tokens.context), `tokens ${s.nativeId}`);
    assert.equal(row.model, s.model || '-', `model ${s.nativeId}`);
  }
  assert.equal(Object.keys(rows).length, 3);
});

test('Desk and status.sh agree on explicit failure (API error, failed/error completion in the parent)', { skip: hasBash ? false : 'bash not on PATH' }, async () => {
  const root = tmpDir('desk-xf-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const proj = path.join(root, 'proj');
  fs.mkdirSync(path.join(proj, '.subdeck'), { recursive: true });
  const projects = path.join(root, 'claude', 'projects');
  const parent = path.join(projects, 'slug', 'sidf.jsonl');
  const sub = path.join(projects, 'slug', 'sidf', 'subagents');
  const f = id => path.join(sub, `agent-${id}.jsonl`);
  const mk = (id, records) => { writeJsonl(f(id), records, { mtimeMs: NOW - 20000 }); writeMeta(f(id), { agentType: 'worker-sonnet', description: 'agent ' + id }); };
  const run = [rec.user(ago(300000), proj), rec.tool(ago(290000), 'Edit', { file_path: '/a' }, usage(1, 0, 10, 1))];
  mk('f1f1f1f1', [...run, rec.apiError(ago(100000))]);                               // own API error
  mk('f2f2f2f2', run);                                                                // failed attachment notification
  mk('f3f3f3f3', run);                                                                // error queue notification
  mk('f4f4f4f4', run);                                                                // failed foreground result
  mk('f5f5f5f5', run);                                                                // completed notification: not failed
  mk('f6f6f6f6', [...run, rec.apiError(ago(100000))]);                                // API error AND a Stop hook: still failed
  mk('f7f7f7f7', [...run, rec.endTurn(ago(250000)), rec.user(ago(120000), proj, 'again')]);   // failure older than the resumed run
  mk('f9f9f9f9', [...run, rec.endTurn(ago(100000))]);                               // stopped and fine: finished
  mk('f8f8f8f8', run);                                                                // plain running
  writeJsonl(parent, [rec.user(ago(600000), proj), rec.aiTitle('Failure check'),
    rec.notifyAttachment(ago(90000), 'f2f2f2f2', 'failed', 1000),
    rec.notifyQueue(ago(80000), 'f3f3f3f3', 'error', null),
    rec.foregroundResult(ago(70000), 'f4f4f4f4', 'failed', 5000),
    rec.notifyUser(ago(60000), 'f5f5f5f5', 'completed', 1000),
    rec.notifyAttachment(ago(200000), 'f7f7f7f7', 'failed', 1000)], { mtimeMs: NOW - 1000 });
  const ev = (ts, event, id) => JSON.stringify({ ts, event, agent_id: id, agent_type: 'worker-sonnet', transcript_path: parent, session_id: 'sidf', payload: { agent_id: id } });
  const ids = ['f1f1f1f1', 'f2f2f2f2', 'f3f3f3f3', 'f4f4f4f4', 'f5f5f5f5', 'f6f6f6f6', 'f7f7f7f7', 'f8f8f8f8', 'f9f9f9f9'];
  fs.writeFileSync(path.join(proj, '.subdeck', 'events.jsonl'), [
    ...ids.map(id => ev(ago(300000), 'SubagentStart', id)), ev(ago(90000), 'SubagentStop', 'f6f6f6f6'), ev(ago(90000), 'SubagentStop', 'f9f9f9f9')].join('\n') + '\n');

  const env = { ...process.env, TZ: 'UTC', COLUMNS: '200' };
  const out = spawnSync('bash', [STATUS, '--all', proj], { encoding: 'utf8', env }).stdout;
  const rows = {};
  for (const line of out.split('\n')) {
    const m = /^(\S{8})  (.{30})  (.{16})  (\S+)\s+(\S+)\s+(\S+)\s+(\S+)/u.exec(line);
    if (m && m[1] !== 'AGENT') rows[m[1]] = m[7];
  }
  const r = await claude.scan({ now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: projects }, { since: null, cache: new Map() });
  const desk = {};
  for (const s of r.sessions.filter(x => x.depth === 1)) desk[s.nativeId.slice(0, 8)] = deriveState(s.stateBasis, NOW).state;
  const expectFailed = new Set(['f1f1f1f1', 'f2f2f2f2', 'f3f3f3f3', 'f4f4f4f4', 'f6f6f6f6']);
  for (const id of ids) {
    assert.equal(desk[id] === 'failed', expectFailed.has(id), `desk failed ${id} (${desk[id]})`);
    assert.equal(rows[id] === 'failed', expectFailed.has(id), `status.sh failed ${id} (${rows[id]})`);
  }
  const counts = spawnSync('bash', [STATUS, '--counts', proj], { encoding: 'utf8', env }).stdout.trim();
  assert.match(counts, /failed=5 /);
});
