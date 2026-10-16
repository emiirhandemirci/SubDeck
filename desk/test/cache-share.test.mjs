// desk/test/cache-share.test.mjs: prompt-cache share per agent and per session (read from transcripts, nothing stored).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readUsage } from '../adapters/claude-code.mjs';
import { cacheShareText, cumulativeTokensTitle } from '../public/format.js';
import './fixtures/tmpclean.mjs';

const USAGE = fileURLToPath(new URL('./fixtures/usage-agent.jsonl', import.meta.url));

test('readUsage: input incl. cache, request count and largest request', async () => {
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'cs-')), 'a.jsonl');
  fs.copyFileSync(USAGE, f);
  const u = await readUsage(f, fs.statSync(f), new Map());
  assert.deepEqual([u.cached, u.input, u.requests, u.largest], [2200, 2315, 2, 1205]);   // m1 streamed twice counts once
  fs.appendFileSync(f, JSON.stringify({ type: 'assistant', message: { usage: { input_tokens: 4000, output_tokens: 1 } } }) + '\n');   // no id: counted as its own request
  const v = await readUsage(f, fs.statSync(f), new Map());
  assert.deepEqual([v.cached, v.input, v.requests, v.largest], [2200, 6315, 3, 4000]);
});

test('cacheShareText: plain text, absent without data', () => {
  assert.equal(cacheShareText({ tokens: { cache: { read: 82000, input: 100000, requests: 38, largest: 65000 } } }), 'Cache 82 % · 38 requests · largest 65.0k');
  assert.equal(cacheShareText({ tokens: { cache: { read: 0, input: 500, requests: 1, largest: 500 } } }), 'Cache 0 % · 1 request · largest 500');
  assert.equal(cacheShareText({ tokens: { total: 5 } }), null);
  assert.equal(cacheShareText({ tokens: { cache: { read: 0, input: 0, requests: 0, largest: 0 } } }), null);
  assert.match(cumulativeTokensTitle({ tokens: { total: 10, cache: { read: 50, input: 100, requests: 2, largest: 60 } } }), /\nCache 50 % · 2 requests/);
});
