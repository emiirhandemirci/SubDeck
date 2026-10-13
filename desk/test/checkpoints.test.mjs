// desk/test/checkpoints.test.mjs  (task 129: checkpoint timeline of a task; synthetic data only)
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCheckpoints, parseTask } from '../lib/tasks.mjs';
import { checkpointRows } from '../public/tasks.js';

const PROGRESS = [
  '### 2026-10-13T09:00:00Z commit', 'commit: aaaaaaaaaa add a', 'agent: ag1', 'files: a.txt', 'dirty: wip.txt', '',
  '### 2026-10-13T09:05:00Z step', 'done: added a', 'next: add b', '',
  '### 2026-10-13T09:10:00Z commit', 'commit: bbbbbbbbbb add b', 'agent: ag1', 'files: b.txt', '',
  '### 2026-10-13T09:20:00Z rewind', 'to: 1', 'reverted: bbbbbbbbbb', '',
].join('\n');

test('parseCheckpoints: commits, steps and rewinds in order; names only', () => {
  const c = parseCheckpoints(PROGRESS);
  assert.deepEqual(c.map(x => [x.kind, x.hash, x.text]), [
    ['commit', 'aaaaaaaaaa', 'add a'], ['step', '', 'added a'], ['commit', 'bbbbbbbbbb', 'add b'], ['rewind', '', 'rewound to #1'],
  ]);
  assert.deepEqual(parseCheckpoints(''), []);
});

test('a parsed task carries its checkpoints', () => {
  const t = parseTask(`---\nid: t-aaaa\ntitle: x\nstatus: open\n---\n## Task\nx\n\n## Progress\n${PROGRESS}\n## Handoff\n`, 't-aaaa').task;
  assert.equal(t.checkpoints.length, 4);
  assert.equal(parseTask('---\nid: t-aaaa\nstatus: open\n---\n', 't-aaaa').task.checkpoints.length, 0);
});

test('checkpointRows: newest few, short hash, rewind entries left out, earlier count', () => {
  const t = { checkpoints: parseCheckpoints(PROGRESS) };
  const r = checkpointRows(t, 2);
  assert.deepEqual(r.rows.map(x => [x.hash, x.text]), [['step', 'added a'], ['bbbbbbb', 'add b']]);
  assert.equal(r.more, 1);
  assert.deepEqual(checkpointRows({}), { rows: [], more: 0 });
});
