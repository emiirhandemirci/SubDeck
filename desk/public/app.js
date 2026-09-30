// desk/public/app.js
// SubDeck Desk UI: three panes, SSE-driven partial refresh, keyboard navigation. Data only via textContent.
import { formatDuration, formatTokens, relativeTime, formatClock, STATE_LABEL, SOURCE_LABEL, TOOL_BADGE, groupProjects, filterProjects, middleEllipsis } from './format.js';

const $ = id => document.getElementById(id);
const store = {
  get(k, d) { try { const v = localStorage.getItem('desk.' + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('desk.' + k, JSON.stringify(v)); } catch { /* storage unavailable */ } },
};
const S = {
  sources: [], server: null, projects: [], project: null, sessions: [], detail: null,
  selectedProject: store.get('project', null), selectedSession: null,
  filter: store.get('filter', ''), onlyActive: store.get('onlyActive', false),
  lastHeartbeat: 0, lastRunning: null,
};

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined && text !== null) e.textContent = String(text); return e; }
async function getJSON(url) { const r = await fetch(url, { cache: 'no-store' }); if (!r.ok) throw new Error(`${url}: ${r.status}`); return r.json(); }
function dot(state) { const d = el('span', `dot ${state}`); d.setAttribute('aria-hidden', 'true'); return d; }
function stateWord(state) { return el('span', 'state-word', STATE_LABEL[state] || state); }
function toolBadge(tool) { return el('span', 'badge', TOOL_BADGE[tool] || tool); }

// Rebuilding a list drops keyboard focus; remember the focused item's id and restore it (only if it was focused).
function keepFocus(box, fn) {
  const a = document.activeElement;
  const id = a && box.contains(a) && a !== box ? a.dataset.id : null;
  fn();
  if (id) { const n = box.querySelector(`[data-id="${CSS.escape(id)}"]`); if (n) { n.tabIndex = 0; n.focus({ preventScroll: true }); } }
}

// ---------- header ----------
function renderSources() {
  const box = $('sources');
  box.replaceChildren();
  for (const s of S.sources) {
    const cls = !s.detected ? 'absent' : s.health;
    const b = el('span', `badge ${cls}`, `${s.label}: ${!s.detected ? 'not found' : s.health}`);
    b.title = `${s.counts.projects} projects, ${s.counts.sessions} sessions, ${s.counts.running} running${s.lastError ? `\n${s.lastError}` : ''}`;
    box.append(b);
  }
  const last = S.sources.map(s => s.lastScanAt).filter(Boolean).sort().pop();
  $('lastScan').textContent = last ? `Last scan ${formatClock(last)}` : '';
  const notices = $('notices');
  notices.replaceChildren();
  for (const s of S.sources) if (s.health === 'error') notices.append(el('div', 'notice error', `${s.label}: ${s.lastError || 'error'}`));
}

// ---------- projects ----------
function renderProjects() { keepFocus($('projects'), renderProjectsInner); }
function renderProjectsInner() {
  const box = $('projects');
  const scroll = box.scrollTop;
  box.replaceChildren();
  const now = Date.now();
  if (!S.sources.some(s => s.detected)) { box.append(el('p', 'empty', 'No supported AI coding tool data found (looked for: ' + S.sources.map(s => s.label).join(', ') + ').')); return; }
  if (!S.projects.length) { box.append(el('p', 'empty', `No sessions in the last ${S.server ? S.server.days : 14} days.`)); return; }
  const list = filterProjects(S.projects, { text: S.filter, onlyActive: S.onlyActive }, now);
  if (!list.length) { box.append(el('p', 'empty', 'No projects match.')); return; }
  for (const g of groupProjects(list, now)) {
    box.append(el('div', 'group-label', g.label));
    for (const p of g.items) {
      const row = el('div', 'row');
      row.setAttribute('role', 'option');
      row.dataset.id = p.id;
      row.tabIndex = p.id === S.selectedProject ? 0 : -1;
      row.setAttribute('aria-selected', String(p.id === S.selectedProject));
      row.append(el('div', 'name', p.name));
      const path = el('div', 'path', middleEllipsis(p.path || '', 48)); path.title = p.path || '';
      row.append(path);
      const meta = el('div', 'meta');
      for (const t of p.tools) meta.append(toolBadge(t));
      if (p.runningCount > 0) { meta.append(dot('running')); meta.append(el('span', 'state-word', `${p.runningCount} running`)); }
      row.append(meta);
      row.addEventListener('click', () => selectProject(p.id, true));
      box.append(row);
    }
  }
  if (!box.querySelector('[tabindex="0"]')) { const first = box.querySelector('.row'); if (first) first.tabIndex = 0; }
  box.scrollTop = scroll;
}

