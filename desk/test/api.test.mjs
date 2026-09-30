// desk/test/api.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { createApi } from '../lib/api.mjs';

const P = 4917;
const S = (id, over = {}) => ({ id, nativeId: id, tool: 'claude-code', sourceId: 'claude-code', projectId: 'p_1', parentId: null, depth: 0,
  title: id, titleSource: 'summary', agentType: null, model: null, state: 'finished', stateSource: 'mtime', createdAt: '2026-09-29T10:00:00.000Z',
  updatedAt: '2026-09-29T10:00:00.000Z', endedAt: null, durationMs: 0, tokens: { context: null, total: null }, lastActivity: null,
  refs: { file: null, db: null, key: null }, archived: false, childCount: 0, ...over });
const snapshot = {
  lastScanAt: '2026-09-29T12:00:00.000Z',
  sources: [{ id: 'claude-code', tool: 'claude-code', label: 'Claude Code', adapterVersion: '1', detected: true, health: 'ok', lastError: null, lastScanAt: '2026-09-29T12:00:00.000Z', scanMs: 5, counts: { projects: 1, sessions: 4, running: 1, skipped: 0 } }],
  projects: [{ id: 'p_1', key: '/x', path: '/x', name: 'x', tools: ['claude-code'], sessionCount: 2, agentCount: 4, runningCount: 1, lastActivityAt: '2026-09-29T11:00:00.000Z' }],
  sessions: [
    S('claude.old', { updatedAt: '2026-09-29T09:00:00.000Z' }),
    S('claude.new', { updatedAt: '2026-09-29T11:00:00.000Z', childCount: 2 }),
    S('claude.k1', { parentId: 'claude.new', depth: 1, createdAt: '2026-09-29T10:30:00.000Z' }),
    S('claude.k2', { parentId: 'claude.new', depth: 1, state: 'running', createdAt: '2026-09-29T10:10:00.000Z' }),
  ],
};
function mk() {
  const pub = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-pub-'));
  for (const f of ['index.html', 'app.js', 'format.js', 'style.css', 'favicon.svg']) fs.writeFileSync(path.join(pub, f), `/* ${f} */`);
  fs.writeFileSync(path.join(pub, 'secret.txt'), 'no');
  return createApi({ core: { snapshot: () => snapshot }, getPort: () => P, startedAt: '2026-09-29T11:00:00.000Z', days: 14, version: '0.2.0', publicDir: pub, now: () => Date.parse('2026-09-29T12:00:01Z') });
}
function call(api, url, { method = 'GET', host = `127.0.0.1:${P}` } = {}) {
  const res = new EventEmitter();
  res.status = null; res.headers = null; res.chunks = [];
  res.writeHead = (s, h) => { res.status = s; res.headers = h; return res; };
  res.write = c => { res.chunks.push(String(c)); return true; };
  res.end = c => { if (c !== undefined) res.chunks.push(String(c)); res.ended = true; };
  const done = api.handle({ method, url, headers: host === null ? {} : { host } }, res);
  return Promise.resolve(done).then(() => res);
}
const body = res => JSON.parse(res.chunks.join(''));

test('Host guard', async () => {
  const api = mk();
  assert.equal((await call(api, '/api/sources')).status, 200);
  assert.equal((await call(api, '/api/sources', { host: `LOCALHOST:${P}` })).status, 200);
  for (const host of ['evil.example:4917', '127.0.0.1:1234', '127.0.0.1', null]) {
    const r = await call(api, '/api/sources', { host });
    assert.equal(r.status, 403, String(host));
    assert.deepEqual(body(r), { error: 'forbidden host' });
  }
  assert.equal((await call(api, '/', { host: 'evil.example' })).status, 403);
});

test('methods and unknown paths', async () => {
  const api = mk();
  assert.equal((await call(api, '/api/sources', { method: 'POST' })).status, 405);
  assert.equal((await call(api, '/nope')).status, 404);
  assert.equal((await call(api, '/secret.txt')).status, 404);
  assert.equal((await call(api, '/../server.mjs')).status, 404);
  assert.equal((await call(api, '/api/projects/p_zzz')).status, 404);
  assert.equal((await call(api, '/api/sessions/nope')).status, 404);
});

test('GET /api/sources and /api/projects', async () => {
  const api = mk();
  const r = await call(api, '/api/sources');
  assert.equal(r.headers['Content-Type'], 'application/json; charset=utf-8');
  assert.equal(r.headers['Cache-Control'], 'no-store');
  const s = body(r);
  assert.deepEqual(s.server, { version: '0.2.0', startedAt: '2026-09-29T11:00:00.000Z', days: 14 });
  assert.equal(s.sources[0].id, 'claude-code');
  assert.equal(s.generatedAt, '2026-09-29T12:00:01.000Z');
  assert.equal(body(await call(api, '/api/projects')).projects[0].id, 'p_1');
});

test('GET /api/projects/:id builds the tree: newest first, running children first', async () => {
  const d = body(await call(mk(), '/api/projects/p_1'));
  assert.equal(d.project.id, 'p_1');
  assert.deepEqual(d.sessions.map(s => s.id), ['claude.new', 'claude.old']);
  assert.deepEqual(d.sessions[0].children.map(s => s.id), ['claude.k2', 'claude.k1']);
  assert.deepEqual(d.sessions[0].children[0].children, []);
});

