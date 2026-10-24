#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-session-hint.sh   (SessionStart hook: one line, off switch; temp HOME and project only)
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$HERE/.."
SH="$PL/scripts/session-hint.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
H="$(mktemp -d)"; P="$(mktemp -d)"; SS="$(mktemp -d)"
trap 'rm -rf "${H:?}" "${P:?}" "${SS:?}"' EXIT
unset CLAUDE_PROJECT_DIR SUBDECK_HOME
export SUBDECK_STATE_DIR="$SS"
hint() { printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$P" | HOME="$H" bash "$SH"; }
set_() { HOME="$H" bash "$PL/scripts/settings.sh" set "$@" "$P" >/dev/null 2>&1; }

out="$(hint)"; rc=$?
[ $rc -eq 0 ] && ok "hook exits 0" || bad "hook exit $rc"
node -e 'const j=JSON.parse(process.argv[1]);const c=j.hookSpecificOutput;process.exit(c.hookEventName==="SessionStart"&&c.additionalContext.startsWith("SubDeck:")&&c.additionalContext.includes("subdeck:orchestrator")&&!c.additionalContext.includes("\n")?0:1)' "$out" \
  && ok "default: valid JSON, one line pointing at the orchestrator skill" || bad "default output: $out"
[ "${#out}" -lt 200 ] && ok "default output is short (${#out} bytes)" || bad "output too long: ${#out}"

set_ session-hint=off
out="$(hint)"; [ -z "$out" ] && ok "session-hint=off (user): the hook prints nothing" || bad "off still prints: $out"
set_ session-hint=on --project
out="$(hint)"; [ -n "$out" ] && ok "project on beats user off" || bad "project scope ignored"
set_ session-hint=off --project
set_ session-hint=on
out="$(hint)"; [ -z "$out" ] && ok "project off beats user on" || bad "project off ignored"
set_ session-hint=on --project
out="$(hint)"; [ -n "$out" ] && ok "back on" || bad "back on failed"

# garbage config and no stdin payload: still prints the hint, exit 0
printf 'not json{{' > "$H/.subdeck/config.json"
out="$(hint)"; [ -n "$out" ] && ok "unreadable user config: hint stays on" || bad "garbage config silenced the hint"
rm -f "$H/.subdeck/config.json"
out="$(CLAUDE_PROJECT_DIR="$P" HOME="$H" bash "$SH" < /dev/null)"; [ -n "$out" ] && ok "empty stdin, CLAUDE_PROJECT_DIR set: hint printed" || bad "empty stdin"

# wiring: hooks.json calls the script through run-hook.cmd; no inline long text left
node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const c=j.hooks.SessionStart[0].hooks[0];process.exit(/run-hook\.cmd.* session-hint$/.test(c.command)&&c.timeout<=5?0:1)' "$PL/hooks/hooks.json" \
  && ok "hooks.json SessionStart runs session-hint through run-hook.cmd" || bad "hooks.json SessionStart wiring"
grep -q 'SubDeck is installed' "$PL/hooks/hooks.json" && bad "old long session text still in hooks.json" || ok "old long session text removed from hooks.json"
[ -f "$PL/scripts/run-hook.cmd" ] && out="$(printf '{"cwd":"%s"}' "$P" | HOME="$H" bash "$PL/scripts/run-hook.cmd" session-hint)" && [ -n "$out" ] && ok "run-hook.cmd session-hint prints the hint" || bad "run-hook.cmd session-hint"
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
