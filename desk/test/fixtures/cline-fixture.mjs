// desk/test/fixtures/cline-fixture.mjs
// Synthetic Cline / Roo globalStorage layout (never real data).
import fs from 'node:fs';
import path from 'node:path';

export const BODY = 'BODY_MARKER';

/** Storage root for an extension under a fake home; matches candidateRoots() for the current platform. */
export function storageRoot(home, ext = 'saoudrizwan.claude-dev', editor = 'Code') {
  if (process.platform === 'win32') return { vars: { APPDATA: path.join(home, 'AppData', 'Roaming') }, dir: path.join(home, 'AppData', 'Roaming', editor, 'User', 'globalStorage', ext) };
  const base = process.platform === 'darwin' ? path.join(home, 'Library', 'Application Support') : path.join(home, '.config');
  return { vars: {}, dir: path.join(base, editor, 'User', 'globalStorage', ext) };
}

/**
 * tasks: { [id]: { ui?: array|string, api?: any, meta?: object|string, historyItem?: object } }
 * history: array | string for state/taskHistory.json (omitted when undefined)
 * Returns { dir, taskDir(id) }.
 */
export function buildClineFixture(dir, { tasks = {}, history } = {}) {
  fs.mkdirSync(path.join(dir, 'tasks'), { recursive: true });
  const w = (p, v) => fs.writeFileSync(p, typeof v === 'string' ? v : JSON.stringify(v));
  for (const [id, t] of Object.entries(tasks)) {
    const td = path.join(dir, 'tasks', id);
    fs.mkdirSync(td, { recursive: true });
    if (t.ui !== undefined) w(path.join(td, 'ui_messages.json'), t.ui);
    w(path.join(td, 'api_conversation_history.json'), t.api ?? [{ role: 'user', content: [{ type: 'text', text: BODY }] }]);
    if (t.meta !== undefined) w(path.join(td, 'task_metadata.json'), t.meta);
    if (t.historyItem !== undefined) w(path.join(td, 'history_item.json'), t.historyItem);
    if (t.mtime) { const d = new Date(t.mtime); for (const f of fs.readdirSync(td)) fs.utimesSync(path.join(td, f), d, d); }
  }
  if (history !== undefined) {
    fs.mkdirSync(path.join(dir, 'state'), { recursive: true });
    w(path.join(dir, 'state', 'taskHistory.json'), history);
  }
  return { dir, taskDir: id => path.join(dir, 'tasks', id) };
}

export const apiReq = (ts, o) => ({ ts, type: 'say', say: 'api_req_started', text: JSON.stringify({ request: BODY, ...o }) });
