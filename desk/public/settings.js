// desk/public/settings.js
// Settings tab and theme switch. Reads GET /api/settings, writes POST /api/settings (the server runs settings.sh); data only via textContent.

export const GROUPS = [
  ['models', 'Models'], ['notify', 'Notifications'], ['push', 'Push'], ['guard', 'Guard rules'],
  ['protect', 'Protected paths'], ['context', 'Context window'], ['statusline', 'Status line'],
];
export const THEMES = [['system', 'System'], ['light', 'Light'], ['dark', 'Dark']];

export function isOn(v) { return v === true || v === 'on' || v === 'true'; }
export function listValue(v) {
  if (Array.isArray(v)) return v.map(String).filter(Boolean);
  if (typeof v === 'string') return v.split(',').map(s => s.trim()).filter(Boolean);
  return [];
}
/** Wire value for settings.sh set k=v. */
export function toWire(item, v) {
  if (item.type === 'bool') return v ? 'on' : 'off';
  if (item.type === 'list') return listValue(v).join(',');
  return String(v);
}
/** Text for the confirm dialog when the change lowers protection, else null. */
export function confirmText(item, next) {
  if (!item) return null;
  if (item.group === 'guard' && next === 'off') return `Turn off ${item.key}? Agents will no longer be stopped or asked for this kind of action.`;
  if (item.key === 'push' && next === 'off') return 'Turn off the push gate? Agents will be able to push to any branch without asking.';
  return null;
}
export const isReadOnly = item => item.key === 'statusline';
export function groupItems(settings) {
  const known = new Set(GROUPS.map(g => g[0]));
  return GROUPS.map(([id, title]) => ({ id, title, items: settings.filter(s => s.group === id) }))
    .concat([{ id: 'other', title: 'Other', items: settings.filter(s => !known.has(s.group)) }])
    .filter(g => g.items.length);
}

export function applyTheme(t) {
  const r = document.documentElement;
  if (t === 'light' || t === 'dark') r.setAttribute('data-theme', t); else r.removeAttribute('data-theme');
}

