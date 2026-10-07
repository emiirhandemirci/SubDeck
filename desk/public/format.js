// Pure display helpers shared by the browser UI and Node tests. No DOM access here.

export const STATE_LABEL = { waiting: 'waiting', running: 'running', idle: 'idle', finished: 'finished', failed: 'failed', stale: 'stale?', unknown: 'unknown' };
export const SOURCE_LABEL = { hook: 'from hook', field: 'from tool status', lock: 'from lock file', mtime: 'estimated from file activity', none: 'unknown' };
export const TOOL_BADGE = { 'claude-code': 'Claude', cursor: 'Cursor', codex: 'Codex', copilot: 'Copilot', gemini: 'Gemini', cline: 'Cline/Roo', opencode: 'OpenCode' };
export const GROUP_ORDER = ['Active now', 'Today', 'Last 7 days', 'Older'];

const pad = n => String(n).padStart(2, '0');

export function formatDuration(ms) {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) return '-';
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return h > 0 ? `${h}h${pad(m)}m${pad(sec)}s` : m > 0 ? `${m}m${pad(sec)}s` : `${sec}s`;
}

export function formatTokens(n) {
  if (n === null || n === undefined || !Number.isFinite(n)) return '-';
  if (n >= 999950) return (n / 1e6).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(n);
}

export function relativeTime(iso, nowMs) {
  const t = iso ? Date.parse(iso) : NaN;
  if (!Number.isFinite(t)) return '-';
  const d = Math.max(0, nowMs - t);
  if (d < 10000) return 'just now';
  if (d < 60000) return `${Math.floor(d / 1000)}s ago`;
  if (d < 3600000) return `${Math.floor(d / 60000)}m ago`;
  if (d < 86400000) return `${Math.floor(d / 3600000)}h ago`;
  return `${Math.floor(d / 86400000)}d ago`;
}

export function formatClock(iso) {
  const t = iso ? new Date(iso) : null;
  if (!t || Number.isNaN(t.getTime())) return '-';
  return `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`;
}

export function recencyGroup(p, nowMs) {
  if (p.runningCount > 0 || p.waitingCount > 0) return 'Active now';
  const t = p.lastActivityAt ? Date.parse(p.lastActivityAt) : NaN;
  if (!Number.isFinite(t)) return 'Older';
  const midnight = new Date(nowMs); midnight.setHours(0, 0, 0, 0);
  if (t >= midnight.getTime()) return 'Today';
  if (nowMs - t < 7 * 86400000) return 'Last 7 days';
  return 'Older';
}

export function groupProjects(projects, nowMs) {
  const m = new Map(GROUP_ORDER.map(g => [g, []]));
  for (const p of projects) m.get(recencyGroup(p, nowMs)).push(p);
  return GROUP_ORDER.map(label => ({ label, items: m.get(label) })).filter(g => g.items.length);
}

export function filterProjects(projects, { text = '', onlyActive = false, showTemp = true }, nowMs) {
  const q = text.trim().toLowerCase();
  return projects.filter(p => {
    if (!showTemp && p.temporary) return false;
    if (q && !p.name.toLowerCase().includes(q) && !(p.path || '').toLowerCase().includes(q)) return false;
    if (onlyActive) {
      const t = p.lastActivityAt ? Date.parse(p.lastActivityAt) : NaN;
      return p.runningCount > 0 || p.waitingCount > 0 || (Number.isFinite(t) && nowMs - t < 1800000);
    }
    return true;
  });
}

// Display-only: replace a leading home directory with "~" (case-insensitive, either separator).
export function tildify(p, home) {
  if (typeof p !== 'string' || !p || typeof home !== 'string' || !home) return p;
  const norm = s => s.replace(/\\/g, '/').toLowerCase();
  const h = norm(home).replace(/\/+$/, '');
  if (!h) return p;
  const n = norm(p);
  if (n === h) return '~';
  if (n.startsWith(h + '/')) return '~' + p.slice(h.length);
  return p;
}

