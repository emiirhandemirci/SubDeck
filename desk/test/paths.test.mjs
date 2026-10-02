// desk/test/paths.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { toSlash, normalizePath, projectKey, baseName, fileUriToPath, resolveEnv } from '../lib/paths.mjs';

test('toSlash converts backslashes', () => {
  assert.equal(toSlash('C:\\Users\\x\\proj'), 'C:/Users/x/proj');
});

test('normalizePath: drive letter lower-case, no trailing slash, dots resolved', () => {
  assert.equal(normalizePath('E:\\SubDeck\\'), 'e:/SubDeck');
  assert.equal(normalizePath('e:/SubDeck/./docs/..'), 'e:/SubDeck');
  assert.equal(normalizePath('/home/u/proj/'), '/home/u/proj');
  assert.equal(normalizePath('C:\\'), 'c:/');
  assert.equal(normalizePath(''), null);
  assert.equal(normalizePath(null), null);
});

test('projectKey folds case on win32 only', () => {
  assert.equal(projectKey('E:\\SubDeck', 'win32'), projectKey('e:/subdeck/', 'win32'));
  assert.equal(projectKey('C:\\Users\\X\\Proj', 'win32'), 'c:/users/x/proj');
  assert.notEqual(projectKey('/home/u/Proj', 'linux'), projectKey('/home/u/proj', 'linux'));
});

test('baseName handles both separators', () => {
  assert.equal(baseName('E:\\SubDeck'), 'SubDeck');
  assert.equal(baseName('/home/u/proj/'), 'proj');
});

test('fileUriToPath', () => {
  assert.equal(fileUriToPath('file:///c%3A/Users/x/proj', 'win32'), 'c:\\Users\\x\\proj');
  assert.equal(fileUriToPath('file:///home/u/proj', 'linux'), '/home/u/proj');
  assert.equal(fileUriToPath('vscode-remote://x/y', 'linux'), null);
  assert.equal(fileUriToPath('not a uri', 'linux'), null);
});

test('resolveEnv defaults per platform and overrides', () => {
  const w = resolveEnv({ APPDATA: 'C:\\Users\\u\\AppData\\Roaming' }, 'win32', 'C:\\Users\\u');
  assert.equal(toSlash(w.claudeProjectsDir), 'C:/Users/u/.claude/projects');
  assert.equal(toSlash(w.cursorUserDir), 'C:/Users/u/AppData/Roaming/Cursor/User');
  assert.equal(w.days, 14);
  const m = resolveEnv({}, 'darwin', '/Users/u');
  assert.equal(m.cursorUserDir, '/Users/u/Library/Application Support/Cursor/User');
  const l = resolveEnv({ SUBDECK_CLAUDE_PROJECTS_DIR: '/tmp/c', SUBDECK_CURSOR_USER_DIR: '/tmp/cu', SUBDECK_DISABLE: 'cursor, x' }, 'linux', '/home/u', { days: 3, now: () => 42 });
  assert.equal(l.claudeProjectsDir, '/tmp/c');
  assert.equal(l.cursorUserDir, '/tmp/cu');
  assert.deepEqual(l.disabled, ['cursor', 'x']);
  assert.equal(l.days, 3);
  assert.equal(l.now(), 42);
  assert.equal(resolveEnv({}, 'linux', '/home/u').cursorUserDir, '/home/u/.config/Cursor/User');
  assert.equal(resolveEnv({}, 'win32', 'C:\\u').cursorUserDir, null); // no APPDATA
});

test('resolveEnv exposes the environment map as vars', () => {
  const vars = { CODEX_HOME: '/x/codex', GEMINI_CLI_HOME: '/x/g', XDG_DATA_HOME: '/x/d' };
  const e = resolveEnv(vars, 'linux', '/home/u');
  assert.equal(e.vars.CODEX_HOME, '/x/codex');
  assert.equal(e.vars.XDG_DATA_HOME, '/x/d');
  assert.deepEqual(resolveEnv({}, 'linux', '/home/u').vars, {});
});

import { resolveHome, sandboxVars } from '../lib/paths.mjs';

test('resolveHome honours SUBDECK_HOME, then USERPROFILE (win32) or HOME, then the OS home', () => {
  assert.equal(resolveHome({ SUBDECK_HOME: '/s', HOME: '/h' }, 'linux', '/os'), '/s');
  assert.equal(resolveHome({ HOME: '/h' }, 'linux', '/os'), '/h');
  assert.equal(resolveHome({}, 'linux', '/os'), '/os');
  assert.equal(resolveHome({ USERPROFILE: 'C:\\u', HOME: '/h' }, 'win32', 'C:\\os'), 'C:\\u');
  assert.equal(resolveHome({ HOME: '/h' }, 'win32', 'C:\\os'), '/h');
  assert.equal(resolveHome({ SUBDECK_HOME: 'C:\\s', USERPROFILE: 'C:\\u' }, 'win32', 'C:\\os'), 'C:\\s');
});

test('with SUBDECK_HOME every derived data root stays inside it, ambient real-profile vars ignored', () => {
  for (const [platform, home] of [['win32', 'C:\\sandbox'], ['linux', '/sandbox'], ['darwin', '/sandbox']]) {
    const ambient = { SUBDECK_HOME: home, APPDATA: 'C:\\Real\\AppData\\Roaming', LOCALAPPDATA: 'C:\\Real\\AppData\\Local', XDG_CONFIG_HOME: '/real/.config', XDG_DATA_HOME: '/real/.local/share', HOME: '/real', USERPROFILE: 'C:\\Real' };
    const vars = sandboxVars(ambient, platform, home);
    const e = resolveEnv(vars, platform, home);
    const inside = p => toSlash(p).startsWith(toSlash(home) + '/');
    assert.ok(inside(e.claudeProjectsDir), e.claudeProjectsDir);
    assert.ok(e.cursorUserDir === null || inside(e.cursorUserDir), e.cursorUserDir);
    assert.ok(!e.appData || inside(e.appData), e.appData);
    assert.equal(vars.XDG_CONFIG_HOME, undefined);
    assert.equal(vars.XDG_DATA_HOME, undefined);
    assert.equal(vars.LOCALAPPDATA, undefined);
  }
  const plain = { HOME: '/h', XDG_DATA_HOME: '/x' };
  assert.equal(sandboxVars(plain, 'linux', '/h'), plain); // no override: untouched
});
