// desk/test/server-symlink.test.mjs
// server.mjs must start when launched through a symlinked path (macOS tmpdir /var -> /private/var, symlinked installs).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import './fixtures/tmpclean.mjs';

const SRC = fileURLToPath(new URL('..', import.meta.url));

test('server starts when launched through a symlinked directory', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-sym-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const real = path.join(root, 'real');
  const link = path.join(root, 'link');
  fs.cpSync(SRC, real, { recursive: true, filter: p => !p.includes(`${path.sep}test`) });
  try { fs.symlinkSync(real, link, 'dir'); } catch (e) { t.skip(`symlinks unavailable: ${e.code}`); return; }
  const home = path.join(root, 'home');
  fs.mkdirSync(home);
  const child = spawn(process.execPath, [path.join(link, 'server.mjs'), '--port', '0'], {
    env: { ...process.env, HOME: home, USERPROFILE: home, SUBDECK_HOME: path.join(home, '.subdeck'), SUBDECK_CLAUDE_PROJECTS_DIR: path.join(home, 'none'), SUBDECK_DISABLE: 'cursor' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => child.kill());
  const line = await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error('no URL line within 8 s: ' + buf)), 8000);
    child.stdout.on('data', d => { buf += d; const m = /SubDeck Desk: (http:\/\/127\.0\.0\.1:\d+\/)/.exec(buf); if (m) { clearTimeout(timer); resolve(m[1]); } });
    child.on('exit', c => { clearTimeout(timer); reject(new Error('exited ' + c + ': ' + buf)); });
  });
  assert.match(line, /^http:\/\/127\.0\.0\.1:\d+\/$/);
});
