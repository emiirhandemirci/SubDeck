// desk/lib/api.mjs
// Pure request handling for Desk (spec section 8). No sockets here; server.mjs wires it to node:http.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { readNotifyEnabled, writeNotifyEnabled } from './notify-settings.mjs';
import { projectKey, relativeTo, isSecretPath, stateDirs } from './paths.mjs';
import { showCommit, HASH_RE } from './git.mjs';

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/format.js': ['format.js', 'text/javascript; charset=utf-8'],
  '/favicon.svg': ['favicon.svg', 'image/svg+xml'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
};
const CSP = "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:";
const JSON_HEADERS = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

export function createApi({ core, getPort, startedAt, days, version, publicDir, now = Date.now, maxStreams = 32, contentEnabled = true, adapters = [], env = null, configFile = null, gitShow = null, token = crypto.randomBytes(24).toString('hex') }) {
  const streams = new Set();
  const iso = () => new Date(now()).toISOString();

  function json(res, status, obj) { res.writeHead(status, JSON_HEADERS); res.end(JSON.stringify(obj)); }

  function hostOk(h) {
    if (typeof h !== 'string') return false;
    const v = h.toLowerCase();
    const p = getPort();
    return v === `127.0.0.1:${p}` || v === `localhost:${p}`;
  }

  function projectTree(snap, id) {
    const project = snap.projects.find(p => p.id === id);
    if (!project) return null;
    const own = snap.sessions.filter(s => s.projectId === id);
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
    const items = snap.sessions.filter(s => s.state === 'waiting').map(s => {
      const p = snap.projects.find(x => x.id === s.projectId);
      return { id: s.id, projectId: s.projectId, projectName: p ? p.name : null, projectPath: p ? p.path : null, tool: s.tool, title: s.title,
        agentType: s.agentType ?? null, isAgent: !!s.parentId, stateSource: s.stateSource, waitingKind: s.waitingKind ?? null, since: s.waitingSince ?? s.updatedAt ?? null };
    }).sort((a, b) => String(a.since).localeCompare(String(b.since)));
    return { generatedAt: iso(), items };
  }

  function sessionDetail(snap, id) {
    const s = snap.sessions.find(x => x.id === id);
    if (!s) return null;
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
    return w.ok ? json(res, 200, { enabled: w.enabled }) : json(res, 500, { error: w.error });
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
      if (p === '/api/settings/notify' && (req.method === 'GET' || req.method === 'POST')) return await notifySettings(req, res);
      if (req.method !== 'GET' && req.method !== 'HEAD') return json(res, 405, { error: 'method not allowed' });
      if (STATIC[p]) return await serveStatic(req, res, STATIC[p]);
      if (req.method === 'HEAD') return json(res, 405, { error: 'method not allowed' });
      const snap = core.snapshot();
      if (p === '/api/sources') return json(res, 200, { generatedAt: iso(), server: { version, startedAt, days }, home: (env && env.home) || os.homedir(), sources: snap.sources });
      if (p === '/api/waiting') return json(res, 200, waitingList(snap));
      if (p === '/api/projects') return json(res, 200, { generatedAt: iso(), projects: snap.projects });
      if (p === '/api/stream') return openStream(res);
      let m = /^\/api\/projects\/([A-Za-z0-9._-]+)$/.exec(p);
      if (m) { const t = projectTree(snap, m[1]); return t ? json(res, 200, t) : json(res, 404, { error: 'not found' }); }
      m = /^\/api\/sessions\/([A-Za-z0-9._-]+)$/.exec(p);
      if (m) { const d = sessionDetail(snap, m[1]); return d ? json(res, 200, d) : json(res, 404, { error: 'not found' }); }
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
    heartbeat() { send('heartbeat', { at: iso() }); },
    closeAll() { for (const r of streams) { try { r.end(); } catch { /* ignore */ } } streams.clear(); },
    streamCount() { return streams.size; },
  };
}
