// desk/lib/core.mjs
// Runs adapters, merges projects by normalized path, derives states, diffs snapshots (spec section 6).
import { projectKey, baseName } from './paths.mjs';
import { deriveState, validateAdapterSession, makeSource, sessionIdOf, projectIdOf } from './model.mjs';

const TIMEOUT_MSG = 'scan timed out after 5 s';

function withTimeout(promise, ms) {
  let timer;
  const t = new Promise((_, rej) => { timer = setTimeout(() => rej(new Error(TIMEOUT_MSG)), ms); });
  return Promise.race([promise, t]).finally(() => clearTimeout(timer));
}
const firstLine = e => String((e && e.message) || e).split('\n')[0].slice(0, 200);

export function createCore({ env, adapters, now = Date.now, timeoutMs = 5000 }) {
  const active = adapters.filter(a => !(env.disabled || []).includes(a.tool));
  const sources = new Map(active.map(a => [a.tool, makeSource(a)]));
  const results = new Map();                       // tool -> last good AdapterResult
  const caches = new Map(active.map(a => [a.tool, new Map()]));
  const lastScanStart = new Map();
  const running = new Map();                       // tool -> in-flight Promise
  const pending = new Set();                       // tools with a follow-up scan requested
  const listeners = [];
  const watchNotes = new Map();                    // tool -> note from the watcher (e.g. polling fallback)
  let snap = { lastScanAt: null, sources: [], projects: [], sessions: [] };
  let bases = new Map();                           // session id -> stateBasis (never served)
  let projectHashes = new Map();
  let sourcesHash = '';

  async function runAdapter(a) {
    const src = sources.get(a.tool);
    const t0 = now();
    try {
      src.detected = !!(await withTimeout(Promise.resolve(a.detect(env)), timeoutMs));
      const r = src.detected
        ? await withTimeout(a.scan(env, { since: lastScanStart.get(a.tool) ?? null, cache: caches.get(a.tool) }), timeoutMs)
        : { sessions: [], skipped: 0, notes: [] };
      results.set(a.tool, { ...r, sessions: r.sessions || [], skipped: r.skipped || 0, notes: r.notes || [] });
      src.health = 'ok'; src.lastError = null;
    } catch (e) {
      src.health = 'error';
      src.lastError = firstLine(e);
    }
    lastScanStart.set(a.tool, t0);
    src.lastScanAt = new Date(now()).toISOString();
    src.scanMs = now() - t0;
  }

  function scanOne(a) {
    if (running.has(a.tool)) { pending.add(a.tool); return running.get(a.tool); }
    const p = (async () => { do { pending.delete(a.tool); await runAdapter(a); } while (pending.has(a.tool)); })()
      .finally(() => running.delete(a.tool));
    running.set(a.tool, p);
    return p;
  }

  function rebuild() {
    const projects = new Map();
    const sessions = [];
    const newBases = new Map();
    const skippedByTool = new Map();
    const nativeIndex = new Map();
    for (const a of active) {
      const r = results.get(a.tool);
      if (!r) continue;
      let skipped = r.skipped || 0;
      for (const s of r.sessions) {
        if (!validateAdapterSession(s).ok) { skipped++; continue; }
        const key = s.projectPath ? projectKey(s.projectPath, env.platform) : `label:${a.tool}:${s.projectLabel}`;
        let p = projects.get(key);
        if (!p) {
          p = { id: projectIdOf(key), key, path: s.projectPath || null, name: s.projectPath ? baseName(s.projectPath) : s.projectLabel,
            tools: new Set(), sessionCount: 0, agentCount: 0, runningCount: 0, lastActivityAt: null };
          projects.set(key, p);
        }
        p.tools.add(a.tool);
        const id = sessionIdOf(a.toolShort, s.nativeId);
        const la = s.lastActivity;
        const out = {
          id, nativeId: s.nativeId, tool: a.tool, sourceId: a.tool, projectId: p.id, parentId: null, depth: 0,
          title: s.title, titleSource: s.titleSource, agentType: s.agentType ?? null, model: s.model ?? null,
          state: 'unknown', stateSource: 'none',
          createdAt: s.createdAt ?? null, updatedAt: s.updatedAt ?? null, endedAt: s.endedAt ?? null, durationMs: null,
          tokens: { context: s.tokens.context ?? null, total: s.tokens.total ?? null },
          lastActivity: la ? { at: la.at ?? null, kind: la.kind, toolName: la.toolName ?? null, summary: la.summary ?? null } : null,
          refs: { file: s.refs?.file ?? null, db: s.refs?.db ?? null, key: s.refs?.key ?? null },
          archived: !!s.archived, childCount: 0,
        };
        Object.defineProperty(out, '_parentNative', { value: s.parentNativeId ?? null, enumerable: false });
        newBases.set(id, s.stateBasis);
        nativeIndex.set(a.tool + '\u0000' + s.nativeId, out);
        sessions.push(out);
      }
      skippedByTool.set(a.tool, skipped);
    }
    for (const s of sessions) {
      if (!s._parentNative) continue;
      const parent = nativeIndex.get(s.tool + '\u0000' + s._parentNative);
      if (parent && parent !== s) { s.parentId = parent.id; s.depth = 1; parent.childCount++; }
    }
    bases = newBases;
    applyStates(sessions, now());
    const projList = finishProjects(projects, sessions);
    for (const [tool, src] of sources) {
      const own = sessions.filter(s => s.tool === tool);
      const skipped = skippedByTool.get(tool) || 0;
      src.counts = { projects: new Set(own.map(s => s.projectId)).size, sessions: own.length,
        running: own.filter(s => s.state === 'running').length, skipped };
      if (src.health !== 'error') {
        const parts = [];
        if (skipped > 0) parts.push(`${skipped} malformed item(s) skipped`);
        parts.push(...(results.get(tool)?.notes || []));
        if (watchNotes.get(tool)) parts.push(watchNotes.get(tool));
        src.health = skipped > 0 ? 'degraded' : 'ok';
        src.lastError = parts.length ? parts.join('; ') : null;
      }
    }
    const lastScanAt = [...sources.values()].map(s => s.lastScanAt).filter(Boolean).sort().pop() || null;
    snap = { lastScanAt, sources: [...sources.values()].map(s => ({ ...s, counts: { ...s.counts } })), projects: projList, sessions };
    emitDiff();
  }

  function applyStates(sessions, t) {
    for (const s of sessions) {
      const { state, stateSource } = deriveState(bases.get(s.id), t);
      s.state = state; s.stateSource = stateSource;
      const c = s.createdAt ? Date.parse(s.createdAt) : NaN;
      if (!Number.isFinite(c)) { s.durationMs = null; continue; }
      const endIso = state === 'finished' ? (s.endedAt || s.updatedAt) : null;
      s.durationMs = Math.max(0, (endIso ? Date.parse(endIso) : t) - c);
    }
  }

  function finishProjects(projects, sessions) {
    const byId = new Map([...projects.values()].map(p => [p.id, { ...p, tools: new Set(p.tools) }]));
    for (const p of byId.values()) { p.sessionCount = 0; p.agentCount = 0; p.runningCount = 0; p.lastActivityAt = null; }
    for (const s of sessions) {
      const p = byId.get(s.projectId);
      p.agentCount++;
      if (!s.parentId) p.sessionCount++;
      if (s.state === 'running') p.runningCount++;
      if (s.updatedAt && (!p.lastActivityAt || s.updatedAt > p.lastActivityAt)) p.lastActivityAt = s.updatedAt;
    }
    return [...byId.values()].map(p => ({ ...p, tools: [...p.tools].sort() }))
      .sort((a, b) => b.runningCount - a.runningCount || String(b.lastActivityAt).localeCompare(String(a.lastActivityAt)));
  }

  function emitDiff() {
    const hashes = new Map();
    for (const p of snap.projects) {
      const own = snap.sessions.filter(s => s.projectId === p.id)
        .map(s => [s.id, s.state, s.updatedAt, s.tokens.context, s.title, s.lastActivity && s.lastActivity.at, s.parentId]);
      hashes.set(p.id, JSON.stringify([p.tools, p.sessionCount, p.agentCount, p.runningCount, p.lastActivityAt, own]));
    }
    const changed = [];
    for (const [id, h] of hashes) if (projectHashes.get(id) !== h) changed.push(id);
    for (const id of projectHashes.keys()) if (!hashes.has(id)) changed.push(id);
    const sh = JSON.stringify(snap.sources.map(s => [s.id, s.detected, s.health, s.lastError, s.counts]));
    const sourcesChanged = sh !== sourcesHash;
    projectHashes = hashes; sourcesHash = sh;
    if (!changed.length && !sourcesChanged) return;
    const ev = { projects: changed, sources: sourcesChanged, at: new Date(now()).toISOString() };
    for (const fn of listeners) { try { fn(ev); } catch { /* a listener never breaks scans */ } }
  }

  return {
    async scanAll() { await Promise.allSettled(active.map(scanOne)); rebuild(); },
    async scanSources(tools) { await Promise.allSettled(active.filter(a => tools.includes(a.tool)).map(scanOne)); rebuild(); },
    refreshStates() {
      applyStates(snap.sessions, now());
      const byKey = new Map(snap.projects.map(p => [p.key, p]));
      snap = { ...snap, projects: finishProjects(byKey, snap.sessions) };
      for (const src of snap.sources) src.counts.running = snap.sessions.filter(s => s.tool === src.id && s.state === 'running').length;
      emitDiff();
    },
    snapshot() { return snap; },
    watchTargets() {
      const out = [];
      for (const a of active) {
        if (!sources.get(a.tool).detected) continue;
        for (const w of a.watchPaths(env, results.get(a.tool)) || []) {
          out.push({ tool: a.tool, path: w.path, recursive: !!w.recursive, ...(w.filter ? { filter: w.filter } : {}) });
        }
      }
      return out;
    },
    onChanged(fn) { listeners.push(fn); },
    setWatchNote(tool, note) { if (!sources.has(tool)) return; watchNotes.set(tool, note || null); rebuild(); },
  };
}
