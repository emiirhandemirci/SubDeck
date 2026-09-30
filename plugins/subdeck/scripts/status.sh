#!/usr/bin/env bash
# SubDeck status: terminal table of subagents recorded by the event logger.
#
# Run from any terminal (Git Bash, macOS, Linux); no model call, no jq/node:
#   bash <plugin>/scripts/status.sh [--all] [project_dir]
# project_dir defaults to $CLAUDE_PROJECT_DIR, else the current directory.
# STATE shows `waiting` when the agent is blocked on you: a Notification hook event (permission prompt,
# question dialog) newer than its transcript's last write, or a trailing AskUserQuestion/ExitPlanMode call.
# MODEL is the real model id from the agent's last assistant record (else the meta alias); narrow terminals
# (COLUMNS) drop ACTIVITY first, then MODEL.
# Default view: running agents + the last 10 finished; --all shows every agent.
# Reads <project>/.subdeck/events.jsonl and <project>/.subdeck/events.d/*.json.

ALL=0
PROJECT=""
for a in "$@"; do
  case "$a" in
    --all) ALL=1 ;;
    "") ;;
    -*) ;;   # unknown flags are ignored (always exit 0)
    *) PROJECT="$a" ;;
  esac
done
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
DIR="$PROJECT/.subdeck"

