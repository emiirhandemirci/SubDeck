import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import './fixtures/tmpclean.mjs';

const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');

// A syntax error in a browser module leaves the UI on "Connecting…" forever, and the server tests never notice.
for (const f of fs.readdirSync(pub).filter(n => n.endsWith('.js'))) {
  test(`public/${f} parses as an ES module`, () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-syntax-'));
    try {
      const copy = path.join(tmp, f.replace(/\.js$/, '.mjs'));
      fs.copyFileSync(path.join(pub, f), copy);
      const r = spawnSync(process.execPath, ['--check', copy], { encoding: 'utf8' });
      assert.equal(r.status, 0, r.stderr);
    } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  });
}
