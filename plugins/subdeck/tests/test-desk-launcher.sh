#!/usr/bin/env bash
# plugins/subdeck/tests/test-desk-launcher.sh — run: bash plugins/subdeck/tests/test-desk-launcher.sh
# Uses a temp HOME; starts and stops a real Desk server from this checkout.
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCH="$HERE/../scripts/desk.sh"
DESK="$(cd "$HERE/../../../desk" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }

export HOME="$(mktemp -d)"; export USERPROFILE="$HOME"
export SUBDECK_CLAUDE_PROJECTS_DIR="$HOME/none" SUBDECK_DISABLE=cursor
export SUBDECK_DESK_DIR="$DESK"

OUT="$(bash "$LAUNCH" status)"; RC=$?
has "$OUT" '^SubDeck Desk is not running$' "status when not running"
[ $RC -eq 0 ] && ok "status exit 0" || bad "status exit 0"

OUT="$(bash "$LAUNCH")"; RC=$?
has "$OUT" '^SubDeck Desk: http://127\.0\.0\.1:[0-9]+/$' "start prints URL"
has "$OUT" 'Simple Browser: Show' "start prints Simple Browser tip"
[ $RC -eq 0 ] && ok "start exit 0" || bad "start exit 0"
[ -f "$HOME/.subdeck/desk.json" ] && ok "desk.json written" || bad "desk.json written"
URL1="$(printf '%s\n' "$OUT" | grep -Eo 'http://127\.0\.0\.1:[0-9]+/' | head -1)"
PID1="$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$HOME/.subdeck/desk.json")"

OUT="$(bash "$LAUNCH" start)"
URL2="$(printf '%s\n' "$OUT" | grep -Eo 'http://127\.0\.0\.1:[0-9]+/' | head -1)"
PID2="$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$HOME/.subdeck/desk.json")"
[ -n "$URL1" ] && [ "$URL1" = "$URL2" ] && [ "$PID1" = "$PID2" ] && ok "second start reuses the running instance" || bad "second start reuses ($URL1 $URL2 $PID1 $PID2)"

OUT="$(bash "$LAUNCH" status)"
has "$OUT" "^SubDeck Desk: $URL1\$" "status prints URL when running"

OUT="$(bash "$LAUNCH" stop)"; RC=$?
has "$OUT" '^SubDeck Desk stopped$' "stop"
[ $RC -eq 0 ] && ok "stop exit 0" || bad "stop exit 0"
[ ! -f "$HOME/.subdeck/desk.json" ] && ok "desk.json removed" || bad "desk.json removed"
OUT="$(bash "$LAUNCH" status)"
has "$OUT" '^SubDeck Desk is not running$' "status after stop"
OUT="$(bash "$LAUNCH" stop)"
has "$OUT" '^SubDeck Desk is not running$' "stop when not running"

OUT="$(SUBDECK_DESK_DIR="$HOME/nowhere" bash "$LAUNCH" start)"; RC=$?
if [ -f "$HERE/../../../desk/server.mjs" ]; then
  has "$OUT" '^SubDeck Desk' "bad SUBDECK_DESK_DIR falls back to the repo-relative desk/"
  bash "$LAUNCH" stop >/dev/null
else
  has "$OUT" 'Set SUBDECK_DESK_DIR' "bad SUBDECK_DESK_DIR message"
fi
[ $RC -eq 0 ] && ok "bad dir exit 0" || bad "bad dir exit 0"

# installed layout: script copied without a sibling desk/, Desk only in the marketplace clone
CACHE="$HOME/cache/subdeck/subdeck/current"; mkdir -p "$CACHE/scripts"; cp "$LAUNCH" "$CACHE/scripts/desk.sh"
FAKEH="$(mktemp -d)"; mkdir -p "$FAKEH/.claude/plugins/marketplaces/subdeck"; cp -r "$DESK" "$FAKEH/.claude/plugins/marketplaces/subdeck/desk"
OUT="$(HOME="$FAKEH" USERPROFILE="$FAKEH" SUBDECK_DESK_DIR= bash "$CACHE/scripts/desk.sh" start)"
has "$OUT" '^SubDeck Desk: http' "installed layout finds Desk in the marketplace clone"
HOME="$FAKEH" USERPROFILE="$FAKEH" bash "$CACHE/scripts/desk.sh" stop >/dev/null
OUT="$(HOME="$HOME/empty" USERPROFILE="$HOME/empty" SUBDECK_DESK_DIR= bash "$CACHE/scripts/desk.sh" start)"
has "$OUT" 'not found.*marketplaces/subdeck/desk' "not-found message lists tried locations"

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
