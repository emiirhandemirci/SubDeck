// desk/test/notify-persist.test.mjs: task 122. A bell write rejected for a dead per-start token used to fail silently
// (the control snapped back with no message). Covers: the restart / stale-token case end to end, token.js recovery,
// the visible error + re-read in the bell, and the bell write queueing behind settings.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import { createApi } from '../lib/api.mjs';
import './fixtures/tmpclean.mjs';

const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));
const pub = path.join(path.dirname(SERVER), 'public');

function start(home) {
  const env = { ...process.env, HOME: home, USERPROFILE: home, SUBDECK_HOME: home, SUBDECK_CLAUDE_PROJECTS_DIR: path.join(home, 'none'), SUBDECK_DISABLE: 'cursor' };
  const child = spawn(process.execPath, [SERVER, '--port', '0'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  const firstLine = new Promise((resolve, reject) => {
    let buf = '';
    child.stdout.on('data', d => { buf += d; const i = buf.indexOf('\n'); if (i >= 0) resolve(buf.slice(0, i)); });
    child.on('exit', code => resolve(`exit ${code}: ${buf}`));
    setTimeout(() => reject(new Error('no output within 10 s')), 10000);
  });
  const exited = new Promise(r => child.on('exit', code => r(code)));
  return { child, firstLine, exited };
}
const tokenOf = html => /name="subdeck-token" content="([0-9a-f]{48})"/.exec(html)[1];

test('Desk restart: the old tab token is rejected, a fresh read of the page yields a working one; nothing is written on 403', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-persist-'));
  const cfg = path.join(home, '.subdeck', 'config.json');
  fs.mkdirSync(path.dirname(cfg), { recursive: true });
  fs.writeFileSync(cfg, '{"notify":{"enabled":true,"events":["waiting","done","agent"]}}');
  const post = (base, token, enabled) => fetch(`${base}/api/settings/notify`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-SubDeck-Token': token }, body: JSON.stringify({ enabled }) });
  const a = start(home);
  let oldToken;
  try {
    const base = `http://127.0.0.1:${/:(\d+)\/$/.exec(await a.firstLine)[1]}`;
    oldToken = tokenOf(await (await fetch(`${base}/`)).text());
    assert.equal((await post(base, oldToken, true)).status, 200);
  } finally { a.child.kill('SIGTERM'); await a.exited; }
  const b = start(home);
  try {
    const base = `http://127.0.0.1:${/:(\d+)\/$/.exec(await b.firstLine)[1]}`;
    const r = await post(base, oldToken, false);                    // what the stale tab sends
    assert.equal(r.status, 403);
    assert.match((await r.json()).error, /token/);
    assert.equal(JSON.parse(fs.readFileSync(cfg, 'utf8')).notify.enabled, true);   // rejected write changed nothing
    const fresh = tokenOf(await (await fetch(`${base}/`, { cache: 'no-store' })).text());
    assert.notEqual(fresh, oldToken);
    assert.equal((await post(base, fresh, false)).status, 200);
    const o = JSON.parse(fs.readFileSync(cfg, 'utf8'));
    assert.equal(o.notify.enabled, false);
    assert.deepEqual(o.notify.events, ['waiting', 'done', 'agent']);   // events untouched by the bell
    assert.deepEqual(await (await fetch(`${base}/api/settings/notify`)).json(), { enabled: false, overriddenBy: [] });
  } finally { b.child.kill('SIGTERM'); await b.exited; }
});

// ---- token.js with a fake page ----
function fakePage({ pageToken, serverToken, failWith = null }) {
  const meta = { content: pageToken };
  globalThis.document = { querySelector: s => (s.includes('subdeck-token') ? meta : null) };
  const calls = [];
  globalThis.fetch = async (url, opt = {}) => {
    calls.push({ url, token: opt.headers && opt.headers['X-SubDeck-Token'] });
    if (failWith) throw new Error(failWith);
    if (url === '/') return { ok: true, text: async () => `<meta name="subdeck-token" content="${serverToken}">` };
    const good = opt.headers['X-SubDeck-Token'] === serverToken;
    return { ok: good, status: good ? 200 : 403, json: async () => (good ? { enabled: true } : { error: 'missing or wrong token' }) };
  };
  return { meta, calls };
}

test('token.js: a stale token is refreshed from the page once and the write is retried', async () => {
  const { writeJSON } = await import('../public/token.js');
  const page = fakePage({ pageToken: 'a'.repeat(48), serverToken: 'b'.repeat(48) });
  const r = await writeJSON('/api/settings/notify', { enabled: true });
  assert.equal(r.ok, true);
  assert.equal(page.meta.content, 'b'.repeat(48));
  assert.deepEqual(page.calls.map(c => c.url), ['/api/settings/notify', '/', '/api/settings/notify']);
});

test('token.js: a rejection that stays a rejection is reported with a readable reason and no retry loop', async () => {
  const { writeJSON } = await import('../public/token.js');
  const same = 'a'.repeat(48);
  const page = fakePage({ pageToken: same, serverToken: 'b'.repeat(48) });
  page.meta.content = same;
  globalThis.fetch = async (url) => (url === '/'
    ? { ok: true, text: async () => `<meta name="subdeck-token" content="${same}">` }
    : { ok: false, status: 403, json: async () => ({ error: 'missing or wrong token' }) });
  const r = await writeJSON('/x', {});
  assert.equal(r.ok, false); assert.equal(r.status, 403); assert.match(r.error, /token/);
  fakePage({ pageToken: 'a', serverToken: 'a', failWith: 'ECONNREFUSED' });
  const u = await writeJSON('/x', {});
  assert.equal(u.ok, false); assert.match(u.error, /unreachable/);
});

test('bell: a failed or rejected write shows a visible error and the control is re-read from the server; Settings uses the same writer', () => {
  const app = fs.readFileSync(path.join(pub, 'app.js'), 'utf8');
  const fn = app.slice(app.indexOf('async function toggleNotify'), app.indexOf("if ($('bell'))"));
  assert.match(fn, /writeJSON\('\/api\/settings\/notify'/);
  assert.match(fn, /Could not change notifications: \$\{r\.error\}/);
  assert.match(fn, /await loadNotify\(\)/);
  assert.ok(!/catch \{ \/\* keep/.test(fn));                       // no silent catch
  assert.match(fs.readFileSync(path.join(pub, 'index.html'), 'utf8'), /id="bellErr"[^>]*role="alert"/);
  assert.match(fs.readFileSync(path.join(pub, 'settings.js'), 'utf8'), /writeJSON\('\/api\/settings'/);
});

// ---- the bell write queues behind settings.sh ----
test('bell write waits for a running settings.sh set (no interleaved read-modify-write of config.json)', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sd-persist-q-'));
  const configFile = path.join(home, 'config.json');
  fs.writeFileSync(configFile, JSON.stringify({ notify: { enabled: true } }));
  const TOKEN = 'c'.repeat(48), P = 4998;
  const H = { 'x-subdeck-token': TOKEN, 'content-type': 'application/json', origin: `http://127.0.0.1:${P}` };
  let releaseRun; const gate = new Promise(r => { releaseRun = r; });
  const settingsRun = async args => {
    if (args[0] === 'set') {                                            // slow settings.sh: writes the file after the bell asked
      await gate;
      const o = JSON.parse(fs.readFileSync(configFile, 'utf8')); o.notify.events = ['done']; fs.writeFileSync(configFile, JSON.stringify(o));
    }
    return { code: 0, stderr: '', stdout: JSON.stringify({ version: 1, scope: 'user', project: null, settings: [] }) };
  };
  const api = createApi({ core: { snapshot: () => ({ lastScanAt: null, sources: [], sessions: [], projects: [] }) }, getPort: () => P, startedAt: 'T', days: 14, version: 't', publicDir: home, token: TOKEN, settingsRun, configFile });
  const call = (url, body) => {
    const res = new EventEmitter(); res.chunks = []; res.writeHead = s => { res.status = s; return res; };
    res.write = c => { res.chunks.push(String(c)); return true; }; res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
    const req = new EventEmitter(); req.method = 'POST'; req.url = url; req.headers = { host: `127.0.0.1:${P}`, ...H };
    const done = api.handle(req, res);
    setImmediate(() => { req.emit('data', Buffer.from(JSON.stringify(body))); req.emit('end'); });
    return Promise.resolve(done).then(() => res);
  };
  try {
    const s = call('/api/settings', { set: { 'notify.events': 'done' }, project: null });
    await new Promise(r => setTimeout(r, 30));
    let bellDone = false;
    const b = call('/api/settings/notify', { enabled: false }).then(r => { bellDone = true; return r; });
    await new Promise(r => setTimeout(r, 50));
    assert.equal(bellDone, false);                                      // queued, not interleaved
    releaseRun();
    assert.equal((await s).status, 200); assert.equal((await b).status, 200);
    const o = JSON.parse(fs.readFileSync(configFile, 'utf8'));
    assert.equal(o.notify.enabled, false);                              // the bell's value is the last write and survives
    assert.deepEqual(o.notify.events, ['done']);
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});
