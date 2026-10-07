// desk/adapters/subdeck-run.mjs
// SubDeck runs (run.sh): one session per run meta <stateRoot>/<project-key>/runs/<task>/<ts>.json. Read-only; the
// meta is a whitelisted summary, logs are only read on demand by the API (never here).
import fs from 'node:fs/promises';
import path from 'node:path';
import { clip } from '../lib/model.mjs';

export const TASK_RE = /^t-[0-9a-f]{4,12}$/;
export const TS_RE = /^\d{8}T\d{6}Z$/;
const META_RE = /^(\d{8}T\d{6}Z)\.json$/;
const MAX_META = 256 * 1024;
const MAX_RUNS = 2000;
const STATUSES = ['running', 'ok', 'failed', 'quota', 'auth', 'timeout', 'violation', 'cancelled'];
const FAIL_KIND = { quota: 'quota', timeout: 'timeout', auth: 'permission', violation: 'tool', failed: 'unknown', cancelled: 'unknown' };

const isObj = v => v && typeof v === 'object' && !Array.isArray(v);
const s = (v, max = 300) => (typeof v === 'string' ? v.slice(0, max) : '');
const toIso = v => { const t = typeof v === 'string' ? Date.parse(v) : NaN; return Number.isFinite(t) ? new Date(t).toISOString() : null; };
const intOrNull = v => (Number.isInteger(v) ? v : null);
async function readdirSafe(p) { try { return await fs.readdir(p, { withFileTypes: true }); } catch { return []; } }
async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }
const rootOf = env => env.stateRoot || null;

/** Whitelisted run object from a meta, or null when it is unusable (bad version, ids, status). */
export function parseMeta(o, task, ts) {
  if (!isObj(o) || o.version !== 1) return null;
  if (!STATUSES.includes(o.status)) return null;
  if (typeof o.project !== 'string' || !o.project) return null;
  if (typeof o.task === 'string' && o.task !== task) return null;
  const startedAt = toIso(o.startedAt);
  if (!startedAt) return null;
  return {
    taskId: task, ts, role: s(o.role, 40), class: s(o.class, 20), tool: s(o.tool, 40), model: s(o.model, 128), status: o.status,
    exit: intOrNull(o.exit), cliExit: intOrNull(o.cliExit), branch: s(o.branch, 200), worktree: s(o.worktree, 500), base: s(o.base, 64),
    experimental: o.experimental === true, writableCheck: s(o.writableCheck, 20),
    violations: Array.isArray(o.violations) ? o.violations.filter(x => typeof x === 'string').slice(0, 50).map(x => x.slice(0, 300)) : [],
    sessionId: typeof o.sessionId === 'string' ? o.sessionId.slice(0, 200) : null,
    _project: o.project, _title: s(o.title, 200), _startedAt: startedAt, _endedAt: toIso(o.endedAt),
  };
}

async function scan(env, { cache }) {
  const root = rootOf(env);
  const cutoff = env.now() - env.days * 86400000;
  let skipped = 0;
  const found = [];
  for (const pd of root ? await readdirSafe(root) : []) {
    if (!pd.isDirectory()) continue;
    for (const td of await readdirSafe(path.join(root, pd.name, 'runs'))) {
      if (!td.isDirectory() || !TASK_RE.test(td.name)) continue;
      const dir = path.join(root, pd.name, 'runs', td.name);
      for (const f of await readdirSafe(dir)) {
        const m = f.isFile() && META_RE.exec(f.name);
        if (m) found.push({ dir, task: td.name, ts: m[1], file: path.join(dir, f.name) });
      }
    }
  }
  const sessions = [];
  found.sort((a, b) => b.ts.localeCompare(a.ts));
  for (const r of found.slice(0, MAX_RUNS)) {
    try {
      const st = await statOrNull(r.file);
      if (!st || st.size > MAX_META) { skipped++; continue; }
      const key = 'm:' + r.file;
      let hit = cache.get(key);
      if (!hit || hit.size !== st.size || hit.mtimeMs !== st.mtimeMs) {
        let run = null;
        try { run = parseMeta(JSON.parse(await fs.readFile(r.file, 'utf8')), r.task, r.ts); } catch { run = null; }
        hit = { size: st.size, mtimeMs: st.mtimeMs, run };
        cache.set(key, hit);
      }
      const run = hit.run;
      if (!run) { skipped++; continue; }
      let newest = st.mtimeMs;
      if (run.status === 'running') {
        for (const ext of ['log', 'out']) { const x = await statOrNull(path.join(r.dir, `${r.ts}.${ext}`)); if (x && x.mtimeMs > newest) newest = x.mtimeMs; }
      }
      const newestIso = new Date(newest).toISOString();
      const ended = run._endedAt;
      if (run.status !== 'running' && newest < cutoff && (!ended || Date.parse(ended) < cutoff)) continue;
      let stateBasis;
      if (run.status === 'running') stateBasis = { kind: 'mtime', at: newestIso, stateSource: 'mtime' };
      else if (run.status === 'ok') stateBasis = { kind: 'fixed', state: 'finished', stateSource: 'field' };
      else stateBasis = { kind: 'fixed', state: 'failed', stateSource: 'field' };
      const { _project, _title, _startedAt, _endedAt, ...pub } = run;
      sessions.push({
        nativeId: `${r.task}.${r.ts}`, tool: 'subdeck-run', parentNativeId: null, depth: 0,
        projectPath: _project, projectLabel: null,
        title: clip(`${run.role || 'run'}: ${_title || r.task}`, 120), titleSource: 'meta',
        agentType: run.role || null, model: run.model || null,
        createdAt: _startedAt, runStartedAt: _startedAt, updatedAt: ended && Date.parse(ended) > newest ? ended : newestIso, endedAt: ended,
        tokens: { context: null, total: null }, lastActivity: null, taskId: r.task,
        refs: { file: r.file, db: null, key: null }, archived: false,
        ...(FAIL_KIND[run.status] ? { failure: { kind: FAIL_KIND[run.status], detail: `${run.status}${run.exit !== null ? ` (exit ${run.exit})` : ''}` } } : {}),
        run: pub, stateBasis,
      });
    } catch { skipped++; }
  }
  return { sessions, skipped, notes: [] };
}

async function detect(env) {
  const root = rootOf(env);
  if (!root) return false;
  for (const pd of await readdirSafe(root)) if (pd.isDirectory() && (await readdirSafe(path.join(root, pd.name, 'runs'))).length) return true;
  return false;
}

export default {
  tool: 'subdeck-run', label: 'SubDeck runs', toolShort: 'run', adapterVersion: '1', experimental: false,
  detect,
  watchPaths(env) { const r = rootOf(env); return r ? [{ path: r, recursive: true }] : []; },
  async scan(env, opts) {
    try { return await scan(env, { cache: (opts && opts.cache) || new Map() }); }
    catch (e) { return { sessions: [], skipped: 0, notes: ['subdeck-run scan failed: ' + (e && e.message)] }; }
  },
};