NOW="$(date +%s)"
ZONE="$(date +%z)"   # e.g. +0300
SIGN=1; [ "${ZONE#-}" != "$ZONE" ] && SIGN=-1
ZH="${ZONE:1:2}"; ZM="${ZONE:3:2}"
OFF=$(( SIGN * (10#$ZH * 3600 + 10#$ZM * 60) ))

# Collect all event lines (CRLF-safe); missing files are fine.
collect() {
  [ -f "$DIR/events.jsonl" ] && cat "$DIR/events.jsonl"
  for f in "$DIR"/events.d/*.json; do [ -f "$f" ] && { cat "$f"; echo; }; done
}

# Fold: sort by ts (stable), then one record per agent, fields separated by \001.
fold() {
  collect | tr -d '\r' | awk '
    /^\{/ { if (match($0, /"ts":"[^"]*"/)) print substr($0, RSTART + 6, RLENGTH - 7) "\001" $0 }' |
  LC_ALL=C sort -s -t $'\001' -k1,1 |
  awk -F $'\001' -v now="$NOW" -v off="$OFF" -v all="$ALL" '
  function field(s, name,   r) {
    if (match(s, "\"" name "\":\"([^\"\\\\]|\\\\.)*\"")) {
      r = substr(s, RSTART, RLENGTH); sub("^\"" name "\":\"", "", r); sub(/"$/, "", r); return r
    }
    return ""
  }
  function epoch(t,   y, m, d, H, M, S, mm, yy, doy, days, era, yoe, doe) {
    if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return 0
    y = substr(t,1,4)+0; m = substr(t,6,2)+0; d = substr(t,9,2)+0
    H = substr(t,12,2)+0; M = substr(t,15,2)+0; S = substr(t,18,2)+0
    yy = (m <= 2) ? y - 1 : y
    mm = (m <= 2) ? m + 9 : m - 3
    era = int(yy/400); yoe = yy - era*400
    doy = int((153*mm + 2)/5) + d - 1
    doe = yoe*365 + int(yoe/4) - int(yoe/100) + doy
    days = era*146097 + doe - 719468
    return days*86400 + H*3600 + M*60 + S
  }
  function hms(e,   s) { e = e + off; s = e % 86400; if (s < 0) s += 86400
    return sprintf("%02d:%02d:%02d", int(s/3600), int((s%3600)/60), s%60) }
  function dur(sec,   h, m, s) { if (sec < 0) sec = 0
    h = int(sec/3600); m = int((sec%3600)/60); s = sec%60
    return h > 0 ? sprintf("%dh%02dm%02ds", h, m, s) : (m > 0 ? sprintf("%dm%02ds", m, s) : sprintf("%ds", s)) }
  {
    line = $2
    ev = field(line, "event")
    if (ev == "Notification") {
      # only waiting-type notifications (idle_prompt etc. are ignored); keyed by agent id, else session id
      if (line !~ /"notification_type":"(permission_prompt|elicitation_dialog|agent_needs_input)"/) next
      e = epoch(field(line, "ts")); k = field(line, "agent_id"); k = (k != "") ? "a:" k : "s:" field(line, "session_id")
      if (e > ntf[k]) ntf[k] = e
      next
    }
    if (ev != "SubagentStart" && ev != "SubagentStop") next
    id = field(line, "agent_id"); if (id == "") id = "unknown"
    e = epoch(field(line, "ts"))
    if (!(id in seen)) { seen[id] = 1; order[++n] = id }
    t = field(line, "agent_type"); if (t != "" ) type[id] = t
    p = field(line, "transcript_path"); if (p != "") path[id] = norm(p)
    p = field(line, "agent_transcript_path"); if (p != "") apath[id] = norm(p)
    p = field(line, "session_id"); if (p != "") ses[id] = p
    if (ev == "SubagentStart") { if (!(id in st) || e < st[id]) st[id] = e }
    else {
      stop[id] = e
      # last_assistant_message lives inside the payload
      if (match(line, /"last_assistant_message":"([^"\\]|\\.)*"/)) {
        m = substr(line, RSTART, RLENGTH); sub(/^"last_assistant_message":"/, "", m); sub(/"$/, "", m)
        msg[id] = m
      }
    }
  }
  END {
    if (n == 0) exit
    for (i = 1; i <= n; i++) { id = order[i]; if (!(id in st)) st[id] = (id in stop) ? stop[id] : 0 }
    nd = 0
    for (i = 1; i <= n; i++) { id = order[i]; if (id in stop) done[++nd] = id }
    from = (all == 1 || nd <= 10) ? 1 : nd - 9
    # selected rows, then grouped by session (first-seen order), running first in each group
    for (i = 1; i <= n; i++) { id = order[i]; if (!(id in stop)) sel[++ns] = id }
    for (j = from; j <= nd; j++) sel[++ns] = done[j]
    for (i = 1; i <= ns; i++) { id = sel[i]; k = sess(id); if (!(k in gseen)) { gseen[k] = 1; gorder[++ng] = k } }
    for (g = 1; g <= ng; g++)
      for (i = 1; i <= ns; i++) { id = sel[i]; if (sess(id) == gorder[g]) row(id, (id in stop) ? "done" : "running", gorder[g]) }
  }
  function norm(p) { gsub(/\\\\/, "/", p); gsub(/\\/, "/", p); return p }
  # Hook transcript_path is the MANAGER transcript <dir>/<session>.jsonl; the subagent
  # transcript is <dir>/<session>/subagents/agent-<id>.jsonl (agent_transcript_path wins).
  # A path already inside /subagents/ is taken as the subagent transcript.
  function parentof(id,   p) {
    if (!(id in path)) return ""
    p = path[id]
    if (match(p, "/subagents/")) return substr(p, 1, RSTART - 1) ".jsonl"
    return p
  }
  # session of an agent: envelope session_id, else the parent transcript basename
  function sess(id,   p, a, c) {
    if (id in ses) return ses[id]
    p = parentof(id); sub(/\.jsonl$/, "", p)
    if (p != "") { c = split(p, a, "/"); if (a[c] != "") return a[c] }
    return "-"
  }
  function agentpath(id,   p, k) {
    if (id in apath) return apath[id]
    if (!(id in path)) return ""
    p = path[id]
    if (match(p, "/subagents/")) return p
    k = sess(id); if (k == "-") return ""
    sub(/\/[^\/]*$/, "", p)
    return p "/" k "/subagents/agent-" id ".jsonl"
  }
  function row(id, state, g,   d, sp) {
    d = (state == "running") ? now - st[id] : stop[id] - st[id]
    if (!(g in gpath)) { gpath[g] = ""; for (sp in path) if (sess(sp) == g) { gpath[g] = parentof(sp); break } }
    w = ""
    if (state == "running") { w = ntf["a:" id] + 0; if (ntf["s:" sess(id)] + 0 > w) w = ntf["s:" sess(id)] + 0; if (w <= st[id]) w = "" }
    printf "%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\001%s\n", id, (id in type ? type[id] : "-"), (st[id] ? hms(st[id]) : "-"), dur(d), state, agentpath(id), g, gpath[g], (d < 0 ? 0 : d), w, (id in msg ? msg[id] : "")
  }'
}

# Shared awk helpers (run under LC_ALL=C): one-pass JSON unescape (incl. \uXXXX and
# surrogate pairs), UTF-8-safe truncation and padding. Continuation bytes 0x80-0xBF are
# not counted, so cuts never split a character in byte awks; in char-aware awks the
# lookup never matches and the count is already in characters.
UTF8_AWK_FUNCS='
function init(  i) { BS = sprintf("%c", 92); for (i = 128; i < 192; i++) cont[sprintf("%c", i)] = 1 }
function clen(s,   n, i, cnt) {
  n = length(s); cnt = 0
  for (i = 1; i <= n; i++) if (!(substr(s, i, 1) in cont)) cnt++
  return cnt
}
# keep the first `keep` characters (never splits a UTF-8 sequence)
function trunc(s, keep,   n, i, cnt) {
  n = length(s); cnt = 0
  for (i = 1; i <= n; i++) if (!(substr(s, i, 1) in cont)) { cnt++; if (cnt == keep + 1) return substr(s, 1, i - 1) }
  return s
}
function clip(s, limit, keep) { return clen(s) > limit ? trunc(s, keep) "..." : s }
function padc(s, w,   n) { n = w - clen(s); while (n-- > 0) s = s " "; return s }
function hexv(h,   i, v) { v = 0; h = tolower(h)
  for (i = 1; i <= length(h); i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
  return v }
function utf8(cp) {
  if (cp < 32) return " "
  if (cp < 128)   return sprintf("%c", cp)
  if (cp < 2048)  return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  if (cp >= 55296 && cp < 57344) cp = 65533
  if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
  return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64) }
# firstonly=1 stops at the first \n (first line of a message)
function unesc(s, firstonly,   out, i, d, cp, lo) {
  out = ""
  while ((i = index(s, "\\")) > 0) {
    out = out substr(s, 1, i - 1); d = substr(s, i + 1, 1); s = substr(s, i + 2)
    if (d == "n") { if (firstonly) return out; out = out " " }
    else if (d == "t" || d == "r") out = out " "
    else if (d == "u" && match(s, /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
      cp = hexv(substr(s, 1, 4)); s = substr(s, 5)
      if (cp >= 55296 && cp < 56320 && substr(s, 1, 2) == (BS "u") && substr(s, 3, 4) ~ /^[dD][c-fC-F][0-9A-Fa-f][0-9A-Fa-f]$/) {
        lo = hexv(substr(s, 3, 4)); cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); s = substr(s, 7) }
      out = out utf8(cp) }
    else out = out d
  }
  return out s
}
BEGIN { init() }'

# Cheap "what is it doing" from the last ~64 KB of a transcript.
tail_activity() {
  local p="$1" size
  [ -n "$p" ] && [ -f "$p" ] || { echo "-"; return; }
  size="$(wc -c < "$p" 2>/dev/null | tr -d ' ')"
  tail -c 65536 "$p" 2>/dev/null | tr -d '\r' | awk -v drop="$([ "${size:-0}" -gt 65536 ] && echo 1 || echo 0)" '
    NR == 1 && drop == 1 { next }
    /"role":"assistant"/ {
      best = ""; bestpos = 0
      s = $0; base = 0
      # last tool_use in this line
      s2 = $0; off2 = 0; tpos = 0
      while ((i = index(s2, "\"type\":\"tool_use\"")) > 0) { tpos = off2 + i; off2 += i + 16; s2 = substr(s2, i + 17) }
      # last text block in this line
      s3 = $0; off3 = 0; xpos = 0
      while ((i = index(s3, "\"type\":\"text\",\"text\":\"")) > 0) { xpos = off3 + i; off3 += i + 21; s3 = substr(s3, i + 22) }
      if (tpos > xpos) {
        r = substr($0, tpos)
        nm = ""; if (match(r, /"name":"[^"]*"/)) nm = substr(r, RSTART + 8, RLENGTH - 9)
        arg = ""
        if (match(r, /"input":\{"[^"]*":"([^"\\]|\\.)*"/)) {
          a = substr(r, RSTART, RLENGTH); sub(/^"input":\{"[^"]*":"/, "", a); sub(/"$/, "", a); arg = a
        }
        best = nm (arg != "" ? " " arg : "")
      } else if (xpos > 0) {
        r = substr($0, xpos + 22)
        if (match(r, /^([^"\\]|\\.)*/)) best = substr(r, 1, RLENGTH)
      }
      if (best != "") last = best
    }
    END { print last }' | LC_ALL=C awk -v FIRST=0 "$UTF8_AWK_FUNCS"'
    { s = unesc($0, FIRST); if (s == "") s = "-"; print clip(s, 60, 57) }'
}

