// desk/public/runs.js
// Run badge text and the run-log view (log/out tails and the final message of one SubDeck run). Read-only; data only via textContent.

/** "worker · codex/gpt-5-codex" (model omitted when empty, " exp" for experimental tools); null without role and tool. */
export function runBadgeText(r) {
  if (!r || (!r.role && !r.tool)) return null;
  const via = r.tool ? `${r.tool}${r.model ? '/' + r.model : ''}${r.experimental || r.tool === 'agy' ? ' exp' : ''}` : '';
  return [r.role, via].filter(Boolean).join(' · ');
}

export const RUN_STATUS_LABEL = { running: 'running', ok: 'ok', failed: 'failed', quota: 'quota', auth: 'login needed', timeout: 'timeout', violation: 'write violation', cancelled: 'cancelled' };
export const runUrl = (projectId, taskId, ts, lines) => `/api/runs/${encodeURIComponent(projectId)}/${encodeURIComponent(taskId)}/${encodeURIComponent(ts)}/log?lines=${lines}`;
const cache = new Map();   // key -> last fetched log, shown again at once when the view is rebuilt

/**
 * Mounts the run-log view into `box`. Refreshes every 3 s while the run is running (stops when the box leaves the page).
 * Returns { stop }.
 */
export function mountRunLog(box, { el, getJSON, projectId, taskId, ts, running, lines = 200 }) {
  const key = `${projectId}/${taskId}/${ts}`;
  let stopped = false, timer = null, n = lines, data = cache.get(key) || null, err = null;
  const wrap = el('div', 'runlog');
  box.append(wrap);

  function pre(title, text, cls) {
    const d = el('div', 'runlog-part');
    d.append(el('h4', 'subhead', title));
    d.append(el('pre', `runlog-pre ${cls || ''}`, text || '(empty)'));
    return d;
  }
  function draw() {
    wrap.replaceChildren();
    const bar = el('div', 'runlog-bar');
    const sel = el('select'); sel.setAttribute('aria-label', 'Lines to show');
    for (const v of [50, 200, 1000, 2000]) { const o = el('option', null, `last ${v} lines`); o.value = String(v); if (v === n) o.selected = true; sel.append(o); }
    sel.addEventListener('change', () => { n = Number(sel.value); load(); });
    const r = el('button', 'refresh', 'Refresh'); r.type = 'button'; r.addEventListener('click', () => load());
    bar.append(sel, r);
    if (running) bar.append(el('span', 'muted', 'refreshing while the run is active'));
    wrap.append(bar);
    if (err) { wrap.append(el('p', 'muted', err)); return; }
    if (!data) { wrap.append(el('p', 'muted', 'Loading run log…')); return; }
    wrap.append(pre('Final message', data.final === null ? '(no final message yet)' : data.final, 'final'));
    wrap.append(pre('Log (run.sh and CLI stderr)', data.log));
    wrap.append(pre('Output (CLI stdout)', data.out));
    if (data.truncated) wrap.append(el('p', 'muted', 'Showing only the end of a longer log.'));
  }
  async function load() {
    try { data = await getJSON(runUrl(projectId, taskId, ts, n)); cache.set(key, data); err = null; }
    catch (e) { err = /: 404$/.test(String(e && e.message)) ? 'The run log is not available (content disabled or files gone).' : 'Could not load the run log.'; }
    if (!stopped) draw();
  }
  draw();
  load();
  if (running) {
    timer = setInterval(() => { if (!wrap.isConnected) { stop(); return; } load(); }, 3000);
  }
  function stop() { stopped = true; if (timer) clearInterval(timer); timer = null; }
  return { stop };
}
