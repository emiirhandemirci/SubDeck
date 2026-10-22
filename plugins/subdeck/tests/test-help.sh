#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-help.sh
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
H="$HERE/../scripts/help.sh"
o="$(bash "$H")"; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
for c in desk status settings version update doctor help; do has "$o" "/subdeck:$c " "lists /subdeck:$c"; done
for k in mode worker verifier notify guard push; do has "$o" "^  $k +[a-z]" "settings key $k with options"; done
has "$o" 'USER_GUIDE\.md' "User Guide link"
for c in version update doctor help; do
  f="$HERE/../skills/$c/SKILL.md"
  grep -qx "name: $c" "$f" && grep -q "scripts/$c.sh" "$f" && grep -q '^disable-model-invocation: true' "$f" && [ -f "$HERE/../scripts/$c.sh" ] && ok "skill $c: frontmatter and script" || bad "skill $c"
done
echo; echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
