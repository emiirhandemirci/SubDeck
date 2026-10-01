import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import { tildify, tildifyText } from '../public/format.js';
import { createApi } from '../lib/api.mjs';

test('tildify replaces home prefix, both separators, case-insensitive', () => {
  assert.equal(tildify('C:\\Users\\Someone\\AppData\\x', 'C:\\Users\\Someone'), '~\\AppData\\x');
  assert.equal(tildify('c:/users/someone/proj', 'C:\\Users\\Someone'), '~/proj');
  assert.equal(tildify('/home/al/projects/x', '/home/al'), '~/projects/x');
  assert.equal(tildify('/home/al', '/home/al/'), '~');
});

test('tildify leaves non-home and lookalike paths alone', () => {
  assert.equal(tildify('/home/alice/x', '/home/al'), '/home/alice/x');
  assert.equal(tildify('/srv/x', '/home/al'), '/srv/x');
  assert.equal(tildify('/srv/x', ''), '/srv/x');
  assert.equal(tildify('', '/home/al'), '');
  assert.equal(tildify('/x', undefined), '/x');
});

test('/api/sources exposes home dir as an additive top-level field', async () => {
  const api = createApi({ core: { snapshot: () => ({ sources: [], projects: [] }) }, getPort: () => 7777, startedAt: 0, days: 14, version: 't', publicDir: '.' });
  let body = '';
  const res = { writeHead() {}, end(b) { body += b || ''; } };
  await api.handle({ method: 'GET', url: '/api/sources', headers: { host: '127.0.0.1:7777' } }, res);
  const j = JSON.parse(body);
  assert.equal(j.home, os.homedir());
  assert.equal(j.server.days, 14);
});

test('tildifyText rewrites home paths inside free text, boundary-safe', () => {
  const home = 'C:\\Users\\Someone';
  assert.equal(tildifyText('Read C:\\Users\\Someone\\proj\\a.txt now', home), 'Read ~\\proj\\a.txt now');
  assert.equal(tildifyText('"c:/users/someone/x" and C:\\Users\\Someone', home), '"~/x" and ~');
  assert.equal(tildifyText('C:\\Users\\SomeoneElse\\x', home), 'C:\\Users\\SomeoneElse\\x');
  assert.equal(tildifyText('see /home/al/a and /home/al/b', '/home/al'), 'see ~/a and ~/b');
  assert.equal(tildifyText('/home/alice/a', '/home/al'), '/home/alice/a');
  assert.equal(tildifyText('/mnt/home/al/a', '/home/al'), '/mnt/home/al/a');
  assert.equal(tildifyText('no path', ''), 'no path');
  assert.equal(tildifyText(null, '/home/al'), null);
});
