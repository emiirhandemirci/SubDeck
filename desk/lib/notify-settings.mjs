// desk/lib/notify-settings.mjs
// The ONLY setting Desk may write: notify.enabled in ~/.subdeck/config.json. Every other key is preserved
// (parsed and re-serialised; refuses to touch a file that is not a JSON object). Atomic write (tmp + rename).
import fs from 'node:fs';
import path from 'node:path';

export function readNotifyEnabled(file) {
  let txt;
  try { txt = fs.readFileSync(file, 'utf8'); } catch { return { ok: true, enabled: false }; }   // absent = default off
  if (txt.trim() === '') return { ok: true, enabled: false };
  try {
    const o = JSON.parse(txt);
    if (!o || typeof o !== 'object' || Array.isArray(o)) return { ok: false, error: 'config is not a JSON object' };
    return { ok: true, enabled: !!(o.notify && typeof o.notify === 'object' && o.notify.enabled === true) };
  } catch { return { ok: false, error: 'config is not valid JSON' }; }
}

export function writeNotifyEnabled(file, enabled) {
  let obj = {};
  let txt = null;
  try { txt = fs.readFileSync(file, 'utf8'); } catch { /* absent: start empty */ }
  if (txt !== null && txt.trim() !== '') {
    try { obj = JSON.parse(txt); } catch { return { ok: false, error: 'config is not valid JSON; left untouched' }; }
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return { ok: false, error: 'config is not a JSON object; left untouched' };
  }
  const notify = obj.notify && typeof obj.notify === 'object' && !Array.isArray(obj.notify) ? { ...obj.notify } : {};
  delete notify.sound;                        // sound was removed; drop a stale key like notify.sh does
  notify.enabled = !!enabled;
  obj.notify = notify;
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(obj) + '\n');
    fs.renameSync(tmp, file);
  } catch {
    try { fs.unlinkSync(tmp); } catch { /* ignore */ }
    return { ok: false, error: 'could not write config' };
  }
  return { ok: true, enabled: !!enabled };
}
