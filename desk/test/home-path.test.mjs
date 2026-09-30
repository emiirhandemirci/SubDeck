import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import { tildify } from '../public/format.js';
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
