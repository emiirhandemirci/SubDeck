// desk/test/settings-api.test.mjs: GET/POST /api/settings, guards, project mapping, and the real bash runner against a fake script.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { createApi, runSettingsSh } from '../lib/api.mjs';

const P = 4917;
const TOKEN = 'a'.repeat(48);
const snapshot = { lastScanAt: null, sources: [], sessions: [], projects: [{ id: 'p_1', path: '/work/x', name: 'x' }] };
const DOC = { version: 1, scope: 'user', project: null, settings: [
  { key: 'worker', value: 'sonnet', source: 'default', group: 'models', type: 'enum', options: ['sonnet', 'opus'], description: 'worker model' },
  { key: 'statusline', value: 'off', source: 'default', group: 'statusline', type: 'enum', options: ['on', 'off'], description: 'status line' }] };

function mk(run) {
  const calls = [];
  const settingsRun = async args => { calls.push(args); return run ? run(args) : { code: 0, stdout: JSON.stringify(DOC), stderr: '' }; };
  const api = createApi({ core: { snapshot: () => snapshot }, getPort: () => P, startedAt: 'T', days: 14, version: 't', publicDir: os.tmpdir(), token: TOKEN, settingsRun });
  return { api, calls };
}
function call(api, url, { method = 'GET', headers = {}, body } = {}) {
  const res = new EventEmitter();
  res.status = null; res.chunks = [];
  res.writeHead = (s, h) => { res.status = s; res.headers = h; return res; };
  res.write = c => { res.chunks.push(String(c)); return true; };
  res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  const req = new EventEmitter();
  req.method = method; req.url = url; req.headers = { host: `127.0.0.1:${P}`, ...headers };
  const done = api.handle(req, res);
  if (body !== undefined) setImmediate(() => { req.emit('data', Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))); req.emit('end'); });
  else if (method === 'POST') setImmediate(() => req.emit('end'));
  return Promise.resolve(done).then(() => res);
}
const out = r => JSON.parse(r.chunks.join(''));
const GOOD = { 'x-subdeck-token': TOKEN, 'content-type': 'application/json', origin: `http://127.0.0.1:${P}` };
const post = (api, body, headers = GOOD) => call(api, '/api/settings', { method: 'POST', headers, body });

test('GET /api/settings returns settings.sh json, no-store; user scope passes no --project', async () => {
  const { api, calls } = mk();
  const r = await call(api, '/api/settings');
  assert.equal(r.status, 200);
  assert.equal(r.headers['Cache-Control'], 'no-store');
  assert.deepEqual(out(r), DOC);
  assert.deepEqual(calls, [['json']]);
});

test('GET with a known project id maps to its path; unknown id is 404, never run', async () => {
  const { api, calls } = mk();
  assert.equal((await call(api, '/api/settings?project=p_1')).status, 200);
  assert.deepEqual(calls[0], ['json', '--project', '/work/x']);
  assert.equal((await call(api, '/api/settings?project=%2Fetc')).status, 404);
  assert.equal((await call(api, '/api/settings?project=p_9')).status, 404);
  assert.equal(calls.length, 1);
});

test('GET: script failure and bad JSON become 502 with a short message', async () => {
  let r = await call(mk(() => ({ code: 3, stdout: '', stderr: 'boom\nmore' })).api, '/api/settings');
  assert.equal(r.status, 502); assert.equal(out(r).error, 'boom');
  r = await call(mk(() => ({ code: 0, stdout: 'not json', stderr: '' })).api, '/api/settings');
  assert.equal(r.status, 502);
  r = await call(mk(() => ({ code: 0, stdout: '{"settings":1}', stderr: '' })).api, '/api/settings');
  assert.equal(r.status, 502);
});

test('Host guard applies to /api/settings (GET and POST)', async () => {
  const { api, calls } = mk();
  assert.equal((await call(api, '/api/settings', { headers: { host: 'evil.example:4917' } })).status, 403);
  assert.equal((await post(api, { set: { worker: 'opus' } }, { ...GOOD, host: 'evil.example:4917' })).status, 403);
  assert.equal(calls.length, 0);
});

test('POST: 403 for missing/wrong token and foreign origin, 415 for wrong content type; nothing runs', async () => {
  const { api, calls } = mk();
  const b = { set: { worker: 'opus' } };
  assert.equal((await post(api, b, { 'content-type': 'application/json' })).status, 403);
  assert.equal((await post(api, b, { ...GOOD, 'x-subdeck-token': 'b'.repeat(48) })).status, 403);
  assert.equal((await post(api, b, { ...GOOD, 'x-subdeck-token': 'short' })).status, 403);
  assert.equal((await post(api, b, { ...GOOD, origin: 'http://evil.example' })).status, 403);
  assert.equal((await post(api, b, { ...GOOD, origin: 'http://127.0.0.1:9999' })).status, 403);
  assert.equal((await post(api, b, { ...GOOD, 'content-type': 'text/plain' })).status, 415);
  assert.equal((await post(api, b, { 'x-subdeck-token': TOKEN })).status, 415);
  assert.equal(calls.length, 0);
});

test('POST: valid change runs settings.sh set with k=v pairs and optional --project', async () => {
  const { api, calls } = mk(() => ({ code: 0, stdout: '', stderr: '' }));
  let r = await post(api, { set: { worker: 'opus' } });
  assert.equal(r.status, 200); assert.deepEqual(out(r), { ok: true });
  assert.deepEqual(calls[0], ['set', 'worker=opus']);
  r = await post(api, { set: { context: 200000, 'protect-branches': 'main,dev' }, project: 'p_1' });
  assert.equal(r.status, 200);
  assert.deepEqual(calls[1], ['set', 'context=200000', 'protect-branches=main,dev', '--project', '/work/x']);
  r = await post(api, { set: { notify: 'on' }, project: null });
  assert.deepEqual(calls[2], ['set', 'notify=on']);
});

