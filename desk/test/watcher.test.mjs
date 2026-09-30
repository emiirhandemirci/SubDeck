// desk/test/watcher.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createWatcher } from '../lib/watcher.mjs';

function fakeWatch({ throwFor = [] } = {}) {
  const watchers = [];
  const fn = (p, opts, listener) => {
    if (throwFor.includes(p)) { const e = new Error('EPERM'); e.code = 'EPERM'; throw e; }
    const w = new EventEmitter();
    w.path = p; w.opts = opts; w.fire = name => listener('change', name); w.closed = false; w.close = () => { w.closed = true; };
    watchers.push(w);
    return w;
  };
  return { fn, watchers };
}

test('debounce collapses a burst into one call per tool', t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const calls = [];
  const fw = fakeWatch();
  const w = createWatcher({ onChange: tool => calls.push(tool), onNote: () => {}, watchFn: fw.fn });
  w.update([{ tool: 'claude-code', path: '/c', recursive: true }, { tool: 'cursor', path: '/g', recursive: false, filter: 'state.vscdb' }]);
  assert.deepEqual(fw.watchers[0].opts, { recursive: true, persistent: true });
  for (let i = 0; i < 10; i++) fw.watchers[0].fire('a.jsonl');
  t.mock.timers.tick(499);
  assert.deepEqual(calls, []);
  t.mock.timers.tick(1);
  assert.deepEqual(calls, ['claude-code']);
  fw.watchers[1].fire('storage.json');                          // filtered out
  fw.watchers[1].fire('state.vscdb-wal');
  t.mock.timers.tick(500);
  assert.deepEqual(calls, ['claude-code', 'cursor']);
  w.close();
  assert.ok(fw.watchers.every(x => x.closed));
});

test('watch failure falls back to polling every 5 s and reports a note', t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const calls = [];
  const notes = [];
  const fw = fakeWatch({ throwFor: ['/c'] });
  const w = createWatcher({ onChange: tool => calls.push(tool), onNote: (tool, n) => notes.push([tool, n]), watchFn: fw.fn });
  w.update([{ tool: 'claude-code', path: '/c', recursive: true }]);
  assert.deepEqual(notes, [['claude-code', 'watching unavailable, polling every 5 s']]);
  t.mock.timers.tick(5000);
  t.mock.timers.tick(500);
  assert.deepEqual(calls, ['claude-code']);
  w.close();
});

test('an error event on a live watcher also switches to polling', t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const calls = [];
  const fw = fakeWatch();
  const w = createWatcher({ onChange: tool => calls.push(tool), onNote: () => {}, watchFn: fw.fn });
  w.update([{ tool: 'cursor', path: '/g', recursive: false }]);
  fw.watchers[0].emit('error', new Error('gone'));
  assert.equal(fw.watchers[0].closed, true);
  t.mock.timers.tick(5000);   // interval fires and schedules the debounce
  t.mock.timers.tick(500);    // debounce fires (one tick does not run timers created during it)
  assert.deepEqual(calls, ['cursor']);
  w.close();
});

test('update adds new targets and closes vanished ones; ENOENT is skipped silently', t => {
  const fw = fakeWatch();
  const notes = [];
  const w = createWatcher({ onChange: () => {}, onNote: (tool, n) => notes.push(n),
    watchFn: (p, o, l) => { if (p === '/missing') { const e = new Error('nope'); e.code = 'ENOENT'; throw e; } return fw.fn(p, o, l); } });
  w.update([{ tool: 'a', path: '/1', recursive: true }, { tool: 'a', path: '/missing', recursive: true }]);
  w.update([{ tool: 'a', path: '/2', recursive: true }]);
  assert.deepEqual(fw.watchers.map(x => [x.path, x.closed]), [['/1', true], ['/2', false]]);
  assert.deepEqual(notes, []);
  w.close();
});

test('null filename with a filter set counts as a change', t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const fw = fakeWatch();
  const calls = [];
  const w = createWatcher({ onChange: tool => calls.push(tool), watchFn: fw.fn });
  w.update([{ tool: 'cursor', path: '/g', recursive: false, filter: 'state.vscdb' }]);
  fw.watchers[0].fire(null);
  t.mock.timers.tick(500);
  assert.deepEqual(calls, ['cursor']);
  w.close();
});
