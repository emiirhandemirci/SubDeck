// desk/adapters/copilot.mjs
// GitHub Copilot adapter: (a) Copilot CLI session-state (events.jsonl + workspace.yaml + inuse lock),
// (b) VS Code Copilot Chat chatSessions/*.jsonl (best effort: title, timestamps, request count).
// Read-only. Whitelists ids, timestamps, tool/agent names, model names and token counts; message bodies never leave this file.
import fs from 'node:fs/promises';
import path from 'node:path';
import { clip, IDLE_MS } from '../lib/model.mjs';
import { fileUriToPath } from '../lib/paths.mjs';

const MAX_CHAT_BYTES = 16 * 1024 * 1024;
const VSCODE_FLAVORS = ['Code', 'Code - Insiders'];

const toIso = v => { const t = typeof v === 'number' ? v : Date.parse(v); return Number.isFinite(t) ? new Date(t).toISOString() : null; };
const isStr = v => typeof v === 'string' && v.length > 0;
const num = v => (Number.isFinite(v) ? v : null);
async function statOrNull(p) { try { return await fs.stat(p); } catch { return null; } }
async function readdirOrEmpty(p) { try { return await fs.readdir(p, { withFileTypes: true }); } catch { return []; } }
const maxIso = (...xs) => { const ts = xs.map(x => (x ? Date.parse(x) : NaN)).filter(Number.isFinite); return ts.length ? new Date(Math.max(...ts)).toISOString() : null; };

// ---- locations (computed from env.home / env.platform / env.vars) ----
function joinFor(env) { return env.platform === 'win32' ? path.win32.join : path.posix.join; }
export function copilotHomeDir(env) {
  const vars = env.vars || {};
  return vars.COPILOT_HOME || joinFor(env)(env.home, '.copilot');
}
export function vscodeUserDirs(env) {
  const vars = env.vars || {};
  const join = joinFor(env);
  let base;
  if (env.platform === 'win32') base = vars.APPDATA || env.appData || join(env.home, 'AppData', 'Roaming');
  else if (env.platform === 'darwin') base = join(env.home, 'Library', 'Application Support');
  else base = vars.XDG_CONFIG_HOME || join(env.home, '.config');
  return VSCODE_FLAVORS.map(f => join(base, f, 'User'));
}
const sessionStateDir = env => joinFor(env)(copilotHomeDir(env), 'session-state');

// ---- workspace.yaml: flat `key: value` lines only ----
export function parseFlatYaml(text) {
  const out = {};
  for (const raw of String(text).split('\n')) {
    const m = /^([A-Za-z_][\w-]*):[ \t]*(.*?)\s*$/.exec(raw);
    if (!m) continue;
    let v = m[2];
    if (/^[|>][-+]?$/.test(v)) continue;
    if (v.length > 1 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) v = v.slice(1, -1);
    if (v) out[m[1]] = v;
  }
  return out;
}

// ---- Copilot CLI events.jsonl: incremental accumulator (append-only, cached per file) ----
function newAcc() {
  return { offset: 0, records: 0, bad: 0, sessionId: null, cwd: null, startAt: null, firstTs: null, lastTs: null, model: null,
    lastActivity: null, turnOpen: false, shutdown: null, context: null, total: null, agents: new Map(), agentSeq: 0 };
}