// Display-only: replace every home-directory occurrence inside free text (titles, summaries, tool targets).
// The match must not start inside a longer path/word and must end at a separator or a non-name character.
export function tildifyText(text, home) {
  if (typeof text !== 'string' || !text || typeof home !== 'string' || !home) return text;
  const h = home.replace(/[\\/]+$/, '');
  if (!h) return text;
  const body = h.split(/[\\/]+/).map(x => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[\\\\/]+');
  const re = new RegExp('(^|[^A-Za-z0-9_.~-])' + body + '(?=$|[\\\\/]|[^A-Za-z0-9_.-])', 'gi');
  return text.replace(re, (m, pre) => pre + '~');
}

export function middleEllipsis(s, max) {
  if (!s) return '';
  const a = Array.from(s);
  if (a.length <= max) return s;
  const keep = max - 1, head = Math.ceil(keep / 2);
  return a.slice(0, head).join('') + '…' + a.slice(a.length - (keep - head)).join('');
}

/** Markdown-lite for the final report: paragraphs, "-"/"*" and "1." lists, `inline code`. Returns data only; the UI renders it with textContent, so nothing is ever parsed as HTML. */
export function markdownLite(text) {
  if (typeof text !== 'string' || !text.trim()) return [];
  const inline = s => {
    const out = [];
    s.split(/(`[^`]+`)/).forEach(part => {
      if (!part) return;
      if (part.length > 2 && part.startsWith('`') && part.endsWith('`')) out.push({ code: true, s: part.slice(1, -1) });
      else out.push({ code: false, s: part });
    });
    return out;
  };
  const blocks = [];
  let para = [], list = null;
  const flushPara = () => { if (para.length) { blocks.push({ type: 'p', inlines: inline(para.join(' ')) }); para = []; } };
  const flushList = () => { if (list) { blocks.push(list); list = null; } };
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trimEnd();
    if (!line.trim()) { flushPara(); flushList(); continue; }
    const ul = /^\s*[-*]\s+(.*)$/.exec(line), ol = /^\s*\d+[.)]\s+(.*)$/.exec(line);
    if (ul || ol) {
      flushPara();
      const type = ul ? 'ul' : 'ol';
      if (!list || list.type !== type) { flushList(); list = { type, items: [] }; }
      list.items.push(inline((ul || ol)[1]));
    } else { flushList(); para.push(line.trim()); }
  }
  flushPara(); flushList();
  return blocks;
}

export function formatToolTime(iso) {
  const t = iso ? new Date(iso) : null;
  return t && !Number.isNaN(t.getTime()) ? formatClock(iso) : '';
}

// ---------- context usage ----------
// Sources (checked 2026-10-01):
//  - https://code.claude.com/docs/en/model-config : "[1m]" is a suffix on the model setting (opus[1m], claude-opus-4-8[1m]);
//    "Claude Code strips the suffix before sending the model ID to your provider", so transcripts hold the plain id.
//    Fable 5.x, Sonnet 5+ and Opus 4.7+ always run 1M on the Anthropic API; Opus 4.6 / Sonnet 4.6 reach 1M only via [1m].
//  - https://platform.claude.com/docs/en/build-with-claude/context-windows : per-model window sizes; others are 200k.
//  - https://code.claude.com/docs/en/statusline : live context_window.context_window_size (not present in transcripts).
// Result: 1M when the id says [1m], the family/version is natively 1M, or the observed context exceeds 200k (proof).
// 200k only for a known 200k model. A model whose window depends on a stripped suffix (4.6, bare aliases, unknown
// versions) has an unknown window: tokens without a percentage.
export function contextWindow(model, ctx) {
  const id = typeof model === 'string' ? model.toLowerCase() : '';
  if (!/^claude[-.]|^(opus|sonnet|haiku|fable|mythos)\b|anthropic\/claude|\.claude-/.test(id)) return null;
  if (/\[1m\]|[-_]1m\b/.test(id)) return 1000000;
  if (Number.isFinite(ctx) && ctx > 200000) return 1000000;
  if (/fable|mythos/.test(id)) return 1000000;
  const m = /(opus|sonnet|haiku)-(\d{1,2})(?!\d)(?:-(\d{1,2})(?!\d))?/.exec(id);
  if (m) {
    const ver = Number(m[2]) + (m[3] ? Number(m[3]) / 100 : 0);
    if (m[1] === 'haiku') return 200000;
    if (ver >= 4.06 && ver < 4.07) return null;
    if (m[1] === 'sonnet') return ver >= 5 ? 1000000 : 200000;
    return ver >= 4.07 ? 1000000 : 200000;
  }
  if (/claude-\d+(-\d+)?-(opus|sonnet|haiku)/.test(id)) return 200000;
  return null;
}

export function usageLevel(pct) { return pct > 85 ? 'high' : pct >= 60 ? 'mid' : 'low'; }

/** null when there is no usage data; else { tokens, window, pct, level, text }. pct/window/level are null for unknown models. */
export function contextUsage(session, fallbackWindow = null) {
  const ctx = session && session.tokens ? session.tokens.context : null;
  if (ctx === null || ctx === undefined || !Number.isFinite(ctx)) return null;
  const fb = Number.isInteger(fallbackWindow) && fallbackWindow > 0 ? fallbackWindow : null;   // context.window setting: only for models whose window is unknown
  const window = contextWindow(session.model, ctx) || fb;
  if (!window) return { tokens: ctx, window: null, pct: null, level: null, text: `${formatTokens(ctx)} tokens` };
  const pct = Math.min(100, Math.round((ctx / window) * 100));
  return { tokens: ctx, window, pct, level: usageLevel(ctx / window * 100),
    text: `${formatTokens(ctx)} of ${formatTokens(window)} tokens (${pct}%)` };
}

/** Simple line diff of two strings: [{ t: ' ' | '-' | '+', s }]. Common head/tail trimmed, LCS on the middle (bounded; very large middles fall back to remove-all, add-all). */
export function lineDiff(a, b) {
  const lines = v => { if (v === '' || v === null || v === undefined) return []; const l = String(v).split('\n'); if (l.length > 1 && l[l.length - 1] === '') l.pop(); return l; };
  const x = lines(a), y = lines(b);
  let h = 0;
  while (h < x.length && h < y.length && x[h] === y[h]) h++;
  let t = 0;
  while (t < x.length - h && t < y.length - h && x[x.length - 1 - t] === y[y.length - 1 - t]) t++;
  const mx = x.slice(h, x.length - t), my = y.slice(h, y.length - t);
  const out = x.slice(0, h).map(s => ({ t: ' ', s }));
  if (mx.length * my.length > 250000) {
    for (const s of mx) out.push({ t: '-', s });
    for (const s of my) out.push({ t: '+', s });
  } else {
    const n = mx.length, m = my.length;
    const L = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = mx[i] === my[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
    let i = 0, j = 0;
    while (i < n && j < m) {
      if (mx[i] === my[j]) { out.push({ t: ' ', s: mx[i] }); i++; j++; }
      else if (L[i + 1][j] >= L[i][j + 1]) out.push({ t: '-', s: mx[i++] });
      else out.push({ t: '+', s: my[j++] });
    }
    while (i < n) out.push({ t: '-', s: mx[i++] });
    while (j < m) out.push({ t: '+', s: my[j++] });
  }
  for (const s of x.slice(x.length - t)) out.push({ t: ' ', s });
  return out;
}

/** Header badge status of a detected source: "scanning…" while a first or slow scan is still running, else its health. */
export function sourceStatus(s) { return s && s.scanning ? 'scanning…' : (s && s.health) || 'ok'; }

/** Text for an empty project list. A source that is still scanning or failed is never reported as "no sessions". */
export function emptyProjectsText(sources, days) {
  const all = Array.isArray(sources) ? sources : [];
  if (!all.length) return 'Scanning…';
  const scanning = all.filter(s => s.detected && s.scanning);
  if (scanning.length) return `Scanning ${scanning.map(s => s.label).join(', ')} history…`;
  const failed = all.filter(s => s.health === 'error');
  if (failed.length) return failed.map(s => `${s.label}: ${s.lastError || 'error'}`).join('; ');
  if (!all.some(s => s.detected)) return 'No supported AI coding tool data found (looked for: ' + all.map(s => s.label).join(', ') + ').';
  return `No sessions in the last ${days} days.`;
}

/** Text when filters leave no project; mentions temporary projects hidden by the toggle. */
export function noMatchText(hiddenTemp) {
  return hiddenTemp > 0 ? `No projects match. ${hiddenTemp} temporary project${hiddenTemp === 1 ? ' is' : 's are'} hidden (tick "Show temporary projects").` : 'No projects match.';
}
