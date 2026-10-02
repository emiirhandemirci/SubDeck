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

/**
 * One override point for the data root. Precedence: SUBDECK_HOME, then USERPROFILE (Windows) or HOME,
 * then the OS answer. Node's os.homedir() on Windows ignores HOME, so it is only the last resort.
 */
export function resolveHome(vars, platform, osHome) {
  const v = vars || {};
  const pick = platform === 'win32' ? [v.SUBDECK_HOME, v.USERPROFILE, v.HOME] : [v.SUBDECK_HOME, v.HOME];
  for (const x of pick) if (typeof x === 'string' && x) return x;
  return osHome;
}

/**
 * With SUBDECK_HOME set, ambient per-user variables that point at the real profile (APPDATA, LOCALAPPDATA,
 * XDG_*) are replaced or dropped so every derived path stays inside the override. Explicit SUBDECK_* and
 * per-tool variables (CODEX_HOME, ...) are kept as given. Without SUBDECK_HOME the map is returned unchanged.
 */
export function sandboxVars(vars, platform, home) {
  if (!vars || !vars.SUBDECK_HOME) return vars;
  const out = { ...vars };
  for (const k of Object.keys(out)) if (k.startsWith('XDG_')) delete out[k];
  delete out.LOCALAPPDATA;
  delete out.APPDATA;
  if (platform === 'win32') {
    out.APPDATA = path.win32.join(home, 'AppData', 'Roaming');
    out.USERPROFILE = home;
  }
  out.HOME = home;
  return out;
}

export function resolveEnv(vars, platform, home, opts = {}) {
  const join = platform === 'win32' ? path.win32.join : path.posix.join;
  let cursorUserDir = null;
  if (vars.SUBDECK_CURSOR_USER_DIR) cursorUserDir = vars.SUBDECK_CURSOR_USER_DIR;
  else if (platform === 'win32') cursorUserDir = vars.APPDATA ? join(vars.APPDATA, 'Cursor', 'User') : null;
  else if (platform === 'darwin') cursorUserDir = join(home, 'Library', 'Application Support', 'Cursor', 'User');
  else cursorUserDir = join(home, '.config', 'Cursor', 'User');
  const tmp = [vars.TMPDIR, vars.TEMP, vars.TMP];
  if (platform === 'win32') { if (home) tmp.push(join(home, 'AppData', 'Local', 'Temp')); }
  else tmp.push('/tmp', '/var/tmp', ...(platform === 'darwin' ? ['/private/tmp', '/private/var/folders'] : []));
  return {
    home,
    tmpDirs: [...new Set(tmp.filter(x => typeof x === 'string' && x))],
    vars,
    appData: vars.APPDATA || null,
    platform,
    now: opts.now || Date.now,
    days: opts.days || 14,
    claudeProjectsDir: vars.SUBDECK_CLAUDE_PROJECTS_DIR || join(home, '.claude', 'projects'),
    cursorUserDir,
    disabled: (vars.SUBDECK_DISABLE || '').split(',').map(s => s.trim()).filter(Boolean),
  };
}

/** True when the path equals or lies inside one of the temp directories (compared with projectKey rules). */
export function isInside(p, dirs, platform) {
  const k = projectKey(p, platform);
  if (k === null) return false;
  for (const d of dirs || []) {
    const t = projectKey(d, platform);
    if (t && t !== '/' && (k === t || k.startsWith(t + '/'))) return true;
  }
  return false;
}

const SECRET_BASE = [/^\.env(\..*)?$/i, /^\.(npmrc|netrc|pypirc|git-credentials|htpasswd)$/i, /\.(pem|key|p12|pfx|jks|keystore|kdbx|ppk)$/i,
  /^id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$/i, /^(credentials?|secrets?)(\.[a-z0-9]+)?$/i, /^service-?account.*\.json$/i];

/** True for files that commonly hold secrets (.env, keys, credentials); their contents are never served. */
export function isSecretPath(p) {
  const base = toSlash(p).split('/').filter(Boolean).pop() || '';
  return SECRET_BASE.some(re => re.test(base));
}

/** Path of p relative to dir (forward slashes), or null when p is not inside dir. Compared with projectKey rules. */
export function relativeTo(p, dir, platform) {
  const a = normalizePath(p), b = normalizePath(dir);
  if (!a || !b) return null;
  const ka = platform === 'win32' ? a.toLowerCase() : a, kb = platform === 'win32' ? b.toLowerCase() : b;
  return ka.startsWith(kb + '/') ? a.slice(b.length + 1) : null;
}