export function initSettings({ $, el, store, getJSON, token, getProject, onWindow }) {
  const st = { theme: store.get('theme', 'system'), scope: 'user', data: null, error: null, busy: false, open: false, msg: null, gen: 0 };
  if (!THEMES.some(t => t[0] === st.theme)) st.theme = 'system';

  // ---- theme ----
  function setTheme(t) { st.theme = t; store.set('theme', t); applyTheme(t); renderThemeSwitch(); if (st.open) render(); }
  function renderThemeSwitch() {
    const box = $('themeSwitch'); if (!box) return;
    box.replaceChildren();
    for (const [id, label] of THEMES) {
      const b = el('button', 'seg', label); b.type = 'button';
      b.setAttribute('aria-pressed', String(st.theme === id));
      b.addEventListener('click', () => setTheme(id));
      box.append(b);
    }
  }

  // ---- data ----
  const project = () => getProject();
  function projectParam() { const p = project(); return st.scope === 'project' && p ? `?project=${encodeURIComponent(p.id)}` : ''; }
  // settings.sh can take several seconds, so a reload after a save is silent: the screen keeps the optimistic values until it lands.
  async function load(silent = false) {
    const gen = st.gen;
    if (!silent) { st.data = null; st.error = null; render(); }
    try { const d = await getJSON('/api/settings' + projectParam()); if (gen !== st.gen) return; st.data = d; st.error = null; }
    catch (e) { if (gen !== st.gen) return; if (!silent) st.data = null; st.error = String(e.message || e).replace(/^\/api\/settings[^:]*: /, 'Settings unavailable: '); }
    render();
  }
  /** Context window for unknown models comes from the user-scope settings; read once at start and after saves. */
  async function loadWindow() {
    try {
      const d = st.scope === 'user' && st.data ? st.data : await getJSON('/api/settings');
      const it = d.settings.find(s => s.key === 'context');
      const n = it ? Number(it.value) : 0;
      onWindow(Number.isInteger(n) && n > 0 ? n : null);
    } catch { /* settings.sh unavailable: window stays auto */ }
  }
  async function save(item, next) {
    const need = confirmText(item, next);
    if (need && !(await confirmDialog(need))) { render(); return; }
    st.busy = true; st.gen++; st.msg = { bad: false, text: `Saving ${item.key}…` }; render();
    try {
      const meta = document.querySelector('meta[name="subdeck-token"]');
      const p = project();
      const r = await fetch('/api/settings', { method: 'POST', cache: 'no-store',
        headers: { 'Content-Type': 'application/json', 'X-SubDeck-Token': meta ? meta.content : '' },
        body: JSON.stringify({ set: { [item.key]: next }, project: st.scope === 'project' && p ? p.id : null }) });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) st.msg = { bad: true, text: body.error || `Save failed (${r.status})` };
      else {
        st.msg = { bad: false, text: `Saved ${item.key}` };
        item.value = item.type === 'list' ? listValue(next) : item.type === 'int' ? Number(next) : next;   // optimistic; the silent reload below confirms it
        item.source = st.scope;
      }
    } catch { st.msg = { bad: true, text: 'Save failed: Desk is unreachable' }; }
    st.busy = false;
    render();
    await load(true);
    loadWindow();
  }

  // ---- confirm dialog (in page, a native dialog element) ----
  function confirmDialog(text) {
    return new Promise(resolve => {
      const d = $('confirmDlg');
      if (!d || typeof d.showModal !== 'function') return resolve(false);   // no dialog support: refuse the risky change
      $('confirmText').textContent = text;
      const yes = $('confirmYes'), no = $('confirmNo');
      const done = v => { yes.onclick = no.onclick = null; d.onclose = null; if (d.open) d.close(); resolve(v); };
      yes.onclick = () => done(true);
      no.onclick = () => done(false);
      d.onclose = () => done(false);
      d.showModal(); no.focus();
    });
  }

  // ---- controls ----
  function control(item) {
    const id = `set-${item.key.replace(/[^A-Za-z0-9_-]/g, '_')}`;
    const dis = st.busy;
    if (isReadOnly(item)) {
      const w = el('span', 'sval', String(item.value)); return { node: w, id };
    }
    if (item.type === 'enum') {
      const s = el('select'); s.id = id; s.disabled = dis;
      const opts = Array.isArray(item.options) ? item.options : [];
      for (const o of opts.includes(item.value) ? opts : [item.value, ...opts]) { const op = el('option', null, o); op.value = o; if (o === item.value) op.selected = true; s.append(op); }
      s.addEventListener('change', () => save(item, s.value));
      return { node: s, id };
    }
    if (item.type === 'bool') {
      const on = isOn(item.value);
      const b = el('button', 'switch'); b.type = 'button'; b.id = id; b.disabled = dis;
      b.setAttribute('role', 'switch'); b.setAttribute('aria-checked', String(on));
      b.append(el('span', 'knob'), el('span', 'sw-label', on ? 'On' : 'Off'));
      b.addEventListener('click', () => save(item, on ? 'off' : 'on'));
      return { node: b, id };
    }
    if (item.type === 'int') {
      const i = el('input'); i.type = 'number'; i.min = '0'; i.step = '1'; i.id = id; i.disabled = dis; i.value = String(item.value ?? 0);
      const commit = () => { const n = Number(i.value); if (i.value !== '' && Number.isInteger(n) && n >= 0 && String(n) !== String(item.value)) save(item, n); };
      i.addEventListener('change', commit);
      i.addEventListener('keydown', e => { if (e.key === 'Enter') commit(); });
      return { node: i, id };
    }
    if (item.type === 'list') {
      const wrap = el('div', 'chips'); wrap.id = id;
      const cur = listValue(item.value);
      for (const v of cur) {
        const c = el('span', 'chip-item'); c.append(el('span', 'mono', v));
        const x = el('button', 'chip-x', '×'); x.type = 'button'; x.disabled = dis;
        x.setAttribute('aria-label', `Remove ${v}`);
        x.addEventListener('click', () => save(item, cur.filter(y => y !== v).join(',')));
        c.append(x); wrap.append(c);
      }
      const add = el('input', 'chip-add'); add.type = 'text'; add.placeholder = 'Add…'; add.disabled = dis; add.setAttribute('aria-label', `Add to ${item.key}`);
      const commit = () => { const v = add.value.trim().replace(/,/g, ''); if (v && !cur.includes(v)) save(item, [...cur, v].join(',')); };
      add.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); commit(); } });
      wrap.append(add);
      return { node: wrap, id };
    }
    const t = el('input'); t.type = 'text'; t.id = id; t.disabled = dis; t.value = String(item.value ?? '');
    t.addEventListener('change', () => save(item, t.value));
    return { node: t, id };
  }

  function row(item) {
    const r = el('div', 'srow');
    const { node, id } = control(item);
    const lab = el('label', 'slabel'); lab.htmlFor = id;
    lab.append(el('span', 'skey', item.key));
    if (item.description) lab.append(el('span', 'sdesc muted', item.description));
    if (isReadOnly(item)) lab.append(el('span', 'sdesc muted', 'Read-only here. Change it from Claude Code with /subdeck:settings.'));
    r.append(lab, node);
    if (item.source && item.source !== 'default') r.append(el('span', `tag src-${item.source}`, item.source));
    else r.append(el('span', 'tag', 'default'));
    return r;
  }

  function render() {
    const keepTop = $('settingsView').scrollTop;
    renderInner();
    $('settingsView').scrollTop = keepTop;
  }
  function renderInner() {
    const box = $('settingsBody'); if (!box) return;
    box.replaceChildren();
    // scope switch
    const sc = $('scopeSwitch'); sc.replaceChildren();
    const p = project();
    if (st.scope === 'project' && !p) st.scope = 'user';
    for (const [id, label] of [['user', 'All projects'], ['project', p ? `This project: ${p.name}` : 'This project']]) {
      const b = el('button', 'seg', label); b.type = 'button';
      b.setAttribute('aria-pressed', String(st.scope === id));
      if (id === 'project' && !p) { b.disabled = true; b.title = 'Select a project first'; }
      b.addEventListener('click', () => { if (st.scope !== id) { st.scope = id; load(); } });
      sc.append(b);
    }
    // appearance (local to this browser)
    const ap = el('section', 'sgroup'); ap.append(el('h3', null, 'Desk appearance'));
    const ar = el('div', 'srow');
    const al = el('label', 'slabel'); al.htmlFor = 'set-theme'; al.append(el('span', 'skey', 'theme'), el('span', 'sdesc muted', 'Colour theme of this Desk, remembered in this browser.'));
    const sel = el('select'); sel.id = 'set-theme';
    for (const [id, label] of THEMES) { const o = el('option', null, label); o.value = id; if (id === st.theme) o.selected = true; sel.append(o); }
    sel.addEventListener('change', () => setTheme(sel.value));
    ar.append(al, sel, el('span', 'tag', 'this browser'));
    ap.append(ar); box.append(ap);
    if (st.msg) { const m = el('p', `smsg ${st.msg.bad ? 'bad' : 'ok'}`, st.msg.text); m.setAttribute('role', st.msg.bad ? 'alert' : 'status'); box.append(m); }
    if (st.error) { const m = el('p', 'notice error', st.error); m.setAttribute('role', 'alert'); box.append(m); return; }
    if (!st.data) { const e = el('div', 'empty'); e.append(el('strong', 'empty-title', 'Loading settings…'), el('span', 'empty-hint', 'Reading the configuration can take a few seconds.')); box.append(e); return; }
    for (const g of groupItems(st.data.settings)) {
      const sec = el('section', 'sgroup'); sec.append(el('h3', null, g.title));
      for (const item of g.items) sec.append(row(item));
      box.append(sec);
    }
  }

  function show(on) {
    st.open = on;
    $('settingsView').hidden = !on; $('panesView').hidden = on;
    $('tabSessions').setAttribute('aria-selected', String(!on)); $('tabSettings').setAttribute('aria-selected', String(on));
    if (on) { render(); load(); }
  }
  $('tabSessions').addEventListener('click', () => show(false));
  $('tabSettings').addEventListener('click', () => show(true));
  renderThemeSwitch();
  applyTheme(st.theme);
  setTimeout(loadWindow, 2500);   // after the first paint: settings.sh is slow on some systems
  let lastProject = null;
  /** Called after the selected project changes: keeps the scope label and, in project scope, the data in step. */
  function projectChanged() {
    const p = project(); const id = p ? p.id : null;
    if (id === lastProject) return;
    lastProject = id;
    if (!st.open) return;
    if (st.scope === 'project') load(); else render();
  }
  return { show, projectChanged, state: st };
}
