// Importing this file makes every fs.mkdtempSync directory under the OS temp dir disappear when the test process exits.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const made = new Set();
const orig = fs.mkdtempSync;
if (!fs.mkdtempSync.__tracked) {
  const tracked = function mkdtempSync(prefix, ...rest) {
    const d = orig.call(fs, prefix, ...rest);
    if (typeof d === 'string' && path.resolve(d).startsWith(path.resolve(os.tmpdir()) + path.sep)) made.add(d);
    return d;
  };
  tracked.__tracked = true;
  fs.mkdtempSync = tracked;
  process.on('exit', () => { for (const d of made) { try { fs.rmSync(d, { recursive: true, force: true }); } catch { /* best effort */ } } });
}
