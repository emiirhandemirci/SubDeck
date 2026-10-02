// desk/test/changes.test.mjs: per-agent changed files, conflicts, waitingKind. Synthetic fixtures only.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import claude, { readChangeList, readChangeFile, waitingBasis, CHANGE_EDITS_MAX, CHANGE_STR_MAX } from '../adapters/claude-code.mjs';
import { createCore } from '../lib/core.mjs';
import { createApi } from '../lib/api.mjs';
import { isSecretPath, relativeTo } from '../lib/paths.mjs';
import { lineDiff } from '../public/format.js';
import { rec, writeJsonl, writeMeta, tmpDir } from './fixtures/claude-fixture.mjs';

const at = n => `2026-09-29T10:00:${String(n).padStart(2, '0')}.000Z`;
const use = (ts, id, name, input) => ({ type: 'assistant', timestamp: ts, message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } });
const res = (ts, id, isError = false) => ({ type: 'user', timestamp: ts, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: 'TOOL_OUTPUT_MARKER', ...(isError ? { is_error: true } : {}) }] } });
const WIN = { platform: 'win32' };

function transcript(records) {
  const f = path.join(tmpDir('desk-chg-'), 'agent.jsonl');
  writeJsonl(f, records);
  return f;
}

test('changes list: Write/Edit/MultiEdit/NotebookEdit, failed edits dropped, paths merged case-insensitively on Windows', async () => {
  const f = transcript([
    use(at(1), 'a', 'Write', { file_path: 'E:\\Work\\Alpha\\src\\a.js', content: 'ONE\nTWO\n' }), res(at(2), 'a'),
    use(at(3), 'b', 'Edit', { file_path: 'e:/work/alpha/src/a.js', old_string: 'ONE', new_string: '1' }), res(at(4), 'b'),
    use(at(5), 'c', 'Edit', { file_path: 'E:\\Work\\Alpha\\src\\a.js', old_string: 'NOPE', new_string: 'x' }), res(at(6), 'c', true),
    use(at(7), 'd', 'MultiEdit', { file_path: 'E:\\Work\\Alpha\\b.md', edits: [{ old_string: 'p', new_string: 'q' }, { old_string: 'r', new_string: 's', replace_all: true }] }), res(at(8), 'd'),
    use(at(9), 'e', 'NotebookEdit', { notebook_path: 'E:\\Work\\Alpha\\n.ipynb', new_source: 'print(1)', cell_id: 'c1', edit_mode: 'replace' }),
    use(at(10), 'f', 'Read', { file_path: 'E:\\Work\\Alpha\\ignored.txt' }),
    use(at(11), 'g', 'Bash', { command: 'echo x > shell.txt' }),
    'not json',
  ]);
  const r = await readChangeList(f, WIN);
  assert.deepEqual(r.files.map(x => [x.path, x.count, x.kinds]), [
    ['E:\\Work\\Alpha\\src\\a.js', 2, ['edit', 'write']],
    ['E:\\Work\\Alpha\\b.md', 2, ['edit']],
    ['E:\\Work\\Alpha\\n.ipynb', 1, ['notebook']],
  ]);
  assert.equal(r.files[0].firstAt, at(1));
  assert.equal(r.files[0].lastAt, at(3));
  assert.ok(!JSON.stringify(r).includes('ONE'), 'the list carries no content');
  const posix = await readChangeList(f, { platform: 'linux' });
  assert.equal(posix.files.length, 4, 'case-sensitive on POSIX: the two spellings stay apart');
  assert.equal(await readChangeList(path.join(os.tmpdir(), 'nope-' + Date.now()), WIN), null);
});