function applyEvent(acc, e) {
  const type = typeof e.type === 'string' ? e.type : null;
  const d = e.data && typeof e.data === 'object' ? e.data : {};
  const at = toIso(e.timestamp);
  if (!type) return false;
  acc.records++;
  if (at) { if (!acc.firstTs) acc.firstTs = at; if (!acc.lastTs || at > acc.lastTs) acc.lastTs = at; }
  switch (type) {
    case 'session.start': case 'session.resume': {
      if (type === 'session.start' && isStr(d.sessionId)) acc.sessionId = d.sessionId;
      const ctx = d.context && typeof d.context === 'object' ? d.context : {};
      const cwd = isStr(ctx.cwd) ? ctx.cwd : isStr(d.cwd) ? d.cwd : null;
      if (cwd) acc.cwd = cwd;
      if (type === 'session.start') acc.startAt = toIso(d.startTime) || at;
      const m = isStr(d.selectedModel) ? d.selectedModel : isStr(d.model) ? d.model : null;
      if (m) acc.model = m;
      acc.shutdown = null;
      break;
    }
    case 'session.model_change': {
      const m = isStr(d.newModel) ? d.newModel : isStr(d.model) ? d.model : null;
      if (m) acc.model = m;
      break;
    }
    case 'session.shutdown': {
      acc.shutdown = { at, failed: d.shutdownType === 'error' };
      acc.turnOpen = false;
      if (isStr(d.currentModel)) acc.model = d.currentModel;
      if (d.modelMetrics && typeof d.modelMetrics === 'object') {
        let sum = 0, any = false;
        for (const mm of Object.values(d.modelMetrics)) {
          const u = mm && typeof mm === 'object' ? mm.usage : null;
          if (u && typeof u === 'object') for (const k of ['inputTokens', 'outputTokens']) if (Number.isFinite(u[k])) { sum += u[k]; any = true; }
        }
        if (any) acc.total = sum;
      }
      break;
    }
    case 'session.compaction_start': case 'session.compaction_complete': {
      const c = num(d.postCompactionTokens) ?? num(d.preCompactionTokens);
      if (c !== null) acc.context = c;
      break;
    }
    case 'assistant.turn_start': acc.turnOpen = true; break;
    case 'assistant.turn_end': acc.turnOpen = false; break;
    case 'user.message': acc.lastActivity = { at, kind: 'user', toolName: null, summary: null }; break;   // prompts never summarized
    case 'assistant.message': acc.lastActivity = { at, kind: 'assistant', toolName: null, summary: null }; break;
    case 'tool.execution_start': {
      const name = isStr(d.toolName) ? d.toolName : null;
      acc.lastActivity = { at, kind: 'tool', toolName: name, summary: clip(name, 80) };
      break;
    }
    case 'tool.execution_complete': {
      const name = isStr(d.toolName) ? d.toolName : (acc.lastActivity && acc.lastActivity.toolName) || null;
      acc.lastActivity = { at, kind: 'tool', toolName: name, summary: clip(name, 80) };
      break;
    }
    case 'subagent.started': {
      const key = isStr(d.toolCallId) ? d.toolCallId : 'n' + acc.agentSeq++;
      acc.agents.set(key, { key, name: isStr(d.agentName) ? d.agentName : null, display: isStr(d.agentDisplayName) ? d.agentDisplayName : null,
        startAt: at, endAt: null, failed: false });
      break;
    }
    case 'subagent.completed': case 'subagent.failed': {
      let a = isStr(d.toolCallId) ? acc.agents.get(d.toolCallId) : null;
      if (!a && isStr(d.agentName)) a = [...acc.agents.values()].reverse().find(x => x.name === d.agentName && !x.endAt);
      if (a) { a.endAt = at; a.failed = type === 'subagent.failed'; }
      break;
    }
    default: break;
  }
  return true;
}

async function readEvents(file, st, cache) {
  let acc = cache.get('e:' + file);
  if (!acc || acc.offset > st.size) acc = newAcc();
  if (acc.offset < st.size) {
    const fh = await fs.open(file, 'r');
    try {
      const len = st.size - acc.offset;
      const buf = Buffer.alloc(len);
      const { bytesRead } = await fh.read(buf, 0, len, acc.offset);
      const text = buf.subarray(0, bytesRead).toString('utf8');
      const cut = text.lastIndexOf('\n');                       // a line still being written is left for the next read
      if (cut >= 0) {
        for (const raw of text.slice(0, cut).split('\n')) {
          const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
          if (!line.trim()) continue;
          try { const o = JSON.parse(line); if (!o || typeof o !== 'object' || !applyEvent(acc, o)) acc.bad++; } catch { acc.bad++; }
        }
        acc.offset += Buffer.byteLength(text.slice(0, cut + 1), 'utf8');
      }
    } finally { await fh.close(); }
  }
  cache.set('e:' + file, acc);
  return acc;
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (e) { return !!(e && e.code === 'EPERM'); }
}

async function liveLock(dir, isAlive) {
  for (const ent of await readdirOrEmpty(dir)) {
    const m = ent.isFile() && /^inuse\.(\d+)\.lock$/.exec(ent.name);
    if (m && isAlive(Number(m[1]))) return true;
  }
  return false;
}

