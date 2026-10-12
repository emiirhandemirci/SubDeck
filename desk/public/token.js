// Per-start write token. Desk issues a new token on every start, so a tab left open across a restart holds a dead one.
// writeJSON re-reads the token from the page once on a token rejection and retries, so old tabs recover by themselves.
export function currentToken() {
  const meta = document.querySelector('meta[name="subdeck-token"]');
  return meta ? meta.content : '';
}

export async function refreshToken() {
  try {
    const r = await fetch('/', { cache: 'no-store' });
    if (!r.ok) return false;
    const m = /<meta name="subdeck-token" content="([0-9a-f]+)"/.exec(await r.text());
    const meta = document.querySelector('meta[name="subdeck-token"]');
    if (!m || !meta) return false;
    const changed = meta.content !== m[1];
    meta.content = m[1];
    return changed;
  } catch { return false; }
}

/** POST a JSON body with the write token. Returns { ok, status, body, error }; never throws (error = a readable reason). */
export async function writeJSON(url, payload) {
  const send = () => fetch(url, { method: 'POST', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'X-SubDeck-Token': currentToken() }, body: JSON.stringify(payload) });
  try {
    let r = await send();
    let body = await r.json().catch(() => ({}));
    if (r.status === 403 && /token/i.test(String(body.error || '')) && await refreshToken()) {
      r = await send(); body = await r.json().catch(() => ({}));
    }
    return { ok: r.ok, status: r.status, body, error: r.ok ? null : (body.error || `Save failed (${r.status})`) };
  } catch { return { ok: false, status: 0, body: {}, error: 'Save failed: Desk is unreachable' }; }
}
