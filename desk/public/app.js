// desk/public/app.js
// SubDeck Desk UI: three panes, SSE-driven partial refresh, keyboard navigation. Data only via textContent.
import { formatDuration, formatTokens, relativeTime, formatClock, STATE_LABEL, SOURCE_LABEL, TOOL_BADGE, groupProjects, filterProjects, middleEllipsis, tildify, tildifyText, markdownLite, formatToolTime, contextUsage, lineDiff } from './format.js';

const $ = id => document.getElementById(id);
const store = {
  get(k, d) { try { const v = localStorage.getItem('desk.' + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('desk.' + k, JSON.stringify(v)); } catch { /* storage unavailable */ } },
};
const S = {
  sources: [], server: null, home: null, projects: [], project: null, sessions: [], detail: null,
  selectedProject: store.get('project', null), selectedSession: null,
  filter: store.get('filter', ''), onlyActive: store.get('onlyActive', false), showTemp: store.get('showTemp', false),
  notify: null, notifyOverrides: [], lastHeartbeat: 0, lastRunning: null, lastWaiting: null,
  content: null, contentFor: null, contentKey: null, open: { prompt: false, tools: false, report: true, changes: false },
  changes: null, changesFor: null, changesKey: null, fileOpen: null, fileData: null,
};

const T = x => tildifyText(x, S.home); // display-only home-directory replacement for free text
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
  if (total <= 0) closeWaiting(false); else if (wp.open) loadWaitingList();
  b.title = total > 0 ? 'Click to list sessions or agents blocked on your input (permission, question or plan approval)' : '';
  b.setAttribute('aria-label', total > 0 ? `${total} waiting for you, open list` : 'Waiting');
}
// ---------- waiting list (the header chip opens a compact list of everything blocked on the user) ----------
const WAIT_KIND = { permission: 'Permission prompt', question: 'Question', plan: 'Plan approval' };
function waitKindLabel(it) {
  if (WAIT_KIND[it.waitingKind]) return WAIT_KIND[it.waitingKind];
  if (it.stateSource === 'hook') return 'Permission prompt';
  if (it.stateSource === 'field') return 'Question or plan approval';
  return 'Unknown';
}
const wp = { open: false, items: [] };
function waitingButtons() { return [...$('waitingPanel').querySelectorAll('.wp-item')]; }
function renderWaitingPanel() {
  const box = $('waitingPanel');
  const keep = document.activeElement && box.contains(document.activeElement) ? document.activeElement.dataset.id : null;
  box.replaceChildren();
  if (!wp.items.length) { box.append(el('p', 'wp-empty', 'Nothing is waiting for you.')); return; }
  const now = Date.now();
  for (const it of wp.items) {
    const b = el('button', 'wp-item'); b.type = 'button'; b.dataset.id = it.id;
    const t0 = it.since ? Date.parse(it.since) : NaN;
    const wait = Number.isFinite(t0) ? formatDuration(Math.max(0, now - t0)) : '';
    const proj = it.projectName || 'unknown project';
    b.append(toolBadge(it.tool), el('span', 'wp-title', T(it.title)), el('span', 'wp-for', waitKindLabel(it)));
    const sub = el('span', 'wp-sub', `${proj}${it.isAgent ? ' · agent' + (it.agentType ? ' ' + it.agentType : '') : ''}${wait ? ' · waiting ' + wait : ''}`);
    if (it.projectPath) sub.title = tildify(it.projectPath, S.home);
    b.append(sub);
    b.setAttribute('aria-label', `${T(it.title)}, ${proj}, ${waitKindLabel(it)}${wait ? ', waiting ' + wait : ''}`);
    b.addEventListener('click', () => { closeWaiting(false); openWaitingItem(it); });
    box.append(b);
  }
  if (keep) { const n = box.querySelector(`[data-id="${CSS.escape(keep)}"]`); if (n) n.focus({ preventScroll: true }); }
}
async function loadWaitingList() {
  try { wp.items = (await getJSON('/api/waiting')).items; } catch { wp.items = []; }
  if (wp.open) renderWaitingPanel();
}
async function openWaitingItem(it) {
  await selectProject(it.projectId, false);
  await selectSession(it.id, true);
}
function closeWaiting(focusChip) {
  if (!wp.open) return;
  wp.open = false;
  $('waitingPanel').hidden = true;
  $('waitingCount').setAttribute('aria-expanded', 'false');
  if (focusChip && !$('waitingCount').hidden) $('waitingCount').focus();
}
async function openWaiting() {
  wp.open = true;
  $('waitingPanel').hidden = false;
  $('waitingCount').setAttribute('aria-expanded', 'true');
  await loadWaitingList();
  renderWaitingPanel();
  const first = waitingButtons()[0]; if (first) first.focus();
}
$('waitingCount').addEventListener('click', () => { if (wp.open) closeWaiting(true); else openWaiting(); });
$('waitingPanel').addEventListener('keydown', ev => {
  if (ev.key !== 'ArrowDown' && ev.key !== 'ArrowUp') return;
  const items = waitingButtons(); const i = items.indexOf(document.activeElement);
  if (i < 0) return;
  ev.preventDefault();
  items[ev.key === 'ArrowDown' ? Math.min(items.length - 1, i + 1) : Math.max(0, i - 1)].focus();
});
document.addEventListener('keydown', ev => { if (ev.key === 'Escape' && wp.open) { ev.preventDefault(); closeWaiting(true); } });
document.addEventListener('click', ev => { if (wp.open && !ev.target.closest('#waitingPanel, #waitingCount')) closeWaiting(false); });

