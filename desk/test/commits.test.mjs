// desk/test/commits.test.mjs: agent commits from Bash `git commit` calls, on-demand git show --stat. Synthetic fixtures only.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { EventEmitter } from 'node:events';
import claude, { readCommitList, pathspecOf } from '../adapters/claude-code.mjs';
import { createCore } from '../lib/core.mjs';
import { createApi } from '../lib/api.mjs';
import { showCommit } from '../lib/git.mjs';
import { rec, writeJsonl, writeMeta, tmpDir } from './fixtures/claude-fixture.mjs';

const at = n => `2026-09-29T10:00:${String(n).padStart(2, '0')}.000Z`;
const use = (ts, id, name, input) => ({ type: 'assistant', timestamp: ts, message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } });
const res = (ts, id, content, isError = false) => ({ type: 'user', timestamp: ts, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content, ...(isError ? { is_error: true } : {}) }] } });

let gitOk = true;
try { execFileSync('git', ['--version'], { stdio: 'ignore' }); } catch { gitOk = false; }
const git = (cwd, ...a) => execFileSync('git', ['-c', 'user.name=T', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ...a], { cwd, encoding: 'utf8' });

function makeRepo() {
  const dir = tmpDir('desk-git-');
  git(dir, 'init', '-q');
  fs.mkdirSync(path.join(dir, 'src'));
  fs.writeFileSync(path.join(dir, 'src', 'made.js'), 'console.log(1)\n');
  fs.writeFileSync(path.join(dir, 'edited.js'), 'a\n');
  fs.writeFileSync(path.join(dir, '.env'), 'TOKEN=ENV_MARKER\n');
  git(dir, 'add', '-A');
  git(dir, 'commit', '-q', '-m', 'Add made file', '-m', 'Body line');
  return { dir, hash: git(dir, 'rev-parse', '--short=10', 'HEAD').trim(), full: git(dir, 'rev-parse', 'HEAD').trim() };
}

test('pathspecOf: words after a lone -- up to the next shell operator, quote-aware', () => {
  assert.deepEqual(pathspecOf('git add a b && git commit -m "x -- y" -- src/a.js "dir with space/b.js" && git log -1'), ['src/a.js', 'dir with space/b.js']);
  assert.deepEqual(pathspecOf('git commit -m "$(cat <<\'END\'\nmsg\nEND\n)" -- one two'), ['one', 'two']);
  assert.deepEqual(pathspecOf('git commit -m x'), []);
  assert.deepEqual(pathspecOf('git commit -m x -- a.js; echo done'), ['a.js']);
});

test('readCommitList: hash + subject from the result, pathspec paths, failed commits and other commands ignored', async () => {
  const f = path.join(tmpDir('desk-cl-'), 'agent.jsonl');
  writeJsonl(f, [
    use(at(1), 'a', 'Bash', { command: 'git add x && git commit -m "First" -- src/a.js docs/b.md' }), res(at(2), 'a', '[main abc1234] First subject\n 2 files changed'),
    use(at(3), 'b', 'Bash', { command: 'git commit -m "Nope" -- c.js' }), res(at(4), 'b', 'nothing to commit', true),
    use(at(5), 'c', 'Bash', { command: 'git commit -m "Second"' }), res(at(6), 'c', [{ type: 'text', text: '[feature/x (root-commit) deadbeef01] Second subject' }]),
    use(at(7), 'd', 'Bash', { command: 'git status' }), res(at(8), 'd', '[main 1111111] fake'),
    use(at(9), 'e', 'Bash', { command: 'git commit -m "no result"' }),
    'not json',
  ]);
  assert.deepEqual(await readCommitList(f), [
    { hash: 'abc1234', subject: 'First subject', at: at(1), paths: ['src/a.js', 'docs/b.md'] },
    { hash: 'deadbeef01', subject: 'Second subject', at: at(5), paths: [] },
  ]);
  assert.equal(await readCommitList(path.join(tmpDir('x-'), 'missing.jsonl')), null);
});

