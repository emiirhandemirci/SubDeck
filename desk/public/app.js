// desk/public/app.js
// SubDeck Desk UI: three panes, SSE-driven partial refresh, keyboard navigation. Data only via textContent.
import { formatDuration, formatTokens, relativeTime, formatClock, STATE_LABEL, SOURCE_LABEL, TOOL_BADGE, groupProjects, filterProjects, middleEllipsis, markdownLite, formatToolTime, contextUsage } from './format.js';

const $ = id => document.getElementById(id);
const store = {
  get(k, d) { try { const v = localStorage.getItem('desk.' + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('desk.' + k, JSON.stringify(v)); } catch { /* storage unavailable */ } },
};
const S = {
  sources: [], server: null, projects: [], project: null, sessions: [], detail: null,
  selectedProject: store.get('project', null), selectedSession: null,
  filter: store.get('filter', ''), onlyActive: store.get('onlyActive', false),
  lastHeartbeat: 0, lastRunning: null, lastWaiting: null,
  content: null, contentFor: null, contentKey: null, open: { prompt: false, tools: false, report: true },
};

function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined && text !== null) e.textContent = String(text); return e; }
async function getJSON(url) { const r = await fetch(url, { cache: 'no-store' }); if (!r.ok) throw new Error(`${url}: ${r.status}`); return r.json(); }
function dot(state) { const d = el('span', `dot ${state}`); d.setAttribute('aria-hidden', 'true'); return d; }
function stateWord(state) { return el('span', `state-word chip ${state}`, STATE_LABEL[state] || state); }
// Waiting count: server-side per-project counts when available, else what the selected project's tree shows.
function updateWaiting() {
  const own = S.sessions.reduce((n, s) => n + (s.state === 'waiting') + s.children.filter(c => c.state === 'waiting').length, 0);
  const total = S.projects.some(p => typeof p.waitingCount === 'number') ? S.projects.reduce((n, p) => n + (p.waitingCount || 0), 0) : own;
  const b = $('waitingCount');
  b.hidden = total <= 0;
  b.textContent = total > 0 ? `${total} waiting` : '';
  b.title = total > 0 ? 'Sessions or agents blocked on your input (permission, question or plan approval)' : '';
}
function toolBadge(tool) {
  const b = el('span', `badge tool tool-${tool}`, TOOL_BADGE[tool] || tool);
  const src = S.sources.find(x => x.id === tool);
  if (src && src.experimental) b.title = `${src.label}: experimental support (parts of this tool's data format are unverified)`;
  return b;
}

// Thin context-usage bar; role=meter with a text equivalent. Colour is never the only signal (percentage is printed too).
function usageBar(u) {
  const m = el('span', `usage ${u.level}`);
  m.setAttribute('role', 'meter');
  m.setAttribute('aria-label', 'Context usage');
  m.setAttribute('aria-valuemin', '0'); m.setAttribute('aria-valuemax', '100'); m.setAttribute('aria-valuenow', String(u.pct));
  m.setAttribute('aria-valuetext', u.text + (u.level === 'high' ? ', nearly full' : ''));
  m.title = `Context: ${u.tokens.toLocaleString('en-US')} of ${u.window.toLocaleString('en-US')} tokens (${u.pct}%)`;
  const fill = el('span', 'usage-fill'); fill.style.width = `${u.pct}%`;
  m.append(fill);
  return m;
}
function projectTokens(p) {
  if (!p || p.tokenTotal === null || p.tokenTotal === undefined) return null;
  const t = el('span', 'tag tokens', `${formatTokens(p.tokenTotal)} tokens`);
  t.title = `${p.tokenTotal.toLocaleString('en-US')} tokens across this project's sessions and agents (latest context or reported total per session; usage, not cost)`;
  return t;
}

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
  for (const s of S.sources.filter(x => x.detected)) {
    const b = el('span', `badge src ${s.health} tool-${s.id}`);
    b.append(document.createTextNode(`${s.label}: ${s.health}`));
    if (s.experimental) b.append(el('span', 'tag exp', 'experimental'));
    const extra = [s.experimental ? "Experimental adapter: some of this tool's data format is unverified" : '', s.lastError || ''].filter(Boolean);
    b.title = [`${s.counts.projects} projects, ${s.counts.sessions} sessions, ${s.counts.running} running${s.counts.waiting ? `, ${s.counts.waiting} waiting` : ''}`, ...extra].join('\n');
    box.append(b);
  }
  const absent = S.sources.filter(x => !x.detected);
  if (absent.length) {
    const d = el('details', 'absent-sources');
    d.append(el('summary', null, `not detected (${absent.length})`), el('span', 'muted', absent.map(x => x.label).join(', ')));
    box.append(d);
  }
  const last = S.sources.map(s => s.lastScanAt).filter(Boolean).sort().pop();
  $('lastScan').textContent = last ? `Last scan ${formatClock(last)}` : '';
  const notices = $('notices');
  notices.replaceChildren();
  for (const s of S.sources) if (s.health === 'error') notices.append(el('div', 'notice error', `${s.label}: ${s.lastError || 'error'}`));
}

