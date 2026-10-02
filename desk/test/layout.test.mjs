import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const css = fs.readFileSync(new URL('../public/style.css', import.meta.url), 'utf8');
const html = fs.readFileSync(new URL('../public/index.html', import.meta.url), 'utf8');

test('desktop layout: page locked to viewport, panes scroll on their own', () => {
  assert.match(css, /body \{[^}]*height: 100dvh;[^}]*overflow: hidden/);
  assert.match(css, /\.pane > \.pbody \{[^}]*min-height: 0;[^}]*overflow: auto/);
  for (const id of ['projects', 'map', 'detail']) assert.match(html, new RegExp(`id="${id}" class="pbody"`));
});

test('narrow layout: page scrolls again below 900px', () => {
  const m = css.match(/@media \(max-width: 900px\) \{([^}]*\}[^}]*)+/);
  assert.ok(m && /overflow: visible/.test(m[0]));
});