test('changes file: edits for one path, write shown as full content, truncation marker', async () => {
  const f = transcript([
    use(at(1), 'a', 'Write', { file_path: '/p/a.js', content: 'ONE\nTWO\n' }), res(at(2), 'a'),
    use(at(3), 'b', 'Edit', { file_path: '/p/a.js', old_string: 'ONE', new_string: '1', replace_all: true }), res(at(4), 'b'),
    use(at(5), 'c', 'Write', { path: '/p/other.js', file_text: 'OTHER' }),
  ]);
  const d = await readChangeFile(f, { platform: 'linux' }, '/p/a.js');
  assert.equal(d.path, '/p/a.js');
  assert.equal(d.truncated, false);
  assert.deepEqual(d.edits, [{ kind: 'write', at: at(1), content: 'ONE\nTWO\n' }, { kind: 'edit', at: at(3), old: 'ONE', new: '1', replaceAll: true }]);
  assert.equal((await readChangeFile(f, { platform: 'linux' }, '/p/other.js')).edits[0].content, 'OTHER');
  assert.equal(await readChangeFile(f, { platform: 'linux' }, '/p/never.js'), null);

  const big = transcript([use(at(1), 'a', 'Write', { file_path: '/p/big.txt', content: 'x'.repeat(CHANGE_STR_MAX + 500) }),
    ...Array.from({ length: CHANGE_EDITS_MAX + 5 }, (_, i) => use(at(2), 'e' + i, 'Edit', { file_path: '/p/big.txt', old_string: 'a', new_string: 'b' }))]);
  const t = await readChangeFile(big, { platform: 'linux' }, '/p/big.txt');
  assert.equal(t.truncated, true);
  assert.equal(t.edits[0].content.length, CHANGE_STR_MAX);
  assert.ok(t.edits.length <= CHANGE_EDITS_MAX);
  assert.equal(t.total, CHANGE_EDITS_MAX + 6);
});

test('waitingBasis sets waitingKind from the blocking tool or the notification type', () => {
  assert.equal(waitingBasis({ at: at(1), name: 'AskUserQuestion' }, null, 0, at(2)).waitingKind, 'question');
  assert.equal(waitingBasis({ at: at(1), name: 'ExitPlanMode' }, null, 0, at(2)).waitingKind, 'plan');
  const t = Date.parse(at(5));
  assert.equal(waitingBasis(null, at(5), t, at(5), 'permission_prompt').waitingKind, 'permission');
  assert.equal(waitingBasis(null, at(5), t, at(5), 'elicitation_dialog').waitingKind, 'question');
  assert.equal('waitingKind' in waitingBasis(null, at(5), t, at(5), 'agent_needs_input'), false);
  assert.equal(waitingBasis(null, at(5), t + 10000, at(5), 'permission_prompt'), null);
});

test('helpers: secret filter, relativeTo, lineDiff', () => {
  for (const p of ['/p/.env', 'C:\\x\\.env.local', '/p/id_rsa', '/p/server.pem', '/p/credentials.json', '/p/secrets.yml']) assert.equal(isSecretPath(p), true, p);
  for (const p of ['/p/environment.js', '/p/src/key.js', '/p/readme.md']) assert.equal(isSecretPath(p), false, p);
  assert.equal(relativeTo('E:\\Work\\Alpha\\src\\a.js', 'e:/work/alpha', 'win32'), 'src/a.js');
  assert.equal(relativeTo('/a/b/c', '/a/b', 'linux'), 'c');
  assert.equal(relativeTo('/a/bc/c', '/a/b', 'linux'), null);
  assert.equal(relativeTo('/A/b/c', '/a/b', 'linux'), null);
  assert.deepEqual(lineDiff('a\nb\nc', 'a\nB\nc'), [{ t: ' ', s: 'a' }, { t: '-', s: 'b' }, { t: '+', s: 'B' }, { t: ' ', s: 'c' }]);
  assert.deepEqual(lineDiff('', 'x\ny'), [{ t: '+', s: 'x' }, { t: '+', s: 'y' }]);
  assert.deepEqual(lineDiff('x', ''), [{ t: '-', s: 'x' }]);
  assert.deepEqual(lineDiff('same', 'same'), [{ t: ' ', s: 'same' }]);
});

// ---- API over the real adapter: two agents of one session touch the same file ----
const call = async (api, url, headers = {}) => {
  const r = new EventEmitter(); r.chunks = [];
  r.writeHead = (s, h) => { r.status = s; r.headers = h; return r; }; r.write = c => { r.chunks.push(String(c)); return true; }; r.end = c => { if (c !== undefined) r.chunks.push(String(c)); };
  await api.handle({ method: 'GET', url, headers: { host: '127.0.0.1:4917', ...headers } }, r);
  const text = r.chunks.join('');
  return { status: r.status, headers: r.headers, text, body: text.startsWith('{') ? JSON.parse(text) : null };
};