function toolBadge(tool) {
  const b = el('span', `badge tool tool-${tool}`, TOOL_BADGE[tool] || tool);
  const src = S.sources.find(x => x.id === tool);
  if (src && src.experimental) { const t = `${src.label}: data format not yet verified on every platform`; b.title = t; b.setAttribute('aria-label', `${TOOL_BADGE[tool] || tool}. ${t}`); }
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

// ---------- notifications switch (the only setting Desk can change) ----------
const BELL_ON = 'M12 3a6 6 0 0 0-6 6v3.6L4.5 16h15L18 12.6V9a6 6 0 0 0-6-6zm0 18a2.5 2.5 0 0 0 2.4-2h-4.8A2.5 2.5 0 0 0 12 21z';
function renderBell() {
  const b = $('bell'); if (!b) return;
  const on = S.notify === true;
  b.hidden = S.notify === null;
  b.setAttribute('aria-checked', String(on));
  b.classList.toggle('on', on);
  b.title = on ? 'Desktop notifications: on (click to turn off)' : 'Desktop notifications: off (click to turn on)';
  const ov = S.notifyOverrides || [];
  if (ov.length) {
    const list = ov.map(o => `${o.project || 'project'}: ${tildify(o.file, S.home)} (${o.enabled ? 'on' : 'off'})`).join('\n');
    b.title += `\nOverridden by a project config, which wins over this switch:\n${list}`;
  }
  b.classList.toggle('overridden', ov.length > 0);
  b.replaceChildren();
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('width', '16'); svg.setAttribute('height', '16'); svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  path.setAttribute('d', BELL_ON); path.setAttribute('fill', 'currentColor'); svg.appendChild(path);
  if (!on) { const l = document.createElementNS('http://www.w3.org/2000/svg', 'path'); l.setAttribute('d', 'M4 4l16 16'); l.setAttribute('stroke', 'currentColor'); l.setAttribute('stroke-width', '2'); l.setAttribute('stroke-linecap', 'round'); svg.appendChild(l); }
  b.append(svg, el('span', 'bell-label', on ? 'Notifications on' : 'Notifications off'));
  if (ov.length) b.append(el('span', 'bell-note', ov.length === 1 ? `overridden by ${ov[0].project || 'project'}` : `overridden by ${ov.length} projects`));
}
async function loadNotify() {
  try { const d = await getJSON('/api/settings/notify'); S.notify = d.enabled === true; S.notifyOverrides = Array.isArray(d.overriddenBy) ? d.overriddenBy : []; }
  catch { S.notify = null; S.notifyOverrides = []; }
  renderBell();
}
async function toggleNotify() {
  const meta = document.querySelector('meta[name="subdeck-token"]');
  const want = !(S.notify === true);
  try {
    const r = await fetch('/api/settings/notify', { method: 'POST', cache: 'no-store',
      headers: { 'Content-Type': 'application/json', 'X-SubDeck-Token': meta ? meta.content : '' }, body: JSON.stringify({ enabled: want }) });
    if (!r.ok) throw new Error(String(r.status));
    S.notify = (await r.json()).enabled === true;
  } catch { /* keep the old state; re-read below */ }
  await loadNotify();
}
if ($('bell')) $('bell').addEventListener('click', () => { toggleNotify(); });

// ---------- header ----------
function renderSources() {
  const box = $('sources');
  box.replaceChildren();
  for (const s of S.sources.filter(x => x.detected)) {
    const b = el('span', `badge src ${s.health} tool-${s.id}`);
    b.append(document.createTextNode(`${s.label}: ${s.health}`));
    const extra = [s.experimental ? `${s.label}: data format not yet verified on every platform` : '', s.lastError || ''].filter(Boolean);
    b.title = [`${s.counts.projects} projects, ${s.counts.sessions} sessions, ${s.counts.running} running${s.counts.waiting ? `, ${s.counts.waiting} waiting` : ''}`, ...extra].join('\n');
    b.setAttribute('aria-label', b.title.split('\n').join('. '));
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
  const list = filterProjects(S.projects, { text: S.filter, onlyActive: S.onlyActive, showTemp: S.showTemp }, now);
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
      const shown = tildify(p.path || '', S.home);
      const path = el('div', 'path', middleEllipsis(shown, 48)); path.title = shown;
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
  line.append(dot(s.state), el('span', 'title', T(s.title)), stateWord(s.state));
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
  loadChanges();
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

// ---------- changed files (from file-edit tool calls; fetched on demand per selected agent) ----------
async function loadChanges(force) {
  const s = S.detail;
  if (!s) { S.changes = null; S.changesFor = null; S.changesKey = null; return; }
  const key = `${s.id}|${s.updatedAt}`;
  if (!force && S.changesKey === key) return;
  S.changesKey = key;
  if (S.changesFor !== s.id) { S.changes = null; S.changesFor = s.id; S.fileOpen = null; S.fileData = null; renderChanges(); }
  let c;
  try { c = await getJSON(`/api/sessions/${encodeURIComponent(s.id)}/changes`); }
  catch (e) { c = { error: /: (d+)$/.exec(e.message)?.[1] === '501' ? 'Changed files are not available for this tool.' : 'Changed files are not available.' }; }
  if (S.selectedSession !== s.id) return;
  S.changes = c;
  renderConflicts();
  renderChanges();
}
function shownPath(f) { return f.rel || tildify(f.path, S.home); }
function renderConflicts() {
  const box = $('conflicts');
  if (!box) return;
  box.replaceChildren();
  const list = S.changes && S.changes.conflicts ? S.changes.conflicts : [];
  box.hidden = !list.length;
  if (!list.length) return;
  box.append(el('strong', null, `${list.length} file${list.length === 1 ? '' : 's'} changed by more than one agent`));
  const ul = el('ul');
  for (const c of list) {
    const li = el('li');
    const code = el('code', null, shownPath(c)); code.title = tildify(c.path, S.home);
    li.append(code, document.createTextNode(` by ${c.agents.map(a => T(a.title)).join(', ')}${c.parallel ? ' (overlapping in time)' : ''}`));
    ul.append(li);
  }
  box.append(ul);
}
function diffView(d) {
  const wrap = el('div', 'diff');
  wrap.setAttribute('role', 'region'); wrap.setAttribute('aria-label', 'Diff of ' + shownPath(d));
  if (d.withheld) { wrap.append(el('div', 'dh', 'Contents withheld: this looks like a secret file.')); return wrap; }
  for (const e of d.edits) {
    const kind = e.kind === 'write' ? 'Write (full new content)' : e.kind === 'notebook' ? `Notebook ${e.editMode}${e.cellId ? ' cell ' + e.cellId : ''} (new source)` : e.replaceAll ? 'Edit (replace all)' : 'Edit';
    wrap.append(el('div', 'dh', `${kind} · ${formatToolTime(e.at)}`));
    const lines = e.kind === 'edit' ? lineDiff(e.old, e.new) : lineDiff('', e.kind === 'write' ? e.content : e.new);
    for (const l of lines) wrap.append(el('div', l.t === '+' ? 'dl add' : l.t === '-' ? 'dl del' : 'dl ctx', (l.t === ' ' ? '  ' : l.t + ' ') + T(l.s)));
  }
  if (d.truncated) wrap.append(el('div', 'dh', `Truncated: showing ${d.edits.length} of ${d.total} edits, long text cut. Line numbers are not available.`));
  else wrap.append(el('div', 'dh', 'Old and new text of each edit; line numbers are not available.'));
  return wrap;
}
async function toggleFile(f, li) {
  if (S.fileOpen === f.path) { S.fileOpen = null; S.fileData = null; renderChanges(); return; }
  S.fileOpen = f.path; S.fileData = { loading: true }; renderChanges();
  const id = S.selectedSession;
  let d;
  try { d = await getJSON(`/api/sessions/${encodeURIComponent(id)}/changes/file?path=${encodeURIComponent(f.path)}`); }
  catch { d = { error: 'Could not load this diff.' }; }
  if (S.selectedSession !== id || S.fileOpen !== f.path) return;
  S.fileData = d; renderChanges();
}
function renderChanges() {
  const box = $('changes');
  if (!box) return;
  box.replaceChildren();
  const c = S.changes;
  const files = c && c.files ? c.files : [];
  box.append(section('changes', 'Changed files', c && !c.error ? files.length : null, () => {
    const w = el('div');
    if (!c) { w.append(el('p', 'muted', 'Loading changed files…')); return w; }
    if (c.error) { w.append(el('p', 'muted', c.error)); return w; }
    if (!files.length) w.append(el('p', 'muted', 'No file edits recorded by this agent.'));
    const ul = el('ul', 'files');
    for (const f of files) {
      const li = el('li');
      const b = el('button', 'file'); b.type = 'button'; b.setAttribute('aria-expanded', String(S.fileOpen === f.path));
      const code = el('code', null, shownPath(f)); code.title = tildify(f.path, S.home);
      b.append(code, el('span', 'muted', `${f.count} edit${f.count === 1 ? '' : 's'}`));
      for (const o of f.alsoBy || []) b.append(el('span', 'tag conflict', `also changed by ${T(o.title)}`));
      b.addEventListener('click', () => toggleFile(f, li));
      li.append(b);
      if (S.fileOpen === f.path) {
        const d = S.fileData;
        if (!d || d.loading) li.append(el('p', 'muted', 'Loading diff…'));
        else if (d.error) li.append(el('p', 'muted', d.error));
        else li.append(diffView(d));
      }
      ul.append(li);
    }
    w.append(ul, el('p', 'muted', 'Listed from file-edit tool calls (Write, Edit, MultiEdit, NotebookEdit); edits made through shell commands are not listed.'));
    return w;
  }));
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
    w.append(el('pre', 'prompt', T(c.prompt) || '(none)'));
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
      if (t.target) li.append(document.createTextNode(' '), el('code', null, T(t.target)));
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
    const fill = (node, inl) => { for (const i of inl) node.append(i.code ? el('code', null, T(i.s)) : document.createTextNode(T(i.s))); };
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
  box.append(el('h3', null, T(s.title)));
  const sub = el('p', 'muted subline');
  sub.append(el('span', `chip ${s.state}`, STATE_LABEL[s.state]));
  if (s.agentType) sub.append(el('span', 'mono', s.agentType));
  if (s.model) sub.append(el('span', 'mono', s.model));
  if (s.parent) sub.append(el('span', null, `Spawned by ${T(s.parent.title)}`));
  const subDur = el('span', null, formatDuration(s.durationMs)); subDur.id = 'headDuration';
  sub.append(subDur);
  const su = contextUsage(s); if (su) sub.append(el('span', null, su.text));
  box.append(sub);
  const conf = el('div', 'conflicts'); conf.id = 'conflicts'; conf.hidden = true;
  box.append(conf);
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
  row('Last activity', la ? T([la.kind, la.toolName, la.summary].filter(Boolean).join(' · ')) + ` (${relativeTime(la.at, now)})` : '-');
  if (s.parent) row('Parent', T(s.parent.title));
  if (s.children && s.children.length) row('Agents', s.children.map(c => `${T(c.title)} (${STATE_LABEL[c.state]})`).join(', '));
  const refPath = s.refs.file || s.refs.db;
  if (refPath) {
    const wrap = el('span', 'refs');
    const shownRef = tildify(refPath, S.home);
    const code = el('code', null, s.refs.key ? `${shownRef} [${s.refs.key}]` : shownRef);
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
  const ch = el('div', 'content'); ch.id = 'changes';
  box.append(ch);
  renderChanges();
  renderConflicts();
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
$('showTemp').checked = S.showTemp;
$('showTemp').addEventListener('change', e => { S.showTemp = e.target.checked; store.set('showTemp', S.showTemp); renderProjects(); });
$('filter').addEventListener('input', e => { S.filter = e.target.value; store.set('filter', S.filter); renderProjects(); });
$('onlyActive').addEventListener('change', e => { S.onlyActive = e.target.checked; store.set('onlyActive', S.onlyActive); renderProjects(); });

// ---------- data flow ----------
async function loadSources() { const d = await getJSON('/api/sources'); S.sources = d.sources; S.server = d.server; S.home = d.home; renderSources(); renderProjects(); }
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
    loadNotify();
    if (S.selectedProject && ev.projects.includes(S.selectedProject)) {
      await loadProject();
      if (S.detail && S.detail.projectId === S.selectedProject) await loadDetail();
    }
  });
  es.onerror = () => { S.lastHeartbeat = 0; };
}

renderMap();
loadNotify();
connect();
