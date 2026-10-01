// desk/test/notify-settings.test.mjs: the Desk bell switch endpoint (only notify.enabled is writable)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { createApi } from '../lib/api.mjs';

const P = 4917;
const TOKEN = 'a'.repeat(48);
function mk() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-ns-'));
  const pub = path.join(dir, 'pub'); fs.mkdirSync(pub);
  fs.writeFileSync(path.join(pub, 'index.html'), '<meta name="subdeck-token" content="__SUBDECK_TOKEN__">');
  const cfg = path.join(dir, 'home', '.subdeck', 'config.json');
  const api = createApi({ core: { snapshot: () => ({ sources: [], projects: [], sessions: [] }) }, getPort: () => P, startedAt: 'x', days: 14, version: 't', publicDir: pub, configFile: cfg, token: TOKEN });
  return { api, cfg };
}
async function call(api, { method = 'GET', url = '/api/settings/notify', host = `127.0.0.1:${P}`, headers = {}, body } = {}) {
  const req = Readable.from(body === undefined ? [] : [Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))]);
  req.method = method; req.url = url; req.headers = { host, ...headers };
  const res = new EventEmitter();
  res.chunks = [];
  res.writeHead = (s, h) => { res.status = s; res.headers = h; return res; };
  res.write = c => { res.chunks.push(String(c)); return true; };
  res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  await api.handle(req, res);
  return res;
}
const json = r => JSON.parse(r.chunks.join(''));
const good = { 'content-type': 'application/json', 'x-subdeck-token': TOKEN };

test('GET: absent config means off; reflects the file', async () => {
  const { api, cfg } = mk();
  assert.deepEqual(json(await call(api)), { enabled: false, overriddenBy: [] });
  fs.mkdirSync(path.dirname(cfg), { recursive: true });
  fs.writeFileSync(cfg, '{"notify":{"enabled":true}}');
  assert.deepEqual(json(await call(api)), { enabled: true, overriddenBy: [] });
});

test('POST writes notify.enabled, preserves every other key, atomic (no tmp left)', async () => {
  const { api, cfg } = mk();
  fs.mkdirSync(path.dirname(cfg), { recursive: true });
  fs.writeFileSync(cfg, JSON.stringify({ modelPolicy: { worker: 'sonnet' }, other: [1, { a: 'b,c' }], notify: { events: ['done'], sound: true } }));
  const r = await call(api, { method: 'POST', headers: good, body: { enabled: true } });
  assert.equal(r.status, 200);
  assert.deepEqual(json(r), { enabled: true });
  const o = JSON.parse(fs.readFileSync(cfg, 'utf8'));
  assert.deepEqual(o, { modelPolicy: { worker: 'sonnet' }, other: [1, { a: 'b,c' }], notify: { events: ['done'], enabled: true } });
  assert.deepEqual(fs.readdirSync(path.dirname(cfg)), ['config.json']);
  await call(api, { method: 'POST', headers: good, body: { enabled: false } });
  assert.equal(JSON.parse(fs.readFileSync(cfg, 'utf8')).notify.enabled, false);
});

test('POST creates the config when absent', async () => {
  const { api, cfg } = mk();
  assert.equal((await call(api, { method: 'POST', headers: good, body: { enabled: true } })).status, 200);
  assert.deepEqual(JSON.parse(fs.readFileSync(cfg, 'utf8')), { notify: { enabled: true } });
});

test('POST rejects: no/wrong token, bad origin, bad host, wrong content-type, bad bodies; file untouched', async () => {
  const { api, cfg } = mk();
  fs.mkdirSync(path.dirname(cfg), { recursive: true });
  fs.writeFileSync(cfg, '{"keep":1}');
  const cases = [
    [{ headers: { 'content-type': 'application/json' }, body: { enabled: true } }, 403],
    [{ headers: { ...good, 'x-subdeck-token': 'b'.repeat(48) }, body: { enabled: true } }, 403],
    [{ headers: { ...good, 'x-subdeck-token': 'short' }, body: { enabled: true } }, 403],
    [{ headers: { ...good, origin: 'http://evil.example' }, body: { enabled: true } }, 403],
    [{ headers: good, host: 'evil.example', body: { enabled: true } }, 403],
    [{ headers: { ...good, 'content-type': 'text/plain' }, body: { enabled: true } }, 415],
    [{ headers: good, body: '{nope' }, 400],
    [{ headers: good, body: { enabled: 'yes' } }, 400],
    [{ headers: good, body: { enabled: true, sound: true } }, 400],
    [{ headers: good, body: { models: 'x' } }, 400],
    [{ headers: good, body: [true] }, 400],
    [{ headers: good, body: 'x'.repeat(5000) }, 400],
  ];
  for (const [opts, status] of cases) assert.equal((await call(api, { method: 'POST', ...opts })).status, status, JSON.stringify(opts.headers) + String(opts.host));
  assert.equal(fs.readFileSync(cfg, 'utf8'), '{"keep":1}');
  assert.equal((await call(api, { method: 'POST', headers: { ...good, origin: `http://127.0.0.1:${P}` }, body: { enabled: true } })).status, 200);
});

test('invalid JSON config is refused and left untouched', async () => {
  const { api, cfg } = mk();
  fs.mkdirSync(path.dirname(cfg), { recursive: true });
  fs.writeFileSync(cfg, 'not json');
  assert.equal((await call(api, { method: 'POST', headers: good, body: { enabled: true } })).status, 500);
  assert.equal(fs.readFileSync(cfg, 'utf8'), 'not json');
  assert.equal((await call(api)).status, 500);
});

test('no other path is writable; other methods stay 405', async () => {
  const { api } = mk();
  for (const url of ['/api/settings', '/api/settings/models', '/api/sources']) assert.equal((await call(api, { method: 'POST', url, headers: good, body: { enabled: true } })).status, 405, url);
  assert.equal((await call(api, { method: 'PUT', headers: good, body: { enabled: true } })).status, 405);
  assert.equal((await call(api, { method: 'DELETE', headers: good })).status, 405);
});

test('the page embeds the per-start token', async () => {
  const { api } = mk();
  const r = await call(api, { url: '/' });
  assert.match(r.chunks.join(''), new RegExp(`content="${TOKEN}"`));
});

test('GET: a project-level config that sets notify.enabled is reported as overriding the switch', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-ov-'));
  const pub = path.join(dir, 'pub'); fs.mkdirSync(pub);
  const cfg = path.join(dir, 'home', '.subdeck', 'config.json');
  const mkProj = (name, content) => {
    const pp = path.join(dir, 'work', name); fs.mkdirSync(path.join(pp, '.subdeck'), { recursive: true });
    if (content !== null) fs.writeFileSync(path.join(pp, '.subdeck', 'config.json'), content);
    return { name, path: pp };
  };
  const projects = [mkProj('Over', '{"notify":{"enabled":false}}'), mkProj('Plain', '{"modelPolicy":{}}'), mkProj('Bad', '{nope'), mkProj('None', null)];
  const api = createApi({ core: { snapshot: () => ({ sources: [], projects, sessions: [] }) }, getPort: () => P, startedAt: 'x', days: 14, version: 't', publicDir: pub, configFile: cfg, token: TOKEN });
  const j = json(await call(api));
  assert.equal(j.overriddenBy.length, 1);
  assert.equal(j.overriddenBy[0].project, 'Over');
  assert.equal(j.overriddenBy[0].enabled, false);
  assert.equal(j.overriddenBy[0].file, path.join(projects[0].path, '.subdeck', 'config.json'));
});
