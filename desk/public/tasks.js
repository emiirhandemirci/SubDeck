// desk/public/tasks.js
import { runBadgeText, RUN_STATUS_LABEL, mountRunLog } from './runs.js';
import { formatTokens, quotaText, cliText, waveText } from './format.js';
// Tasks tab: one card per task file (and Beads item), columns by status. Read-only; data only via textContent.

export const COLUMNS = [
  ['open', 'Open'], ['in-progress', 'In progress'], ['blocked', 'Blocked'], ['interrupted', 'Interrupted'], ['review', 'Review'], ['done', 'Done'],
];

/** Groups tasks into the six columns (unknown status -> open), newest update first. */
export function groupTasks(tasks) {
  const cols = new Map(COLUMNS.map(([id]) => [id, []]));
  for (const t of tasks) cols.get(cols.has(t.status) ? t.status : 'open').push(t);
  for (const l of cols.values()) l.sort((a, b) => String(b.updated).localeCompare(String(a.updated)));
  return COLUMNS.map(([id, title]) => ({ id, title, tasks: cols.get(id) }));
}

/** "interrupted: N uncommitted files" for an interrupted task with a handoff note, else null. */
export function handoffSummary(t) {
  if (!t || t.status !== 'interrupted' || !t.handoff) return null;
  const n = t.handoff.files;
  if (!Number.isInteger(n)) return 'interrupted';
  return `interrupted: ${n} uncommitted file${n === 1 ? '' : 's'}`;
}

/** Tab label: the total task count, plus "!N" when N tasks are blocked or interrupted. */
export function tabLabel(projects) {
  let total = 0, attn = 0;
  for (const p of projects || []) for (const t of p.tasks || []) { total++; if (t.status === 'interrupted' || t.status === 'blocked') attn++; }
  if (!total) return { text: 'Tasks', title: '' };
  const title = `${total} task${total === 1 ? '' : 's'}${attn ? `, ${attn} blocked or interrupted` : ''}`;
  return { text: attn ? `Tasks (${total}) !${attn}` : `Tasks (${total})`, title };
}