async function scanCli(env, cache, isAlive) {
  const root = sessionStateDir(env);
  const cutoff = env.now() - env.days * 86400000;
  const sessions = [];
  let skipped = 0;
  for (const ent of await readdirOrEmpty(root)) {
    if (!ent.isDirectory()) continue;
    const id = ent.name;
    const dir = path.join(root, id);
    try {
      const evFile = path.join(dir, 'events.jsonl');
      const evSt = await statOrNull(evFile);
      const yamlSt = await statOrNull(path.join(dir, 'workspace.yaml'));
      if (!evSt && !yamlSt) { skipped++; continue; }
      let y = {};
      if (yamlSt) { try { y = parseFlatYaml(await fs.readFile(path.join(dir, 'workspace.yaml'), 'utf8')); } catch { y = {}; } }
      const acc = evSt ? await readEvents(evFile, evSt, cache) : newAcc();
      if (acc.records === 0 && !Object.keys(y).length) { skipped++; continue; }
      const locked = await liveLock(dir, isAlive);
      const fileMs = Math.max(evSt ? evSt.mtimeMs : 0, yamlSt ? yamlSt.mtimeMs : 0);
      const updatedAt = maxIso(acc.lastTs, toIso(y.updated_at)) || (fileMs ? new Date(fileMs).toISOString() : null);
      if (!locked && Date.parse(updatedAt || 0) < cutoff) continue;
      const createdAt = acc.startAt || toIso(y.created_at) || acc.firstTs || updatedAt;
      const cwd = acc.cwd || y.cwd || y.git_root || null;
      const summary = clip(y.summary || y.name, 120);
      const age = updatedAt ? env.now() - Date.parse(updatedAt) : Infinity;
      let stateBasis;
      if (locked) {
        stateBasis = acc.turnOpen ? { kind: 'fixed', state: 'running', stateSource: 'lock' }
          : age < IDLE_MS ? { kind: 'mtime', at: updatedAt, stateSource: 'mtime' } : { kind: 'fixed', state: 'idle', stateSource: 'lock' };
      } else if (acc.shutdown) stateBasis = { kind: 'fixed', state: acc.shutdown.failed ? 'failed' : 'finished', stateSource: 'field' };
      else stateBasis = { kind: 'mtime', at: updatedAt, stateSource: 'mtime' };
      const endedAt = !locked && acc.shutdown ? acc.shutdown.at || updatedAt : null;
      const base = { tool: 'copilot', projectPath: cwd, projectLabel: cwd ? null : 'Copilot CLI (no folder)', model: acc.model,
        refs: { file: evSt ? evFile : null, db: null, key: null }, archived: false };
      sessions.push({
        ...base, nativeId: id, parentNativeId: null, depth: 0,
        title: summary || `Copilot CLI ${id.slice(0, 8)}`, titleSource: summary ? 'summary' : 'fallback', agentType: 'copilot-cli',
        createdAt, updatedAt, endedAt, tokens: { context: acc.context, total: acc.total }, lastActivity: acc.lastActivity, stateBasis,
      });
      for (const a of acc.agents.values()) {
        const ended = a.endAt || (!locked && acc.shutdown ? acc.shutdown.at : null);
        const label = clip(a.display || a.name, 120);
        const basis = a.endAt ? { kind: 'fixed', state: a.failed ? 'failed' : 'finished', stateSource: 'field' }
          : locked ? { kind: 'fixed', state: 'running', stateSource: 'lock' }
          : acc.shutdown ? { kind: 'fixed', state: 'finished', stateSource: 'field' } : { kind: 'mtime', at: a.startAt || updatedAt, stateSource: 'mtime' };
        sessions.push({
          ...base, nativeId: `${id}#${a.key}`, parentNativeId: id, depth: 1,
          title: label || `Copilot sub-agent ${a.key.slice(0, 8)}`, titleSource: label ? 'explicit' : 'fallback', agentType: a.name || 'subagent',
          createdAt: a.startAt || createdAt, updatedAt: a.endAt || updatedAt, endedAt: ended || null, tokens: { context: null, total: null },
          lastActivity: null, stateBasis: basis,
        });
      }
    } catch { skipped++; }
  }
  return { sessions, skipped };
}

// ---- VS Code Copilot Chat (best effort) ----
function summarizeChat(text) {
  const out = { records: 0, bad: 0, sessionId: null, createdMs: null, title: null, requests: 0, lastReqMs: null, model: null };
  const req = r => {
    out.requests++;
    if (r && typeof r === 'object') {
      const ts = num(r.timestamp);
      if (ts !== null && (out.lastReqMs === null || ts > out.lastReqMs)) out.lastReqMs = ts;
      if (isStr(r.modelId)) out.model = r.modelId;
    }
  };
  for (const raw of text.split('\n')) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { out.bad++; continue; }
    if (!o || typeof o !== 'object' || !Number.isInteger(o.kind)) { out.bad++; continue; }
    out.records++;
    const v = o.v;
    if (o.kind === 0 && v && typeof v === 'object') {
      if (isStr(v.sessionId)) out.sessionId = v.sessionId;
      if (num(v.creationDate) !== null) out.createdMs = v.creationDate;
      if (isStr(v.customTitle)) out.title = v.customTitle;
      if (Array.isArray(v.requests)) v.requests.forEach(req);
    } else if (Array.isArray(o.k) && o.k.length === 1) {
      if (o.k[0] === 'customTitle' && isStr(v)) out.title = v;
      else if (o.k[0] === 'requests' && o.kind === 2 && Array.isArray(v)) v.forEach(req);
    }
  }
  return out;
}

