// desk/lib/git.mjs: read-only `git show --stat` for one commit, run on demand in the project directory.
// Never reads the working tree diff; callers must pass a hash found in the agent's own transcript.
import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';

export const GIT_TIMEOUT_MS = 5000;
export const GIT_MAX_BYTES = 65536;
export const HASH_RE = /^[0-9a-f]{7,40}$/;

/** Resolves { ok:true, hash, author, date, subject, body, stat, truncated } or { ok:false, reason }. */
export async function showCommit(dir, hash, { gitBin = 'git', timeoutMs = GIT_TIMEOUT_MS, maxBytes = GIT_MAX_BYTES } = {}) {
  if (!HASH_RE.test(hash)) return { ok: false, reason: 'invalid hash' };
  if (typeof dir !== 'string' || !dir) return { ok: false, reason: 'project directory unknown' };
  try { if (!(await fs.stat(dir)).isDirectory()) throw new Error('x'); } catch { return { ok: false, reason: 'project directory not found' }; }
  const sep = '\u001e';
  const args = ['-C', dir, '--no-pager', '-c', 'core.quotepath=off', 'show', '--stat=120,80,200', '--no-color', '--no-ext-diff',
    `--format=%H${sep}%an${sep}%aI${sep}%s${sep}%b${sep}`, hash, '--'];
  return await new Promise(resolve => {
    execFile(gitBin, args, { timeout: timeoutMs, maxBuffer: maxBytes, windowsHide: true, env: { ...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_PAGER: 'cat', LC_ALL: 'C' } }, (err, stdout) => {
      let out = String(stdout || '');
      let truncated = false;
      if (err) {
        if (err.code === 'ENOENT') return resolve({ ok: false, reason: 'git is not installed or not on PATH' });
        if (err.killed || err.signal) return resolve({ ok: false, reason: 'git took too long' });
        if (err.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') truncated = true;
        else return resolve({ ok: false, reason: 'commit not found in this repository (it may have been rewritten or removed)' });
      }
      const parts = out.split(sep);
      if (parts.length < 6) return resolve({ ok: false, reason: 'commit not found in this repository (it may have been rewritten or removed)' });
      const [h, author, date, subject, body, rest] = parts;
      resolve({ ok: true, hash: h, author, date, subject, body: body.trim(), stat: rest.replace(/^\r?\n+/, '').replace(/\s+$/, ''), truncated });
    });
  });
}
