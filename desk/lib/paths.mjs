// desk/lib/paths.mjs
// Cross-platform path helpers. Keys compare paths; display paths keep the original spelling.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function toSlash(p) { return String(p).replace(/\\/g, '/'); }

export function normalizePath(p) {
  if (p === null || p === undefined || p === '') return null;
  let s = path.posix.normalize(toSlash(p));
  s = s.replace(/^([A-Za-z]):/, (_, d) => d.toLowerCase() + ':');
  if (s.length > 1 && s.endsWith('/') && !/^[a-z]:\/$/.test(s)) s = s.slice(0, -1);
  return s;
}

export function projectKey(p, platform) {
  const n = normalizePath(p);
  if (n === null) return null;
  return platform === 'win32' ? n.toLowerCase() : n;
}

export function baseName(p) {
  const n = normalizePath(p) || '';
  const parts = n.split('/').filter(Boolean);
  return parts.length ? parts[parts.length - 1] : n;
}

export function fileUriToPath(uri, platform) {
  if (typeof uri !== 'string' || !uri.startsWith('file:')) return null;
  try { return fileURLToPath(uri, { windows: platform === 'win32' }); } catch { return null; }
}

export function resolveEnv(vars, platform, home, opts = {}) {
  const join = platform === 'win32' ? path.win32.join : path.posix.join;
  let cursorUserDir = null;
  if (vars.SUBDECK_CURSOR_USER_DIR) cursorUserDir = vars.SUBDECK_CURSOR_USER_DIR;
  else if (platform === 'win32') cursorUserDir = vars.APPDATA ? join(vars.APPDATA, 'Cursor', 'User') : null;
  else if (platform === 'darwin') cursorUserDir = join(home, 'Library', 'Application Support', 'Cursor', 'User');
  else cursorUserDir = join(home, '.config', 'Cursor', 'User');
  return {
    home,
    appData: vars.APPDATA || null,
    platform,
    now: opts.now || Date.now,
    days: opts.days || 14,
    claudeProjectsDir: vars.SUBDECK_CLAUDE_PROJECTS_DIR || join(home, '.claude', 'projects'),
    cursorUserDir,
    disabled: (vars.SUBDECK_DISABLE || '').split(',').map(s => s.trim()).filter(Boolean),
  };
}
