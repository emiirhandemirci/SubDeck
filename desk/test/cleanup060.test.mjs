// desk/test/cleanup060.test.mjs: phantom agents, home-folder project name, temp-dir projects (synthetic fixtures only)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import claude from '../adapters/claude-code.mjs';
import { createCore } from '../lib/core.mjs';
import { resolveEnv, isInside } from '../lib/paths.mjs';
import { filterProjects } from '../public/format.js';
import { rec, writeJsonl, tmpDir } from './fixtures/claude-fixture.mjs';

test('claude-code: Stop-only hook events with no type, no start and no transcript are not agents', async () => {
  const root = tmpDir('desk-ph-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString();
  const proj = path.join(root, 'work', 'Phantom');
  fs.mkdirSync(path.join(proj, '.subdeck'), { recursive: true });
  const dir = path.join(root, 'claude', 'projects', 'slug-p');
  const parent = path.join(dir, 'sess-p.jsonl');
  writeJsonl(parent, [rec.user(ago(3600000), proj)], { mtimeMs: NOW - 1000 });
  writeJsonl(path.join(dir, 'sess-p', 'subagents', 'agent-real0000.jsonl'), [rec.user(ago(60000), proj), rec.endTurn(ago(50000))], { mtimeMs: NOW - 50000 });
  const ev = (ts, event, id, type) => JSON.stringify({ ts, event, agent_id: id, agent_type: type, session_id: 'sess-p', transcript_path: parent });
  fs.writeFileSync(path.join(proj, '.subdeck', 'events.jsonl'), [
    ev(ago(40000), 'SubagentStop', 'ghost001', ''), ev(ago(39000), 'SubagentStop', 'ghost002', ''),
    ev(ago(38000), 'SubagentStop', 'real0000', ''),                       // transcript exists: kept even with no Start and no type
    ev(ago(37000), 'SubagentStop', 'typed000', 'worker-sonnet'),          // typed Stop-only: kept
    ev(ago(36000), 'SubagentStart', 'start000', ''),                      // Start only: kept
  ].join('\n') + '\n');
  const env = { now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: path.join(root, 'claude', 'projects') };
  const r = await claude.scan(env, { since: null, cache: new Map() });
  const ids = r.sessions.map(s => s.nativeId).sort();
  assert.deepEqual(ids, ['real0000', 'sess-p', 'start000', 'typed000']);
});

function adapter(sessions) {
  return { tool: 'fake', label: 'fake', toolShort: 'fake', adapterVersion: '1', async detect() { return true; }, watchPaths() { return []; },
    async scan() { return { sessions, skipped: 0, notes: [] }; } };
}
const sess = (projectPath, nativeId) => ({ nativeId, tool: 'fake', parentNativeId: null, depth: 0, projectPath, projectLabel: null,
  title: 'T', titleSource: 'summary', agentType: null, model: null, createdAt: '2026-09-29T10:00:00Z', updatedAt: '2026-09-29T11:00:00Z', endedAt: null,
  tokens: { context: 1, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false,
  stateBasis: { kind: 'mtime', at: '2026-09-29T11:00:00Z', stateSource: 'mtime' } });

test('home folder project is named "~", never the home folder name; subfolders keep their names', async () => {
  for (const [platform, home, other, sub] of [
    ['win32', 'C:\\Users\\Someone', 'c:/users/someone/', 'C:\\Users\\Someone\\proj'],
    ['linux', '/home/someone', '/home/someone', '/home/someone/proj'],
  ]) {
    const env = { ...resolveEnv({}, platform, home), disabled: [] };
    const core = createCore({ env, adapters: [adapter([sess(home, 'a'), sess(other, 'b'), sess(sub, 'c')])] });
    await core.scanAll();
    const ps = core.snapshot().projects;
    assert.equal(ps.length, 2, platform);
    assert.ok(ps.some(p => p.name === '~'), platform);
    assert.ok(ps.some(p => p.name === 'proj'), platform);
    assert.ok(!ps.some(p => p.name.toLowerCase() === 'someone'), platform);
  }
});

test('projects inside the temp dir are flagged temporary (win32, linux, TMPDIR, darwin)', async () => {
  const w = { ...resolveEnv({}, 'win32', 'C:\\Users\\Someone'), disabled: [] };
  const l = { ...resolveEnv({ TMPDIR: '/scratch/t' }, 'linux', '/home/someone'), disabled: [] };
  const d = { ...resolveEnv({}, 'darwin', '/Users/someone'), disabled: [] };
  const run = async (env, paths) => {
    const core = createCore({ env, adapters: [adapter(paths.map((p, i) => sess(p, 'n' + i)))] });
    await core.scanAll();
    return Object.fromEntries(core.snapshot().projects.map(p => [p.path, p.temporary]));
  };
  assert.deepEqual(await run(w, ['C:\\Users\\Someone\\AppData\\Local\\Temp\\x1', 'c:/users/someone/AppData/Local/Temp', 'C:\\Users\\Someone\\proj', 'C:\\Users\\Someone\\AppData\\Local\\Tempo']),
    { 'C:\\Users\\Someone\\AppData\\Local\\Temp\\x1': true, 'c:/users/someone/AppData/Local/Temp': true, 'C:\\Users\\Someone\\proj': false, 'C:\\Users\\Someone\\AppData\\Local\\Tempo': false });
  assert.deepEqual(await run(l, ['/tmp/a', '/scratch/t/b', '/home/someone/proj', '/tmpx/c']), { '/tmp/a': true, '/scratch/t/b': true, '/home/someone/proj': false, '/tmpx/c': false });
  assert.deepEqual(await run(d, ['/private/var/folders/ab/T/x', '/Users/someone/proj']), { '/private/var/folders/ab/T/x': true, '/Users/someone/proj': false });
  assert.equal(isInside('/x', ['/'], 'linux'), false);
});

test('filterProjects hides temporary projects unless showTemp; default stays visible for old callers', () => {
  const ps = [{ name: 'a', path: '/p/a', temporary: false }, { name: 'b', path: '/tmp/b', temporary: true }];
  assert.deepEqual(filterProjects(ps, { showTemp: false }, 0).map(p => p.name), ['a']);
  assert.deepEqual(filterProjects(ps, { showTemp: true }, 0).map(p => p.name), ['a', 'b']);
  assert.deepEqual(filterProjects(ps, {}, 0).map(p => p.name), ['a', 'b']);
});
