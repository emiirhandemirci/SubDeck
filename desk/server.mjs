// desk/server.mjs
// SubDeck Desk: local, read-only dashboard of AI coding agent sessions.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolveEnv, resolveHome, sandboxVars } from './lib/paths.mjs';
import { createCore } from './lib/core.mjs';
import { createWatcher } from './lib/watcher.mjs';
import { createApi } from './lib/api.mjs';
import claudeCode from './adapters/claude-code.mjs';
import cursor from './adapters/cursor.mjs';
import codex from './adapters/codex.mjs';
import copilot from './adapters/copilot.mjs';
import gemini from './adapters/gemini.mjs';
import cline from './adapters/cline.mjs';
import opencode from './adapters/opencode.mjs';

export const VERSION = '0.6.1';
export const ADAPTERS = [claudeCode, cursor, codex, copilot, gemini, cline, opencode];
const DEFAULT_PORT = 4917;
const PORT_TRIES = 20;

export function parseArgs(argv) {
  const out = { port: null, open: false, days: 14, noContent: false, warnings: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--open') out.open = true;
    else if (a === '--no-content') out.noContent = true;
    else if (a === '--port') {
      const n = Number(argv[++i]);
      if (Number.isInteger(n) && n >= 0 && n <= 65535) out.port = n; else out.warnings.push(`invalid --port ${argv[i]}, using default`);
    } else if (a === '--days') {
      const n = Number(argv[++i]);
      if (Number.isInteger(n) && n >= 1 && n <= 365) out.days = n; else out.warnings.push(`invalid --days ${argv[i]}, using 14`);
    } else out.warnings.push(`unknown flag ${a} ignored`);
  }
  return out;
}

function pidAlive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }

async function existingInstance(file) {
  let rt;
  try { rt = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
  if (!rt || !Number.isInteger(rt.pid) || !Number.isInteger(rt.port) || !pidAlive(rt.pid)) return null;
  try {
    const res = await fetch(`http://127.0.0.1:${rt.port}/api/sources`, { signal: AbortSignal.timeout(1000) });
    return res.status === 200 ? rt : null;
  } catch { return null; }
}

function listen(server, port) {
  return new Promise((resolve, reject) => {
    const onErr = e => { server.off('listening', onOk); reject(e); };
    const onOk = () => { server.off('error', onErr); resolve(server.address().port); };
    server.once('error', onErr);
    server.once('listening', onOk);
    server.listen(port, '127.0.0.1');
  });
}

function openBrowser(url) {
  const [cmd, args] = process.platform === 'win32' ? ['cmd', ['/c', 'start', '', url]]
    : process.platform === 'darwin' ? ['open', [url]] : ['xdg-open', [url]];
  try { spawn(cmd, args, { detached: true, stdio: 'ignore' }).on('error', () => {}).unref(); } catch { /* ignore */ }
}

export async function main(argv = process.argv.slice(2)) {
  const major = Number(process.versions.node.split('.')[0]);
  if (major < 20) { console.error(`SubDeck Desk needs Node >= 20 (22.13+ for Cursor); found ${process.versions.node}`); process.exit(1); }
  const args = parseArgs(argv);
  for (const w of args.warnings) console.error(w);
  const home = resolveHome(process.env, process.platform, os.homedir());
  const rtDir = path.join(home, '.subdeck');
  const rtFile = path.join(rtDir, 'desk.json');

  const running = await existingInstance(rtFile);
  if (running) { console.log(`SubDeck Desk already running: http://127.0.0.1:${running.port}/`); process.exit(0); }

  const env = resolveEnv(sandboxVars(process.env, process.platform, home), process.platform, home, { days: args.days });
  const core = createCore({ env, adapters: ADAPTERS });
  const startedAt = new Date().toISOString();
  let port = null;
  const api = createApi({ core, getPort: () => port, startedAt, days: args.days, version: VERSION, contentEnabled: !args.noContent, adapters: ADAPTERS, env, configFile: path.join(rtDir, 'config.json'),
    publicDir: fileURLToPath(new URL('./public/', import.meta.url)) });
  const server = http.createServer((req, res) => { api.handle(req, res); });

  const candidates = args.port !== null ? [args.port] : Array.from({ length: PORT_TRIES }, (_, i) => DEFAULT_PORT + i);
  for (const p of candidates) {
    try { port = await listen(server, p); break; } catch (e) {
      if (e.code !== 'EADDRINUSE') throw e;
      if (args.port !== null) { console.error(`port ${p} is in use`); process.exit(1); }
    }
  }
  if (port === null) { console.error(`no free port in ${DEFAULT_PORT}-${DEFAULT_PORT + PORT_TRIES - 1}`); process.exit(1); }

  await core.scanAll();
  const url = `http://127.0.0.1:${port}/`;
  fs.mkdirSync(rtDir, { recursive: true });
  fs.writeFileSync(rtFile, JSON.stringify({ pid: process.pid, port, startedAt, version: VERSION }));
  console.log(`SubDeck Desk: ${url}`);
  for (const s of core.snapshot().sources) {
    console.log(`${s.id}: ${s.detected ? s.health : 'not found'}, ${s.counts.projects} projects, ${s.counts.sessions} sessions${s.lastError ? ` (${s.lastError})` : ''}`);
  }

  core.onChanged(ev => api.broadcast(ev));
  const watcher = createWatcher({
    onChange: tool => { core.scanSources([tool]).then(() => watcher.update(core.watchTargets())).catch(() => {}); },
    onNote: (tool, note) => core.setWatchNote(tool, note),
  });
  watcher.update(core.watchTargets());
  const timers = [setInterval(() => core.refreshStates(), 15000), setInterval(() => api.heartbeat(), 15000)];

  let stopping = false;
  function cleanup() {
    if (stopping) return;
    stopping = true;
    try { const rt = JSON.parse(fs.readFileSync(rtFile, 'utf8')); if (rt.pid === process.pid) fs.unlinkSync(rtFile); } catch { /* ignore */ }
    for (const t of timers) clearInterval(t);
    watcher.close();
    api.closeAll();
    server.close();
  }
  process.on('exit', cleanup);
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) { try { process.on(sig, () => { cleanup(); process.exit(0); }); } catch { /* unsupported */ } }
  if (args.open) openBrowser(url);
}

// Node resolves symlinks for the main module, so compare real paths (macOS tmpdir /var -> /private/var, symlinked installs).
function isMain() {
  if (!process.argv[1]) return false;
  const self = fileURLToPath(import.meta.url);
  try { return fs.realpathSync(process.argv[1]) === fs.realpathSync(self); }
  catch { return import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href; }
}
if (isMain()) {
  main().catch(e => { console.error(`SubDeck Desk failed: ${String(e && e.message).split('\n')[0]}`); process.exit(1); });
}