async function workspaceFolder(env, hashDir) {
  try {
    const w = JSON.parse(await fs.readFile(path.join(hashDir, 'workspace.json'), 'utf8'));
    if (typeof w.folder === 'string') return fileUriToPath(w.folder, env.platform);
    if (typeof w.workspace === 'string') { const f = fileUriToPath(w.workspace, env.platform); return f ? path.dirname(f) : null; }
  } catch { /* unreadable workspace.json */ }
  return null;
}

async function scanChat(env, cache) {
  const cutoff = env.now() - env.days * 86400000;
  const sessions = [];
  const watchExtra = [];
  let skipped = 0;
  for (const userDir of vscodeUserDirs(env)) {
    const wsRoot = path.join(userDir, 'workspaceStorage');
    for (const ent of await readdirOrEmpty(wsRoot)) {
      if (!ent.isDirectory()) continue;
      const hashDir = path.join(wsRoot, ent.name);
      const chatDir = path.join(hashDir, 'chatSessions');
      const files = (await readdirOrEmpty(chatDir)).filter(f => f.isFile() && f.name.endsWith('.jsonl'));
      if (!files.length) continue;
      watchExtra.push(chatDir);
      let folder;
      for (const f of files) {
        try {
          const file = path.join(chatDir, f.name);
          const st = await statOrNull(file);
          if (!st || st.mtimeMs < cutoff) continue;
          const sig = `${st.size}|${st.mtimeMs}`;
          let hit = cache.get('c:' + file);
          if (!hit || hit.sig !== sig) {
            hit = { sig, value: st.size > MAX_CHAT_BYTES ? { records: 1, oversized: true, requests: null } : summarizeChat(await fs.readFile(file, 'utf8')) };
            cache.set('c:' + file, hit);
          }
          const c = hit.value;
          if (c.records === 0) { skipped++; continue; }
          if (folder === undefined) folder = await workspaceFolder(env, hashDir);
          const id = c.sessionId || f.name.slice(0, -'.jsonl'.length);
          const updatedAt = new Date(st.mtimeMs).toISOString();
          const title = clip(c.title, 120);
          sessions.push({
            nativeId: 'vsc-' + id, tool: 'copilot', parentNativeId: null, depth: 0,
            projectPath: folder || null, projectLabel: folder ? null : 'Copilot Chat (no folder)',
            title: title || `Copilot Chat ${id.slice(0, 8)}`, titleSource: title ? 'explicit' : 'fallback', agentType: 'vscode-chat', model: c.model || null,
            createdAt: toIso(c.createdMs) || updatedAt, updatedAt, endedAt: null, tokens: { context: null, total: null },
            lastActivity: c.requests ? { at: toIso(c.lastReqMs) || updatedAt, kind: 'user', toolName: null, summary: `${c.requests} request${c.requests === 1 ? '' : 's'}` } : null,
            refs: { file, db: null, key: null }, archived: false, stateBasis: { kind: 'mtime', at: updatedAt, stateSource: 'mtime' },
          });
        } catch { skipped++; }
      }
    }
  }
  return { sessions, skipped, watchExtra };
}

export function createCopilotAdapter({ isAlive = pidAlive } = {}) {
  return {
    tool: 'copilot', label: 'Copilot', toolShort: 'gh', adapterVersion: '1', experimental: true,
    async detect(env) {
      try {
        const st = await statOrNull(sessionStateDir(env));
        if (st && st.isDirectory()) return true;
        for (const userDir of vscodeUserDirs(env)) {
          const wsRoot = path.join(userDir, 'workspaceStorage');
          for (const ent of await readdirOrEmpty(wsRoot)) {
            if (!ent.isDirectory()) continue;
            const c = await statOrNull(path.join(wsRoot, ent.name, 'chatSessions'));
            if (c && c.isDirectory()) return true;
          }
        }
      } catch { /* fall through */ }
      return false;
    },
    watchPaths(env, last) {
      return [{ path: sessionStateDir(env), recursive: true }, ...((last && last.watchExtra) || []).map(p => ({ path: p, recursive: false }))];
    },
    async scan(env, { cache }) {
      const notes = [];
      let cli = { sessions: [], skipped: 0 }, chat = { sessions: [], skipped: 0, watchExtra: [] };
      try { cli = await scanCli(env, cache, isAlive); } catch { notes.push('copilot cli scan failed'); }
      try { chat = await scanChat(env, cache); } catch { notes.push('copilot chat scan failed'); }
      return { sessions: [...cli.sessions, ...chat.sessions], skipped: cli.skipped + chat.skipped, notes, watchExtra: chat.watchExtra };
    },
  };
}

export default createCopilotAdapter();
