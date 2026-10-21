// desk/test/budget149.test.mjs: task verify level and token budget parsed from the task file; over-budget text in the task card.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseTask } from '../lib/tasks.mjs';
import './fixtures/tmpclean.mjs';

const head = extra => `---\nid: t-aaaa\ntitle: Job\nstatus: open\nowner: worker-sonnet\n${extra}created: 2026-10-21T08:00:00Z\nupdated: 2026-10-21T09:00:00Z\n---\n## Task\n\n## Report\n`;
const pub = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'public');

test('verify and budget are read from the frontmatter', () => {
  const t = parseTask(head('verify: L2\nverify-reason: auth\nbudget: 60000\n'), 't-aaaa').task;
  assert.equal(t.verify, 'L2');
  assert.equal(t.budget, 60000);
});
test('defaults and bad values (negative control)', () => {
  const d = parseTask(head(''), 't-aaaa').task;
  assert.equal(d.verify, 'L1'); assert.equal(d.budget, null);
  const b = parseTask(head('verify: L9\nbudget: lots\n'), 't-aaaa').task;
  assert.equal(b.verify, 'L1'); assert.equal(b.budget, null);
});
test('the task card marks a task over its budget in plain text', () => {
  const js = fs.readFileSync(path.join(pub, 'tasks.js'), 'utf8');
  assert.match(js, /over the budget of/);
  assert.match(js, /t\.tokens > t\.budget/);
});