test('showCommit: stat of a real commit; unknown hash, missing git and bad input are explained', { skip: !gitOk }, async () => {
  const r = makeRepo();
  const ok = await showCommit(r.dir, r.hash);
  assert.equal(ok.ok, true);
  assert.equal(ok.subject, 'Add made file');
  assert.equal(ok.body, 'Body line');
  assert.equal(ok.hash, r.full);
  assert.match(ok.stat, /src\/made\.js/);
  assert.match(ok.stat, /3 files changed/);
  assert.ok(!/console\.log|ENV_MARKER/.test(JSON.stringify(ok)), 'stat only, no patch content');
  const gone = await showCommit(r.dir, 'abcdef1234');
  assert.equal(gone.ok, false);
  assert.match(gone.reason, /not found/);
  const nogit = await showCommit(r.dir, r.hash, { gitBin: 'git-does-not-exist-xyz' });
  assert.equal(nogit.ok, false);
  assert.match(nogit.reason, /git is not installed/);
  assert.equal((await showCommit(r.dir, 'HEAD')).ok, false);
  assert.equal((await showCommit(r.dir, '--output=x1234567')).ok, false);
  assert.match((await showCommit(path.join(r.dir, 'nope'), r.hash)).reason, /directory/);
  const small = await showCommit(r.dir, r.hash, { maxBytes: 150 });
  assert.equal(small.truncated, true);
});

const call = async (api, url, headers = {}) => {
  const r = new EventEmitter(); r.chunks = [];
  r.writeHead = (s, h) => { r.status = s; r.headers = h; return r; }; r.write = c => { r.chunks.push(String(c)); return true; }; r.end = c => { if (c !== undefined) r.chunks.push(String(c)); };
  await api.handle({ method: 'GET', url, headers: { host: '127.0.0.1:4917', ...headers } }, r);
  const text = r.chunks.join('');
  return { status: r.status, headers: r.headers, text, body: text.startsWith('{') ? JSON.parse(text) : null };
};

async function setup(opts = {}) {
  const repo = makeRepo();
  const root = tmpDir('desk-cmtapi-');
  const NOW = Date.now();
  const ago = ms => new Date(NOW - ms).toISOString();
  const projects = path.join(root, 'projects');
  const proj = repo.dir;
  const sub = path.join(projects, 'slug', 'sess-1', 'subagents');
  writeJsonl(path.join(projects, 'slug', 'sess-1.jsonl'), [rec.user(ago(900000), proj), rec.aiTitle('Manager')], { mtimeMs: NOW - 1000 });
  const a1 = path.join(sub, 'agent-a1.jsonl');
  writeJsonl(a1, [rec.user(ago(700000), proj),
    use(ago(690000), 'x1', 'Edit', { file_path: path.join(proj, 'edited.js'), old_string: 'a', new_string: 'b' }), res(ago(689000), 'x1', 'ok'),
    use(ago(680000), 'x2', 'Bash', { command: 'git add -A && git commit -m "Add made file" -- src/made.js edited.js .env' }),
    res(ago(679000), 'x2', `[main ${repo.hash}] Add made file\n 3 files changed`),
    use(ago(670000), 'x3', 'Bash', { command: 'git commit -m "Gone" -- src/made.js' }), res(ago(669000), 'x3', '[main abcdef1234] Gone commit'),
  ], { mtimeMs: NOW - 2000 });
  writeMeta(a1, { agentType: 'worker-sonnet', description: 'Committer' });
  const a2 = path.join(sub, 'agent-a2.jsonl');
  writeJsonl(a2, [rec.user(ago(600000), proj)], { mtimeMs: NOW - 3000 });
  writeMeta(a2, { agentType: 'worker-sonnet', description: 'Idle' });
  const env = { now: () => NOW, days: 14, platform: process.platform, claudeProjectsDir: projects, disabled: [], tmpDirs: [] };
  const core = createCore({ env, adapters: [claude], now: () => NOW });
  await core.scanAll();
  const api = createApi({ core, getPort: () => 4917, startedAt: 'x', days: 14, version: 't', publicDir: root, adapters: [claude], env, now: () => NOW, ...opts });
  const ids = Object.fromEntries(core.snapshot().sessions.map(s => [s.nativeId, s.id]));
  return { api, ids, repo };
}

