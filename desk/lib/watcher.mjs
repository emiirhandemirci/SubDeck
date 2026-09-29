// desk/lib/watcher.mjs
// fs.watch per target, 500 ms debounce per tool, 5 s polling fallback per tool (spec section 7).
import fs from 'node:fs';

export const POLL_NOTE = 'watching unavailable, polling every 5 s';

export function createWatcher({ onChange, onNote = () => {}, debounceMs = 500, pollMs = 5000, watchFn = fs.watch }) {
  const timers = new Map();     // tool -> debounce timer
  const watchers = new Map();   // target key -> FSWatcher
  const polls = new Map();      // tool -> interval
  let closed = false;

  function trigger(tool) {
    if (closed) return;
    clearTimeout(timers.get(tool));
    timers.set(tool, setTimeout(() => { timers.delete(tool); onChange(tool); }, debounceMs));
  }

  function startPolling(tool) {
    if (polls.has(tool) || closed) return;
    polls.set(tool, setInterval(() => trigger(tool), pollMs));
    onNote(tool, POLL_NOTE);
  }

  const keyOf = t => `${t.tool}|${t.path}|${t.recursive ? 1 : 0}|${t.filter || ''}`;

  function update(targets) {
    const wanted = new Map(targets.map(t => [keyOf(t), t]));
    for (const [k, w] of watchers) if (!wanted.has(k)) { try { w.close(); } catch { /* ignore */ } watchers.delete(k); }
    for (const [k, t] of wanted) {
      if (watchers.has(k) || polls.has(t.tool)) continue;
      try {
        const w = watchFn(t.path, { recursive: t.recursive, persistent: true }, (_ev, name) => {
          if (t.filter && !(name && String(name).startsWith(t.filter))) return;
          trigger(t.tool);
        });
        w.on('error', () => { try { w.close(); } catch { /* ignore */ } watchers.delete(k); startPolling(t.tool); });
        watchers.set(k, w);
      } catch (e) {
        if (e && e.code === 'ENOENT') continue;    // retried at the next update()
        startPolling(t.tool);
      }
    }
  }

  function close() {
    closed = true;
    for (const w of watchers.values()) { try { w.close(); } catch { /* ignore */ } }
    watchers.clear();
    for (const t of timers.values()) clearTimeout(t);
    for (const p of polls.values()) clearInterval(p);
  }

  return { update, close };
}