first_line() { # unescape + first line + truncate
  printf '%s' "$1" | LC_ALL=C awk -v FIRST=1 "$UTF8_AWK_FUNCS"'
    { s = unesc($0, FIRST); if (s == "") s = "-"; print clip(s, 60, 57) }'
}

# padded, clipped cell: unescape, cut to W characters (keep W-3 + "..."), pad to W (sentinel keeps trailing blanks)
cell() { # text width
  printf '%s' "$1" | LC_ALL=C awk -v W="$2" "$UTF8_AWK_FUNCS"'
    { s = unesc($0, 0); if (s == "") s = "-"; print padc(clip(s, W, W - 3), W) "|" }'
}

norm_path() { printf '%s' "$1" | sed 's/\\\\/\//g; s/\\/\//g'; }

# Title from <transcript>.meta.json ".description"; "-" when unavailable.
title_of() {
  local p="$1" m
  [ -n "$p" ] || { echo "-"; return; }
  m="${p%.jsonl}.meta.json"
  [ -f "$m" ] || { echo "-"; return; }
  tr -d '\r' < "$m" 2>/dev/null | awk '
    match($0, /"description":"([^"\\]|\\.)*"/) { r = substr($0, RSTART, RLENGTH); sub(/^"description":"/, "", r); sub(/"$/, "", r); print r; found = 1; exit }
    END { if (!found) print "-" }'
}

