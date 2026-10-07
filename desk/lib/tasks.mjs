// desk/lib/tasks.mjs
// SubDeck Tasks reader. Read-only; own tiny frontmatter parser, no YAML.
// Task files: <dir>/<id>.md (live), <dir>/archive/<id>.md (done). Dir rule: env SUBDECK_TASKS_DIR, config tasks.dir
// (project config before user config), else <state dir>/tasks.
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { stateDirs } from './paths.mjs';

export const TASK_ID_RE = /^t-[0-9a-f]{4,12}$/;
const FILE_RE = /^(t-[0-9a-f]{4,12})\.md$/;
export const STATUSES = ['open', 'in-progress', 'blocked', 'interrupted', 'review', 'done'];
const MAX_FILE = 2 * 1024 * 1024;
const MAX_LIVE = 500;
const MAX_ARCHIVE = 200;
const BODY_CAP = 200000;

/** Parses the restricted frontmatter. Returns { fm, body, ok } (ok false: no frontmatter block, whole text is the body). */
export function parseFrontmatter(text) {
  let s = String(text);
  if (s.charCodeAt(0) === 0xfeff) s = s.slice(1);
  const lines = s.split('\n').map(l => l.replace(/\r$/, ''));
  if (lines[0] !== '---') return { fm: {}, body: lines.join('\n'), ok: false };
  let end = -1;
  for (let i = 1; i < lines.length; i++) if (lines[i] === '---') { end = i; break; }
  if (end < 0) return { fm: {}, body: lines.join('\n'), ok: false };
  const fm = {};
  for (let i = 1; i < end; i++) {
    const l = lines[i];
    const c = l.indexOf(':');
    if (c < 1) continue;
    const k = l.slice(0, c);
    if (!/^[a-z][a-z-]*$/.test(k)) continue;
    fm[k] = l.slice(c + 1).trim();   // duplicate keys: last wins
  }
  return { fm, body: lines.slice(end + 1).join('\n'), ok: true };
}

/** `[a, b]`, `a, b`, `[]` or empty -> array of trimmed non-empty items. */
export function parseList(v) {
  let s = String(v === undefined || v === null ? '' : v).trim();
  if (s.startsWith('[') && s.endsWith(']')) s = s.slice(1, -1);
  return s.split(',').map(x => x.trim()).filter(Boolean);
}

/** Body sections: name (text after `## `, lower case) -> text. A section runs to the next line starting with `## `. */
export function parseSections(body) {
  const out = {};
  let cur = null;
  for (const l of String(body).split('\n')) {
    if (l.startsWith('## ')) { cur = l.slice(3).trim().toLowerCase(); if (!(cur in out)) out[cur] = []; continue; }
    if (cur !== null) out[cur].push(l);
  }
  const r = {};
  for (const k of Object.keys(out)) r[k] = out[k].join('\n');
  return r;
}

/** Latest `### <time> interrupted (<type>)` block of the Handoff section: { at, errorType, files } or null. */
export function parseHandoff(handoffText) {
  if (!handoffText) return null;
  const lines = String(handoffText).split('\n');
  let last = null;
  for (let i = 0; i < lines.length; i++) {
    const m = /^###\s+(\S+)\s+interrupted(?:\s+\(([^)]*)\))?\s*$/.exec(lines[i]);
    if (!m) continue;
    let files = null;
    for (let j = i + 1; j < lines.length && !lines[j].startsWith('### '); j++) {
      const f = /^files:\s*(\d+)\s*$/.exec(lines[j]);
      if (f) { files = Number(f[1]); break; }
    }
    last = { at: m[1], errorType: (m[2] || '').replace(/[^a-z_]/g, '') || 'unknown', files };
  }
  return last;
}

/** One task from file text. `id` comes from the file name. */
export function parseTask(text, id, { archived = false, file = null } = {}) {
  const { fm, body, ok } = parseFrontmatter(text);
  let status = fm.status || 'open';
  let invalid = !ok;
  if (!STATUSES.includes(status)) { status = 'open'; invalid = true; }
  const sections = parseSections(body);
  const handoff = parseHandoff(sections.handoff);
  const task = {
    id, title: fm.title || id, status, owner: fm.owner || '', agent: fm.agent || '', session: fm.session || '', transcript: fm.transcript || '',
    blockedBy: parseList(fm['blocked-by']), writable: parseList(fm.writable), created: fm.created || '', updated: fm.updated || '',
    archived, invalid, file,
  };
  return { task, body: body.length > BODY_CAP ? body.slice(0, BODY_CAP) : body, handoff };
}

