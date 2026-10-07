// desk/lib/api.mjs
// Pure request handling for Desk (spec section 8). No sockets here; server.mjs wires it to node:http.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import fsSync from 'node:fs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readNotifyEnabled, writeNotifyEnabled } from './notify-settings.mjs';
import { projectKey, relativeTo, isSecretPath, stateDirs } from './paths.mjs';
import { showCommit, HASH_RE } from './git.mjs';
import { createTasksReader } from './tasks.mjs';

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/format.js': ['format.js', 'text/javascript; charset=utf-8'],
  '/favicon.svg': ['favicon.svg', 'image/svg+xml'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
  '/theme.js': ['theme.js', 'text/javascript; charset=utf-8'],
  '/settings.js': ['settings.js', 'text/javascript; charset=utf-8'],
  '/tasks.js': ['tasks.js', 'text/javascript; charset=utf-8'],
  '/runs.js': ['runs.js', 'text/javascript; charset=utf-8'],
};
const CSP = "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:";
const JSON_HEADERS = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

// ---- settings: Desk never writes config files; it runs settings.sh (json / set) ----
const SETTINGS_SH = fileURLToPath(new URL('../../plugins/subdeck/scripts/settings.sh', import.meta.url));
function findBash() {
  if (process.env.SUBDECK_BASH) return process.env.SUBDECK_BASH;
  if (process.platform === 'win32') {
    for (const b of [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Programs')]) {
      if (!b) continue;
      const f = path.join(b, 'Git', 'bin', 'bash.exe');
      if (fsSync.existsSync(f)) return f;
    }
  }
  return 'bash';
}
/** Runs `bash settings.sh <args>`; never through a shell. Resolves { code, stdout, stderr }; never rejects. */
export function runSettingsSh(args, { home = null, script = SETTINGS_SH, timeoutMs = 60000 } = {}) {
  return new Promise(resolve => {
    const env = { ...process.env };
    if (home) { env.HOME = home; env.USERPROFILE = home; }
    let out = '', err = '', done = false, timer = null;
    const end = r => { if (!done) { done = true; clearTimeout(timer); resolve(r); } };
    let child;
    try { child = spawn(findBash(), [script.replace(/\\/g, '/'), ...args], { env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true }); }
    catch (e) { return resolve({ code: 127, stdout: '', stderr: String(e && e.message) }); }
    timer = setTimeout(() => { try { child.kill(); } catch { /* gone */ } end({ code: 124, stdout: out, stderr: 'settings.sh timed out' }); }, timeoutMs);
    child.stdout.on('data', c => { if (out.length < 1e6) out += c; });
    child.stderr.on('data', c => { if (err.length < 1e5) err += c; });
    child.on('error', e => end({ code: 127, stdout: '', stderr: String(e && e.message) }));
    child.on('close', code => end({ code: code === null ? 1 : code, stdout: out, stderr: err }));
  });
}
const SETTING_KEY_RE = /^[A-Za-z][A-Za-z0-9._-]{0,63}$/;

export function createApi({ core, getPort, startedAt, days, version, publicDir, now = Date.now, maxStreams = 32, contentEnabled = true, adapters = [], env = null, configFile = null, gitShow = null, settingsRun = null, tasks = null, token = crypto.randomBytes(24).toString('hex') }) {
  const streams = new Set();
  const reader = tasks || createTasksReader({ env });
  const iso = () => new Date(now()).toISOString();

  function json(res, status, obj) { res.writeHead(status, JSON_HEADERS); res.end(JSON.stringify(obj)); }

  function hostOk(h) {
    if (typeof h !== 'string') return false;
    const v = h.toLowerCase();
    const p = getPort();
    return v === `127.0.0.1:${p}` || v === `localhost:${p}`;
  }

  // task ids of a project whose work was accepted: archived/done, or the latest verdict is Approved
  async function acceptedIds(snap, projectId) {
    const p = snap.projects.find(x => x.id === projectId);
    if (!p || !p.path || !snap.sessions.some(s => s.projectId === projectId && s.taskId)) return new Set();
    try {
      const r = await reader.read(p.path);
      return new Set(r.tasks.filter(t => t.task.archived || t.task.status === 'done' || t.task.verdict === 'Approved').map(t => t.task.id));
    } catch { return new Set(); }
  }

  async function projectTree(snap, id) {
    const project = snap.projects.find(p => p.id === id);
    if (!project) return null;
    const acc = await acceptedIds(snap, id);
    const own = snap.sessions.filter(s => s.projectId === id).map(s => (s.taskId && acc.has(s.taskId) ? { ...s, accepted: true } : s));
    const w = x => (x.state === 'waiting' ? 1 : 0);   // blocked-on-user first
    const byUpdated = (a, b) => w(b) - w(a) || String(b.updatedAt).localeCompare(String(a.updatedAt));
    const childOrder = (a, b) => w(b) - w(a) || (b.state === 'running') - (a.state === 'running') || String(b.createdAt).localeCompare(String(a.createdAt));
    const sessions = own.filter(s => !s.parentId).sort(byUpdated).map(s => ({
      ...s, children: own.filter(c => c.parentId === s.id).sort(childOrder).map(c => ({ ...c, children: [] })),
    }));
    return { generatedAt: iso(), project, sessions };
  }

  // Everything blocked on the user, across projects and tools. Titles and metadata only, never prompt content.
  function waitingList(snap) {
    // sessions blocked on the user, plus agents that stopped without a report or were interrupted (their state is unchanged)
    const kindOf = s => (s.state === 'waiting' ? (s.waitingKind ?? null) : s.reportMissing ? 'no-report' : 'interrupted');
    const sinceOf = s => (s.state === 'waiting' ? (s.waitingSince ?? s.updatedAt ?? null) : (s.reportMissing || s.interrupted).at);
    const items = snap.sessions.filter(s => s.state === 'waiting' || s.reportMissing || s.interrupted).map(s => {
      const p = snap.projects.find(x => x.id === s.projectId);
      return { id: s.id, projectId: s.projectId, projectName: p ? p.name : null, projectPath: p ? p.path : null, tool: s.tool, title: s.title,
        agentType: s.agentType ?? null, isAgent: !!s.parentId, stateSource: s.stateSource, waitingKind: kindOf(s), since: sinceOf(s),
        ...(s.state !== 'waiting' ? { taskId: (s.reportMissing && s.reportMissing.task) || (s.interrupted && s.interrupted.task) || null } : {}) };
    }).sort((a, b) => String(a.since).localeCompare(String(b.since)));
    return { generatedAt: iso(), items };
  }

  // ---- tasks (read-only): files of the tasks dir, optional Beads items ----
  async function tasksList(res, snap, only) {
    runsNow = lastRuns(snap);
    const projs = snap.projects.filter(p => p.path && (!only || p.id === only));
    if (only && !projs.length) return json(res, 404, { error: 'not found' });
    const out = [];
    for (const p of projs) {
      let r;
      try { r = await reader.read(p.path); } catch { r = { dir: reader.dir(p.path), tasks: [] }; }
      const bySession = new Map(snap.sessions.filter(x => x.projectId === p.id && x.parentId).map(x => [x.nativeId, x.id]));
      let sm = null;
      try { sm = await reader.summary(p.path, now()); } catch { /* events are optional */ }
      const tasks = r.tasks.map(t => taskOut(t, bySession, p.id));
      const waves = annotate(tasks, snap.sessions.filter(x => x.projectId === p.id && x.parentId), sm ? sm.verifies : []);
      out.push({ projectId: p.id, projectName: p.name, dir: r.dir, tasks, waves, quota: sm ? sm.quota : null, cli: sm ? sm.cli : { calls: 0, bytes: 0, since: null } });
    }
    return json(res, 200, { generatedAt: iso(), projects: out });
  }
  // Adds verifiedBy, wave and tokens to the task objects (in place); returns the project's waves.
  function annotate(tasks, agents, verifies) {
    const byId = new Map(tasks.map(t => [t.id, t]));
    const parent = new Map(tasks.map(t => [t.id, t.id]));
    const find = x => { while (parent.get(x) !== x) { parent.set(x, parent.get(parent.get(x))); x = parent.get(x); } return x; };
    const union = (a, b) => { if (byId.has(a) && byId.has(b)) parent.set(find(a), find(b)); };
    const packFirst = new Map();
    for (const t of tasks) {
      if (t.pack) { if (packFirst.has(t.pack)) union(t.id, packFirst.get(t.pack)); else packFirst.set(t.pack, t.id); }
      for (const c of t.covers || []) union(t.id, c);
    }
    const comp = new Map();
    for (const t of tasks) { const k = find(t.id); if (!comp.has(k)) comp.set(k, []); comp.get(k).push(t); }
    const tokOf = a => { const v = a.tokens && (a.tokens.total ?? a.tokens.context); return Number.isFinite(v) ? v : null; };
    const sum = list => { let n = null; for (const a of list) { const v = tokOf(a); if (v !== null) n = (n || 0) + v; } return n; };
    const agentByNative = new Map(agents.map(a => [a.nativeId, a]));
    const waves = [];
    for (const members of comp.values()) {
      const ids = members.map(t => t.id).sort();
      const packs = members.map(t => t.pack).filter(Boolean).sort();
      const linked = packs.length || members.some(t => (t.covers || []).length) || members.length > 1;
      const id = packs.length ? packs[0] : `covers:${ids[0]}`;
      for (const t of members) t.wave = linked ? id : null;
      const set = new Set(ids);
      const ag = new Map();
      for (const a of agents) if (a.taskId && set.has(a.taskId)) ag.set(a.nativeId, a);
      for (const v of verifies) if (v.by && (set.has(v.task) || v.covers.some(c => set.has(c))) && agentByNative.has(v.by)) ag.set(v.by, agentByNative.get(v.by));
      if (linked) waves.push({ id, tasks: ids, agents: ag.size, tokens: sum([...ag.values()]) });
    }
    for (const t of tasks) {
      const mine = agents.filter(a => a.taskId === t.id);
      t.tokens = mine.length ? sum(mine) : null;
      let best = t.verifiedBy ? { ...t.verifiedBy, t: Date.parse(t.verifiedBy.at) } : null;
      for (const v of verifies) if ((v.task === t.id || v.covers.includes(t.id)) && (!best || !(best.t > v.t))) best = { by: v.by, fingerprint: v.fingerprint, at: v.at, t: v.t };
      t.verifiedBy = best ? { by: best.by, fingerprint: best.fingerprint, at: best.at } : null;
      if (!('wave' in t)) t.wave = null;
    }
    return waves.sort((a, b) => a.id.localeCompare(b.id));
  }
  // newest run of each task (project id + task id -> run session), from the subdeck-run source
  function lastRuns(snap) {
    const m = new Map();
    for (const s of snap.sessions) {
      if (s.tool !== 'subdeck-run' || !s.run) continue;
      const k = `${s.projectId}/${s.run.taskId}`;
      const was = m.get(k);
      if (!was || s.run.ts > was.ts) m.set(k, s.run);
    }
    return m;
  }
  let runsNow = new Map();
  function taskOut(t, bySession, pid) {
    const r = runsNow.get(`${pid}/${t.task.id}`);
    return { auto: false, pack: '', grants: [], covers: [], verdict: '', verifiedBy: null, wave: null, tokens: null, ...t.task, agentSessionId: (t.task.agent && bySession.get(t.task.agent)) || null, handoff: t.handoff || null,
      lastRun: r ? { ts: r.ts, status: r.status, role: r.role, tool: r.tool, model: r.model } : null };
  }
  // ---- runs (read-only): metas come from the subdeck-run source; logs are read on demand ----
  const RUN_TASK_RE = /^t-[0-9a-f]{4,12}$/, RUN_TS_RE = /^\d{8}T\d{6}Z$/;
  function runsList(res, snap, only) {
    if (only && !snap.projects.some(p => p.id === only)) return json(res, 404, { error: 'not found' });
    const runs = snap.sessions.filter(s => s.tool === 'subdeck-run' && s.run && (!only || s.projectId === only))
      .sort((a, b) => b.run.ts.localeCompare(a.run.ts) || String(a.run.taskId).localeCompare(String(b.run.taskId))).slice(0, 200)
      .map(s => ({ projectId: s.projectId, taskId: s.run.taskId, ts: s.run.ts, role: s.run.role, tool: s.run.tool, model: s.run.model, status: s.run.status,
        exit: s.run.exit, startedAt: s.runStartedAt, endedAt: s.endedAt, branch: s.run.branch, sessionId: s.id }));
    return json(res, 200, { generatedAt: iso(), runs });
  }
  async function tailLines(file, n) {
    let fh;
    try {
      const st = await fs.lstat(file);
      if (!st.isFile()) return { text: '', truncated: false };
      fh = await fs.open(file, 'r');
      const cap = 512 * 1024, len = Math.min(st.size, cap), buf = Buffer.alloc(len);
      await fh.read(buf, 0, len, st.size - len);
      let lines = buf.toString('utf8').split('\n');
      let truncated = st.size > len;
      if (truncated) lines.shift();   // first line is probably cut
      if (lines.length && lines[lines.length - 1] === '') lines.pop();
      if (lines.length > n) { lines = lines.slice(-n); truncated = true; }
      return { text: lines.join('\n'), truncated };
    } catch { return { text: '', truncated: false }; }
    finally { if (fh) await fh.close().catch(() => {}); }
  }
  async function runLog(res, snap, projectId, taskId, ts, linesParam) {
    if (!contentEnabled) return json(res, 404, { error: 'content disabled' });
    if (!RUN_TASK_RE.test(taskId) || !RUN_TS_RE.test(ts)) return json(res, 404, { error: 'not found' });
    const s = snap.sessions.find(x => x.tool === 'subdeck-run' && x.projectId === projectId && x.run && x.run.taskId === taskId && x.run.ts === ts);
    const meta = s && s.refs && s.refs.file;
    if (!meta) return json(res, 404, { error: 'not found' });
    let n = Number(linesParam === null || linesParam === undefined || linesParam === '' ? 200 : linesParam);
    if (!Number.isInteger(n) || n < 1) n = 200;
    n = Math.min(n, 2000);
    const base = meta.replace(/\.json$/, '');   // <dir>/<ts>
    const [log, out] = await Promise.all([tailLines(`${base}.log`, n), tailLines(`${base}.out`, n)]);
    let final = null;
    try {
      const f = `${base}.final.txt`;
      const st = await fs.lstat(f);
      if (st.isFile()) final = (await fs.readFile(f, 'utf8')).slice(0, 65536);
    } catch { /* no final message */ }
    return json(res, 200, { log: log.text, out: out.text, final, truncated: log.truncated || out.truncated });
  }
  async function taskDetail(res, snap, projectId, taskId) {
    if (!contentEnabled) return json(res, 404, { error: 'content disabled' });
    const p = snap.projects.find(x => x.id === projectId);
    if (!p || !p.path) return json(res, 404, { error: 'not found' });
    runsNow = lastRuns(snap);
    const t = await reader.get(p.path, taskId);
    if (!t) return json(res, 404, { error: 'not found' });
    const bySession = new Map(snap.sessions.filter(x => x.projectId === p.id && x.parentId).map(x => [x.nativeId, x.id]));
    return json(res, 200, { task: { ...taskOut(t, bySession, p.id), body: t.body } });
  }

  async function sessionDetail(snap, id) {
    let s = snap.sessions.find(x => x.id === id);
    if (!s) return null;
    if (s.taskId && (await acceptedIds(snap, s.projectId)).has(s.taskId)) s = { ...s, accepted: true };
    const p = snap.projects.find(x => x.id === s.projectId);
    const parent = s.parentId ? snap.sessions.find(x => x.id === s.parentId) : null;
    return { generatedAt: iso(), session: { ...s,
      project: p ? { id: p.id, name: p.name, path: p.path } : null,
      parent: parent ? { id: parent.id, title: parent.title } : null,
      children: snap.sessions.filter(x => x.parentId === s.id).map(x => ({ id: x.id, title: x.title, state: x.state })) } };
  }

  function openStream(res) {
    if (streams.size >= maxStreams) return json(res, 503, { error: 'too many streams' });
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive', 'X-Content-Type-Options': 'nosniff' });
    res.write('retry: 3000\n\n');
    res.write(`event: hello\ndata: ${JSON.stringify({ at: iso(), lastScanAt: core.snapshot().lastScanAt })}\n\n`);
    streams.add(res);
    res.on('close', () => streams.delete(res));
  }

  const TOKEN_HEADER = 'x-subdeck-token';
  function tokenOk(h) {
    if (typeof h !== 'string' || h.length !== token.length) return false;
    return crypto.timingSafeEqual(Buffer.from(h), Buffer.from(token));
  }
  function originOk(origin) {   // browsers send Origin on POST; if present it must be this server
    if (origin === undefined) return true;
    const p = getPort();
    return origin === `http://127.0.0.1:${p}` || origin === `http://localhost:${p}`;
  }
  function readBody(req, limit = 1024) {
    return new Promise((resolve, reject) => {
      let n = 0; const chunks = [];
      req.on('data', c => { n += c.length; if (n > limit) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
      req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      req.on('error', reject);
    });
  }

  // Projects whose own project config (state dir, else legacy .subdeck/config.json) sets notify.enabled; the project value wins over the user config, so the bell cannot change it.
  async function projectOverrides() {
    const out = [];
    const mine = path.resolve(configFile);
    for (const p of core.snapshot().projects || []) {
      if (!p.path || out.length >= 20) continue;
      // project config: state dir first (wins), then a legacy <project>/.subdeck/config.json
      const dirs = env ? stateDirs(p.path, env) : [path.join(p.path, '.subdeck')];
      for (const d of dirs) {
        const file = path.join(d, 'config.json');
        if (path.resolve(file) === mine) continue;
        try {
          const o = JSON.parse(await fs.readFile(file, 'utf8'));
          if (o && typeof o === 'object' && o.notify && typeof o.notify === 'object' && typeof o.notify.enabled === 'boolean') { out.push({ project: p.name, file, enabled: o.notify.enabled }); break; }
        } catch { /* absent or unreadable: no override */ }
      }
    }
    return out;
  }

  async function notifySettings(req, res) {
    if (!configFile) return json(res, 404, { error: 'not found' });
    if (req.method === 'GET') {
      const r = readNotifyEnabled(configFile);
      return r.ok ? json(res, 200, { enabled: r.enabled, overriddenBy: await projectOverrides() }) : json(res, 500, { error: r.error });
    }
    if (!originOk(req.headers.origin)) return json(res, 403, { error: 'forbidden origin' });
    if (!tokenOk(req.headers[TOKEN_HEADER])) return json(res, 403, { error: 'missing or wrong token' });
    if (!/^application\/json\s*(;|$)/i.test(String(req.headers['content-type'] || ''))) return json(res, 415, { error: 'content-type must be application/json' });
    let body;
    try { body = JSON.parse(await readBody(req)); } catch { return json(res, 400, { error: 'invalid body' }); }
    if (!body || typeof body !== 'object' || Array.isArray(body) || typeof body.enabled !== 'boolean' || Object.keys(body).length !== 1) return json(res, 400, { error: 'body must be {"enabled": true|false}' });
    const w = writeNotifyEnabled(configFile, body.enabled);
    settingsGen++; settingsCache.clear();   // the Settings tab reads this value; never serve a stale cached copy
    return w.ok ? json(res, 200, { enabled: w.enabled }) : json(res, 500, { error: w.error });
  }

  // Shared guard for every browser write: Origin, per-start token, JSON content type, bounded JSON object body. Returns the body, or null after answering.
  async function guardedBody(req, res) {
    if (!originOk(req.headers.origin)) { json(res, 403, { error: 'forbidden origin' }); return null; }
    if (!tokenOk(req.headers[TOKEN_HEADER])) { json(res, 403, { error: 'missing or wrong token' }); return null; }
    if (!/^application\/json\s*(;|$)/i.test(String(req.headers['content-type'] || ''))) { json(res, 415, { error: 'content-type must be application/json' }); return null; }
    let body;
    try { body = JSON.parse(await readBody(req, 8192)); } catch { json(res, 400, { error: 'invalid body' }); return null; }
    if (!body || typeof body !== 'object' || Array.isArray(body)) { json(res, 400, { error: 'invalid body' }); return null; }
    return body;
  }
  const runSettings = settingsRun || (args => runSettingsSh(args, { home: env && env.home }));
  // A project is addressed by its Desk project id and mapped to the path Desk already knows; no client-supplied paths.
  function projectArgs(id) {
    if (id === null || id === undefined || id === '') return { args: [] };
    const p = typeof id === 'string' ? (core.snapshot().projects || []).find(x => x.id === id) : null;
    return p && p.path ? { args: ['--project', p.path] } : { error: 'unknown project' };
  }
  const settingsCache = new Map(), settingsInflight = new Map(); let settingsGen = 0, setChain = Promise.resolve();
  const SETTINGS_TTL_MS = 30000;
  const firstLine = (t, d) => (String(t).trim().split('\n')[0] || d).replace(/\r/g, '').slice(0, 300);

  async function settings(req, res, url) {
    if (req.method === 'GET') {
      const pa = projectArgs(url.searchParams.get('project'));
      if (pa.error) return json(res, 404, { error: pa.error });
      const gen0 = settingsGen;
      // settings.sh can take several seconds on some systems: one run per scope at a time, answers cached briefly, cleared by every write.
      const key = pa.args[1] || '';
      const hit = settingsCache.get(key);
      if (hit && now() - hit.at < SETTINGS_TTL_MS) return json(res, 200, hit.data);
      let run = settingsInflight.get(key);
      if (!run) {
        run = (async () => {
          const r = await runSettings(['json', ...pa.args]);
          if (r.code !== 0) return { status: 502, error: firstLine(r.stderr, 'settings.sh failed') };
          let d;
          try { d = JSON.parse(r.stdout); } catch { return { status: 502, error: 'settings.sh returned invalid JSON' }; }
          if (!d || !Array.isArray(d.settings)) return { status: 502, error: 'settings.sh returned an unexpected shape' };
          return { status: 200, data: d };
        })().finally(() => settingsInflight.delete(key));
        settingsInflight.set(key, run);
      }
      const out = await run;
      if (out.status !== 200) return json(res, out.status, { error: out.error });
      if (settingsGen === gen0) settingsCache.set(key, { at: now(), data: out.data });
      return json(res, 200, out.data);
    }
    const body = await guardedBody(req, res);
    if (!body) return;
    const set = body.set;
    if (!set || typeof set !== 'object' || Array.isArray(set) || Object.keys(body).some(k => k !== 'set' && k !== 'project')) return json(res, 400, { error: 'body must be {"set": {key: value}, "project": id|null}' });
    const keys = Object.keys(set);
    if (!keys.length || keys.length > 20) return json(res, 400, { error: 'set needs 1-20 keys' });
    const pairs = [];
    for (const k of keys) {
      const v = set[k];
      if (!SETTING_KEY_RE.test(k) || k === 'statusline') return json(res, 400, { error: `key not writable from Desk: ${k.slice(0, 40)}` });
      const val = typeof v === 'number' && Number.isInteger(v) ? String(v) : v;
      if (typeof val !== 'string' || val.length > 500 || /[\0\r\n]/.test(val)) return json(res, 400, { error: `invalid value for ${k}` });
      pairs.push(`${k}=${val}`);
    }
    const pa = projectArgs(body.project);
    if (pa.error) return json(res, 404, { error: pa.error });
    const prev = setChain;   // writes run one at a time
    let release; setChain = new Promise(r => { release = r; });
    await prev;
    let r;
    try { r = await runSettings(['set', ...pairs, ...pa.args]); } finally { release(); }
    settingsGen++; settingsCache.clear();
    if (r.code !== 0) return json(res, 422, { error: firstLine(r.stderr, 'settings.sh rejected the change') });
    return json(res, 200, { ok: true });
  }

  async function serveStatic(req, res, entry) {
    const [file, type] = entry;
    let data;
    try { data = await fs.readFile(path.join(publicDir, file)); } catch { return json(res, 404, { error: 'not found' }); }
    if (file === 'index.html') data = Buffer.from(data.toString('utf8').replace('__SUBDECK_TOKEN__', token));
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store', 'Content-Security-Policy': CSP, 'X-Content-Type-Options': 'nosniff' });
    res.end(req.method === 'HEAD' ? undefined : data);
  }

  // ---- changed files: read on demand from the transcript, never stored; same switch as the content endpoint ----
  const CHANGES_MAX_AGENTS = 40;
  const platform = () => (env && env.platform) || process.platform;
  const overlaps = (a, b) => !!(a.firstAt && b.firstAt && Date.parse(a.firstAt) <= Date.parse(b.lastAt) && Date.parse(b.firstAt) <= Date.parse(a.lastAt));

  async function changes(res, snap, id, one, filePath, commitHash) {
    if (!contentEnabled) return json(res, 404, { error: 'content disabled' });
    const s = snap.sessions.find(x => x.id === id);
    if (!s) return json(res, 404, { error: 'not found' });
    const a = adapters.find(x => x.tool === s.tool);
    if (!a || typeof a.changes !== 'function') return json(res, 501, { error: 'changed files not available for this tool' });
    const proj = snap.projects.find(x => x.id === s.projectId);
    const rel = fp => (proj && proj.path ? relativeTo(fp, proj.path, platform()) : null);
    if (one === 'commit') {
      // only hashes found in this agent's own transcript can be queried; never an arbitrary ref
      const h = typeof commitHash === 'string' ? commitHash.toLowerCase() : '';
      if (!HASH_RE.test(h)) return json(res, 400, { error: 'hash required' });
      const list = typeof a.commits === 'function' ? await a.commits(env, s) : null;
      const c = (list || []).find(x => x.hash.toLowerCase() === h);
      if (!c) return json(res, 404, { error: 'not found' });
      const g = await (gitShow || showCommit)(proj && proj.path, c.hash);
      return json(res, 200, g.ok ? { ...g, found: c.hash } : { ok: false, reason: g.reason, hash: c.hash });
    }
    if (one) {
      if (typeof filePath !== 'string' || !filePath || filePath.length > 1024 || filePath.includes('\0')) return json(res, 400, { error: 'path required' });
      if (isSecretPath(filePath)) return json(res, 200, { path: filePath, rel: rel(filePath), edits: [], total: 0, truncated: false, withheld: true });
      const d = typeof a.changeFile === 'function' ? await a.changeFile(env, s, filePath) : null;   // only paths present in the transcript can match
      return d ? json(res, 200, { ...d, rel: rel(d.path), withheld: false }) : json(res, 404, { error: 'not found' });
    }
    const own = await a.changes(env, s);
    if (!own) return json(res, 404, { error: 'not found' });
    // everyone in the session tree (the top session and its agents): who touched which file
    const rootId = s.parentId || s.id;
    const tree = snap.sessions.filter(x => x.tool === s.tool && (x.id === rootId || x.parentId === rootId)).slice(0, CHANGES_MAX_AGENTS);
    if (!tree.some(x => x.id === s.id)) tree.push(s);
    const byKey = new Map();   // normalized path -> [{ id, title, firstAt, lastAt }]
    for (const t of tree) {
      const l = t.id === s.id ? own : await a.changes(env, t);
      if (!l) continue;
      for (const f of l.files) {
        const k = projectKey(f.path, platform());
        if (!byKey.has(k)) byKey.set(k, { path: f.path, by: [] });
        byKey.get(k).by.push({ id: t.id, title: t.title, firstAt: f.firstAt, lastAt: f.lastAt });
      }
    }
    // commits made through the agent's Bash `git commit` calls; files seen only there are marked via commit
    const cl = (typeof a.commits === 'function' ? await a.commits(env, s) : null) || [];
    const absOf = p => (path.win32.isAbsolute(p) || path.posix.isAbsolute(p) || !(proj && proj.path) ? p : path.join(proj.path, p));
    const known = new Set(own.files.map(f => projectKey(f.path, platform())));
    const viaFiles = new Map();
    const commits = cl.map(c => {
      const files = c.paths.filter(p => !/[*?[]|^:/.test(p)).map(p => absOf(p));
      for (const p of files) {
        const k = projectKey(p, platform());
        if (known.has(k)) continue;
        let v = viaFiles.get(k);
        if (!v) { v = { path: p, rel: rel(p), count: 0, firstAt: c.at, lastAt: c.at, kinds: ['commit'], via: 'commit', secret: isSecretPath(p), alsoBy: [], commits: [] }; viaFiles.set(k, v); }
        v.lastAt = c.at; v.commits.push(c.hash);
      }
      return { hash: c.hash, subject: c.subject, at: c.at, files: c.paths.map(p => { const a = absOf(p); return rel(a) || p; }) };
    });
    const files = own.files.map(f => {
      const others = (byKey.get(projectKey(f.path, platform())) || { by: [] }).by.filter(x => x.id !== s.id);
      const me = own.files.find(x => x.path === f.path);
      return { ...f, rel: rel(f.path), secret: isSecretPath(f.path), alsoBy: others.map(x => ({ id: x.id, title: x.title, parallel: overlaps(f, x) })) };
    });
    const conflicts = [...byKey.values()].filter(c => c.by.length >= 2 && (s.id === rootId || c.by.some(x => x.id === s.id)))
      .map(c => ({ path: c.path, rel: rel(c.path), agents: c.by.map(x => ({ id: x.id, title: x.title })),
        parallel: c.by.some((x, i) => c.by.some((y, j) => j > i && overlaps(x, y))) }));
    return json(res, 200, { generatedAt: iso(), files: [...files, ...viaFiles.values()], commits, conflicts, agentsChecked: tree.length });
  }

  async function handle(req, res) {
    try {
      if (!hostOk(req.headers && req.headers.host)) return json(res, 403, { error: 'forbidden host' });
      const url = new URL(req.url, 'http://127.0.0.1');
      const p = url.pathname;
      if (p === '/api/settings' && (req.method === 'GET' || req.method === 'POST')) return await settings(req, res, url);
      if (p === '/api/settings/notify' && (req.method === 'GET' || req.method === 'POST')) return await notifySettings(req, res);
      if (req.method !== 'GET' && req.method !== 'HEAD') return json(res, 405, { error: 'method not allowed' });
      if (STATIC[p]) return await serveStatic(req, res, STATIC[p]);
      if (req.method === 'HEAD') return json(res, 405, { error: 'method not allowed' });
      const snap = core.snapshot();
      let m;
      if (p === '/api/sources') return json(res, 200, { generatedAt: iso(), server: { version, startedAt, days }, home: (env && env.home) || os.homedir(), sources: snap.sources });
      if (p === '/api/tasks') { const q = url.searchParams.get('project'); return await tasksList(res, snap, q === null ? null : q); }
      if (p === '/api/runs') return runsList(res, snap, url.searchParams.get('project') || null);
      m = /^\/api\/runs\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)\/log$/.exec(p);
      if (m) return await runLog(res, snap, m[1], m[2], m[3], url.searchParams.get('lines'));
      m = /^\/api\/tasks\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)$/.exec(p);
      if (m) return await taskDetail(res, snap, m[1], m[2]);
      if (p === '/api/waiting') return json(res, 200, waitingList(snap));
      if (p === '/api/projects') return json(res, 200, { generatedAt: iso(), projects: snap.projects });
      if (p === '/api/stream') return openStream(res);
      m = /^\/api\/projects\/([A-Za-z0-9._-]+)$/.exec(p);
      if (m) { const t = await projectTree(snap, m[1]); return t ? json(res, 200, t) : json(res, 404, { error: 'not found' }); }
      m = /^\/api\/sessions\/([A-Za-z0-9._-]+)$/.exec(p);
      if (m) { const d = await sessionDetail(snap, m[1]); return d ? json(res, 200, d) : json(res, 404, { error: 'not found' }); }
      m = /^\/api\/sessions\/([A-Za-z0-9._-]+)\/content$/.exec(p);
      if (m) {
        if (!contentEnabled) return json(res, 404, { error: 'content disabled' });
        const s = snap.sessions.find(x => x.id === m[1]);
        if (!s) return json(res, 404, { error: 'not found' });
        const a = adapters.find(x => x.tool === s.tool);
        if (!a || typeof a.timeline !== 'function') return json(res, 501, { error: 'content not available for this tool' });
        const data = await a.timeline(env, s);   // read on demand; never stored
        return data ? json(res, 200, data) : json(res, 404, { error: 'not found' });
      }
      m = /^\/api\/sessions\/([A-Za-z0-9._-]+)\/changes(?:\/(file|commit))?$/.exec(p);
      if (m) return await changes(res, snap, m[1], m[2] || false, url.searchParams.get('path'), url.searchParams.get('hash'));
      return json(res, 404, { error: 'not found' });
    } catch (e) {
      process.stderr.write(`api error: ${String(e && e.message).split('\n')[0]}\n`);
      try { json(res, 500, { error: 'internal error' }); } catch { /* headers already sent */ }
    }
  }

  function send(event, data) { for (const r of streams) { try { r.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); } catch { streams.delete(r); } } }

  return {
    handle,
    broadcast(ev) { send('changed', ev); },
    broadcastTasks(projectIds) { send('tasks', { projects: projectIds, at: iso() }); },
    heartbeat() { send('heartbeat', { at: iso() }); },
    closeAll() { for (const r of streams) { try { r.end(); } catch { /* ignore */ } } streams.clear(); },
    streamCount() { return streams.size; },
  };
}