async function selectProject(id, focus) {
  if (id !== S.selectedProject) { S.selectedSession = null; S.detail = null; renderDetail(); }
  S.selectedProject = id; store.set('project', id);
  renderProjects();
  if (focus) { const r = $('projects').querySelector(`[data-id="${CSS.escape(id)}"]`); if (r) r.focus(); }
  await loadProject();
}

// ---------- agent map ----------
function sessionLine(s, cls) {
  const line = el('div', cls);
  line.setAttribute('role', 'treeitem');
  line.dataset.id = s.id;
  line.tabIndex = s.id === S.selectedSession ? 0 : -1;
  line.setAttribute('aria-selected', String(s.id === S.selectedSession));
  line.append(dot(s.state), el('span', 'title', s.title), stateWord(s.state));
  line.append(el('span', 'muted', `${formatDuration(s.durationMs)} · ${formatTokens(s.tokens.context)}`));
  if (s.agentType && cls === 'agent') line.append(el('span', 'muted', s.agentType));
  if (s.archived) line.append(el('span', 'tag', 'archived'));
  line.addEventListener('click', ev => { ev.stopPropagation(); selectSession(s.id, false); });
  return line;
}

function renderMap() { keepFocus($('map'), renderMapInner); }
function renderMapInner() {
  const box = $('map');
  const scroll = box.scrollTop;
  box.replaceChildren();
  if (!S.selectedProject || !S.project) { box.append(el('p', 'empty', 'Select a project')); return; }
  if (!S.sessions.length) { box.append(el('p', 'empty', 'No sessions')); return; }
  for (const s of S.sessions) {
    const card = el('div', 'card');
    const head = sessionLine(s, 'head');
    head.insertBefore(toolBadge(s.tool), head.children[1]);
    card.append(head);
    if (s.children.length) {
      const ul = el('ul', 'agents');
      ul.setAttribute('role', 'group');
      for (const c of s.children) { const li = el('li'); li.append(sessionLine(c, 'agent')); ul.append(li); }
      card.append(ul);
    }
    box.append(card);
  }
  if (!box.querySelector('[tabindex="0"]')) { const first = box.querySelector('[role=treeitem]'); if (first) first.tabIndex = 0; }
  box.scrollTop = scroll;
  const running = S.sessions.reduce((n, s) => n + (s.state === 'running') + s.children.filter(c => c.state === 'running').length, 0);
  if (S.lastRunning !== null && running !== S.lastRunning) $('announce').textContent = `${running} running`;
  S.lastRunning = running;
}

async function loadProject() {
  if (!S.selectedProject) { S.project = null; S.sessions = []; renderMap(); return; }
  try {
    const d = await getJSON(`/api/projects/${encodeURIComponent(S.selectedProject)}`);
    S.project = d.project; S.sessions = d.sessions;
  } catch { S.project = null; S.sessions = []; }
  renderMap();
}

// ---------- detail ----------
async function selectSession(id, focus) {
  S.selectedSession = id;
  renderMap();
  if (focus) { const r = $('map').querySelector(`[data-id="${CSS.escape(id)}"]`); if (r) r.focus(); }
  await loadDetail();
}

async function loadDetail() {
  if (!S.selectedSession) { S.detail = null; renderDetail(); return; }
  try { S.detail = (await getJSON(`/api/sessions/${encodeURIComponent(S.selectedSession)}`)).session; } catch { S.detail = null; }
  renderDetail();
}

