// desk/test/state-key.test.mjs
// Per-project state dir key: Desk must produce exactly what plugins/subdeck/scripts/lib-paths.sh produces.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { stateKeyPath, stateKey, stateRoot, stateDirs, resolveEnv } from '../lib/paths.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const rows = fs.readFileSync(path.join(here, 'fixtures', 'state-keys.tsv'), 'utf8').split('\n')
  .filter(l => l && !l.startsWith('#')).map(l => l.replace(/\r$/, '').split('\t'));

test('state key fixture has the Windows spellings of one project', () => {
  const win = rows.filter(r => r[0] === 'win' && r[2] === 'e:/x').map(r => r[1]);
  for (const s of ['E:\\x', '/e/x', 'E:/x', 'e:\\x\\', 'E:\\X']) assert.ok(win.includes(s), s);
  assert.ok(rows.length >= 20);
});

for (const [pl, input, norm, key] of rows) {
  test(`stateKey ${pl} ${JSON.stringify(input)}`, () => {
    const platform = pl === 'win' ? 'win32' : 'linux';
    assert.equal(stateKeyPath(input, platform), norm);
    assert.equal(stateKey(input, platform), key);
  });
}

test('stateKey: empty input gives null; key is filesystem-safe', () => {
  assert.equal(stateKey('', 'linux'), null);
  assert.equal(stateKey(null, 'win32'), null);
  for (const [pl, input] of rows) assert.match(stateKey(input, pl === 'win' ? 'win32' : 'linux'), /^[A-Za-z0-9._-]{1,32}-[0-9a-f]{8}$/);
});

test('stateRoot: SUBDECK_STATE_DIR wins, else <home>/.subdeck/projects; MSYS form converted on Windows', () => {
  assert.equal(stateRoot({}, 'linux', '/home/u'), '/home/u/.subdeck/projects');
  assert.equal(stateRoot({ SUBDECK_STATE_DIR: '/s/state' }, 'linux', '/home/u'), '/s/state');
  assert.equal(stateRoot({}, 'win32', 'C:\\Users\\u'), 'C:\\Users\\u\\.subdeck\\projects');
  assert.equal(stateRoot({ SUBDECK_STATE_DIR: '/d/state' }, 'win32', 'C:\\u'), 'D:/state');
  assert.equal(resolveEnv({}, 'linux', '/home/u').stateRoot, '/home/u/.subdeck/projects');
});

test('stateDirs: new location first, legacy <project>/.subdeck second', () => {
  const env = resolveEnv({ SUBDECK_STATE_DIR: '/st' }, 'linux', '/home/u');
  const d = stateDirs('/work/proj', env);
  assert.equal(d.length, 2);
  assert.equal(d[0], '/st/' + stateKey('/work/proj', 'linux'));
  assert.equal(path.basename(d[1]), '.subdeck');
  assert.deepEqual(stateDirs(null, env), []);
});