// ---------- projects ----------
function renderProjects() { keepFocus($('projects'), renderProjectsInner); updateWaiting(); }
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
      if (p.waitingCount > 0) { const pill = el('span', 'pill waiting'); pill.append(dot('waiting'), document.createTextNode(`${p.waitingCount} waiting`)); meta.append(pill); }
      if (p.runningCount > 0) { const pill = el('span', 'pill running'); pill.append(dot('running'), document.createTextNode(`${p.runningCount} running`)); meta.append(pill); }
      const pt = projectTokens(p); if (pt) meta.append(pt);
      row.append(meta);
      row.addEventListener('click', () => selectProject(p.id, true));
      box.append(row);
    }
  }
  if (!box.querySelector('[tabindex="0"]')) { const first = box.querySelector('.row'); if (first) first.tabIndex = 0; }
  box.scrollTop = scroll;
}

function stacked() { return typeof matchMedia === 'function' && matchMedia('(max-width: 900px)').matches; }
async function selectProject(id, focus) {
  if (id !== S.selectedProject) { S.selectedSession = null; S.detail = null; renderDetail(); }
  S.selectedProject = id; store.set('project', id);
  renderProjects();
  if (focus) { const r = $('projects').querySelector(`[data-id="${CSS.escape(id)}"]`); if (r) r.focus(); }
  if (stacked()) { const r = $('projects').querySelector(`[data-id="${CSS.escape(id)}"]`); if (r) r.scrollIntoView({ block: 'nearest' }); }
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
  if (s.agentType && cls === 'agent') line.append(el('span', 'tag mono', s.agentType));
  const u = contextUsage(s);
  line.append(el('span', 'meta-line muted', u ? `${formatDuration(s.durationMs)} · ${u.pct === null ? u.text : `${formatTokens(u.tokens)} · ${u.pct}%`}` : formatDuration(s.durationMs)));
  if (u && u.pct !== null) line.append(usageBar(u));
  if (s.archived) line.append(el('span', 'tag', 'archived'));
  line.addEventListener('click', ev => { ev.stopPropagation(); selectSession(s.id, false); });
  return line;
}

