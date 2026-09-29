// desk/test/claude-code.test.mjs  (reader part; Task B2 appends scan tests to this file)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { parseJsonl, summarizeRecords, readTranscript, TAIL_BYTES } from '../adapters/claude-code.mjs';
import { rec, usage, writeJsonl, tmpDir } from './fixtures/claude-fixture.mjs';

const T = '2026-09-29T10:00:00.000Z';

test('parseJsonl: CRLF, malformed counted, partial trailing line is not counted as skipped', () => {
  const r = parseJsonl('{"a":1}\r\nnot json\n{"b":2}\n{"c":');
  assert.equal(r.records.length, 2);
  assert.equal(r.bad, 1);
  const d = parseJsonl('tail-of-a-line"}\n{"a":1}\n', { dropFirst: true });
  assert.deepEqual(d, { records: [{ a: 1 }], bad: 0 });
});

test('summarizeRecords: last usage line wins (no summing), titles, model', () => {
  const s = summarizeRecords([
    rec.aiTitle('Old'), rec.text(T, 'a', usage(10, 100, 1000, 5)),
    rec.tool(T, 'Edit', { file_path: '/a/b.sh' }, usage(10, 100, 79000, 390)),
    rec.aiTitle('New title'), rec.customTitle('Renamed'),
  ]);
  assert.equal(s.tokens, 79500);
  assert.equal(s.aiTitle, 'New title');
  assert.equal(s.customTitle, 'Renamed');
  assert.equal(s.model, 'claude-sonnet-4-5');
});

test('summarizeRecords: last activity kinds and privacy', () => {
  const at = n => `2026-09-29T10:00:0${n}.000Z`;
  assert.deepEqual(summarizeRecords([rec.tool(at(1), 'Read', { file_path: 'C:\\x\\main.rs', limit: 5 })]).lastActivity,
    { at: at(1), kind: 'tool', toolName: 'Read', summary: 'Read C:\\x\\main.rs' });
  assert.deepEqual(summarizeRecords([rec.text(at(2), 'First line\nsecond line')]).lastActivity,
    { at: at(2), kind: 'assistant', toolName: null, summary: 'First line' });
  assert.deepEqual(summarizeRecords([rec.text(at(1), 'x'), rec.toolResult(at(3))]).lastActivity,
    { at: at(3), kind: 'tool', toolName: null, summary: null });
  assert.deepEqual(summarizeRecords([rec.user(at(4), '/p')]).lastActivity,
    { at: at(4), kind: 'user', toolName: null, summary: null });
  assert.deepEqual(summarizeRecords([rec.thinking(at(5))]).lastActivity,
    { at: at(5), kind: 'assistant', toolName: null, summary: null });
  assert.equal(summarizeRecords([rec.text(at(1), 'y'.repeat(200))]).lastActivity.summary.length, 80);
  assert.equal(summarizeRecords([{ type: 'assistant', message: { content: [] } }]).tokens, null);
});

test('readTranscript: head gives cwd/createdAt; tail grows to 256 KB when no usage in 64 KB', async () => {
  const dir = tmpDir('desk-cc-');
  const f = path.join(dir, 's.jsonl');
  const filler = rec.text(T, 'z'.repeat(1000));
  const lines = [rec.attachment(T, 'E:\\Work\\Alpha'), rec.tool(T, 'Bash', { command: 'npm test' }, usage(1, 2, 3, 4))];
  for (let i = 0; i < 100; i++) lines.push(filler);           // ~100 KB without usage after the usage line
  writeJsonl(f, lines);
  const st = fs.statSync(f);
  assert.ok(st.size > TAIL_BYTES);
  const cache = new Map();
  const r = await readTranscript(f, st, cache, { growIfNoUsage: true });
  assert.equal(r.cwd, 'E:\\Work\\Alpha');
  assert.equal(r.createdAt, T);
  assert.equal(r.tokens, 10);
  assert.equal(r.bad, 0);                                        // cut first line of the tail window is dropped, not counted
  assert.equal(cache.size, 1);
  const again = await readTranscript(f, st, cache, { growIfNoUsage: true });
  assert.equal(again, r);                                        // cached by path|size|mtime
});
