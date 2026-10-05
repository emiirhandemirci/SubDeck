#!/usr/bin/env bash
# SubDeck Desk launcher: bash plugins/subdeck/scripts/desk.sh [start|stop|status]   (always exits 0)
# Desk location: $SUBDECK_DESK_DIR (the desk/ folder of a SubDeck checkout), else <repo>/desk relative to this script,
# else the marketplace clone <claude config dir>/plugins/marketplaces/subdeck/desk (installed from GitHub),
# else the folder Claude Code records for a local-directory marketplace (known_marketplaces.json),
# else the offline installer target ~/.subdeck/offline/SubDeck/desk.
# Runtime file: ~/.subdeck/desk.json {pid, port, startedAt, version}; log: ~/.subdeck/desk.log

CMD="${1:-start}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RT_DIR="$HOME/.subdeck"
RT="$RT_DIR/desk.json"
LOG="$RT_DIR/desk.log"
TIP='Tip: in VS Code or Cursor run "Simple Browser: Show" and paste the URL to open Desk in an editor tab.'

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MKT_DESK="$CFG/plugins/marketplaces/subdeck/desk"
# mkt_dirs: paths recorded for the "subdeck" marketplace in known_marketplaces.json (installLocation, path);
# for a local-directory marketplace these point at the folder it was added from.
mkt_dirs() {
  local f="$CFG/plugins/known_marketplaces.json" blk k v
  [ -f "$f" ] || return 0
  blk="$(tr '\n\r' '  ' < "$f" | awk '{ i = match($0, /"subdeck"[ \t]*:[ \t]*\{/); if (i) print substr($0, i + RLENGTH) }')"
  for k in installLocation path; do
    v="$(printf '%s' "$blk" | grep -o "\"$k\"[ 	]*:[ 	]*\"[^\"]*\"" | head -1 | sed 's/^[^:]*:[ 	]*"//; s/"$//')"
    [ -n "$v" ] || continue
    v="${v//\\\\/\\}"
    if is_windows; then v="$(cygpath -u "$v" 2>/dev/null || printf '%s' "$v")"; fi
    printf '%s\n' "$v"
  done
}
find_desk() {
  local d
  if [ -n "${SUBDECK_DESK_DIR:-}" ] && [ -f "$SUBDECK_DESK_DIR/server.mjs" ]; then printf '%s' "$SUBDECK_DESK_DIR"; return; fi
  if [ -f "$HERE/../../../desk/server.mjs" ]; then (cd "$HERE/../../../desk" && pwd); return; fi
  if [ -f "$MKT_DESK/server.mjs" ]; then printf '%s' "$MKT_DESK"; return; fi
  while IFS= read -r d; do
    if [ -n "$d" ] && [ -f "$d/desk/server.mjs" ]; then printf '%s' "$d/desk"; return; fi
  done <<EOL
$(mkt_dirs)
EOL
  if [ -f "$HOME/.subdeck/offline/SubDeck/desk/server.mjs" ]; then printf '%s' "$HOME/.subdeck/offline/SubDeck/desk"; return; fi
  printf ''
}
is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
rt_field() { [ -f "$RT" ] && sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p" "$RT" | head -1; }
# alive = the recorded port answers GET /api/sources with 200 within 2 s
alive() {
  local port; port="$(rt_field port)"
  [ -n "$port" ] || return 1
  node -e "fetch('http://127.0.0.1:$port/api/sources',{signal:AbortSignal.timeout(2000)}).then(r=>process.exit(r.status===200?0:1),()=>process.exit(1))" 2>/dev/null
}
url() { printf 'http://127.0.0.1:%s/' "$(rt_field port)"; }

if ! command -v node >/dev/null 2>&1; then echo "Node.js >= 20 is required: https://nodejs.org"; exit 0; fi
NODE_V="$(node -p 'process.versions.node' 2>/dev/null | tr -d '\r')"
NODE_MAJOR="${NODE_V%%.*}"; NODE_REST="${NODE_V#*.}"; NODE_MINOR="${NODE_REST%%.*}"
case "$NODE_MAJOR$NODE_MINOR" in ''|*[!0-9]*) NODE_MAJOR=0; NODE_MINOR=0 ;; esac
if [ "$NODE_MAJOR" -lt 20 ]; then echo "Node.js >= 20 is required (found ${NODE_V:-unknown}): https://nodejs.org"; exit 0; fi
NODE_WARN=""
if [ "$NODE_MAJOR" -lt 22 ] || { [ "$NODE_MAJOR" -eq 22 ] && [ "$NODE_MINOR" -lt 13 ]; }; then
  NODE_WARN="Warning: Node.js $NODE_V found; Cursor, Codex and OpenCode sessions need Node.js >= 22.13 (other sources work)."
fi

case "$CMD" in
  status)
    if alive; then echo "SubDeck Desk: $(url)"; echo "$TIP"; else echo "SubDeck Desk is not running"; fi ;;
  stop)
    if ! alive; then rm -f "$RT"; echo "SubDeck Desk is not running"; exit 0; fi
    PID="$(rt_field pid)"
    if is_windows; then taskkill //PID "$PID" //T //F >/dev/null 2>&1; else kill "$PID" 2>/dev/null; fi
    i=0; while alive && [ $i -lt 10 ]; do sleep 0.5; i=$((i+1)); done
    rm -f "$RT"
    echo "SubDeck Desk stopped" ;;
  start|*)
    if alive; then echo "SubDeck Desk: $(url)"; echo "$TIP"; exit 0; fi
    [ -n "$NODE_WARN" ] && echo "$NODE_WARN"
    DESK="$(find_desk)"
    if [ -z "$DESK" ]; then
      echo "SubDeck Desk is not part of the plugin folder; it ships in the SubDeck repository."
      echo "To get it, run: claude plugin marketplace add emiirhandemirci/SubDeck (this clones the repo; /subdeck:desk then finds it automatically)."
      echo "Or clone the repo yourself and set SUBDECK_DESK_DIR to its desk/ folder."
      echo "Tried: \$SUBDECK_DESK_DIR (${SUBDECK_DESK_DIR:-unset}), $HERE/../../../desk, $MKT_DESK"
      exit 0
    fi
    mkdir -p "$RT_DIR"
    rm -f "$RT"
    if is_windows; then
      cmd //c start "SubDeck Desk" //min node "$(cygpath -w "$DESK/server.mjs" 2>/dev/null || printf '%s' "$DESK/server.mjs")" >/dev/null 2>&1
    else
      nohup node "$DESK/server.mjs" >"$LOG" 2>&1 &
      disown 2>/dev/null
    fi
    i=0; while ! alive && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
    if alive; then echo "SubDeck Desk: $(url)"; echo "$TIP"; else echo "SubDeck Desk did not start within 10 s; see ~/.subdeck/desk.log"; fi ;;
esac
exit 0