function renderMap() { keepFocus($('map'), renderMapInner); updateWaiting(); }
function renderMapInner() {
  const box = $('map');
  const scroll = box.scrollTop;
  box.replaceChildren();
  if (!S.selectedProject || !S.project) { box.append(el('p', 'empty', 'Select a project')); return; }
  if (!S.sessions.length) { box.append(el('p', 'empty', 'No sessions in this project.')); return; }
  const ph = el('div', 'proj-head');
  ph.append(el('span', 'name', S.project.name));
  const pht = projectTokens(S.project); if (pht) ph.append(pht);
  box.append(ph);
  for (const s of S.sessions) {
    const card = el('div', `card st-${s.state}`);   // sessions arrive waiting-first from the API
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
  const waiting = S.sessions.reduce((n, s) => n + (s.state === 'waiting') + s.children.filter(c => c.state === 'waiting').length, 0);
  if (S.lastWaiting !== null && waiting > S.lastWaiting) $('announce').textContent = `${waiting} waiting for input`;
  S.lastWaiting = waiting;
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
  if (stacked()) { const r = $('map').querySelector(`[data-id="${CSS.escape(id)}"]`); if (r) r.scrollIntoView({ block: 'nearest' }); }
  if (focus) { const r = $('map').querySelector(`[data-id="${CSS.escape(id)}"]`); if (r) r.focus(); }
  await loadDetail();
}

async function loadDetail() {
  if (!S.selectedSession) { S.detail = null; renderDetail(); return; }
  try { S.detail = (await getJSON(`/api/sessions/${encodeURIComponent(S.selectedSession)}`)).session; } catch { S.detail = null; }
  renderDetail();
  loadContent();
}

// Agent content is fetched on demand only (never part of lists or SSE); refetched when the selected agent's updatedAt changes.
async function loadContent(force) {
  const s = S.detail;
  if (!s) { S.content = null; S.contentFor = null; S.contentKey = null; return; }
  const key = `${s.id}|${s.updatedAt}`;
  if (!force && S.contentKey === key) return;
  S.contentKey = key;
  if (S.contentFor !== s.id) { S.content = null; S.contentFor = s.id; renderContent(); }
  let c;
  try { c = await getJSON(`/api/sessions/${encodeURIComponent(s.id)}/content`); }
  catch (e) { c = { error: /: (\d+)$/.exec(e.message)?.[1] === '501' ? 'Content is not available for this tool.' : 'Content is not available.' }; }
  if (S.selectedSession !== s.id) return;
  S.content = c;
  renderContent();
}

function section(name, title, count, build) {
  const d = el('details', 'sect');
  d.open = !!S.open[name];
  d.addEventListener('toggle', () => { S.open[name] = d.open; });
  const sum = el('summary', null, title);
  if (count !== null) sum.append(el('span', 'count', count));
  d.append(sum, build());
  return d;
}

function renderContent() {
  const box = $('content');
  if (!box) return;
  box.replaceChildren();
  const c = S.content;
  if (!c) { box.append(el('p', 'muted', 'Loading content…')); return; }
  if (c.error) { box.append(el('p', 'muted', c.error)); return; }
  box.append(section('prompt', 'Prompt', null, () => {
    const w = el('div');
    w.append(el('pre', 'prompt', c.prompt || '(none)'));
    if (c.promptTruncated) w.append(el('p', 'muted', 'Prompt truncated.'));
    return w;
  }));
  box.append(section('tools', 'Tool calls', c.toolCallTotal ?? c.toolCalls.length, () => {
    const w = el('div');
    if (c.toolCallsTruncated) w.append(el('p', 'muted', `Showing the last ${c.toolCalls.length} calls.`));
    const ol = el('ol', 'calls');
    for (const t of c.toolCalls) {
      const li = el('li', t.ok === false ? 'err' : null);
      li.append(el('span', 'muted', formatToolTime(t.at)), document.createTextNode(' '), el('strong', `toolname tn-${String(t.tool).replace(/[^A-Za-z0-9]/g, '')}`, t.tool));
      if (t.target) li.append(document.createTextNode(' '), el('code', null, t.target));
      if (t.ok === false) li.append(document.createTextNode(' '), el('span', 'tag', 'error'));
      ol.append(li);
    }
    w.append(ol);
    return w;
  }));
  box.append(section('report', 'Final report', null, () => {
    const w = el('div', 'report');
    const blocks = markdownLite(c.finalReport);
    if (!blocks.length) w.append(el('p', 'muted', '(none)'));
    const fill = (node, inl) => { for (const i of inl) node.append(i.code ? el('code', null, i.s) : document.createTextNode(i.s)); };
    for (const b of blocks) {
      if (b.type === 'p') { const p = el('p'); fill(p, b.inlines); w.append(p); }
      else { const l = el(b.type); for (const it of b.items) { const li = el('li'); fill(li, it); l.append(li); } w.append(l); }
    }
    return w;
  }));
  const r = el('button', 'refresh', 'Refresh');
  r.addEventListener('click', () => loadContent(true));
  box.append(r);
}

function renderDetail() {
  const box = $('detail');
  box.replaceChildren();
  const s = S.detail;
  if (!s) { box.append(el('p', 'empty', 'Select a session or agent')); return; }
  box.append(el('h3', null, s.title));
  const sub = el('p', 'muted subline');
  sub.append(el('span', `chip ${s.state}`, STATE_LABEL[s.state]));
  if (s.agentType) sub.append(el('span', 'mono', s.agentType));
  if (s.model) sub.append(el('span', 'mono', s.model));
  if (s.parent) sub.append(el('span', null, `Spawned by ${s.parent.title}`));
  const subDur = el('span', null, formatDuration(s.durationMs)); subDur.id = 'headDuration';
  sub.append(subDur);
  const su = contextUsage(s); if (su) sub.append(el('span', null, su.text));
  box.append(sub);
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
  if (s.runStartedAt) row('Latest run started', when(s.runStartedAt));
  row('Updated', when(s.updatedAt));
  row('Ended', when(s.endedAt));
  const dur = el('span', null, formatDuration(s.durationMs)); dur.id = 'detailDuration'; row('Duration', dur);
  const du = contextUsage(s);
  if (du) { const w = el('span'); w.append(document.createTextNode(`${du.text} context`)); if (du.pct !== null) { const b = usageBar(du); b.classList.add('block'); w.append(b); } row('Tokens', w); }
  else row('Tokens', '-');
  const la = s.lastActivity;
  row('Last activity', la ? [la.kind, la.toolName, la.summary].filter(Boolean).join(' · ') + ` (${relativeTime(la.at, now)})` : '-');
  if (s.parent) row('Parent', s.parent.title);
  if (s.children && s.children.length) row('Agents', s.children.map(c => `${c.title} (${STATE_LABEL[c.state]})`).join(', '));
  const refPath = s.refs.file || s.refs.db;
  if (refPath) {
    const wrap = el('span', 'refs');
    const code = el('code', null, s.refs.key ? `${refPath} [${s.refs.key}]` : refPath);
    const btn = el('button', 'copy', 'Copy path');
    btn.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(refPath); btn.textContent = 'Copied'; }
      catch { const r = document.createRange(); r.selectNodeContents(code); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); }
      setTimeout(() => { btn.textContent = 'Copy path'; }, 1500);
    });
    wrap.append(code, document.createTextNode(' '), btn);
    row('Data', wrap);
  }
  box.append(dl);
  const content = el('div', 'content'); content.id = 'content';
  box.append(content);
  renderContent();
  box.dataset.createdAt = s.createdAt || '';
}

setInterval(() => {   // live duration for running/idle sessions
  const s = S.detail;
  const d = $('detailDuration');
  const hd = $('headDuration');
  if (s && d && (s.state === 'running' || s.state === 'idle') && (s.runStartedAt || s.createdAt)) { d.textContent = formatDuration(Date.now() - Date.parse(s.runStartedAt || s.createdAt)); if (hd) hd.textContent = d.textContent; }
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
async function loadSources() { const d = await getJSON('/api/sources'); S.sources = d.sources; S.server = d.server; renderSources(); renderProjects(); }
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