// ---- directory resolution ----
function readJsonSync(f) { try { const o = JSON.parse(fsSync.readFileSync(f, 'utf8')); return o && typeof o === 'object' ? o : null; } catch { return null; } }
function cfgTasksDir(o) {
  const d = o && o.tasks && typeof o.tasks === 'object' ? o.tasks.dir : null;
  return typeof d === 'string' && d.trim() ? d.trim() : null;
}

/** Tasks dir of a project (absolute path). env is the Desk env ({ vars, home, platform, stateRoot }). */
export function resolveTasksDir(projectPath, env) {
  const e = env || {};
  const vars = e.vars || {};
  const sd = stateDirs(projectPath, e);
  let v = typeof vars.SUBDECK_TASKS_DIR === 'string' && vars.SUBDECK_TASKS_DIR ? vars.SUBDECK_TASKS_DIR : null;
  if (!v) {
    const cands = [];
    if (sd[0]) cands.push(path.join(sd[0], 'config.json'));
    cands.push(path.join(projectPath, '.subdeck', 'config.json'));
    for (const f of cands) { v = cfgTasksDir(readJsonSync(f)); if (v) break; }
  }
  if (!v && e.home) v = cfgTasksDir(readJsonSync(path.join(e.home, '.subdeck', 'config.json')));
  if (!v) return sd[0] ? path.join(sd[0], 'tasks') : path.join(projectPath, '.subdeck', 'tasks');
  v = v.replace(/\\/g, '/');
  const abs = path.posix.isAbsolute(v) || path.win32.isAbsolute(v);
  return abs ? path.normalize(v) : path.join(projectPath, v);
}

// ---- Beads bridge: opt-in (SUBDECK_BEADS=1), read-only, only when .beads/ exists and `bd` runs ----
const BEADS_STATUS = { open: 'open', in_progress: 'in-progress', 'in-progress': 'in-progress', blocked: 'blocked', deferred: 'blocked', closed: 'done', done: 'done', review: 'review' };
export function mapBeads(raw, projectPath) {
  const list = Array.isArray(raw) ? raw : raw && Array.isArray(raw.issues) ? raw.issues : [];
  const out = [];
  for (const b of list.slice(0, 500)) {
    if (!b || typeof b !== 'object' || typeof b.id !== 'string' || !/^[A-Za-z0-9._-]{1,64}$/.test(b.id)) continue;
    const st = BEADS_STATUS[String(b.status || 'open').toLowerCase()];
    const deps = Array.isArray(b.dependencies) ? b.dependencies.map(d => (typeof d === 'string' ? d : d && (d.depends_on_id || d.id))).filter(x => typeof x === 'string') : [];
    out.push({ task: {
      id: b.id, title: String(b.title || b.id).slice(0, 200), status: st || 'open', owner: typeof b.assignee === 'string' ? b.assignee : '', agent: '', session: '', transcript: '',
      blockedBy: deps, writable: [], created: typeof b.created_at === 'string' ? b.created_at : '', updated: typeof b.updated_at === 'string' ? b.updated_at : (typeof b.created_at === 'string' ? b.created_at : ''),
      archived: (st || 'open') === 'done', invalid: !st, file: null, source: 'beads',
    }, body: typeof b.description === 'string' ? b.description.slice(0, BODY_CAP) : '', handoff: null });
  }
  return out;
}

const inside = (p, dir) => { const r = path.relative(path.resolve(dir), path.resolve(p)); return r === '' || (!r.startsWith('..') && !path.isAbsolute(r)); };

/**
 * Absolute path of the bd executable, or null. An absolute `cmd` (SUBDECK_BD) is used as given; a bare name is looked up in
 * PATH only: relative PATH entries and entries inside the project are skipped, so a bd in the project or the cwd is never run.
 */
export function resolveBd(cmd, { pathVar = process.env.PATH || '', platform = process.platform, projectPath = null, exists = f => { try { return fsSync.statSync(f).isFile(); } catch { return false; } } } = {}) {
  const c = String(cmd || 'bd');
  const pp = platform === 'win32' ? path.win32 : path.posix;
  if (pp.isAbsolute(c)) return projectPath && inside(c, projectPath) ? null : (exists(c) ? c : null);
  if (/[\\/]/.test(c)) return null;
  const exts = platform === 'win32' ? ['.exe', '.com'] : [''];
  for (const d of pathVar.split(platform === 'win32' ? ';' : ':')) {
    if (!d || !pp.isAbsolute(d) || (projectPath && inside(d, projectPath))) continue;
    for (const e of exts) { const f = pp.join(d, c + e); if (exists(f)) return f; }
  }
  return null;
}

