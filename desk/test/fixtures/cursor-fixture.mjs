// desk/test/fixtures/cursor-fixture.mjs
// Creates a Cursor-shaped state.vscdb (real DDL from this machine, 2026-09-29) with synthetic rows.
import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

export const DDL = [
  'CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)',
  'CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)',
  'CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, subagentTypeName TEXT, value TEXT)',
  'CREATE INDEX idx_composerHeaders_0 ON composerHeaders (workspaceId, isSubagent, isArchived, recency)',
];

/** Content-bearing and secret fields every composer carries in real data; the adapter must never surface them. */
export const SECRET_FIELDS = { text: 'BODY_MARKER', richText: 'BODY_MARKER', blobEncryptionKey: 'KEY_MARKER',
  speculativeSummarizationEncryptionKey: 'KEY_MARKER', conversationMap: {}, codeBlockData: { x: 'BODY_MARKER' } };

/**
 * headers:   [{ composerId, workspaceId, createdAt, lastUpdatedAt?, isArchived?, isSubagent?, recency, subagentTypeName?, value: {...} | string }]
 * composers: { [composerId]: object | string }   (string = raw, e.g. malformed JSON)
 * bubbles:   { [`${composerId}:${bubbleId}`]: object }
 * workspaces:{ [workspaceId]: object }            (written to workspaceStorage/<id>/workspace.json)
 */
export function buildCursorFixture(userDir, { headers = [], composers = {}, bubbles = {}, workspaces = {} }) {
  const gs = path.join(userDir, 'globalStorage');
  fs.mkdirSync(gs, { recursive: true });
  const dbPath = path.join(gs, 'state.vscdb');
  const db = new DatabaseSync(dbPath);
  for (const s of DDL) db.exec(s);
  const ih = db.prepare('INSERT INTO composerHeaders VALUES (?,?,?,?,?,?,?,?,?,?)');
  for (const h of headers) {
    ih.run(h.composerId, h.workspaceId ?? null, h.createdAt ?? null, h.lastUpdatedAt ?? null, h.isArchived ?? 0, h.isSubagent ?? 0,
      h.recency ?? null, null, h.subagentTypeName ?? null, typeof h.value === 'string' ? h.value : JSON.stringify(h.value ?? { type: 'head' }));
  }
  const ik = db.prepare('INSERT INTO cursorDiskKV VALUES (?, ?)');
  for (const [id, c] of Object.entries(composers)) ik.run('composerData:' + id, typeof c === 'string' ? c : JSON.stringify({ ...SECRET_FIELDS, ...c }));
  for (const [k, b] of Object.entries(bubbles)) ik.run('bubbleId:' + k, JSON.stringify({ text: 'BODY_MARKER', ...b }));
  db.close();
  for (const [id, w] of Object.entries(workspaces)) {
    fs.mkdirSync(path.join(userDir, 'workspaceStorage', id), { recursive: true });
    fs.writeFileSync(path.join(userDir, 'workspaceStorage', id, 'workspace.json'), JSON.stringify(w));
  }
  return dbPath;
}
