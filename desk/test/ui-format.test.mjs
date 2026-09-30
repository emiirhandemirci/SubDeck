import test from 'node:test';
import assert from 'node:assert/strict';
import * as f from '../public/format.js';

const NOW = new Date(2026, 8, 29, 15, 0, 0).getTime();   // local time, so "Today" is deterministic

test('formatDuration matches status.sh style', () => {
  assert.equal(f.formatDuration(5000), '5s');
  assert.equal(f.formatDuration(125000), '2m05s');
  assert.equal(f.formatDuration(3723000), '1h02m03s');
  assert.equal(f.formatDuration(-5), '0s');
  assert.equal(f.formatDuration(null), '-');
});

test('formatTokens', () => {
  assert.equal(f.formatTokens(null), '-');
  assert.equal(f.formatTokens(123), '123');
  assert.equal(f.formatTokens(79500), '79.5k');
  assert.equal(f.formatTokens(1100002), '1.1M');
  assert.equal(f.formatTokens(999999), '1.0M');
  assert.equal(f.formatTokens(999949), '999.9k');
});

test('relativeTime', () => {
  const ago = ms => new Date(NOW - ms).toISOString();
  assert.equal(f.relativeTime(ago(3000), NOW), 'just now');
  assert.equal(f.relativeTime(ago(42000), NOW), '42s ago');
  assert.equal(f.relativeTime(ago(5 * 60000), NOW), '5m ago');
  assert.equal(f.relativeTime(ago(3 * 3600000), NOW), '3h ago');
  assert.equal(f.relativeTime(ago(2 * 86400000), NOW), '2d ago');
  assert.equal(f.relativeTime(null, NOW), '-');
});

test('labels', () => {
  assert.equal(f.STATE_LABEL.stale, 'stale?');
  assert.equal(f.SOURCE_LABEL.mtime, 'estimated from file activity');
  assert.equal(f.SOURCE_LABEL.hook, 'from hook');
  assert.equal(f.TOOL_BADGE['claude-code'], 'Claude');
  assert.deepEqual(Object.keys(f.TOOL_BADGE), ['claude-code', 'cursor', 'codex', 'copilot', 'gemini', 'cline', 'opencode']);
  assert.equal(f.SOURCE_LABEL.lock, 'from lock file');
});

test('grouping and filtering', () => {
  const p = (name, over) => ({ id: name, name, path: '/w/' + name, runningCount: 0, lastActivityAt: null, ...over });
  const list = [
    p('run', { runningCount: 2, lastActivityAt: new Date(NOW - 1000).toISOString() }),
    p('today', { lastActivityAt: new Date(NOW - 3600000).toISOString() }),
    p('week', { lastActivityAt: new Date(NOW - 3 * 86400000).toISOString() }),
    p('old', { lastActivityAt: new Date(NOW - 30 * 86400000).toISOString() }),
    p('recent', { lastActivityAt: new Date(NOW - 10 * 60000).toISOString() }),
  ];
  assert.deepEqual(f.groupProjects(list, NOW).map(g => [g.label, g.items.map(x => x.name)]),
    [['Active now', ['run']], ['Today', ['today', 'recent']], ['Last 7 days', ['week']], ['Older', ['old']]]);
  assert.deepEqual(f.filterProjects(list, { text: 'TOD', onlyActive: false }, NOW).map(x => x.name), ['today']);
  assert.deepEqual(f.filterProjects(list, { text: '/w/we', onlyActive: false }, NOW).map(x => x.name), ['week']);
  assert.deepEqual(f.filterProjects(list, { text: '', onlyActive: true }, NOW).map(x => x.name), ['run', 'recent']);
});

test('middleEllipsis', () => {
  assert.equal(f.middleEllipsis('short', 10), 'short');
  assert.equal(f.middleEllipsis('C:/Users/someone/projects/alpha', 15), 'C:/User…s/alpha');
  assert.equal(Array.from(f.middleEllipsis('x'.repeat(50), 15)).length, 15);
});

test('markdownLite: paragraphs, lists, inline code; markup stays literal text', () => {
  const b = f.markdownLite('Hello `x` world\nnext\n\n- one\n- two `c`\n\n1. a\n2. b');
  assert.deepEqual(b[0], { type: 'p', inlines: [{ code: false, s: 'Hello ' }, { code: true, s: 'x' }, { code: false, s: ' world next' }] });
  assert.equal(b[1].type, 'ul');
  assert.deepEqual(b[1].items[1], [{ code: false, s: 'two ' }, { code: true, s: 'c' }]);
  assert.equal(b[2].type, 'ol');
  assert.equal(b[2].items.length, 2);
  const x = f.markdownLite('<script>alert(1)</script> & <img onerror=x>');
  assert.equal(x.length, 1);
  assert.equal(x[0].inlines.map(i => i.s).join(''), '<script>alert(1)</script> & <img onerror=x>');
  assert.deepEqual(f.markdownLite(''), []);
  assert.deepEqual(f.markdownLite(null), []);
});

test('formatToolTime', () => {
  assert.equal(f.formatToolTime(null), '');
  assert.match(f.formatToolTime('2026-09-29T10:00:05.000Z'), /^\d\d:\d\d:\d\d$/);
});
