// desk/lib/model.mjs
// Tool-neutral model helpers (spec section 4). Plain objects only.
import { createHash } from 'node:crypto';

export const RUNNING_MS = 120000;
export const IDLE_MS = 1800000;
export const STALE_MS = 300000;
export const WAITING_MS = 21600000;   // a pending prompt older than this is treated as abandoned
export const STATES = ['waiting', 'running', 'idle', 'finished', 'failed', 'stale', 'unknown'];
export const STATE_SOURCES = ['hook', 'field', 'lock', 'mtime', 'none'];
const KINDS = ['user', 'assistant', 'tool', 'other'];
const TITLE_SOURCES = ['explicit', 'summary', 'meta', 'fallback'];

/** Single line, trimmed, at most `max` code points (max-1 + '…' when cut). */
export function clip(s, max) {
  if (s === null || s === undefined) return null;
  const one = String(s).replace(/\s+/g, ' ').trim();
  if (!one) return null;
  const cps = Array.from(one);
  return cps.length > max ? cps.slice(0, max - 1).join('') + '…' : one;
}

export function deriveState(basis, nowMs) {
  if (!basis) return { state: 'unknown', stateSource: 'none' };
  if (basis.kind === 'fixed') return { state: basis.state, stateSource: basis.stateSource };
  const t = basis.at ? Date.parse(basis.at) : NaN;
  if (!Number.isFinite(t)) return { state: 'unknown', stateSource: 'none' };
  const age = nowMs - t;
  if (basis.kind === 'waiting' && Number.isFinite(t) && age <= WAITING_MS) return { state: 'waiting', stateSource: basis.stateSource };
  if (basis.kind === 'hookOpen') return { state: age > STALE_MS ? 'stale' : 'running', stateSource: 'hook' };
  if (basis.kind === 'waiting') return deriveState({ kind: 'mtime', at: basis.fallbackAt || null, stateSource: 'mtime' }, nowMs);
  if (basis.kind === 'mtime') return { state: age < RUNNING_MS ? 'running' : age < IDLE_MS ? 'idle' : 'finished', stateSource: 'mtime' };
  return { state: 'unknown', stateSource: 'none' };
}

const str = v => typeof v === 'string' && v.length > 0;
const optStr = v => v === null || v === undefined || typeof v === 'string';
const optNum = v => v === null || v === undefined || (typeof v === 'number' && Number.isFinite(v));

export function validateAdapterSession(s) {
  const fail = error => ({ ok: false, error });
  if (!s || typeof s !== 'object') return fail('not an object');
  if (!str(s.nativeId)) return fail('nativeId');
  if (!str(s.tool)) return fail('tool');
  if (!str(s.title)) return fail('title');
  if (!TITLE_SOURCES.includes(s.titleSource)) return fail('titleSource');
  if (!str(s.projectPath) && !str(s.projectLabel)) return fail('project');
  for (const k of ['parentNativeId', 'agentType', 'model', 'createdAt', 'runStartedAt', 'updatedAt', 'endedAt']) if (!optStr(s[k])) return fail(k);
  if (!s.tokens || !optNum(s.tokens.context) || !optNum(s.tokens.total)) return fail('tokens');
  if (s.lastActivity && !KINDS.includes(s.lastActivity.kind)) return fail('lastActivity.kind');
  const b = s.stateBasis;
  if (!b || !['fixed', 'mtime', 'hookOpen', 'waiting'].includes(b.kind)) return fail('stateBasis');
  if (b.kind === 'fixed' && (!STATES.includes(b.state) || !STATE_SOURCES.includes(b.stateSource))) return fail('stateBasis.fixed');
  return { ok: true };
}

export function makeSource({ tool, label, adapterVersion, experimental }) {
  return { id: tool, tool, label, adapterVersion, experimental: !!experimental, detected: false, health: 'ok', lastError: null,
    lastScanAt: null, scanMs: null, counts: { projects: 0, sessions: 0, running: 0, waiting: 0, skipped: 0 } };
}

export function sessionIdOf(toolShort, nativeId) {
  return `${toolShort}.${String(nativeId).replace(/[^A-Za-z0-9._-]/g, '_')}`;
}

export function projectIdOf(key) {
  return 'p_' + createHash('sha1').update(key).digest('hex').slice(0, 12);
}
