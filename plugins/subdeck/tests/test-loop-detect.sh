#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-loop-detect.sh   (loop detection in checkpoint.sh: PostToolUse failure ring)
HERE="$(cd "$(dirname "$0")" && pwd)"
CP="$HERE/../scripts/checkpoint.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2')" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (found '$2')" ;; *) ok "$3" ;; esac; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export SUBDECK_STATE_DIR="$W/state" HOME="$W/home"
unset SUBDECK_TASKS SUBDECK_LOOP_DETECT
mkdir -p "$HOME/.subdeck" "$W/proj"
export CLAUDE_PROJECT_DIR="$W/proj"
EV="$(bash -c ". '$HERE/../scripts/lib-paths.sh'; sd_state_dir '$W/proj'; echo \"\$SD_STATE\"")/events.jsonl"
# fire AGENT TOOL CMD EXITCODE : PostToolUse payload through the hook script; prints the hook's stdout
fire() {
  printf '{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"%s","tool_name":"%s","tool_input":{"command":"%s"}%s,"tool_response":{"stdout":"x","exit_code":%s}}' \
    "$W/proj" "$2" "$3" "${1:+,\"agent_id\":\"$1\"}" "$4" | bash "$CP"
}
WARN="Same failing command 3 times"

# 1. two failures then success -> no warning
o="$(fire a1 Bash 'npm test' 1)$(fire a1 Bash 'npm test' 1)$(fire a1 Bash 'npm test' 0)"
check "$o" "" "2 failures then success: silent"
# 2. 3 identical failures -> warning once
o1="$(fire a2 Bash 'make  build' 2)"; o2="$(fire a2 Bash 'make build' 2)"; o3="$(fire a2 Bash 'make build' 2)"; o4="$(fire a2 Bash 'make build' 2)"
check "$o1$o2" "" "first two failures silent (whitespace normalised)"
has "$o3" "$WARN" "third identical failure warns"
has "$o3" '"hookEventName":"PostToolUse"' "output is PostToolUse additionalContext"
has "$o3" 'Stop: no-progress' "warning names the stop reason"
check "$o4" "" "fourth failure does not warn again"
# 3. different commands -> none
o="$(fire a3 Bash 'cmd one' 1)$(fire a3 Bash 'cmd two' 1)$(fire a3 Bash 'cmd three' 1)$(fire a3 Bash 'cmd one' 1)$(fire a3 Bash 'cmd two' 1)"
check "$o" "" "different commands: silent"
# 4. repeated successes never trigger
o="$(fire a4 Bash 'npm test' 0)$(fire a4 Bash 'npm test' 0)$(fire a4 Bash 'npm test' 0)$(fire a4 Bash 'npm test' 0)"
check "$o" "" "non-failing repeats: silent"
# 5. window of 10: 2 failures, 9 other failures push the first out, then the third failure does not warn
fire a5 Bash 'x' 1 >/dev/null; fire a5 Bash 'x' 1 >/dev/null
for i in 1 2 3 4 5 6 7 8 9; do fire a5 Bash "other $i" 1 >/dev/null; done
check "$(fire a5 Bash 'x' 1)" "" "failures outside the window do not count"
# 6. main thread (no agent_id) is not tracked
o="$(fire '' Bash 'z' 1)$(fire '' Bash 'z' 1)$(fire '' Bash 'z' 1)"
check "$o" "" "no agent_id: silent"
# 7. agents are independent; tool name is part of the key
o="$(fire b1 Bash 'y' 1)$(fire b2 Bash 'y' 1)$(fire b1 Bash 'y' 1)$(fire b2 Bash 'y' 1)$(fire b1 PowerShell 'y' 1)"
check "$o" "" "separate agents and tools do not mix"
# 8. PostToolUseFailure event counts as a failure
ff() { printf '{"hook_event_name":"PostToolUseFailure","cwd":"%s","tool_name":"Bash","tool_input":{"command":"boom"},"agent_id":"a6","error":"Exit code 1"}' "$W/proj" | bash "$CP"; }
o="$(ff)$(ff)$(ff)"; has "$o" "$WARN" "PostToolUseFailure x3 warns"
# 9. event logged without command text
L="$(cat "$EV" 2>/dev/null)"
has "$L" '"event":"loop_detected"' "loop_detected event logged"
hasnt "$L" 'make build' "event holds no command text"
check "$(printf '%s\n' "$L" | grep -c loop_detected)" 2 "one event per warning (a2 and a6)"
# 10. off switch: project config loopDetect=false
mkdir -p "$(dirname "$EV")"; echo '{"loopDetect":false}' > "$(dirname "$EV")/config.json"
o="$(fire c1 Bash 'q' 1)$(fire c1 Bash 'q' 1)$(fire c1 Bash 'q' 1)"
check "$o" "" "loopDetect=false: silent"
echo '{"loopDetect":true}' > "$(dirname "$EV")/config.json"
o="$(fire c2 Bash 'q' 1)$(fire c2 Bash 'q' 1)$(fire c2 Bash 'q' 1)"; has "$o" "$WARN" "loopDetect=true: warns"
rm -f "$(dirname "$EV")/config.json"
# 11. hook always exits 0, also on garbage
printf 'garbage' | bash "$CP"; check "$?" 0 "garbage payload exits 0"
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" = 0 ]
