#!/usr/bin/env bash
# SubDeck Desk launcher: bash plugins/subdeck/scripts/desk.sh [start|stop|status]   (always exits 0)
# Desk location: $SUBDECK_DESK_DIR (the desk/ folder of a SubDeck checkout), else <repo>/desk relative to this script.
# Runtime file: ~/.subdeck/desk.json {pid, port, startedAt, version}; log: ~/.subdeck/desk.log

CMD="${1:-start}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RT_DIR="$HOME/.subdeck"
RT="$RT_DIR/desk.json"
LOG="$RT_DIR/desk.log"
TIP='Tip: in VS Code or Cursor run "Simple Browser: Show" and paste the URL to open Desk in an editor tab.'

find_desk() {
  if [ -n "${SUBDECK_DESK_DIR:-}" ] && [ -f "$SUBDECK_DESK_DIR/server.mjs" ]; then printf '%s' "$SUBDECK_DESK_DIR"; return; fi
  if [ -f "$HERE/../../../desk/server.mjs" ]; then (cd "$HERE/../../../desk" && pwd); return; fi
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

if ! command -v node >/dev/null 2>&1; then echo "Node.js >= 22.13 is required: https://nodejs.org"; exit 0; fi

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
    DESK="$(find_desk)"
    if [ -z "$DESK" ]; then echo "SubDeck Desk not found. Set SUBDECK_DESK_DIR to the desk/ folder of a SubDeck checkout."; exit 0; fi
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
