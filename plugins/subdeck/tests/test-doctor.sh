#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-doctor.sh   (temp dirs, no network)
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
D="$HERE/../scripts/doctor.sh"
P="$T/proj"; mkdir -p "$P"
printf '{"enabledPlugins":{"subdeck@subdeck":true}}' > "$T/cfg/settings.json"
export SUBDECK_LATEST="0.9.2 1234567890abcdef"
o="$(bash "$D" "$P")"; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc"
has "$o" '^ok +plugin installed' "installed"
has "$o" '^ok +plugin enabled' "enabled"
has "$o" '^ok +hooks\.json present' "hooks resolve"
has "$o" '^ok +7 agent files present' "7 agents"
has "$o" '^ok +state dir writable' "state dir writable"
has "$o" '^ok +version up to date' "version ok"
has "$o" '^info +Desk not running' "Desk not running is info"
has "$o" '^summary: [0-9]+ ok, 0 warn, 0 fail$' "summary line"
# problems
printf '{"version":2,"plugins":{}}' > "$T/inst.json"
printf '{"enabledPlugins":{"subdeck@subdeck":false}}' > "$T/cfg/settings.json"
export SUBDECK_LATEST="0.9.3 aaaaaaa"
o="$(bash "$D" "$P")"
has "$o" '^fail +plugin subdeck@subdeck not found' "not installed: fail"
has "$o" 'fix: claude plugin marketplace add' "fail has a fix hint"
has "$o" '^warn +plugin is disabled' "disabled: warn"
has "$o" '^warn +version: 0\.9\.3 available' "update available: warn"
has "$o" 'summary: [0-9]+ ok, [1-9][0-9]* warn, 1 fail' "summary counts"
# offline is not a warning; model override warning is
export SUBDECK_LATEST=offline CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1
o="$(bash "$D" "$P")"
has "$o" '^info +version: latest unknown' "offline: info"
has "$o" '^warn +model policy: CLAUDE_CODE_SUBAGENT_MODEL_FORCE' "model policy override: warn"
unset CLAUDE_CODE_SUBAGENT_MODEL_FORCE
# unwritable state dir
printf 'x' > "$T/afile"; o="$(SUBDECK_STATE_DIR="$T/afile/sub" bash "$D" "$P")"
has "$o" '^fail +state dir not writable' "unwritable state dir: fail"
echo; echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
