import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { readContent, contentReadStats } from '../adapters/claude-code.mjs';
import { rec, writeJsonl, tmpDir } from './fixtures/claude-fixture.mjs';

const T = '2026-09-29T10:00:00.000Z';
const targets = c => c.toolCalls.map(t => t.target);
const line = o => JSON.stringify(o) + '\n';

test('readContent: appended records are picked up incrementally', async () => {
  const f = path.join(tmpDir('desk-cc-'), 's.jsonl');
  writeJsonl(f, [rec.user(T, '/p', 'hello'), rec.tool(T, 'Read', { file_path: '/a' })]);
  let c = await readContent(f, { subagent: false });
  assert.deepEqual(targets(c), ['/a']);
  fs.appendFileSync(f, line(rec.tool(T, 'Read', { file_path: '/b' })) + line(rec.text(T, 'done')));
  c = await readContent(f, { subagent: false });
  assert.deepEqual(targets(c), ['/a', '/b']);
  assert.equal(c.toolCallTotal, 2);
  assert.equal(c.finalReport, 'done');
  assert.equal(c.prompt, 'hello');
});

test('readContent: a partially written trailing line is shown if valid but only committed once terminated', async () => {
  const f = path.join(tmpDir('desk-cc-'), 's.jsonl');
  writeJsonl(f, [rec.user(T, '/p', 'hi')]);
  await readContent(f, { subagent: false });
  const full = JSON.stringify(rec.tool(T, 'Read', { file_path: '/x' }));
  fs.appendFileSync(f, full.slice(0, 20));
  assert.deepEqual(targets(await readContent(f, { subagent: false })), []);
  fs.appendFileSync(f, full.slice(20));
  assert.deepEqual(targets(await readContent(f, { subagent: false })), ['/x']);   // unterminated but complete JSON
  fs.appendFileSync(f, '\n');
  assert.deepEqual(targets(await readContent(f, { subagent: false })), ['/x']);
  assert.equal((await readContent(f, { subagent: false })).toolCallTotal, 1);
});

test('readContent: a truncated or replaced file is re-read from scratch', async () => {
  const dir = tmpDir('desk-cc-');
  const f = path.join(dir, 's.jsonl');
  writeJsonl(f, [rec.user(T, '/p', 'first'), rec.tool(T, 'Read', { file_path: '/a' }), rec.tool(T, 'Read', { file_path: '/b' }), rec.tool(T, 'Read', { file_path: '/c' })]);
  assert.equal((await readContent(f, { subagent: false })).toolCallTotal, 3);
  writeJsonl(f, [rec.user(T, '/p', 'second')]);   // shrunk in place
  let c = await readContent(f, { subagent: false });
  assert.equal(c.prompt, 'second');
  assert.equal(c.toolCallTotal, 0);
  // replaced by a new file of at least the same size
  const g = path.join(dir, 'new.jsonl');
  writeJsonl(g, [rec.user(T, '/p', 'third'), rec.tool(T, 'Read', { file_path: '/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz' })]);
  fs.renameSync(g, f);
  c = await readContent(f, { subagent: false });
  assert.equal(c.prompt, 'third');
  assert.equal(c.toolCallTotal, 1);
});

test('readContent: tool result arriving in a later read updates an earlier call; subagent flag keeps separate state', async () => {
  const f = path.join(tmpDir('desk-cc-'), 's.jsonl');
  const use = { type: 'assistant', timestamp: T, message: { role: 'assistant', content: [{ type: 'tool_use', id: 'u1', name: 'Bash', input: { command: 'ls' } }] } };
  writeJsonl(f, [{ ...rec.user(T, '/p', 'META'), isMeta: true }, use]);
  assert.equal((await readContent(f, { subagent: false })).toolCalls[0].ok, null);
  fs.appendFileSync(f, line({ type: 'user', timestamp: T, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'u1', content: 'x', is_error: true }] } }));
  assert.equal((await readContent(f, { subagent: false })).toolCalls[0].ok, false);
  assert.equal((await readContent(f, { subagent: true })).prompt, 'META');
  assert.equal((await readContent(f, { subagent: false })).prompt, null);
});

test('readContent: a second read after an append reads only the appended bytes', async () => {
  const f = path.join(tmpDir('desk-cc-'), 's.jsonl');
  const recs = [rec.user(T, '/p', 'hello')];
  for (let i = 0; i < 200; i++) recs.push(rec.tool(T, 'Read', { file_path: '/file-' + i }));
  writeJsonl(f, recs);
  await readContent(f, { subagent: false });
  const size = fs.statSync(f).size;
  const add = line(rec.tool(T, 'Read', { file_path: '/extra' }));
  fs.appendFileSync(f, add);
  const before = contentReadStats.bytes;
  const c = await readContent(f, { subagent: false });
  const read = contentReadStats.bytes - before;
  assert.equal(c.toolCallTotal, 201);
  assert.ok(size > 10 * add.length);
  assert.equal(read, Buffer.byteLength(add));
});

test('readContent: a same-inode rewrite to a larger size is re-read from scratch', async () => {
  const f = path.join(tmpDir('desk-cc-'), 's.jsonl');
  writeJsonl(f, [rec.user(T, '/p', 'first'), rec.tool(T, 'Read', { file_path: '/a' })]);
  assert.equal((await readContent(f, { subagent: false })).prompt, 'first');
  const ino = fs.statSync(f).ino;
  writeJsonl(f, [rec.user(T, '/p', 'other'), rec.tool(T, 'Read', { file_path: '/b' }), rec.tool(T, 'Read', { file_path: '/c' }), rec.tool(T, 'Read', { file_path: '/d' })]);
  assert.equal(fs.statSync(f).ino, ino);
  const c = await readContent(f, { subagent: false });
  assert.equal(c.prompt, 'other');
  assert.deepEqual(targets(c), ['/b', '/c', '/d']);
});