test('GET /api/sessions/:id adds project, parent, children', async () => {
  const api = mk();
  const k = body(await call(api, '/api/sessions/claude.k1')).session;
  assert.deepEqual(k.project, { id: 'p_1', name: 'x', path: '/x' });
  assert.deepEqual(k.parent, { id: 'claude.new', title: 'claude.new' });
  const n = body(await call(api, '/api/sessions/claude.new')).session;
  assert.equal(n.parent, null);
  assert.deepEqual(n.children.map(c => Object.keys(c)), [['id', 'title', 'state'], ['id', 'title', 'state']]);
});

test('static whitelist with CSP', async () => {
  const api = mk();
  const r = await call(api, '/');
  assert.equal(r.status, 200);
  assert.equal(r.headers['Content-Type'], 'text/html; charset=utf-8');
  assert.match(r.headers['Content-Security-Policy'], /default-src 'self'/);
  assert.equal(r.chunks.join(''), '/* index.html */');
  assert.equal((await call(api, '/app.js')).headers['Content-Type'], 'text/javascript; charset=utf-8');
  assert.equal((await call(api, '/style.css')).headers['Content-Type'], 'text/css; charset=utf-8');
  const h = await call(api, '/format.js', { method: 'HEAD' });
  assert.equal(h.status, 200);
  assert.equal(h.chunks.join(''), '');
});

test('SSE: hello, changed, heartbeat, close, limit', async () => {
  const api = mk();
  const r = await call(api, '/api/stream');
  assert.equal(r.headers['Content-Type'], 'text/event-stream');
  assert.match(r.chunks.join(''), /^retry: 3000\n\nevent: hello\ndata: \{"at":"2026-09-29T12:00:01.000Z","lastScanAt":"2026-09-29T12:00:00.000Z"\}\n\n$/);
  api.broadcast({ projects: ['p_1'], sources: false, at: 'T' });
  api.heartbeat();
  const all = r.chunks.join('');
  assert.ok(all.includes('event: changed\ndata: {"projects":["p_1"],"sources":false,"at":"T"}\n\n'));
  assert.ok(all.includes('event: heartbeat\ndata: {"at":"2026-09-29T12:00:01.000Z"}\n\n'));
  assert.equal(api.streamCount(), 1);
  r.emit('close');
  assert.equal(api.streamCount(), 0);
  const small = createApi({ core: { snapshot: () => snapshot }, getPort: () => P, startedAt: 'x', days: 14, version: '0.2.0', publicDir: '.', maxStreams: 1 });
  await call(small, '/api/stream');
  assert.equal((await call(small, '/api/stream')).status, 503);
});

// ---- on-demand content (task 024) ----
const CONTENT = { prompt: 'PROMPT_MARKER', promptTruncated: false, toolCalls: [{ at: 'T', tool: 'Read', target: '/x', ok: true }], toolCallsTruncated: false, finalReport: 'REPORT_MARKER' };
function mkContent(opts = {}) {
  const pub = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-pub-'));
  const core = { snapshot: () => ({ ...snapshot, sessions: [...snapshot.sessions, S('cursor.x', { tool: 'cursor' }), S('claude.gone')] }) };
  const adapters = [{ tool: 'claude-code', timeline: async (env, s) => (s.id === 'claude.k1' ? CONTENT : null) }, { tool: 'cursor' }];
  return createApi({ core, adapters, env: {}, getPort: () => P, startedAt: 'x', days: 14, version: '0.3.1', publicDir: pub, ...opts });
}

test('GET /api/sessions/:id/content: data, no-store, 404, 501', async () => {
  const api = mkContent();
  const r = await call(api, '/api/sessions/claude.k1/content');
  assert.equal(r.status, 200);
  assert.equal(r.headers['Cache-Control'], 'no-store');
  assert.deepEqual(body(r), CONTENT);
  assert.equal((await call(api, '/api/sessions/nope/content')).status, 404);
  assert.equal((await call(api, '/api/sessions/claude.gone/content')).status, 404);
  assert.equal((await call(api, '/api/sessions/cursor.x/content')).status, 501);
  assert.equal((await call(api, '/api/sessions/claude.k1/content', { method: 'POST' })).status, 405);
});

test('content endpoint: disabled flag and Host guard', async () => {
  assert.equal((await call(mkContent({ contentEnabled: false }), '/api/sessions/claude.k1/content')).status, 404);
  const r = await call(mkContent(), '/api/sessions/claude.k1/content', { host: 'evil.example:4917' });
  assert.equal(r.status, 403);
  assert.ok(!r.chunks.join('').includes('PROMPT_MARKER'));
});

test('content never appears in list, detail, snapshot or SSE payloads', async () => {
  const api = mkContent();
  for (const u of ['/api/sources', '/api/projects', '/api/projects/p_1', '/api/sessions/claude.k1']) {
    const t = (await call(api, u)).chunks.join('');
    assert.ok(!/"prompt"|"finalReport"|"toolCalls"|PROMPT_MARKER|REPORT_MARKER/.test(t), u);
  }
  const s = await call(api, '/api/stream');
  api.broadcast({ projects: ['p_1'], sources: false, at: 'T' });
  assert.ok(!/prompt|finalReport|toolCalls/.test(s.chunks.join('')));
});

test('GET /favicon.svg served; other unknown paths 404', async () => {
  const api = mk();
  const r = await call(api, '/favicon.svg');
  assert.equal(r.status, 200);
  assert.equal(r.headers['Content-Type'], 'image/svg+xml');
  assert.equal((await call(api, '/favicon.ico')).status, 404);
  assert.equal((await call(api, '/other.svg')).status, 404);
});
