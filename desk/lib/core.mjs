// desk/lib/core.mjs
// Runs adapters, merges projects by normalized path, derives states, diffs snapshots (spec section 6).
import { projectKey, baseName, isInside } from './paths.mjs';
import { deriveState, validateAdapterSession, makeSource, sessionIdOf, projectIdOf } from './model.mjs';

const FAILURE_KINDS = ['test', 'permission', 'api', 'quota', 'timeout', 'tool', 'stuck', 'unknown'];

const RUN_STR = ['taskId', 'ts', 'role', 'class', 'tool', 'model', 'status', 'branch', 'worktree', 'base', 'writableCheck'];
/** Run metadata of a SubDeck run session (adapter subdeck-run): known fields only, bounded. */
function cleanRun(r) {
  const o = {};
  for (const k of RUN_STR) o[k] = typeof r[k] === 'string' ? r[k].slice(0, 500) : '';
  o.exit = Number.isInteger(r.exit) ? r.exit : null;
  o.cliExit = Number.isInteger(r.cliExit) ? r.cliExit : null;
  o.experimental = r.experimental === true;
  o.violations = Array.isArray(r.violations) ? r.violations.filter(x => typeof x === 'string').slice(0, 50).map(x => x.slice(0, 300)) : [];
  o.sessionId = typeof r.sessionId === 'string' ? r.sessionId.slice(0, 200) : null;
  return o;
}

function withTimeout(promise, ms, what) {
  let timer;
  const t = new Promise((_, rej) => { timer = setTimeout(() => rej(new Error(`${what} timed out after ${Math.round(ms / 1000)} s`)), ms); });
  return Promise.race([promise, t]).finally(() => clearTimeout(timer));
}
const firstLine = e => String((e && e.message) || e).split('\n')[0].slice(0, 200);

/**
 * Scan budgets: a scan that outlives its budget is not an error and its work is not thrown away. The caller stops waiting,
 * the source keeps its previous result (or the partial result of a first scan) and shows a warning, and the scan goes on in
 * the background and publishes its result when it ends. Only an adapter exception (or a hung detect) is an error.
 * timeoutMs: budget of a rescan; firstTimeoutMs: budget of a source's first scan (cold caches, whole history).
 * Adapters may report progress during a first scan through ctx.partial({ sessions, skipped, notes, progress: { projects } }).
 */