export function initTasks({ $, el, getJSON, relativeTime, openSession, showSessions, closeOthers }) {
  const st = { open: false, data: null, error: null, project: '', expanded: new Set(), bodies: new Map(), gen: 0, runLogs: new Set(), mounts: [], pending: [] };

  function projectsWithTasks() { return (st.data ? st.data.projects : []).filter(p => p.tasks.length); }

  function card(p, t) {
    const key = `${p.projectId}/${t.id}`;
    const c = el('article', `tcard st-${t.status}`);
    const head = el('div', 'tcard-head');
    head.append(el('span', 'mono tcard-id', t.id));
    if (t.source === 'beads') head.append(el('span', 'tag', 'Beads'));
    if (t.auto) { const b = el('span', 'tag autotask', 'auto'); b.title = 'Created automatically for an agent that had no task (auto-bind); records untracked work'; head.append(b); }
    if (t.verdict) { const b = el('span', `tag verdict v-${t.verdict.replace(/\s+/g, '-').toLowerCase()}`, t.verdict); b.title = t.verifiedBy ? `Latest verdict by ${t.verifiedBy.by || 'unknown'}${t.verifiedBy.fingerprint ? `, fingerprint ${t.verifiedBy.fingerprint}` : ''}` : 'Latest verdict'; head.append(b); }
    if (t.invalid) { const b = el('span', 'tag conflict', 'invalid'); b.title = 'Unreadable or unknown status; shown as open'; head.append(b); }
    c.append(head, el('div', 'tcard-title', t.title));
    const rb = runBadgeText(t);
    if (rb || t.branch) {
      const rl = el('div', 'tcard-run');
      if (rb) { const b = el('span', 'tag runbadge', rb); b.title = `Last producer: ${rb}`; rl.append(b); }
      if (t.branch) { const b = el('span', 'mono muted tcard-branch', t.branch); b.title = t.worktree ? `Branch ${t.branch}, worktree ${t.worktree}` : `Branch ${t.branch}`; rl.append(b); }
      c.append(rl);
    }
    const meta = el('div', 'tcard-meta muted');
    if (t.owner) meta.append(el('span', 'mono', t.owner));
    if (t.agent) {
      if (t.agentSessionId) {
        const b = el('button', 'linklike mono', `agent ${t.agent.slice(0, 8)}`); b.type = 'button';
        b.title = 'Open this agent in Sessions';
        b.addEventListener('click', () => { showSessions(); openSession(p.projectId, t.agentSessionId); });
        meta.append(b);
      } else meta.append(el('span', 'mono', `agent ${t.agent.slice(0, 8)}`));
    }
    if (t.blockedBy.length) meta.append(el('span', null, `blocked by ${t.blockedBy.join(', ')}`));
    if (t.updated) { const u = el('span', null, relativeTime(t.updated, Date.now())); u.title = t.updated; meta.append(u); }
    c.append(meta);
    if (t.wave || t.grants.length || Number.isFinite(t.tokens)) {
      const x = el('div', 'tcard-extra muted');
      if (t.wave) { const w = el('span', 'tag wavechip', `wave ${t.wave}`); w.title = t.covers.length ? `Verified together with ${t.covers.join(', ')}` : `Context pack ${t.pack}`; x.append(w); }
      if (t.grants.length) { const g = el('span', 'tag grantchip', `+${t.grants.length} grant${t.grants.length === 1 ? '' : 's'}`); g.title = `Granted paths: ${t.grants.join(', ')}`; x.append(g); }
      if (Number.isFinite(t.tokens)) { const k = el('span', null, `${formatTokens(t.tokens)} tokens`); k.title = 'Cumulative tokens of the agents that worked on this task'; x.append(k); }
      c.append(x);
    }
    if (t.grants.length) c.append(el('div', 'tcard-paths mono muted', `grants: ${t.grants.join(', ')}`));
    const hs = handoffSummary(t);
    if (hs) c.append(el('div', 'tcard-handoff', hs));
    if (t.writable.length) c.append(el('div', 'tcard-paths mono muted', t.writable.join(', ')));
    if (t.lastRun) {
      const lr = t.lastRun, rk = `${key}/${lr.ts}`;
      const line = el('div', 'tcard-lastrun muted');
      line.append(el('span', `tag runstatus rs-${lr.status}`, RUN_STATUS_LABEL[lr.status] || lr.status), el('span', null, `last run ${lr.ts.replace(/^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d).*$/, '$1-$2-$3 $4:$5')}`));
      const lb = el('button', 'linklike', st.runLogs.has(rk) ? 'Hide run log' : 'Run log'); lb.type = 'button';
      lb.setAttribute('aria-expanded', String(st.runLogs.has(rk)));
      lb.addEventListener('click', () => { if (st.runLogs.has(rk)) st.runLogs.delete(rk); else st.runLogs.add(rk); render(); });
      line.append(lb);
      {
        const ob = el('button', 'linklike', 'Open as agent'); ob.type = 'button';
        ob.addEventListener('click', () => { showSessions(); openSession(p.projectId, `run.${t.id}.${lr.ts}`); });
        line.append(ob);
      }
      c.append(line);
      if (st.runLogs.has(rk)) {
        const holder = el('div', 'tcard-runlog'); c.append(holder);
        st.pending.push(() => st.mounts.push(mountRunLog(holder, { el, getJSON, projectId: p.projectId, taskId: t.id, ts: lr.ts, running: lr.status === 'running' })));
      }
    }
    const open = st.expanded.has(key);
    const tog = el('button', 'linklike', open ? 'Hide details' : 'Details'); tog.type = 'button';
    tog.setAttribute('aria-expanded', String(open));
    tog.addEventListener('click', async () => {
      if (st.expanded.has(key)) st.expanded.delete(key); else { st.expanded.add(key); if (!st.bodies.has(key)) await loadBody(p.projectId, t.id, key); }
      render();
    });
    c.append(tog);
    if (open) {
      const b = st.bodies.get(key);
      c.append(el('pre', 'tcard-body', b === undefined ? 'Loading…' : b === null ? 'Details are not available (content disabled or file gone).' : b));
    }
    return c;
  }

  async function loadBody(projectId, taskId, key) {
    try { st.bodies.set(key, (await getJSON(`/api/tasks/${encodeURIComponent(projectId)}/${encodeURIComponent(taskId)}`)).task.body || '(empty)'); }
    catch { st.bodies.set(key, null); }
  }

  function render() {
    const box = $('tasksBody');
    const top = box.scrollTop;
    for (const m of st.mounts) m.stop();
    st.mounts = []; st.pending = [];
    box.replaceChildren();
    const sel = $('tasksProject');
    const pl = projectsWithTasks();
    const keep = st.project && pl.some(p => p.projectId === st.project) ? st.project : '';
    st.project = keep;
    sel.replaceChildren();
    const all = el('option', null, 'All projects'); all.value = ''; sel.append(all);
    for (const p of pl) { const o = el('option', null, p.projectName); o.value = p.projectId; sel.append(o); }
    sel.value = keep;
    if (st.error) { box.append(el('p', 'empty', `Could not load tasks: ${st.error}`)); return; }
    if (!st.data) { box.append(el('p', 'empty', 'Loading…')); return; }
    const shown = pl.filter(p => !keep || p.projectId === keep);
    if (!shown.length) {
      const d = el('div', 'empty');
      d.append(el('strong', 'empty-title', 'No tasks yet'), el('span', 'empty-hint', 'Tasks are created by the manager with tasks.sh new; they show up here as they change.'));
      box.append(d); return;
    }
    const multi = shown.length > 1;
    const flat = [];
    for (const p of shown) for (const t of p.tasks) flat.push({ p, t });
    for (const p of shown) {
      const notes = [quotaText(p.quota), cliText(p.cli)].filter(Boolean);
      const ws = p.waves || [];
      if (!notes.length && !ws.length) continue;
      const sum = el('div', 'tsummary');
      if (quotaText(p.quota)) sum.append(el('div', 'notice-banner', quotaText(p.quota)));
      if (cliText(p.cli)) sum.append(el('div', 'muted tsummary-cli', multi ? `${p.projectName}: ${cliText(p.cli)}` : cliText(p.cli)));
      for (const w of ws) { const r = el('div', 'tsummary-wave', waveText(w)); r.title = `${w.agents} agent${w.agents === 1 ? '' : 's'}: ${w.tasks.join(', ')}`; sum.append(r); }
      box.append(sum);
    }
    const cols = el('div', 'tcols');
    for (const g of groupTasks(flat.map(x => x.t))) {
      const col = el('section', `tcol col-${g.id}`);
      col.setAttribute('aria-label', `${g.title}, ${g.tasks.length}`);
      const h = el('h3', null, g.title); h.append(el('span', 'tcount', String(g.tasks.length)));
      col.append(h);
      if (!g.tasks.length) col.append(el('p', 'tcol-empty muted', 'None'));
      for (const t of g.tasks) {
        const x = flat.find(f => f.t === t);
        const cd = card(x.p, t);
        if (multi) cd.querySelector('.tcard-head').append(el('span', 'tag', x.p.projectName));
        col.append(cd);
      }
      cols.append(col);
    }
    box.append(cols);
    for (const f of st.pending) f();
    st.pending = [];
    box.scrollTop = top;
  }

  async function load() {
    const gen = ++st.gen;
    try { const d = await getJSON('/api/tasks'); if (gen !== st.gen) return; st.data = d; st.error = null; }
    catch (e) { if (gen !== st.gen) return; st.error = String(e && e.message).slice(0, 120); }
    for (const k of st.expanded) st.bodies.delete(k);   // re-read open details after a change
    if (st.open) { render(); for (const k of st.expanded) { const [pid, tid] = k.split('/'); if (!st.bodies.has(k)) loadBody(pid, tid, k).then(() => { if (st.open) render(); }); } }
    updateTab();
  }

  function updateTab() {
    const l = tabLabel(st.data ? st.data.projects : []);
    const b = $('tabTasks');
    b.textContent = l.text;
    b.title = l.title;
  }

  function show(on) {
    st.open = on;
    $('tasksView').hidden = !on;
    $('tabTasks').setAttribute('aria-selected', String(on));
    if (on) { $('panesView').hidden = true; $('settingsView').hidden = true; $('tabSessions').setAttribute('aria-selected', 'false'); $('tabSettings').setAttribute('aria-selected', 'false'); render(); load(); }
  }
  $('tabTasks').addEventListener('click', () => { closeOthers(); show(true); });
  // Sessions and Settings tabs close this view (their own handlers show their view first).
  $('tabSessions').addEventListener('click', () => { if (st.open) show(false); });
  $('tabSettings').addEventListener('click', () => { if (st.open) show(false); });
  $('tasksProject').addEventListener('change', e => { st.project = e.target.value; render(); });
  load().catch(() => {});

  return { show, reload: () => load(), state: st };
}
