#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-update.sh   (stub claude, no network, no real update)
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
hasnt() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then bad "$3"; else ok "$3"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SUBDECK_STATE_DIR="$T/state" SUBDECK_HOME="$T/home" HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg"
mkdir -p "$T/home" "$T/cfg/plugins" "$T/state"
cat > "$T/inst.json" <<J
{"version":2,"plugins":{"other@x":[{"version":"9.9.9","gitCommitSha":"ffffffffffffffff"}],"subdeck@subdeck":[{"scope":"user","installPath":"/p","version":"0.9.2","lastUpdated":"2026-10-22T10:00:00.000Z","gitCommitSha":"1234567890abcdef"}]}}
J
export SUBDECK_INSTALLED_JSON="$T/inst.json"
U="$HERE/../scripts/update.sh"
B="$T/bin"; mkdir -p "$B"
cat > "$B/claude" <<S
#!/usr/bin/env bash
echo "STUB \$*" >> "$T/calls"
exit 0
S
chmod +x "$B/claude"
export SUBDECK_CLAUDE_BIN="$B/claude"
o="$(bash "$U")"
has "$o" '^before: 0\.9\.2 1234567890abcdef' "before version and commit"
has "$o" '^after: +0\.9\.2' "after version"
has "$o" 'reload-plugins' "reload hint"
c="$(cat "$T/calls")"
[ "$(printf '%s\n' "$c" | wc -l | tr -d ' ')" = 2 ] && ok "exactly two claude calls" || bad "calls: $c"
has "$c" '^STUB plugin marketplace update subdeck$' "marketplace update subdeck only"
has "$c" '^STUB plugin update subdeck@subdeck$' "plugin update subdeck@subdeck only"
# no claude found: prints the commands, runs nothing
rm -f "$T/calls"
o="$(SUBDECK_CLAUDE_BIN="$T/missing" bash "$U")"; rc=$?
[ "$rc" = 0 ] && ok "exit 0 without claude" || bad "exit $rc"
has "$o" 'claude plugin marketplace update subdeck' "prints command 1"
has "$o" 'claude plugin update subdeck@subdeck' "prints command 2"
[ ! -f "$T/calls" ] && ok "nothing executed without claude" || bad "ran something"
# failing claude: still exit 0, note shown
printf '#!/usr/bin/env bash\nexit 3\n' > "$B/claude"
o="$(bash "$U")"; rc=$?
[ "$rc" = 0 ] && ok "exit 0 when claude fails" || bad "exit $rc"
has "$o" 'exited non-zero' "failure noted"
echo; echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