async function setup(opts = {}) {
  const root = tmpDir('desk-chgapi-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString();
  const projects = path.join(root, 'projects');
  const proj = path.join(root, 'work', 'Alpha');
  fs.mkdirSync(proj, { recursive: true });
  const top = path.join(projects, 'slug', 'sess-1.jsonl');
  writeJsonl(top, [rec.user(ago(900000), proj), rec.aiTitle('Manager'),
    use(ago(800000), 'm1', 'Edit', { file_path: path.join(proj, 'README.md'), old_string: 'a', new_string: 'b' }), res(ago(799000), 'm1')], { mtimeMs: NOW - 1000 });
  const sub = path.join(projects, 'slug', 'sess-1', 'subagents');
  const a1 = path.join(sub, 'agent-a1.jsonl');
  writeJsonl(a1, [rec.user(ago(700000), proj),
    use(ago(690000), 'x1', 'Write', { file_path: path.join(proj, 'src', 'shared.js'), content: 'SECRET_BODY_MARKER\nline2' }), res(ago(689000), 'x1'),
    use(ago(688000), 'x2', 'Write', { file_path: path.join(proj, '.env'), content: 'TOKEN=ENV_MARKER' }), res(ago(687000), 'x2')], { mtimeMs: NOW - 2000 });
  writeMeta(a1, { agentType: 'worker-sonnet', description: 'Parser' });
  const a2 = path.join(sub, 'agent-a2.jsonl');
  const shared2 = path.join(proj, 'src', 'shared.js').replace('Alpha', 'ALPHA');   // other casing: same file on Windows
  writeJsonl(a2, [rec.user(ago(600000), proj),
    use(ago(300000), 'y1', 'Edit', { file_path: shared2, old_string: 'line2', new_string: 'LINE2' }), res(ago(299000), 'y1'),
    use(ago(298000), 'y2', 'Edit', { file_path: path.join(proj, 'only-a2.js'), old_string: 'q', new_string: 'r' }), res(ago(297000), 'y2')], { mtimeMs: NOW - 3000 });
  writeMeta(a2, { agentType: 'worker-sonnet', description: 'Tests' });
  const env = { now: () => NOW, days: 14, platform: 'win32', claudeProjectsDir: projects, disabled: [], tmpDirs: [] };
  const core = createCore({ env, adapters: [claude], now: () => NOW });
  await core.scanAll();
  const api = createApi({ core, getPort: () => 4917, startedAt: 'x', days: 14, version: 't', publicDir: root, adapters: [claude], env, now: () => NOW, ...opts });
  const ids = Object.fromEntries(core.snapshot().sessions.map(s => [s.nativeId, s.id]));
  return { api, ids, proj };
}

test('GET changes: own files, alsoBy badges, tree conflicts, relative paths, no content, no-store', async () => {
  const { api, ids } = await setup();
  const r = await call(api, `/api/sessions/${ids.a1}/changes`);
  assert.equal(r.status, 200);
  assert.equal(r.headers['Cache-Control'], 'no-store');
  assert.deepEqual(r.body.files.map(f => f.rel), ['src/shared.js', '.env']);
  const shared = r.body.files[0];
  assert.deepEqual(shared.alsoBy.map(x => x.title), ['Tests']);
  assert.equal(shared.alsoBy[0].parallel, false);
  assert.equal(r.body.files[1].alsoBy.length, 0);
  assert.equal(r.body.files[1].secret, true);
  assert.equal(r.body.conflicts.length, 1);
  assert.equal(r.body.conflicts[0].rel, 'src/shared.js');
  assert.deepEqual(r.body.conflicts[0].agents.map(a => a.title).sort(), ['Parser', 'Tests']);
  assert.ok(!/SECRET_BODY_MARKER|ENV_MARKER|TOOL_OUTPUT_MARKER|"old"|"content"/.test(r.text), 'list carries no content');
  const top = await call(api, `/api/sessions/${ids['sess-1']}/changes`);
  assert.deepEqual(top.body.files.map(f => f.rel), ['README.md']);
  assert.equal(top.body.conflicts.length, 1);   // the top session sees the whole tree
  assert.equal(top.body.agentsChecked, 3);
  const a2 = await call(api, `/api/sessions/${ids.a2}/changes`);
  assert.equal(a2.body.conflicts.length, 1);
  assert.deepEqual(a2.body.files.map(f => f.alsoBy.length), [1, 0]);
});

test('GET changes/file: edits for one path, secret file withheld, unknown path 404, bad input 400', async () => {
  const { api, ids, proj } = await setup();
  const q = p => `/api/sessions/${ids.a1}/changes/file?path=${encodeURIComponent(p)}`;
  const ok = await call(api, q(path.join(proj, 'src', 'shared.js')));
  assert.equal(ok.status, 200);
  assert.equal(ok.headers['Cache-Control'], 'no-store');
  assert.equal(ok.body.edits[0].content, 'SECRET_BODY_MARKER\nline2');
  assert.equal(ok.body.rel, 'src/shared.js');
  const env = await call(api, q(path.join(proj, '.env')));
  assert.equal(env.status, 200);
  assert.equal(env.body.withheld, true);
  assert.deepEqual(env.body.edits, []);
  assert.ok(!env.text.includes('ENV_MARKER'));
  assert.equal((await call(api, q(path.join(proj, 'never.js')))).status, 404);
  assert.equal((await call(api, q('/etc/passwd'))).status, 404);   // only paths found in the transcript can match; the filesystem is never read
  assert.equal((await call(api, `/api/sessions/${ids.a1}/changes/file`)).status, 400);
  assert.equal((await call(api, '/api/sessions/nope/changes')).status, 404);
});

test('changes endpoints: --no-content disables them, Host guard, nothing leaks into other surfaces', async () => {
  const off = await setup({ contentEnabled: false });
  assert.equal((await call(off.api, `/api/sessions/${off.ids.a1}/changes`)).status, 404);
  assert.equal((await call(off.api, `/api/sessions/${off.ids.a1}/changes/file?path=x`)).status, 404);
  const on = await setup();
  const bad = await call(on.api, `/api/sessions/${on.ids.a1}/changes`, { host: 'evil.example:4917' });
  assert.equal(bad.status, 403);
  for (const u of ['/api/projects', `/api/sessions/${on.ids.a1}`, '/api/waiting', '/api/sources']) {
    assert.ok(!/SECRET_BODY_MARKER|shared\.js/.test((await call(on.api, u)).text), u);
  }
});

test('adapters without changes() answer 501', async () => {
  const core = { snapshot: () => ({ projects: [], sessions: [{ id: 'cursor.x', tool: 'cursor', projectId: 'p', title: 't' }], sources: [] }) };
  const a = createApi({ core, getPort: () => 4917, startedAt: 'x', days: 1, version: 't', publicDir: '.', adapters: [{ tool: 'cursor' }], env: {} });
  assert.equal((await call(a, '/api/sessions/cursor.x/changes')).status, 501);
});

test('scan: a pending ExitPlanMode / AskUserQuestion yields waitingKind on the basis', async () => {
  const root = tmpDir('desk-wk-');
  const NOW = Date.now();
  const projects = path.join(root, 'projects');
  const proj = path.join(root, 'w');
  fs.mkdirSync(proj, { recursive: true });
  writeJsonl(path.join(projects, 's', 'p1.jsonl'), [rec.user(new Date(NOW - 5000).toISOString(), proj), rec.exitPlan(new Date(NOW - 1000).toISOString())], { mtimeMs: NOW - 1000 });
  writeJsonl(path.join(projects, 's', 'q1.jsonl'), [rec.user(new Date(NOW - 5000).toISOString(), proj), rec.ask(new Date(NOW - 1000).toISOString())], { mtimeMs: NOW - 1000 });
  const env = { now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: projects };
  const r = await claude.scan(env, { since: null, cache: new Map() });
  const by = Object.fromEntries(r.sessions.map(s => [s.nativeId, s.stateBasis.waitingKind]));
  assert.deepEqual(by, { p1: 'plan', q1: 'question' });
});
