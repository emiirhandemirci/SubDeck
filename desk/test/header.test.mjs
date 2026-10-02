// desk/test/header.test.mjs: the header keeps one row, with an info popover instead of "not detected (N)" text.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const read = f => fs.readFileSync(path.join(pub, f), 'utf8');

test('index.html: info button with an accessible label, popover dialog and +N button', () => {
  const h = read('index.html');
  assert.match(h, /id="srcInfo"[^>]*aria-label="Tool detection details"/);
  assert.match(h, /id="srcPanel"[^>]*role="dialog"/);
  assert.match(h, /id="srcMore"/);
  assert.ok(!/not detected \(/.test(h));
});

test('app.js: no "not detected (N)" summary, popover closes on Esc and outside click, no innerHTML', () => {
  const a = read('app.js');
  assert.ok(!/absent-sources|`not detected \(/.test(a));
  assert.match(a, /Not detected \(/);
  assert.match(a, /key === 'Escape' && sp\.open/);
  assert.match(a, /closest\('#srcPanel, #srcInfo, #srcMore'\)/);
  for (const f of ['app.js', 'settings.js']) assert.ok(!/innerHTML|insertAdjacentHTML/.test(read(f)), `${f} must not use innerHTML`);
});

test('style.css: header stays on one row above 900px, wraps below', () => {
  const c = read('style.css');
  assert.match(c, /\.top \{[^}]*flex-wrap: nowrap/);
  assert.match(c, /@media \(max-width: 900px\) \{\s*\.top \{ flex-wrap: wrap/);
});