test('POST: settings.sh rejection (exit 2) returns its one-line error as 422', async () => {
  const { api } = mk(() => ({ code: 2, stdout: '', stderr: 'invalid value for worker: nope\n' }));
  const r = await post(api, { set: { worker: 'nope' } });
  assert.equal(r.status, 422);
  assert.equal(out(r).error, 'invalid value for worker: nope');
});

test('POST: bodies that could smuggle flags or paths are refused before running', async () => {
  const { api, calls } = mk();
  const bad = [
    { set: { '--project': 'x' } }, { set: { '-x': 'y' } }, { set: { 'a b': 'c' } }, { set: { 'a=b': 'c' } },
    { set: { statusline: 'on' } }, { set: {} }, { set: [] }, { set: { worker: 'a\nb' } }, { set: { worker: { x: 1 } } },
    { set: { worker: 'x'.repeat(501) } }, { set: { worker: 'opus' }, extra: 1 }, { worker: 'opus' }, [], 'str',
    { set: { worker: 'opus' }, project: '/etc' }, { set: { worker: 'opus' }, project: 5 },
  ];
  for (const b of bad) {
    const r = await post(api, b);
    assert.ok([400, 404].includes(r.status), `${JSON.stringify(b).slice(0, 40)} -> ${r.status}`);
  }
  assert.equal((await post(api, '{broken')).status, 400);
  assert.equal(calls.length, 0);
});

test('PUT/DELETE on /api/settings are rejected', async () => {
  const { api } = mk();
  assert.equal((await call(api, '/api/settings', { method: 'PUT', headers: GOOD, body: {} })).status, 405);
  assert.equal((await call(api, '/api/settings', { method: 'DELETE', headers: GOOD })).status, 405);
});

test('static: theme.js and settings.js are served', async () => {
  const pub = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-pub-'));
  fs.writeFileSync(path.join(pub, 'theme.js'), '//t'); fs.writeFileSync(path.join(pub, 'settings.js'), '//s');
  const api = createApi({ core: { snapshot: () => snapshot }, getPort: () => P, startedAt: 'T', days: 14, version: 't', publicDir: pub, token: TOKEN });
  for (const f of ['/theme.js', '/settings.js']) { const r = await call(api, f); assert.equal(r.status, 200); assert.match(r.headers['Content-Type'], /javascript/); }
});

const bash = spawnSync('bash', ['-c', 'echo ok'], { encoding: 'utf8' });
test('runSettingsSh runs bash with plain args (no shell), HOME override, exit code and stderr', { skip: bash.status !== 0 && 'bash not available' }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-fake-'));
  const script = path.join(dir, 'fake.sh');
  fs.writeFileSync(script, '#!/usr/bin/env bash\nif [ "$1" = fail ]; then echo "bad value" >&2; exit 2; fi\nprintf "%s|" "$@"; printf "HOME=%s" "$HOME"\n');
  const ok = await runSettingsSh(['set', 'a=b;touch pwned', '$(x)'], { home: dir, script });
  assert.equal(ok.code, 0);
  assert.ok(ok.stdout.startsWith('set|a=b;touch pwned|$(x)|HOME='), ok.stdout);
  assert.ok(!fs.existsSync(path.join(dir, 'pwned')));
  const bad = await runSettingsSh(['fail'], { script });
  assert.equal(bad.code, 2); assert.equal(bad.stderr.trim(), 'bad value');
  const none = await runSettingsSh(['json'], { script: path.join(dir, 'missing.sh') });
  assert.notEqual(none.code, 0);
});

// Against the real plugin script, in a throw-away HOME (never the real one).
test('real settings.sh: json shape, validated set (exit 2, nothing written), then the value reads back', { skip: bash.status !== 0 && 'bash not available', timeout: 240000 }, async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-realhome-'));
  const saved = process.env.SUBDECK_STATE_DIR; delete process.env.SUBDECK_STATE_DIR;
  try {
    const bad = await runSettingsSh(['set', 'push=maybe'], { home });
    assert.equal(bad.code, 2, bad.stderr);
    assert.ok(bad.stderr.trim().length > 3);
    assert.ok(!fs.existsSync(path.join(home, '.subdeck', 'config.json')), 'nothing written on invalid input');
    const ok = await runSettingsSh(['set', 'worker=opus', 'context=123000'], { home });
    assert.equal(ok.code, 0, ok.stderr);
    const j = await runSettingsSh(['json'], { home });
    assert.equal(j.code, 0, j.stderr);
    const d = JSON.parse(j.stdout);
    assert.equal(d.version, 1);
    const by = k => d.settings.find(s => s.key === k);
    assert.equal(by('worker').value, 'opus'); assert.equal(by('worker').source, 'user');
    assert.equal(by('context').value, 123000);
    assert.ok(Array.isArray(by('protect-branches').value));
    for (const s of d.settings) assert.ok(['models', 'notify', 'push', 'guard', 'protect', 'resources', 'tasks', 'context', 'statusline'].includes(s.group), s.key);
  } finally { if (saved !== undefined) process.env.SUBDECK_STATE_DIR = saved; fs.rmSync(home, { recursive: true, force: true }); }
});
