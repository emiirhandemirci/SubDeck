#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-settings.sh   (temp HOME and project only)
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../scripts/settings.sh"
SK="$HERE/../skills/settings/SKILL.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
hasnt() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then bad "$3 (found: $2)"; else ok "$3"; fi; }
H="$(mktemp -d)"; P="$(mktemp -d)"
unset SUBDECK_NOTIFY SUBDECK_GUARD CLAUDE_CODE_SUBAGENT_MODEL_FORCE SUBDECK_STATE_DIR SUBDECK_HOME
# project config lives in the state dir outside the project (lib-paths.sh), under the temp HOME
PS="$(HOME="$H"; . "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$P"; printf '%s' "$SD_STATE")"
run() { HOME="$H" bash "$S" "$@" "$P"; }

out="$(run)"; rc=$?
[ $rc -eq 0 ] && ok "show exits 0" || bad "show exit $rc"
has "$out" '^worker +sonnet +default' "table: worker default"
has "$out" '^escalation +opus +default' "table: escalation default"
has "$out" '^mode +auto +default' "table: mode"
has "$out" '^notify +off +default' "table: notify off by default"
has "$out" '^notify.events +waiting,done,agent +default' "table: notify events"
has "$out" '^guard +on ' "table: guard on"
has "$out" '^push +ask +default' "table: guard rule"
has "$out" '^statusline +not installed' "table: statusline not installed"
hasnt "$out" '->' "table: no resolved-model rows"

out="$(run set worker=opus notify=on notify.events=done,agent push=off attribution=deny)"
has "$out" '^worker +opus +user' "set: model routed"
has "$out" '^notify +on +user' "set: notify on"
has "$out" '^notify.events +done,agent +user' "set: notify events"
has "$out" '^push +off +user' "set: guard rule"
has "$out" '^attribution +deny +user' "set: guard rule 2"
CFG="$H/.subdeck/config.json"
grep -q '"modelPolicy"' "$CFG" && grep -q '"notify"' "$CFG" && grep -q '"guard"' "$CFG" && ok "config holds all three members" || bad "config members"

out="$(run set guard=off)"
has "$out" '^guard +off ' "set: guard off"
out="$(run set bogus=1 worker=haiku)"
has "$out" "unknown key 'bogus'" "unknown key rejected"
has "$out" 'nothing written' "unknown key writes nothing"
has "$(run)" '^worker +opus +user' "worker unchanged after rejected set"
out="$(run set notify=maybe)"
has "$out" 'notify must be on or off' "invalid notify value"
out="$(run set statusline=on)"
has "$out" 'needs your confirmation' "statusline not written by script"
[ ! -e "$H/.claude/settings.json" ] && ok "settings.json untouched" || bad "settings.json created"

out="$(run set worker=sonnet --project)"
has "$out" '^worker +sonnet +project' "project scope"
[ -f "$PS/config.json" ] && [ ! -e "$P/.subdeck" ] && ok "project file written" || bad "project file missing"

mkdir -p "$H/.claude"; echo '{"statusLine":{"type":"command","command":"bash x/scripts/statusline.sh"}}' > "$H/.claude/settings.json"
has "$(run)" '^statusline +installed' "table: statusline installed"

out="$(run reset)"
has "$out" '^worker +sonnet +(default|project)' "reset: user model policy gone"
has "$out" '^notify +off' "reset: notify off"
has "$out" '^push +ask' "reset: guard rule default"
rm -rf "$P/.subdeck" "$PS"; run reset --project >/dev/null
has "$(run)" '^worker +sonnet +default' "reset --project exits cleanly"


out="$(run set protect=CLAUDE.md,migrations/**)"
has "$out" '^protect +CLAUDE.md,migrations/\*\* +user' "set protect: table row"
grep -q '"protectedPaths":\["CLAUDE.md","migrations/\*\*"\]' "$CFG" && ok "set protect: array written to config" || bad "protect config: $(cat "$CFG")"
out="$(run set protect=*.lock unprotect=CLAUDE.md --project)"
has "$out" '^protect +\*.lock +project' "set protect --project: project row wins"
run reset --project >/dev/null; rm -rf "$P/.subdeck" "$PS"
out="$(run set unprotect=CLAUDE.md,migrations/**)"
has "$out" '^protect +\(none\) +default' "set unprotect: list empty again"
out="$(run set protect=)"; has "$out" 'protect needs a glob' "empty protect rejected"
has "$out" 'nothing written' "empty protect writes nothing"
out="$(run set protect=a.txt push=off)"
has "$out" '^push +off +user' "protect and a rule in one call"
has "$out" '^protect +a.txt +user' "protect and a rule in one call: list"
out="$(run reset)"; has "$out" '^protect +\(none\)' "reset clears the protected list"
rm -rf "$P/.subdeck" "$PS"

[ -f "$SK" ] && grep -q '^disable-model-invocation: true' "$SK" && ok "skill is user-only" || bad "skill frontmatter"
grep -q '\${[A-Za-z_]*:-' "$SK" && bad "skill uses \${VAR:-default}" || ok "skill avoids \${VAR:-default}"
grep -q '|| true' "$SK" && ok "injected command ends with || true" || bad "no || true"
for d in task pr models notify guard statusline; do [ ! -e "$HERE/../skills/$d" ] && ok "skill $d removed" || bad "skill $d still present"; done
for d in desk status settings orchestrator; do [ -f "$HERE/../skills/$d/SKILL.md" ] && ok "skill $d present" || bad "skill $d missing"; done

echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