/** `bd list --json` for one project. The cwd must be the project (bd finds its database from it); BEADS_NO_DAEMON asks bd not to start a daemon. */
export function runBd(projectPath, { timeoutMs = 5000, cmd = process.env.SUBDECK_BD || 'bd', pathVar, platform } = {}) {
  return new Promise(resolve => {
    const exe = resolveBd(cmd, { pathVar, platform, projectPath });
    if (!exe) return resolve(null);
    let out = '', done = false, timer = null, child;
    const end = v => { if (!done) { done = true; clearTimeout(timer); resolve(v); } };
    try { child = spawn(exe, ['list', '--json'], { cwd: projectPath, env: { ...process.env, BEADS_NO_DAEMON: '1', BD_NO_DAEMON: '1' }, stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true }); } catch { return resolve(null); }
    timer = setTimeout(() => { try { child.kill(); } catch { /* gone */ } end(null); }, timeoutMs);
    child.stdout.on('data', c => { if (out.length < 4e6) out += c; });
    child.on('error', () => end(null));
    child.on('close', code => { if (code !== 0) return end(null); try { end(JSON.parse(out)); } catch { end(null); } });
  });
}

async function statOrNull(f) { try { return await fs.stat(f); } catch { return null; } }
async function lstatOrNull(f) { try { return await fs.lstat(f); } catch { return null; } }

/**
 * Reader with a per-file cache (size + mtime). beads: async (projectPath) -> raw bd JSON or null (default: runs `bd list --json`
 * when <project>/.beads exists); beadsTtlMs caches that answer per project.
 */
export function createTasksReader({ env = null, now = Date.now, beads = runBd, beadsTtlMs = 10000, beadsEnabled = null } = {}) {
  const beadsOn = beadsEnabled !== null ? !!beadsEnabled : ((env && env.vars && env.vars.SUBDECK_BEADS) || process.env.SUBDECK_BEADS) === '1';
  const cache = new Map();   // file -> { sig, parsed }
  const beadsCache = new Map();   // project path -> { at, items }

  async function listDir(dir, archived, cap) {
    let ents;
    try { ents = await fs.readdir(dir, { withFileTypes: true }); } catch { return []; }
    const files = [];
    for (const e of ents) {
      const m = FILE_RE.exec(e.name);
      if (!m || e.name.includes('.tmp')) continue;
      const f = path.join(dir, e.name);
      const st = await lstatOrNull(f);
      if (!st || !st.isFile() || st.size > MAX_FILE) continue;
      files.push({ id: m[1], file: f, st, archived });
    }
    files.sort((a, b) => b.st.mtimeMs - a.st.mtimeMs);
    return files.slice(0, cap);
  }

  async function load(f) {
    const sig = `${f.st.size}|${f.st.mtimeMs}`;
    const c = cache.get(f.file);
    if (c && c.sig === sig) return c.parsed;
    let text;
    try { text = await fs.readFile(f.file, 'utf8'); } catch { return null; }
    const parsed = parseTask(text, f.id, { archived: f.archived, file: f.file });
    cache.set(f.file, { sig, parsed });
    return parsed;
  }

  async function beadsItems(projectPath) {
    if (!beadsOn || !beads) return [];
    const b = await statOrNull(path.join(projectPath, '.beads'));
    if (!b || !b.isDirectory()) return [];
    const hit = beadsCache.get(projectPath);
    if (hit && now() - hit.at < beadsTtlMs) return hit.items;
    let items = [];
    try { const raw = await beads(projectPath); if (raw) items = mapBeads(raw, projectPath); } catch { /* bridge is optional */ }
    beadsCache.set(projectPath, { at: now(), items });
    return items;
  }

  return {
    dir(projectPath) { return resolveTasksDir(projectPath, env); },
    /** { dir, tasks: [{ task, handoff }] } newest update first; live files, then archive; beads items last. */
    async read(projectPath) {
      const dir = resolveTasksDir(projectPath, env);
      const files = [...await listDir(dir, false, MAX_LIVE), ...await listDir(path.join(dir, 'archive'), true, MAX_ARCHIVE)];
      const seen = new Set();
      const out = [];
      for (const f of files) {
        if (seen.has(f.id)) continue;   // a live file wins over a stale archive copy
        seen.add(f.id);
        const p = await load(f);
        if (p) out.push({ task: { ...p.task, source: 'subdeck' }, handoff: p.handoff });
      }
      const live = new Set(cache.keys());
      for (const k of live) if (!files.some(f => f.file === k) && k.startsWith(dir + path.sep)) cache.delete(k);
      for (const b of await beadsItems(projectPath)) out.push({ task: b.task, handoff: null });
      out.sort((a, b) => String(b.task.updated).localeCompare(String(a.task.updated)));
      return { dir, tasks: out };
    },
    /** One task with its markdown body, or null. */
    async get(projectPath, id) {
      if (TASK_ID_RE.test(id)) {
        const dir = resolveTasksDir(projectPath, env);
        for (const [d, archived] of [[dir, false], [path.join(dir, 'archive'), true]]) {
          const f = path.join(d, id + '.md');
          const st = await lstatOrNull(f);
          if (!st || !st.isFile() || st.size > MAX_FILE) continue;
          const p = await load({ id, file: f, st, archived });
          if (p) return { task: { ...p.task, source: 'subdeck' }, handoff: p.handoff, body: p.body };
        }
        return null;
      }
      const b = (await beadsItems(projectPath)).find(x => x.task.id === id);
      return b ? { task: b.task, handoff: null, body: b.body } : null;
    },
    /** Cheap change signature of a project's task dirs (names, sizes, mtimes). */
    async signature(projectPath) {
      const dir = resolveTasksDir(projectPath, env);
      const parts = [];
      for (const d of [dir, path.join(dir, 'archive')]) {
        let ents;
        try { ents = await fs.readdir(d, { withFileTypes: true }); } catch { parts.push('-'); continue; }
        for (const e of ents) {
          if (!FILE_RE.test(e.name)) continue;
          const st = await lstatOrNull(path.join(d, e.name));
          if (st) parts.push(`${d === dir ? '' : 'a/'}${e.name}|${st.size}|${st.mtimeMs}`);
        }
      }
      return parts.sort().join('\n');
    },
    dirs(projectPath) { const d = resolveTasksDir(projectPath, env); return [d, path.join(d, 'archive')]; },
  };
}

