// desk/test/theme.test.mjs: palette contrast (WCAG AA) in both themes, theme wiring, settings helpers, context.window fallback.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { contextUsage } from '../public/format.js';
import { confirmText, groupItems, isOn, listValue, toWire, isReadOnly, THEMES } from '../public/settings.js';

const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const css = fs.readFileSync(path.join(pub, 'style.css'), 'utf8').replace(/\r\n/g, '\n');

function block(open) {
  const i = css.indexOf(open);
  assert.ok(i >= 0, `css block ${open}`);
  const j = css.indexOf('\n}', i);
  return css.slice(i + open.length, j);
}
function vars(text) { const o = {}; for (const m of text.matchAll(/--([a-z-]+):\s*(#[0-9a-fA-F]{6})\b/g)) o[m[1]] = m[2]; return o; }
const dark = vars(block(':root {'));
const light = vars(block(':root[data-theme="light"] {'));
const lum = hex => { const c = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255).map(v => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

const FG = ['text', 'muted', 'accent', 'waiting', 'running', 'idle', 'finished', 'failed', 'stale', 'claude', 'cursor', 'codex', 'copilot', 'gemini', 'cline', 'opencode'];
const BG = ['bg', 'panel', 'card', 'raised', 'sel'];
for (const [name, v] of [['dark', dark], ['light', light]]) {
  test(`WCAG AA text contrast (4.5:1) in the ${name} theme`, () => {
    const bad = [];
    for (const f of FG) for (const b of BG) {
      if (!v[f] || !v[b]) { bad.push(`${f}/${b} undefined`); continue; }
      const r = ratio(v[f], v[b]);
      if (r < 4.5) bad.push(`${f} on ${b}: ${r.toFixed(2)}`);
    }
    assert.deepEqual(bad, []);
  });
  test(`${name} theme: non-text accents (focus, bars) reach 3:1 on the panel`, () => {
    for (const f of ['focus', 'use-low', 'use-mid', 'use-high']) assert.ok(ratio(v[f], v.panel) >= 3, `${f} ${ratio(v[f], v.panel).toFixed(2)}`);
  });
  test(`${name} theme: danger button text reaches 4.5:1`, () => {
    const d = css.match(name === 'dark' ? /--danger-bg: (#[0-9a-f]{6}); --danger-fg: (#[0-9a-f]{6})/ : /--danger-bg: (#[0-9a-f]{6}); --danger-fg: (#[0-9a-f]{6});\n\}\n:root\[data-theme="dark"\]/);
    assert.ok(ratio(d[1], d[2]) >= 4.5);
  });
}

test('the dark palette is deeper than before and light stays light', () => {
  assert.ok(lum(dark.bg) < lum('#0a0c10'));
  assert.ok(lum(light.bg) > 0.5);
});

test('system light block and explicit light block carry the same variables', () => {
  const media = vars(block('  :root:not([data-theme="dark"]) {'));
  assert.deepEqual(media, light);
  assert.match(css, /prefers-reduced-motion: reduce[\s\S]*animation: none !important/);
  assert.match(css, /--diff-add/);
  assert.match(css, /\.diff \.dl\.add \{ background: var\(--diff-add\)/);
});

test('theme.js applies a stored theme, ignores junk and unavailable storage', () => {
  const src = fs.readFileSync(path.join(pub, 'theme.js'), 'utf8');
  const run = (stored, throwing = false) => {
    const attrs = {};
    const ctx = { localStorage: { getItem: () => { if (throwing) throw new Error('blocked'); return stored; } }, document: { documentElement: { setAttribute: (k, v) => { attrs[k] = v; } } } };
    vm.runInNewContext(src, ctx);
    return attrs;
  };
  assert.deepEqual(run('"dark"'), { 'data-theme': 'dark' });
  assert.deepEqual(run('"light"'), { 'data-theme': 'light' });
  assert.deepEqual(run('"system"'), {});
  assert.deepEqual(run('{nope'), {});
  assert.deepEqual(run(null), {});
  assert.deepEqual(run('"dark"', true), {});
});

test('index.html: theme script before the stylesheet consumers, switch, tabs and in-page dialog', () => {
  const h = fs.readFileSync(path.join(pub, 'index.html'), 'utf8');
  for (const id of ['themeSwitch', 'tabSettings', 'settingsView', 'confirmDlg', 'scopeSwitch', 'settingsBody']) assert.match(h, new RegExp(`id="${id}"`));
  assert.match(h, /<script src="\/theme\.js"><\/script>/);
  assert.ok(!/<script>/.test(h), 'no inline script (CSP)');
  assert.ok(!/window\.confirm|[^A-Za-z]confirm\(/.test(fs.readFileSync(path.join(pub, 'settings.js'), 'utf8')), 'no window.confirm');
});

test('settings helpers: confirm only when protection drops', () => {
  const rule = { key: 'force-push', group: 'guard', type: 'enum' };
  assert.match(confirmText(rule, 'off'), /Turn off force-push/);
  assert.equal(confirmText(rule, 'ask'), null);
  assert.equal(confirmText(rule, 'deny'), null);
  assert.match(confirmText({ key: 'push', group: 'push' }, 'off'), /push/i);
  assert.equal(confirmText({ key: 'push', group: 'push' }, 'branches'), null);
  assert.equal(confirmText({ key: 'notify', group: 'notify', type: 'bool' }, 'off'), null);
});

test('settings helpers: values, wire format, grouping, read-only', () => {
  assert.equal(isOn('on'), true); assert.equal(isOn(true), true); assert.equal(isOn('off'), false);
  assert.deepEqual(listValue(['a', 'b']), ['a', 'b']);
  assert.deepEqual(listValue('a, b,,c'), ['a', 'b', 'c']);
  assert.deepEqual(listValue(null), []);
  assert.equal(toWire({ type: 'bool' }, true), 'on');
  assert.equal(toWire({ type: 'list' }, ['x', 'y']), 'x,y');
  assert.equal(toWire({ type: 'int' }, 5), '5');
  assert.equal(isReadOnly({ key: 'statusline' }), true);
  assert.equal(isReadOnly({ key: 'notify' }), false);
  const g = groupItems([{ key: 'worker', group: 'models' }, { key: 'x', group: 'weird' }, { key: 'notify', group: 'notify' }]);
  assert.deepEqual(g.map(x => x.id), ['models', 'notify', 'other']);
  assert.deepEqual(THEMES.map(t => t[0]), ['system', 'light', 'dark']);
});

test('context.window is used only for models whose window is unknown', () => {
  const s = (model, ctx) => ({ model, tokens: { context: ctx } });
  assert.equal(contextUsage(s('some-local-model', 50000)).pct, null);
  const u = contextUsage(s('some-local-model', 50000), 100000);
  assert.equal(u.window, 100000); assert.equal(u.pct, 50);
  assert.equal(contextUsage(s('claude-sonnet-4-5', 100000), 123456).window, 200000, 'known window wins');
  assert.equal(contextUsage(s('some-local-model', 50000), 0).pct, null);
  assert.equal(contextUsage(s('some-local-model', 500000), 100000).pct, 100);
});
