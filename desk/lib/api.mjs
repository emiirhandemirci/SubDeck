// desk/lib/api.mjs
// Pure request handling for Desk (spec section 8). No sockets here; server.mjs wires it to node:http.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { readNotifyEnabled, writeNotifyEnabled } from './notify-settings.mjs';

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/format.js': ['format.js', 'text/javascript; charset=utf-8'],
  '/favicon.svg': ['favicon.svg', 'image/svg+xml'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
};
const CSP = "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:";
const JSON_HEADERS = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

export function createApi({ core, getPort, startedAt, days, version, publicDir, now = Date.now, maxStreams = 32, contentEnabled = true, adapters = [], env = null, configFile = null, token = crypto.randomBytes(24).toString('hex') }) {
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

  // Projects whose own .subdeck/config.json sets notify.enabled; the project value wins over the user config, so the bell cannot change it.
  async function projectOverrides() {
    const out = [];
    const mine = path.resolve(configFile);
    for (const p of core.snapshot().projects || []) {
      if (!p.path || out.length >= 20) continue;
      const file = path.join(p.path, '.subdeck', 'config.json');
      if (path.resolve(file) === mine) continue;
      try {
        const o = JSON.parse(await fs.readFile(file, 'utf8'));
        if (o && typeof o === 'object' && o.notify && typeof o.notify === 'object' && typeof o.notify.enabled === 'boolean') out.push({ project: p.name, file, enabled: o.notify.enabled });
      } catch { /* absent or unreadable: no override */ }
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