function renderDetail() {
  const box = $('detail');
  box.replaceChildren();
  const s = S.detail;
  if (!s) { box.append(el('p', 'empty', 'Select a session or agent')); return; }
  box.append(el('h3', null, s.title));
  const dl = el('dl', 'kv');
  const row = (k, v) => { dl.append(el('dt', null, k)); const dd = el('dd'); if (v instanceof Node) dd.append(v); else dd.textContent = v ?? '-'; dl.append(dd); };
  const now = Date.now();
  const when = iso => (iso ? `${new Date(iso).toLocaleString()} (${relativeTime(iso, now)})` : '-');
  row('Tool', TOOL_BADGE[s.tool] || s.tool);
  row('Agent type', s.agentType);
  row('Model', s.model);
  const st = el('span'); st.append(dot(s.state), document.createTextNode(` ${STATE_LABEL[s.state]} (${SOURCE_LABEL[s.stateSource]})`));
  row('State', st);
  row('Started', when(s.createdAt));
  row('Updated', when(s.updatedAt));
  row('Ended', when(s.endedAt));
  const dur = el('span', null, formatDuration(s.durationMs)); dur.id = 'detailDuration'; row('Duration', dur);
  row('Tokens', s.tokens.context === null ? '-' : `${formatTokens(s.tokens.context)} context`);
  const la = s.lastActivity;
  row('Last activity', la ? [la.kind, la.toolName, la.summary].filter(Boolean).join(' · ') + ` (${relativeTime(la.at, now)})` : '-');
  if (s.parent) row('Parent', s.parent.title);
  if (s.children && s.children.length) row('Agents', s.children.map(c => `${c.title} (${STATE_LABEL[c.state]})`).join(', '));
  const refPath = s.refs.file || s.refs.db;
  if (refPath) {
    const wrap = el('span', 'refs');
    const code = el('code', null, s.refs.key ? `${refPath} [${s.refs.key}]` : refPath);
    const btn = el('button', null, 'Copy path');
    btn.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(refPath); btn.textContent = 'Copied'; }
      catch { const r = document.createRange(); r.selectNodeContents(code); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); }
      setTimeout(() => { btn.textContent = 'Copy path'; }, 1500);
    });
    wrap.append(code, document.createTextNode(' '), btn);
    row('Data', wrap);
  }
  box.append(dl);
  box.dataset.createdAt = s.createdAt || '';
}

setInterval(() => {   // live duration for running/idle sessions
  const s = S.detail;
  const d = $('detailDuration');
  if (s && d && (s.state === 'running' || s.state === 'idle') && s.createdAt) d.textContent = formatDuration(Date.now() - Date.parse(s.createdAt));
  const live = $('live');
  const fresh = Date.now() - S.lastHeartbeat < 40000;
  live.textContent = fresh ? 'Live' : 'Reconnecting…';
  live.className = `live ${fresh ? 'on' : 'off'}`;
}, 1000);

// ---------- keyboard ----------
function listNav(container, selector, onEnter) {
  container.addEventListener('keydown', ev => {
    const items = [...container.querySelectorAll(selector)];
    const i = items.indexOf(document.activeElement);
    if (i < 0) return;
    let j = i;
    if (ev.key === 'ArrowDown') j = Math.min(items.length - 1, i + 1);
    else if (ev.key === 'ArrowUp') j = Math.max(0, i - 1);
    else if (ev.key === 'Home') j = 0;
    else if (ev.key === 'End') j = items.length - 1;
    else if (ev.key === 'Enter') { ev.preventDefault(); onEnter(items[i].dataset.id); return; }
    else return;
    ev.preventDefault();
    items[i].tabIndex = -1; items[j].tabIndex = 0; items[j].focus();
  });
}
listNav($('projects'), '.row', id => selectProject(id, true));
listNav($('map'), '[role=treeitem]', id => selectSession(id, true));

$('filter').value = S.filter;
$('onlyActive').checked = S.onlyActive;
$('filter').addEventListener('input', e => { S.filter = e.target.value; store.set('filter', S.filter); renderProjects(); });
$('onlyActive').addEventListener('change', e => { S.onlyActive = e.target.checked; store.set('onlyActive', S.onlyActive); renderProjects(); });

// ---------- data flow ----------
async function loadSources() { const d = await getJSON('/api/sources'); S.sources = d.sources; S.server = d.server; renderSources(); }
async function loadProjects() { S.projects = (await getJSON('/api/projects')).projects; renderProjects(); }
async function loadAll() {
  await Promise.all([loadSources(), loadProjects()]);
  if (S.selectedProject && !S.projects.some(p => p.id === S.selectedProject)) S.selectedProject = null;
  await loadProject();
  await loadDetail();
}

function connect() {
  const es = new EventSource('/api/stream');
  es.addEventListener('hello', () => { S.lastHeartbeat = Date.now(); loadAll().catch(() => {}); });
  es.addEventListener('heartbeat', () => { S.lastHeartbeat = Date.now(); });
  es.addEventListener('changed', async e => {
    S.lastHeartbeat = Date.now();
    let ev; try { ev = JSON.parse(e.data); } catch { return; }
    if (ev.sources) await loadSources().catch(() => {});
    await loadProjects().catch(() => {});
    if (S.selectedProject && ev.projects.includes(S.selectedProject)) {
      await loadProject();
      if (S.detail && S.detail.projectId === S.selectedProject) await loadDetail();
    }
  });
  es.onerror = () => { S.lastHeartbeat = 0; };
}

renderMap();
connect();
