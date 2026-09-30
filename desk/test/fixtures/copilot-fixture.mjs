// desk/test/fixtures/copilot-fixture.mjs
// Synthetic Copilot CLI session-state and VS Code chatSessions trees (never real user data).
import fs from 'node:fs';
import path from 'node:path';
import { copilotHomeDir, vscodeUserDirs } from '../../adapters/copilot.mjs';

export const BODY = 'BODY_MARKER';
let seq = 0;
/** Event line builder: ev('assistant.message', tsMs, data). */
export const ev = (type, ts, data = {}) => JSON.stringify({ type, data, id: 'e' + (seq++), timestamp: new Date(ts).toISOString() });

/**
 * cli:  { [sessionId]: { events?: string[] | string, yaml?: string, locks?: number[] } }
 * chat: { [hash]: { folder?: string (file URI), workspace?: string, files: { [name.jsonl]: string[] | string }, mtimeMs?: { [name]: ms } } }
 */
export function buildCopilotFixture(env, { cli = {}, chat = {} }) {
  const stateDir = path.join(copilotHomeDir(env), 'session-state');
  fs.mkdirSync(stateDir, { recursive: true });
  for (const [id, s] of Object.entries(cli)) {
    const dir = path.join(stateDir, id);
    fs.mkdirSync(dir, { recursive: true });
    if (s.events !== undefined) fs.writeFileSync(path.join(dir, 'events.jsonl'), Array.isArray(s.events) ? s.events.join('\n') + '\n' : s.events);
    if (s.yaml !== undefined) fs.writeFileSync(path.join(dir, 'workspace.yaml'), s.yaml);
    for (const pid of s.locks || []) fs.writeFileSync(path.join(dir, `inuse.${pid}.lock`), '');
  }
  const userDir = vscodeUserDirs(env)[0];
  for (const [hash, w] of Object.entries(chat)) {
    const hd = path.join(userDir, 'workspaceStorage', hash);
    fs.mkdirSync(path.join(hd, 'chatSessions'), { recursive: true });
    if (w.folder || w.workspace) fs.writeFileSync(path.join(hd, 'workspace.json'), JSON.stringify(w.folder ? { folder: w.folder } : { workspace: w.workspace }));
    for (const [name, lines] of Object.entries(w.files || {})) {
      const f = path.join(hd, 'chatSessions', name);
      fs.writeFileSync(f, Array.isArray(lines) ? lines.join('\n') + '\n' : lines);
      const m = w.mtimeMs && w.mtimeMs[name];
      if (m) fs.utimesSync(f, m / 1000, m / 1000);
    }
  }
  return { stateDir, userDir };
}