# Tokens = input + cache_read + cache_creation + output of the LAST assistant usage line
# in the last 64 KB (streaming lines repeat per request; summing would over-count).
tokens_of() {
  local p="$1" size
  [ -n "$p" ] && [ -f "$p" ] || { echo "-"; return; }
  size="$(wc -c < "$p" 2>/dev/null | tr -d ' ')"
  tail -c 65536 "$p" 2>/dev/null | tr -d '\r' | awk -v drop="$([ "${size:-0}" -gt 65536 ] && echo 1 || echo 0)" '
    function num(s, key,   r) {
      if (match(s, "\"" key "\":[0-9]+")) { r = substr(s, RSTART, RLENGTH); sub(/^.*:/, "", r); return r + 0 }
      return 0
    }
    NR == 1 && drop == 1 { next }
    /"role":"assistant"/ && /"usage":\{/ {
      s = $0; last = 0
      while ((i = index(s, "\"usage\":{")) > 0) { last = i; s = substr(s, i + 9) }
      u = substr(s, 1, 600)
      t = num(u, "input_tokens") + num(u, "cache_read_input_tokens") + num(u, "cache_creation_input_tokens") + num(u, "output_tokens")
      if (t > 0) best = t
    }
    END {
      if (best == "") { print "-"; exit }
      if (best >= 1000000) printf "%.1fM\n", best / 1000000
      else if (best >= 1000) printf "%.1fk\n", best / 1000
      else printf "%d\n", best
    }'
}

# Model id: the real id from the last assistant record (last 64 KB of the agent transcript),
# else the alias in <transcript>.meta.json; "-" when neither exists.
model_of() {
  local p="$1" size m out=""
  if [ -n "$p" ] && [ -f "$p" ]; then
    size="$(wc -c < "$p" 2>/dev/null | tr -d ' ')"
    out="$(tail -c 65536 "$p" 2>/dev/null | tr -d '\r' | awk -v drop="$([ "${size:-0}" -gt 65536 ] && echo 1 || echo 0)" '
      NR == 1 && drop == 1 { next }
      /"role":"assistant"/ && match($0, /"model":"[^"]+"/) { best = substr($0, RSTART + 9, RLENGTH - 10) }
      END { print best }')"
    if [ -z "$out" ]; then
      m="${p%.jsonl}.meta.json"
      [ -f "$m" ] && out="$(tr -d '\r' < "$m" 2>/dev/null | awk 'match($0, /"model":"[^"]+"/) { print substr($0, RSTART + 9, RLENGTH - 10); exit }')"
    fi
  fi
  [ -n "$out" ] || out="-"
  echo "$out"
}

# Manager session name: last aiTitle in the parent transcript (tail 256 KB); else short id.
session_title() {
  local sid="$1" tp="$2" parent
  case "$tp" in
    */subagents/*) parent="${tp%/subagents/*}.jsonl" ;;
    *.jsonl) parent="$tp" ;;
    *) parent="" ;;
  esac
  if [ -n "$parent" ] && [ -f "$parent" ]; then
    tail -c 262144 "$parent" 2>/dev/null | tr -d '\r' | awk '
      { s = $0; while (match(s, /"aiTitle":"([^"\\]|\\.)*"/)) {
          r = substr(s, RSTART, RLENGTH); sub(/^"aiTitle":"/, "", r); sub(/"$/, "", r); best = r; s = substr(s, RSTART + RLENGTH) } }
      END { print best }' | LC_ALL=C awk -v FIRST=0 "$UTF8_AWK_FUNCS"'
      { s = unesc($0, FIRST); if (s != "") { print clip(s, 80, 77); found = 1 } }
      END { if (!found) print "" }' | { read -r t; printf '%s' "$t"; }
  fi
}

ROWS="$(fold)"
if [ -z "$ROWS" ]; then
  echo "no agents recorded yet"
  exit 0
fi

# Column budget. MODEL is 25 wide. Fixed columns without MODEL are 98 wide. With COLUMNS set, ACTIVITY shrinks
# first (min 15); when it cannot fit it is dropped, then MODEL is dropped as well.
FIXED=98
MODW=25
ACTW=60
SHOW_MODEL=1
SHOW_ACT=1
case "${COLUMNS:-}" in
  ''|*[!0-9]*) ;;
  *)
    ACTW=$(( COLUMNS - FIXED - MODW - 2 ))
    if [ "$ACTW" -lt 15 ]; then
      SHOW_ACT=0
      if [ "$COLUMNS" -lt $(( FIXED + MODW )) ]; then
        SHOW_MODEL=0; SHOW_ACT=1
        ACTW=$(( COLUMNS - FIXED )); [ "$ACTW" -lt 15 ] && ACTW=15
      fi
    fi
    [ "$ACTW" -gt 60 ] && ACTW=60
    ;;
esac

STALE_MIN="${SUBDECK_STALE_MIN:-5}"
case "$STALE_MIN" in ""|*[!0-9]*) STALE_MIN=5 ;; esac
prev="<none>"
while IFS=$'\001' read -r id type start dur state path sid spath secs wts msg; do
  if [ "$sid" != "$prev" ]; then
    [ "$prev" != "<none>" ] && echo
    st="$(session_title "$sid" "$(norm_path "$spath")")"
    [ -n "$st" ] || { st="${sid:0:8}"; [ "$sid" = "-" ] && st="unknown"; }
    echo "Session: $st"
    hdr="$(printf '%-8s  %-30s  %-16s  %-8s  %-9s  %-6s  %-7s' AGENT TITLE TYPE STARTED DURATION TOKENS STATE)"
    if [ "$SHOW_MODEL" = 1 ]; then hdr="$hdr  $(printf '%-*s' "$MODW" MODEL)"; fi
    if [ "$SHOW_ACT" = 1 ]; then hdr="$hdr  ACTIVITY"; fi
    printf '%s\n' "${hdr%"${hdr##*[![:space:]]}"}"
    prev="$sid"
  fi
  short="${id:0:8}"
  np="$(norm_path "$path")"
  if [ "$state" = running ]; then
    # waiting: Notification newer than the transcript's last write, or a trailing blocking tool call
    if [ -n "$wts" ]; then
      if [ -f "$np" ]; then
        mt="$(stat -c %Y "$np" 2>/dev/null || stat -f %m "$np" 2>/dev/null)"
        [ -n "$mt" ] && [ "$mt" -lt $(( wts + 2 )) ] && state=waiting
      else
        state=waiting
      fi
    fi
    if [ "$state" = running ] && [ -f "$np" ] && tail -n 1 "$np" 2>/dev/null | grep -Eq '"type":"tool_use","id":"[^"]*","name":"(AskUserQuestion|ExitPlanMode)"'; then state=waiting; fi
  fi
  if [ "$state" = waiting ]; then
    act="$(tail_activity "$np")"
  elif [ "$state" = running ]; then
    # stale?: no Stop and the transcript untouched for STALE_MIN minutes (missing file: Start age)
    if [ -f "$np" ]; then
      [ -n "$(find "$np" -maxdepth 0 -mmin +"$STALE_MIN" 2>/dev/null)" ] && state="stale?"
    elif [ "${secs:-0}" -gt $(( STALE_MIN * 60 )) ] 2>/dev/null; then
      state="stale?"
    fi
    act="$(tail_activity "$np")"
  else
    act="$(first_line "$msg")"
  fi
  # clip activity to the available width
  act="$(printf '%s' "$act" | LC_ALL=C awk -v W="$ACTW" "$UTF8_AWK_FUNCS"'{ print (clen($0) > W) ? trunc($0, W - 3) "..." : $0 }')"
  tc="$(cell "${type#*:}" 16)"; tc="${tc%|}"
  ti="$(cell "$(title_of "$np")" 30)"; ti="${ti%|}"
  tk="$(tokens_of "$np")"
  line="$(printf '%-8s  %s  %s  %-8s  %-9s  %-6s  %-7s' "$short" "$ti" "$tc" "$start" "$dur" "$tk" "$state")"
  if [ "$SHOW_MODEL" = 1 ]; then
    mo="$(cell "$(model_of "$np")" "$MODW")"; line="$line  ${mo%|}"
  fi
  if [ "$SHOW_ACT" = 1 ]; then line="$line  $act"; fi
  printf '%s\n' "${line%"${line##*[![:space:]]}"}"
done <<< "$ROWS"
exit 0
