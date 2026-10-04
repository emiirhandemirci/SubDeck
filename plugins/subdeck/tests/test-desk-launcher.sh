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

# local-directory marketplace: Desk found through the path Claude Code records in known_marketplaces.json
LOCALM="$(mktemp -d)"; cp -r "$DESK" "$LOCALM/desk"
LH="$(mktemp -d)"; mkdir -p "$LH/.claude/plugins"
printf '{\n  "other": {"source": {"source": "github", "repo": "x/y"}, "installLocation": "/nope/other"},\n  "subdeck": {\n    "source": {"source": "directory", "path": "%s"},\n    "installLocation": "%s",\n    "lastUpdated": "2026-01-01T00:00:00Z"\n  }\n}\n' "$LOCALM" "$LOCALM" > "$LH/.claude/plugins/known_marketplaces.json"
OUT="$(HOME="$LH" USERPROFILE="$LH" SUBDECK_DESK_DIR= bash "$CACHE/scripts/desk.sh" start)"
has "$OUT" '^SubDeck Desk: http' "local-directory marketplace: Desk found via known_marketplaces.json"
HOME="$LH" USERPROFILE="$LH" bash "$CACHE/scripts/desk.sh" stop >/dev/null
# only "path" recorded (no installLocation)
printf '{"subdeck":{"source":{"source":"directory","path":"%s"}}}' "$LOCALM" > "$LH/.claude/plugins/known_marketplaces.json"
OUT="$(HOME="$LH" USERPROFILE="$LH" SUBDECK_DESK_DIR= bash "$CACHE/scripts/desk.sh" start)"
has "$OUT" '^SubDeck Desk: http' "minified record with only source.path"
HOME="$LH" USERPROFILE="$LH" bash "$CACHE/scripts/desk.sh" stop >/dev/null
# offline installer target
OH="$(mktemp -d)"; mkdir -p "$OH/.subdeck/offline/SubDeck"; cp -r "$DESK" "$OH/.subdeck/offline/SubDeck/desk"
OUT="$(HOME="$OH" USERPROFILE="$OH" SUBDECK_DESK_DIR= bash "$CACHE/scripts/desk.sh" start)"
has "$OUT" '^SubDeck Desk: http' "offline target ~/.subdeck/offline/SubDeck/desk found"
HOME="$OH" USERPROFILE="$OH" bash "$CACHE/scripts/desk.sh" stop >/dev/null

# Node version gate: fake node reports a version, otherwise delegates to the real node
REALNODE="$(command -v node)"; FN="$(mktemp -d)"
cat > "$FN/node" <<EOF
#!/usr/bin/env bash
case "\$*" in *process.versions.node*) echo "\$FAKE_NODE_V" ;; *) exec "$REALNODE" "\$@" ;; esac
EOF
chmod +x "$FN/node"
OUT="$(PATH="$FN:$PATH" FAKE_NODE_V=18.19.0 bash "$LAUNCH" start)"
has "$OUT" '^Node\.js >= 20 is required' "node < 20 refuses"
OUT="$(PATH="$FN:$PATH" FAKE_NODE_V=20.11.0 bash "$LAUNCH" start)"
has "$OUT" '^Warning: .*Cursor, Codex and OpenCode.*22\.13' "node 20 warns about SQLite adapters"
has "$OUT" '^SubDeck Desk: http' "node 20 still starts"
bash "$LAUNCH" stop >/dev/null
OUT="$(PATH="$FN:$PATH" FAKE_NODE_V=22.12.1 bash "$LAUNCH" start)"
has "$OUT" '^Warning: ' "node 22.12 warns"
bash "$LAUNCH" stop >/dev/null
OUT="$(PATH="$FN:$PATH" FAKE_NODE_V=22.13.0 bash "$LAUNCH" start)"
if printf '%s\n' "$OUT" | grep -q '^Warning'; then bad "node 22.13 no warning"; else ok "node 22.13 no warning"; fi
bash "$LAUNCH" stop >/dev/null

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
