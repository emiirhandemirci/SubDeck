// desk/test/waiting-list.test.mjs: the header "N waiting" chip opens a list backed by GET /api/waiting.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import { createCore } from '../lib/core.mjs';
import { createApi } from '../lib/api.mjs';

const NOW = Date.parse('2026-09-29T12:00:00Z');
const iso = msAgo => new Date(NOW - msAgo).toISOString();
const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
function sess(over = {}) {
  return { nativeId: 'n1', tool: 'fake', parentNativeId: null, depth: 0, projectPath: 'E:\\Alpha', projectLabel: null,
    title: 'T', titleSource: 'summary', agentType: null, model: null, createdAt: iso(600000), updatedAt: iso(1000), endedAt: null,
    tokens: { context: 10, total: null }, lastActivity: null, refs: { file: null, db: null, key: null }, archived: false,
    stateBasis: { kind: 'mtime', at: iso(1000), stateSource: 'mtime' }, ...over };
}
const adapter = (tool, toolShort, sessions) => ({ tool, label: tool, toolShort, adapterVersion: '1', async detect() { return true; },
  watchPaths() { return [{ path: '/w/' + tool, recursive: true }]; }, async scan() { return { sessions, skipped: 0, notes: [] }; } });
const call = async (api, url) => {
  const res = new EventEmitter(); res.chunks = [];
  res.writeHead = s => { res.status = s; return res; }; res.write = c => { res.chunks.push(String(c)); return true; }; res.end = c => { if (c !== undefined) res.chunks.push(String(c)); };
  await api.handle({ method: 'GET', url, headers: { host: '127.0.0.1:4917' } }, res);
  return { status: res.status, body: JSON.parse(res.chunks.join('')) };
};

async function setup() {
  const waitingBasis = (ago, stateSource, extra = {}) => ({ kind: 'waiting', at: iso(ago), stateSource, fallbackAt: iso(1000), ...extra });
  const a = adapter('claude-code', 'claude', [
    sess({ tool: 'claude-code', nativeId: 'top', title: 'Fix login', prompt: 'SECRET PROMPT', stateBasis: waitingBasis(300000, 'field') }),
    sess({ tool: 'claude-code', nativeId: 'kid', parentNativeId: 'top', agentType: 'reviewer', title: 'Review diff', stateBasis: waitingBasis(60000, 'hook') }),
    sess({ tool: 'claude-code', nativeId: 'run', title: 'Busy' }),
  ]);
  const b = adapter('cursor', 'cursor', [sess({ tool: 'cursor', nativeId: 'c1', projectPath: 'E:\\Beta', title: 'Refactor', stateBasis: waitingBasis(900000, 'field', { waitingKind: 'plan' }) })]);
  const core = createCore({ env: { platform: 'win32', disabled: [], days: 14 }, adapters: [a, b], now: () => NOW });
  await core.scanAll();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'desk-wl-'));
  const api = createApi({ core, getPort: () => 4917, startedAt: iso(0), days: 14, version: 't', publicDir: dir, now: () => NOW });
  return { api, core };
}

test('/api/waiting lists waiting sessions and agents across projects and tools, longest wait first', async () => {
  const { api } = await setup();
  const r = await call(api, '/api/waiting');
  assert.equal(r.status, 200);
  const items = r.body.items;
  assert.deepEqual(items.map(i => i.title), ['Refactor', 'Fix login', 'Review diff']);
  assert.deepEqual(items.map(i => i.projectName), ['Beta', 'Alpha', 'Alpha']);
  assert.deepEqual(items.map(i => i.tool), ['cursor', 'claude-code', 'claude-code']);
  assert.deepEqual(items.map(i => i.isAgent), [false, false, true]);
  assert.equal(items[0].since, iso(900000));
  assert.equal(items[0].waitingKind, 'plan');
  assert.equal(items[2].stateSource, 'hook');
  assert.equal(items[2].agentType, 'reviewer');
});

test('/api/waiting carries no content and is empty when nothing waits', async () => {
  const { api } = await setup();
  const text = JSON.stringify((await call(api, '/api/waiting')).body);
  assert.ok(!/SECRET PROMPT/.test(text));
  const core = createCore({ env: { platform: 'win32', disabled: [], days: 14 }, adapters: [adapter('claude-code', 'claude', [sess({ tool: 'claude-code' })])], now: () => NOW });
  await core.scanAll();
  const api2 = createApi({ core, getPort: () => 4917, startedAt: iso(0), days: 14, version: 't', publicDir: os.tmpdir(), now: () => NOW });
  assert.deepEqual((await call(api2, '/api/waiting')).body.items, []);
});

test('waitingSince is only present while waiting', async () => {
  const { core } = await setup();
  const s = core.snapshot().sessions;
  assert.equal(s.find(x => x.id === 'claude.run').waitingSince, undefined);
  assert.equal(s.find(x => x.id === 'claude.top').waitingSince, iso(300000));
});

test('public UI: chip is a button wired to the list, Esc closes, no innerHTML', () => {
  const html = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  const js = fs.readFileSync(path.join(pub, 'app.js'), 'utf8');
  assert.match(html, /<button id="waitingCount"[^>]*aria-expanded="false"[^>]*aria-controls="waitingPanel"/);
  assert.match(html, /id="waitingPanel"[^>]*role="dialog"/);
  assert.match(js, /\/api\/waiting/);
  assert.match(js, /ev\.key === 'Escape' && wp\.open/);
  assert.match(js, /Nothing is waiting for you/);
  assert.ok(!/innerHTML|insertAdjacentHTML/.test(js));
});
