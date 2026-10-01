// desk/test/server.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseArgs, ADAPTERS } from '../server.mjs';

const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));

test('parseArgs', () => {
  assert.deepEqual(parseArgs([]), { port: null, open: false, days: 14, noContent: false, warnings: [] });
  assert.deepEqual(parseArgs(['--port', '0', '--open', '--days', '3']), { port: 0, open: true, days: 3, noContent: false, warnings: [] });
  const bad = parseArgs(['--days', '999', '--frobnicate']);
  assert.equal(bad.days, 14);
  assert.equal(bad.warnings.length, 2);
});

function start(home, extra = []) {
  const env = { ...process.env, HOME: home, USERPROFILE: home, SUBDECK_CLAUDE_PROJECTS_DIR: path.join(home, 'none'), SUBDECK_DISABLE: 'cursor' };
  const child = spawn(process.execPath, [SERVER, '--port', '0', ...extra], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  const firstLine = new Promise((resolve, reject) => {
    let buf = '';
    child.stdout.on('data', d => { buf += d; const i = buf.indexOf('\n'); if (i >= 0) resolve(buf.slice(0, i)); });
    child.on('exit', code => resolve(`exit ${code}: ${buf}`));
    setTimeout(() => reject(new Error('no output within 10 s')), 10000);
  });
  const exited = new Promise(r => child.on('exit', code => r(code)));
  return { child, firstLine, exited };
}

test('starts, writes desk.json, answers, second start exits 0, cleans up', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-home-'));
  const a = start(home);
  const line = await a.firstLine;
  const m = /^SubDeck Desk: http:\/\/127\.0\.0\.1:(\d+)\/$/.exec(line);
  assert.ok(m, line);
  const port = Number(m[1]);
  const rt = JSON.parse(fs.readFileSync(path.join(home, '.subdeck', 'desk.json'), 'utf8'));
  assert.equal(rt.port, port);
  assert.equal(rt.pid, a.child.pid);
  assert.equal(rt.version, '0.4.2');
  const res = await fetch(`http://127.0.0.1:${port}/api/sources`);
  assert.equal(res.status, 200);
  const srcs = (await res.json()).sources;
  assert.deepEqual(srcs.map(x => x.id), ['claude-code', 'codex', 'copilot', 'gemini', 'cline', 'opencode']);
  // cursor is disabled by this test's env; every other adapter is registered
  assert.deepEqual(srcs.filter(x => x.experimental).map(x => x.id), ['codex', 'copilot', 'gemini', 'cline', 'opencode']);
  // fetch() may refuse to override Host, so use node:http for the rebinding check
  const bad = await new Promise((resolve, reject) => http.get({ host: '127.0.0.1', port, path: '/api/sources', headers: { Host: 'evil.example' } },
    r => { r.resume(); resolve(r.statusCode); }).on('error', reject));
  assert.equal(bad, 403);
  const b = start(home);
  assert.equal(await b.firstLine, `SubDeck Desk already running: http://127.0.0.1:${port}/`);
  assert.equal(await b.exited, 0);
  a.child.kill('SIGTERM');
  await a.exited;
  if (process.platform !== 'win32') assert.equal(fs.existsSync(path.join(home, '.subdeck', 'desk.json')), false);
});

test("parseArgs: --no-content", () => {
  assert.equal(parseArgs(["--no-content"]).noContent, true);
  assert.equal(parseArgs(["--no-content"]).warnings.length, 0);
});
