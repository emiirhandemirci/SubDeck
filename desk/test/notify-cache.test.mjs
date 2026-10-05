// desk/test/notify-cache.test.mjs: the header bell write must invalidate the cached GET /api/settings answer.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { createApi } from '../lib/api.mjs';

const P = 4999;
const TOKEN = 'b'.repeat(48);
const GOOD = { 'x-subdeck-token': TOKEN, 'content-type': 'application/json', origin: `http://127.0.0.1:${P}` };

function call(api, url, { method = 'GET', headers = {}, body } = {}) {
  const res = new EventEmitter();
  res.status = null; res.chunks = [];
  res.writeHead = s => { res.status = s; return res; };
  res.write = c => { res.chunks.push(String(c)); return true; };
  res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  const req = new EventEmitter();
  req.method = method; req.url = url; req.headers = { host: `127.0.0.1:${P}`, ...headers };
  const done = api.handle(req, res);
  if (body !== undefined) setImmediate(() => { req.emit('data', Buffer.from(JSON.stringify(body))); req.emit('end'); });
  return Promise.resolve(done).then(() => res);
}
const out = r => JSON.parse(r.chunks.join(''));

test('POST /api/settings/notify invalidates the settings cache', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sd-notify-cache-'));
  const configFile = path.join(home, 'config.json');
  fs.writeFileSync(configFile, JSON.stringify({ notify: { enabled: false } }));
  // Fake settings.sh: reports the real notify value from the config file, so a stale cache is observable.
  const settingsRun = async () => {
    const enabled = JSON.parse(fs.readFileSync(configFile, 'utf8')).notify.enabled;
    return { code: 0, stderr: '', stdout: JSON.stringify({ version: 1, scope: 'user', project: null, settings: [{ key: 'notify', value: enabled ? 'on' : 'off', source: 'user', group: 'notify', type: 'enum', options: ['on', 'off'], description: 'n' }] }) };
  };
  const api = createApi({ core: { snapshot: () => ({ lastScanAt: null, sources: [], sessions: [], projects: [] }) }, getPort: () => P, startedAt: 'T', days: 14, version: 't', publicDir: home, token: TOKEN, settingsRun, configFile });
  try {
    const val = async () => out(await call(api, '/api/settings')).settings[0].value;
    assert.equal(await val(), 'off');            // fills the cache
    const r = await call(api, '/api/settings/notify', { method: 'POST', headers: GOOD, body: { enabled: true } });
    assert.equal(r.status, 200);
    assert.equal(await val(), 'on');             // stale 'off' would fail here
    await call(api, '/api/settings/notify', { method: 'POST', headers: GOOD, body: { enabled: false } });
    assert.equal(await val(), 'off');
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
});