/**
 * Watches the task dirs of the known projects. A change (fs.watch, plus a polling check as fallback) calls
 * onChange([projectId...]). The first signature of a project is the baseline and fires nothing.
 */
export function createTasksWatcher({ reader, getProjects, onChange, pollMs = 5000, debounceMs = 300, watchFn = fsSync.watch }) {
  const sigs = new Map();     // project id -> signature
  const watchers = new Map(); // dir -> FSWatcher
  const dirOwners = new Map();// dir -> Set(project id)
  let timer = null, poll = null, closed = false, busy = false;
  const dirty = new Set();

  async function check(ids) {
    if (closed || busy) { for (const i of ids) dirty.add(i); return; }
    busy = true;
    try {
      const changed = [];
      for (const p of getProjects() || []) {
        if (!p.path || (ids && !ids.includes(p.id))) continue;
        let s;
        try { s = await reader.signature(p.path); } catch { continue; }
        const was = sigs.get(p.id);
        sigs.set(p.id, s);
        if (was !== undefined && was !== s) changed.push(p.id);
      }
      if (changed.length && !closed) { try { onChange(changed); } catch { /* listener errors never stop the watcher */ } }
    } finally { busy = false; }
    if (dirty.size) { const d = [...dirty]; dirty.clear(); check(d); }
  }

  function schedule(ids) {
    if (closed) return;
    for (const i of ids) dirty.add(i);
    clearTimeout(timer);
    timer = setTimeout(() => { const d = [...dirty]; dirty.clear(); check(d); }, debounceMs);
  }

  /** Re-resolves dirs: watches new ones, closes obsolete ones. Call after scans. */
  function update() {
    if (closed) return;
    const want = new Map();
    for (const p of getProjects() || []) {
      if (!p.path) continue;
      for (const d of reader.dirs(p.path)) { if (!want.has(d)) want.set(d, new Set()); want.get(d).add(p.id); }
    }
    for (const [d, w] of watchers) if (!want.has(d)) { try { w.close(); } catch { /* ignore */ } watchers.delete(d); }
    dirOwners.clear();
    for (const [d, ids] of want) {
      dirOwners.set(d, ids);
      if (watchers.has(d)) continue;
      try {
        const w = watchFn(d, { persistent: false }, () => schedule([...(dirOwners.get(d) || [])]));
        w.on('error', () => { try { w.close(); } catch { /* ignore */ } watchers.delete(d); });
        watchers.set(d, w);
      } catch { /* dir absent: the poll catches it, the next update() retries */ }
    }
  }

  update();
  check(null);   // baseline
  poll = setInterval(() => { update(); check(null); }, pollMs);
  if (poll.unref) poll.unref();

  return { update, check: () => check(null), close() {
    closed = true; clearTimeout(timer); clearInterval(poll);
    for (const w of watchers.values()) { try { w.close(); } catch { /* ignore */ } }
    watchers.clear();
  } };
}