test('GET changes: commits listed, commit-only files marked via commit, edited files are not', { skip: !gitOk }, async () => {
  const { api, ids, repo } = await setup();
  const r = await call(api, `/api/sessions/${ids.a1}/changes`);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.commits.map(c => [c.hash, c.subject]), [[repo.hash, 'Add made file'], ['abcdef1234', 'Gone commit']]);
  assert.deepEqual(r.body.commits[0].files, ['src/made.js', 'edited.js', '.env']);
  const by = Object.fromEntries(r.body.files.map(f => [f.rel, f]));
  assert.equal(by['edited.js'].via, undefined, 'edited through a tool call: no marker');
  assert.equal(by['src/made.js'].via, 'commit');
  assert.equal(by['src/made.js'].count, 0);
  assert.deepEqual(by['src/made.js'].commits, [repo.hash, 'abcdef1234']);
  assert.equal(by['.env'].via, 'commit');
  assert.equal(by['.env'].secret, true);
  assert.equal(Object.keys(by).length, 3);
  const idle = await call(api, `/api/sessions/${ids.a2}/changes`);
  assert.deepEqual(idle.body.commits, []);
  assert.ok(!/ENV_MARKER|console\.log/.test(r.text));
});

test('GET changes/commit: only hashes from this agent transcript, stat on demand, gone hash and missing git explained', { skip: !gitOk }, async () => {
  const { api, ids, repo } = await setup();
  const q = (id, h) => `/api/sessions/${id}/changes/commit?hash=${encodeURIComponent(h)}`;
  const ok = await call(api, q(ids.a1, repo.hash));
  assert.equal(ok.status, 200);
  assert.equal(ok.headers['Cache-Control'], 'no-store');
  assert.equal(ok.body.ok, true);
  assert.equal(ok.body.subject, 'Add made file');
  assert.match(ok.body.stat, /src\/made\.js/);
  assert.ok(!/console\.log|ENV_MARKER/.test(ok.text), 'no patch content');
  const gone = await call(api, q(ids.a1, 'abcdef1234'));
  assert.equal(gone.status, 200);
  assert.equal(gone.body.ok, false);
  assert.match(gone.body.reason, /not found/);
  assert.equal((await call(api, q(ids.a2, repo.hash))).status, 404, 'another agent did not make this commit');
  assert.equal((await call(api, q(ids.a1, repo.full))).status, 404, 'a hash spelled differently from the transcript is not queryable');
  for (const bad of ['HEAD', 'main', '--all', 'zzzzzzz', '', 'abc']) assert.equal((await call(api, q(ids.a1, bad))).status, 400, bad);
  assert.equal((await call(api, `/api/sessions/${ids.a1}/changes/commit`)).status, 400);
  const nogit = await setup({ gitShow: (dir, h) => showCommit(dir, h, { gitBin: 'git-does-not-exist-xyz' }) });
  const m = await call(nogit.api, q(nogit.ids.a1, nogit.repo.hash));
  assert.equal(m.body.ok, false);
  assert.match(m.body.reason, /git is not installed/);
});

test('commit endpoints: --no-content disables them, Host guard, nothing leaks into other surfaces', { skip: !gitOk }, async () => {
  const off = await setup({ contentEnabled: false });
  assert.equal((await call(off.api, `/api/sessions/${off.ids.a1}/changes/commit?hash=${off.repo.hash}`)).status, 404);
  assert.equal((await call(off.api, `/api/sessions/${off.ids.a1}/changes`)).status, 404);
  const on = await setup();
  assert.equal((await call(on.api, `/api/sessions/${on.ids.a1}/changes/commit?hash=${on.repo.hash}`, { host: 'evil.example:4917' })).status, 403);
  for (const u of ['/api/projects', `/api/sessions/${on.ids.a1}`, '/api/waiting', '/api/sources']) {
    assert.ok(!/Add made file|made\.js/.test((await call(on.api, u)).text), u);
  }
});
