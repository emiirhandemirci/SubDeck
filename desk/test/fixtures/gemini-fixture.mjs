// desk/test/fixtures/gemini-fixture.mjs
// Synthetic Gemini CLI layout: <root>/.gemini/tmp/<id>/chats/session-*.jsonl|json (+ optional .project_root, projects.json).
import fs from 'node:fs';
import path from 'node:path';

export const BODY = 'BODY_MARKER_prompt_and_output';
export const msg = (id, type, at, extra = {}) => ({ id, timestamp: new Date(at).toISOString(), type, content: BODY, ...extra });
export const geminiMsg = (id, at, over = {}) => msg(id, 'gemini', at, { model: 'gemini-2.5-pro', thoughts: [{ subject: BODY }],
  tokens: { input: 1000, output: 50, cached: 0, thoughts: 5, tool: 0, total: 1055 }, ...over });

export function writeJsonl(file, records) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, records.map(r => (typeof r === 'string' ? r : JSON.stringify(r))).join('\n') + '\n');
}
export function writeJson(file, obj) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(obj)); }
export const setMtime = (file, ms) => fs.utimesSync(file, new Date(ms), new Date(ms));
export const chatsDir = (home, id) => path.join(home, '.gemini', 'tmp', id, 'chats');
