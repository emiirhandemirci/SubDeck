// desk/test/settings-ui.test.mjs: Settings tab layout and bell/switch sync wiring (static checks on the public files)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');
const rd = f => fs.readFileSync(path.join(pub, f), 'utf8').replace(/\r\n/g, '\n');
const css = rd('style.css'), settings = rd('settings.js'), app = rd('app.js');

test('settings rows use one fixed control column and a narrow tag column', () => {
  assert.match(css, /\.srow \{[^}]*grid-template-columns: minmax\(0, 1fr\) 170px 84px/);
  assert.match(css, /\.srow select[^{]*\{[^}]*width: 170px/);
  assert.match(css, /\.srow \.tag \{[^}]*grid-area: tag/);
});
test('switches carry no On/Off text but keep an accessible label', () => {
  assert.ok(!settings.includes('sw-label'));
  assert.match(settings, /b\.setAttribute\('aria-label', item\.key\)/);
  assert.match(settings, /aria-checked/);
});
test('enum lists render toggle chips and keep at least one selected; free lists put the input above the chips', () => {
  assert.match(settings, /item\.type === 'list' && Array\.isArray\(item\.options\)/);
  assert.match(settings, /needs at least one option selected/);
  assert.match(settings, /aria-pressed/);
  const free = settings.slice(settings.indexOf("el('div', 'lwrap')"));
  assert.ok(free.indexOf('wrap.append(add)') < free.indexOf("el('div', 'chips')"));
});
test('bell and settings switch share state both ways', () => {
  assert.match(settings, /onNotify\(isOn\(next\)\)/);
  assert.match(settings, /function setNotify/);
  assert.match(app, /onNotify: on =>/);
  assert.match(app, /settingsUi\.setNotify\(S\.notify\)/);
});