export function createCore({ env, adapters, now = Date.now, timeoutMs = 5000, firstTimeoutMs = 60000, publishMs = 1000 }) {
  const active = adapters.filter(a => !(env.disabled || []).includes(a.tool));
  const sources = new Map(active.map(a => [a.tool, { ...makeSource(a), scanning: false, slow: false, scanProgress: null }]));
  const results = new Map();                       // tool -> last good AdapterResult
  const partials = new Map();                      // tool -> partial AdapterResult of a first scan still running
  const caches = new Map(active.map(a => [a.tool, new Map()]));
  const lastScanStart = new Map();
  const running = new Map();                       // tool -> in-flight Promise (scan loop, may outlive its waiters)
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
    const first = !results.has(a.tool);
    const budget = first ? firstTimeoutMs : timeoutMs;
    let lastPublish = 0;
    const ctx = { since: lastScanStart.get(a.tool) ?? null, cache: caches.get(a.tool) };
    if (first) {
      ctx.partial = r => {   // first scan only: show what was found so far
        if (!r || results.has(a.tool)) return;
        partials.set(a.tool, { ...r, sessions: r.sessions || [], skipped: r.skipped || 0, notes: r.notes || [] });
        const n = r.progress && Number.isFinite(r.progress.projects) ? r.progress.projects : null;
        if (n !== null) src.scanProgress = n;
        const t = Date.now();
        if (t - lastPublish >= publishMs) { lastPublish = t; rebuild(); }
      };
    }
    try {
      src.detected = !!(await withTimeout(Promise.resolve(a.detect(env)), budget, 'detection'));
      if (src.detected && first) { src.scanning = true; rebuild(); }
      const r = src.detected ? await a.scan(env, ctx) : { sessions: [], skipped: 0, notes: [] };
      results.set(a.tool, { ...r, sessions: r.sessions || [], skipped: r.skipped || 0, notes: r.notes || [] });
      partials.delete(a.tool);
      src.health = 'ok'; src.lastError = null;
    } catch (e) {
      src.health = 'error';
      src.lastError = firstLine(e);
    }
    const late = src.slow;   // the waiters gave up: nobody else rebuilds for this result
    src.scanning = false; src.slow = false; src.scanProgress = null;
    lastScanStart.set(a.tool, t0);
    src.lastScanAt = new Date(now()).toISOString();
    src.scanMs = now() - t0;
    if (late) rebuild();
  }

  /** Resolves when the scan loop of `a` ends or its budget runs out, whichever is first; never rejects. */
  function scanOne(a) {
    if (running.has(a.tool)) pending.add(a.tool);
    else {
      const p = (async () => { do { pending.delete(a.tool); await runAdapter(a); } while (pending.has(a.tool)); })()
        .finally(() => running.delete(a.tool));
      running.set(a.tool, p);
    }
    const loop = running.get(a.tool);
    const budget = results.has(a.tool) ? timeoutMs : firstTimeoutMs;
    let timer;
    const t = new Promise(res => { timer = setTimeout(() => {
      if (running.get(a.tool) === loop) { const src = sources.get(a.tool); src.slow = true; src.scanning = true; }
      res();
    }, budget); });
    return Promise.race([loop, t]).finally(() => clearTimeout(timer));
  }

  function rebuild() {
    const projects = new Map();
    const sessions = [];
    const newBases = new Map();
    const skippedByTool = new Map();
    const nativeIndex = new Map();
    for (const a of active) {
      const r = results.get(a.tool) || partials.get(a.tool);
      if (!r) continue;
      let skipped = r.skipped || 0;
      for (const s of r.sessions) {
        if (!validateAdapterSession(s).ok) { skipped++; continue; }
        const key = s.projectPath ? projectKey(s.projectPath, env.platform) : `label:${a.tool}:${s.projectLabel}`;
        let p = projects.get(key);
        if (!p) {
          p = { id: projectIdOf(key), key, path: s.projectPath || null, name: s.projectPath ? (env.home && projectKey(env.home, env.platform) === key ? '~' : baseName(s.projectPath)) : s.projectLabel,
            temporary: !!(s.projectPath && isInside(s.projectPath, env.tmpDirs, env.platform)),
            tools: new Set(), sessionCount: 0, agentCount: 0, runningCount: 0, waitingCount: 0, lastActivityAt: null };
          projects.set(key, p);
        }
        p.tools.add(a.tool);
        const id = sessionIdOf(a.toolShort, s.nativeId);
        const la = s.lastActivity;
        const out = {
          id, nativeId: s.nativeId, tool: a.tool, sourceId: a.tool, projectId: p.id, parentId: null, depth: 0,
          title: s.title, titleSource: s.titleSource, agentType: s.agentType ?? null, model: s.model ?? null, effort: typeof s.effort === 'string' ? s.effort : null,
          state: 'unknown', stateSource: 'none',
          createdAt: s.createdAt ?? null, runStartedAt: s.runStartedAt ?? null, updatedAt: s.updatedAt ?? null, endedAt: s.endedAt ?? null, durationMs: null,
          tokens: { context: s.tokens.context ?? null, total: s.tokens.total ?? null },
          lastActivity: la ? { at: la.at ?? null, kind: la.kind, toolName: la.toolName ?? null, summary: la.summary ?? null } : null,
          refs: { file: s.refs?.file ?? null, db: s.refs?.db ?? null, key: s.refs?.key ?? null },
          archived: !!s.archived, childCount: 0,
        };
        if (s.reportMissing && typeof s.reportMissing === 'object' && typeof s.reportMissing.at === 'string') out.reportMissing = { at: s.reportMissing.at, task: typeof s.reportMissing.task === 'string' ? s.reportMissing.task : null };
        if (s.interrupted && typeof s.interrupted === 'object' && typeof s.interrupted.at === 'string') {
          const i = s.interrupted;
          out.interrupted = { at: i.at, task: typeof i.task === 'string' ? i.task : null, errorType: typeof i.errorType === 'string' ? i.errorType : 'unknown', files: Number.isInteger(i.files) ? i.files : null };
        }
        if (s.run && typeof s.run === 'object') out.run = cleanRun(s.run);
        if (s.taskId !== undefined) out.taskId = typeof s.taskId === 'string' ? s.taskId : null;
        Object.defineProperty(out, '_parentNative', { value: s.parentNativeId ?? null, enumerable: false });
        if (s.failure && FAILURE_KINDS.includes(s.failure.kind)) Object.defineProperty(out, '_failure', { value: { kind: s.failure.kind, detail: String(s.failure.detail || '').slice(0, 80) }, enumerable: false });
        newBases.set(id, s.stateBasis);
        nativeIndex.set(a.tool + '\u0000' + s.nativeId, out);
        sessions.push(out);
      }
      skippedByTool.set(a.tool, skipped);
    }
    for (const s of sessions) {
      if (!s._parentNative) continue;
      const parent = nativeIndex.get(s.tool + '\u0000' + s._parentNative);
      if (parent && parent !== s) { s.parentId = parent.id; s.depth = 1; parent.childCount++; Object.defineProperty(s, '_parentObj', { value: parent, enumerable: false }); }
    }
    for (const s of sessions) {   // nested sub-agents: depth follows the parent chain (capped, cycle-safe)
      let d = 0, p = s;
      for (; p._parentObj && d < 8; p = p._parentObj) d++;
      if (s._parentObj) s.depth = d;
    }
    bases = newBases;
    applyStates(sessions, now());
    const projList = finishProjects(projects, sessions);
    for (const [tool, src] of sources) {
      const own = sessions.filter(s => s.tool === tool);
      const skipped = skippedByTool.get(tool) || 0;
      src.counts = { projects: new Set(own.map(s => s.projectId)).size, sessions: own.length,
        running: own.filter(s => s.state === 'running').length, waiting: own.filter(s => s.state === 'waiting').length, skipped };
      if (src.health !== 'error') {
        const parts = [];
        if (src.scanning) parts.push(scanNote(src, results.has(tool)));
        if (skipped > 0) parts.push(`${skipped} malformed item(s) skipped`);
        parts.push(...((results.get(tool) || partials.get(tool))?.notes || []));
        if (watchNotes.get(tool)) parts.push(watchNotes.get(tool));
        src.health = skipped > 0 || src.scanning ? 'degraded' : 'ok';   // a slow or unfinished scan is a warning, not an error
        src.lastError = parts.length ? parts.join('; ') : null;
      }
    }
    const lastScanAt = [...sources.values()].map(s => s.lastScanAt).filter(Boolean).sort().pop() || null;
    snap = { lastScanAt, sources: [...sources.values()].map(s => ({ ...s, counts: { ...s.counts } })), projects: projList, sessions };
    emitDiff();
  }

  function scanNote(src, hasPrevious) {
    const so = src.scanProgress !== null ? ` (${src.scanProgress} project${src.scanProgress === 1 ? '' : 's'} so far)` : '';
    if (!src.slow) return `scanning…${so}`;
    return hasPrevious ? 'slow scan, still running; showing previous data' : `slow scan, still running; showing partial data${so}`;
  }

  function applyStates(sessions, t) {
    for (const s of sessions) {
      const { state, stateSource } = deriveState(bases.get(s.id), t);
      s.state = state; s.stateSource = stateSource;
      if (state === 'failed' && s._failure) s.failure = { ...s._failure }; else delete s.failure;   // failure only on failed sessions
      if (state === 'waiting') { const b = bases.get(s.id); s.waitingSince = b.at || null; s.waitingKind = b.waitingKind || null; } else { delete s.waitingSince; delete s.waitingKind; }
      const c = Date.parse(s.runStartedAt || s.createdAt);   // latest run when known, else first start
      if (!Number.isFinite(c)) { s.durationMs = null; continue; }
      const endIso = (state === 'finished' || state === 'failed') ? (s.endedAt || s.updatedAt) : null;
      s.durationMs = Math.max(0, (endIso ? Date.parse(endIso) : t) - c);
    }
  }

  function finishProjects(projects, sessions) {
    const byId = new Map([...projects.values()].map(p => [p.id, { ...p, tools: new Set(p.tools) }]));
    for (const p of byId.values()) { p.sessionCount = 0; p.agentCount = 0; p.runningCount = 0; p.waitingCount = 0; p.noticeCount = 0; p.lastActivityAt = null; p.tokenTotal = null; }
    for (const s of sessions) {
      const p = byId.get(s.projectId);
      p.agentCount++;
      if (!s.parentId) p.sessionCount++;
      if (s.state === 'running') p.runningCount++;
      if (s.state === 'waiting') p.waitingCount++;
      else if (s.reportMissing || s.interrupted) p.noticeCount++;   // listed in /api/waiting, state unchanged
      const tk = s.tokens.total ?? s.tokens.context;   // adapters without usage data contribute nothing (no fake zeros)
      if (Number.isFinite(tk)) p.tokenTotal = (p.tokenTotal || 0) + tk;
      if (s.updatedAt && (!p.lastActivityAt || s.updatedAt > p.lastActivityAt)) p.lastActivityAt = s.updatedAt;
    }
    return [...byId.values()].map(p => ({ ...p, tools: [...p.tools].sort() }))
      .sort((a, b) => b.waitingCount - a.waitingCount || b.runningCount - a.runningCount || String(b.lastActivityAt).localeCompare(String(a.lastActivityAt)));
  }

  function emitDiff() {
    const hashes = new Map();
    for (const p of snap.projects) {
      const own = snap.sessions.filter(s => s.projectId === p.id)
        .map(s => [s.id, s.state, s.updatedAt, s.tokens.context, s.title, s.lastActivity && s.lastActivity.at, s.parentId, s.reportMissing || null, s.interrupted || null, s.taskId ?? null]);
      hashes.set(p.id, JSON.stringify([p.tools, p.sessionCount, p.agentCount, p.runningCount, p.waitingCount, p.noticeCount, p.lastActivityAt, own]));
    }
    const changed = [];
    for (const [id, h] of hashes) if (projectHashes.get(id) !== h) changed.push(id);
    for (const id of projectHashes.keys()) if (!hashes.has(id)) changed.push(id);
    const sh = JSON.stringify(snap.sources.map(s => [s.id, s.detected, s.health, s.lastError, s.counts, s.scanning, s.slow, s.scanProgress]));
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
      for (const src of snap.sources) {
        src.counts.running = snap.sessions.filter(s => s.tool === src.id && s.state === 'running').length;
        src.counts.waiting = snap.sessions.filter(s => s.tool === src.id && s.state === 'waiting').length;
      }
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
