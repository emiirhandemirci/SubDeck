#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-task-hooks.sh   (task status from SubagentStart/Stop/StopFailure, via log-event.sh)
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$HERE/.."
LE="$PL/scripts/log-event.sh"
TS="$PL/scripts/tasks.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2')" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (found '$2')" ;; *) ok "$3" ;; esac; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export SUBDECK_STATE_DIR="$W/state" HOME="$W/home" SUBDECK_NOTIFY_OS=linux SUBDECK_NOTIFY_COLLAPSE=0
unset SUBDECK_TASKS_DIR SUBDECK_TASKS SUBDECK_NOTIFY
mkdir -p "$HOME/.subdeck" "$W/bin"
printf '{"notify":{"enabled":true,"events":["waiting"]}}' > "$HOME/.subdeck/config.json"
printf '#!/bin/sh\necho "$@" >> "%s/notify.out"\n' "$W" > "$W/bin/notify-send"; chmod +x "$W/bin/notify-send"
export PATH="$W/bin:$PATH"

P="$W/proj"; mkdir -p "$P"; git -C "$P" init -q 2>/dev/null
git -C "$P" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init 2>/dev/null
echo base > "$P/f.txt"; git -C "$P" add f.txt; git -C "$P" -c user.email=a@b -c user.name=t commit -q -m base 2>/dev/null
ST="$( . "$PL/scripts/lib-paths.sh"; sd_state_dir "$P"; printf '%s' "$SD_STATE" )"
TD="$ST/tasks"
export CLAUDE_PROJECT_DIR="$P"
t() { bash "$TS" --project "$P" "$@"; }
field() { t show "$1" | sed -n "s/^$2: //p" | head -n 1; }
newtask() { t new "job" --owner worker-sonnet --writable "f.txt,new.txt" "$@"; }
SID="5b0d7c1e-0000-4000-8000-000000000001"
TP="$W/sessions/$SID.jsonl"; mkdir -p "$W/sessions/$SID/subagents"
# fire EVENT AGENT_ID AGENT_TYPE "<msg with JSON escapes>" [extra json fields]
fire() {
  local ev="$1" aid="$2" at="$3" msg="$4" extra="$5"
  printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s","cwd":"%s","agent_id":"%s","agent_type":"%s"%s%s}' \
    "$ev" "$SID" "$TP" "$P" "$aid" "$at" "${msg:+,\"last_assistant_message\":\"$msg\"}" "${extra:+,$extra}" | bash "$LE" "$ev"
}
OKMSG='Did it.\nTested: ran `npm test` -> 12 passed\nStop: done'
events() { local n; n="$(grep -c "\"event\":\"$1\"" "$ST/events.jsonl" 2>/dev/null)"; echo "${n:-0}"; }
lastevent() { grep "\"event\":\"$1\"" "$ST/events.jsonl" | tail -n 1; }
notified() { local i=0; while [ ! -s "$W/notify.out" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done; cat "$W/notify.out" 2>/dev/null; }
reset_notify() { rm -f "$W/notify.out"; }

# ---- 1. Start: id in the prompt (payload) -> in-progress ----
T1="$(newtask)"
fire SubagentStart a1 worker-sonnet "" "\"prompt\":\"Task: $T1\\nbuild it\""
check "$(field $T1 status)" "in-progress" "start with Task in payload -> in-progress"
check "$(field $T1 agent)" "a1" "agent recorded"
check "$(field $T1 session)" "$SID" "session recorded"
check "$(field $T1 transcript)" "$W/sessions/$SID/subagents/agent-a1.jsonl" "transcript path derived from transcript_path + agent id"
check "$(lastevent task_status | sed 's/.*"payload"://')" "{\"agent_id\":\"a1\",\"session_id\":\"$SID\",\"task\":\"$T1\",\"from\":\"open\",\"to\":\"in-progress\",\"by\":\"hook\"}}" "task_status event"
check "$(events SubagentStart)" "1" "the original SubagentStart line is still logged"

# ---- 2. Start via the agent transcript ----
T2="$(newtask)"
printf '{"type":"system"}\n{"type":"user","message":{"content":"Please do it. Task: %s and more"}}\n{"type":"user","message":{"content":"Task: t-9999"}}\n' "$T2" > "$W/sessions/$SID/subagents/agent-a2.jsonl"
fire SubagentStart a2 subdeck:worker-opus ""
check "$(field $T2 status)" "in-progress" "start finds the id in the first user line of the transcript"
check "$(field $T2 agent)" "a2" "agent a2 recorded (subdeck: prefix ok)"

# ---- 3. Start without prompt or transcript: nothing; Stop repeats the search and applies Start effects ----
T3="$(newtask)"
fire SubagentStart a3 worker-sonnet ""
check "$(field $T3 status)" "open" "start without any id leaves the task alone"
printf '{"type":"user","message":{"content":"Task: %s"}}\n' "$T3" > "$W/sessions/$SID/subagents/agent-a3.jsonl"
fire SubagentStop a3 worker-sonnet "$OKMSG"
check "$(field $T3 status)" "review" "stop applies the missed start and the stop effects (-> review)"
check "$(field $T3 agent)" "a3" "agent set at stop"
BODY="$(t show $T3)"
has "$BODY" "final reply (worker-sonnet a3)" "final reply appended to Report"
has "$BODY" "Tested: ran \`npm test\` -> 12 passed" "reply text decoded (newlines, backticks)"
check "$(events task_status)" "4" "events: 1 + 1 + (open->in-progress, in-progress->review)"
fire SubagentStop a3 worker-sonnet "$OKMSG"
check "$(t show $T3 | grep -c 'final reply')" "1" "a repeated stop of the same agent changes nothing"

# ---- 4. stop words ----
stopcase() { # word expected-status
  local id; id="$(newtask)"
  fire SubagentStart "w$1" worker-sonnet "" "\"prompt\":\"Task: $id\""
  fire SubagentStop "w$1" worker-sonnet "x\nTested: not run (no env)\nStop: $1"
  check "$(field $id status)" "$2" "Stop: $1 -> $2"
}
stopcase waiting blocked; stopcase timeout blocked; stopcase no-progress blocked; stopcase blocked blocked
stopcase waiting-on blocked; stopcase frobnicate blocked; stopcase DONE review
check "$(events report_missing)" "0" "no report_missing for well-formed replies"

# ---- 5. quota -> interrupted + handoff ----
T5="$(newtask)"
echo changed > "$P/f.txt"; echo more > "$P/new.txt"; echo unrelated > "$P/other.txt"
fire SubagentStart q1 worker-sonnet "" "\"prompt\":\"Task: $T5\""
reset_notify
fire SubagentStop q1 worker-sonnet 'Out of quota.\nTested: not run (quota)\nStop: quota'
check "$(field $T5 status)" "interrupted" "Stop: quota -> interrupted"
BODY="$(t show $T5)"
has "$BODY" "interrupted (quota)" "handoff header"
has "$BODY" "agent: q1 (worker-sonnet)" "handoff agent line"
has "$BODY" "files: 2" "handoff counts the writable files only"
has "$BODY" "uncommitted (git status --porcelain -- f.txt new.txt):" "handoff status header with pathspecs"
has "$BODY" "     M f.txt" "porcelain line indented 4 spaces"
has "$BODY" "    ?? new.txt" "untracked file listed"
hasnt "$BODY" "other.txt" "files outside writable are not listed"
has "$BODY" "diff --stat:" "diff --stat part"
has "$BODY" "Resume: read this note, then resume the agent or revert the files above." "resume line"
check "$(lastevent task_interrupted | sed 's/.*"payload"://')" "{\"agent_id\":\"q1\",\"agent_type\":\"worker-sonnet\",\"session_id\":\"$SID\",\"task\":\"$T5\",\"error_type\":\"quota\",\"files\":2}}" "task_interrupted event"
has "$(notified)" "agent worker-sonnet interrupted" "notify: agent worker-sonnet interrupted"
check "$(printf '%s\n' "$BODY" | grep -c '^## ')" "5" "no stray ## heading from hook text"

# ---- 6. report missing ----
T6="$(newtask)"
fire SubagentStart m1 worker-sonnet "" "\"prompt\":\"Task: $T6\""
reset_notify
fire SubagentStop m1 worker-sonnet 'All good.\nStop: done'
check "$(field $T6 status)" "blocked" "Tested line missing -> blocked"
check "$(lastevent report_missing | sed 's/.*"payload"://')" "{\"agent_id\":\"m1\",\"agent_type\":\"worker-sonnet\",\"session_id\":\"$SID\",\"transcript_path\":\"$W/sessions/$SID/subagents/agent-m1.jsonl\",\"task\":\"$T6\",\"missing\":[\"Tested\"]}}" "report_missing event with task and missing list"
has "$(notified)" "agent worker-sonnet stopped without a report" "notify: stopped without a report"
T6b="$(newtask)"
fire SubagentStart m2 worker-sonnet "" "\"prompt\":\"Task: $T6b\""
fire SubagentStop m2 worker-sonnet 'nothing useful'
has "$(lastevent report_missing)" '"missing":["Stop","Tested"]' "both lines missing listed"
check "$(field $T6b status)" "blocked" "no lines -> blocked"
# fallback to the Report text when the payload has no message
T6c="$(newtask)"
fire SubagentStart m3 worker-sonnet "" "\"prompt\":\"Task: $T6c\""
printf 'Tested: not run (x)\nStop: done\n' | t append "$T6c" report
N0="$(events report_missing)"
fire SubagentStop m3 worker-sonnet ""
check "$(field $T6c status)" "review" "empty message falls back to the task's Report text"
check "$(events report_missing)" "$N0" "no report_missing with a good Report fallback"

# ---- 7. StopFailure ----
T7="$(newtask)"
fire SubagentStart f1 worker-sonnet "" "\"prompt\":\"Task: $T7\""
reset_notify
fire StopFailure f1 worker-sonnet "" '"error_type":"Rate_Limit"'
check "$(field $T7 status)" "interrupted" "StopFailure by agent id -> interrupted"
has "$(t show $T7)" "interrupted (rate_limit)" "error type lower-cased in the handoff header"
has "$(lastevent task_interrupted)" '"error_type":"rate_limit"' "task_interrupted error_type"
has "$(notified)" "interrupted" "StopFailure notifies"
T7b="$(newtask)"; fire SubagentStart f2 worker-sonnet "" "\"prompt\":\"Task: $T7b\""
fire StopFailure f2 worker-sonnet "" '"error":"overloaded!"'
has "$(t show $T7b)" "interrupted (overloaded)" "falls back to the error string, stripped to [a-z_]"
T7c="$(newtask)"; fire SubagentStart f3 worker-sonnet "" "\"prompt\":\"Task: $T7c\""
fire StopFailure f3 worker-sonnet ""
has "$(t show $T7c)" "interrupted (unknown)" "unknown error type"
# session-level StopFailure: no agent_id
S1="s-two-tasks"
TA="$(newtask)"; TB="$(newtask)"; TC="$(newtask)"
for x in "$TA" "$TB"; do
  SID="$S1" fire SubagentStart "g$x" worker-sonnet "" "\"prompt\":\"Task: $x\""
done
SID="s-other"; fire SubagentStart gc worker-sonnet "" "\"prompt\":\"Task: $TC\""
printf '{"hook_event_name":"StopFailure","session_id":"%s","cwd":"%s","error_type":"rate_limit"}' "$S1" "$P" | bash "$LE" StopFailure
SID="5b0d7c1e-0000-4000-8000-000000000001"
check "$(field $TA status) $(field $TB status) $(field $TC status)" "interrupted interrupted in-progress" "no agent_id: every in-progress task of that session, others untouched"
# a task that is not in-progress is not touched
T7d="$(newtask)"; t set "$T7d" status=review
fire StopFailure f9 worker-sonnet "" "\"prompt\":\"Task: $T7d\""
check "$(field $T7d status)" "review" "StopFailure leaves non-in-progress tasks alone"

# ---- 8. Stop finds the task by the recorded agent id (step 3) ----
T8="$(newtask)"; t set "$T8" status=in-progress agent=byagent
fire SubagentStop byagent worker-sonnet "$OKMSG"
check "$(field $T8 status)" "review" "stop without any Task text matches the task's agent id"

# ---- 9. verifier ----
T9="$(newtask)"; t set "$T9" status=review
printf '{"type":"user","message":{"content":"Task: %s"}}\n' "$T9" > "$W/sessions/$SID/subagents/agent-v1.jsonl"
fire SubagentStart v1 verifier "" "\"prompt\":\"Task: $T9\""
check "$(field $T9 status)" "review" "verifier start does not change the status"
fire SubagentStop v1 verifier 'Checked.\nVerdict: Approved'
check "$(field $T9 status)" "review" "verifier stop does not change the status"
R="$(t show $T9 | awk '/^## Verification$/{f=1;next} /^## /{f=0} f')"
has "$R" "Verdict: Approved" "verdict appended to Verification"
check "$(t done $T9; echo $?)" "0" "done now accepted (Verification has Approved)"
T9b="$(newtask)"; t set "$T9b" status=in-progress
N0="$(events report_missing)"
fire SubagentStop v2 verifier 'looks fine' "\"prompt\":\"Task: $T9b\""
check "$(field $T9b status)" "in-progress" "verifier without verdict leaves the status"
check "$(events report_missing)" "$((N0 + 1))" "verifier without Verdict logs report_missing"
has "$(lastevent report_missing)" '"missing":["Verdict"]' "missing Verdict named"

# ---- 10. done tasks and unknown tasks ----
T10="$(newtask)"; t set "$T10" status=in-progress; printf 'Verdict: Approved\n' | t append "$T10" verification; t done "$T10"
fire SubagentStart d1 worker-sonnet "" "\"prompt\":\"Task: $T10\""
check "$(t show $T10 | sed -n 's/^status: //p')" "done" "archived done task ignored by hooks"
N0="$(events task_status)"
fire SubagentStart n1 worker-sonnet "" '"prompt":"Task: t-dead"'
fire SubagentStop n1 worker-sonnet "$OKMSG" '"prompt":"Task: t-dead"'
check "$(events task_status)" "$N0" "unknown task id: nothing happens"
ls "$TD" | grep -q 't-dead' && bad "no file created for an unknown id" || ok "no file created for an unknown id"

# ---- 11. watchdog without a task ----
N0="$(events report_missing)"; reset_notify
fire SubagentStop wd1 worker-sonnet 'finished, bye'
check "$(events report_missing)" "$((N0 + 1))" "worker stop without task and without report: report_missing"
has "$(lastevent report_missing)" '"task":null' "task is null"
has "$(notified)" "stopped without a report" "watchdog notifies"
fire SubagentStop wd2 researcher 'found stuff\nStop: done'
check "$(events report_missing)" "$((N0 + 1))" "researcher with Stop: line is fine"
fire SubagentStop wd3 subdeck:researcher-current 'found stuff'
check "$(events report_missing)" "$((N0 + 2))" "researcher without Stop: line is flagged (subdeck: prefix ok)"
fire SubagentStop wd4 verifier 'ok'
check "$(events report_missing)" "$((N0 + 3))" "verifier without Verdict is flagged"
fire SubagentStop wd5 Explore 'whatever'
check "$(events report_missing)" "$((N0 + 3))" "other agent types without a task are not checked"
fire SubagentStop wd6 "" 'whatever'
check "$(events report_missing)" "$((N0 + 3))" "phantom stop (no agent type) is not checked"
printf '{"tasks":{"reportCheck":false}}' > "$ST/config.json"
fire SubagentStop wd7 worker-sonnet 'no report'
check "$(events report_missing)" "$((N0 + 3))" "tasks.reportCheck=false silences the watchdog"
T11="$(newtask)"; fire SubagentStart rc1 worker-sonnet "" "\"prompt\":\"Task: $T11\""
fire SubagentStop rc1 worker-sonnet 'no report'
check "$(field $T11 status) $(events report_missing)" "blocked $((N0 + 3))" "reportCheck=false: status logic unchanged, no event"
rm -f "$ST/config.json"

# ---- 12. opt-out, garbage, robustness ----
T12="$(newtask)"
SUBDECK_TASKS=0 fire SubagentStart o1 worker-sonnet "" "\"prompt\":\"Task: $T12\""
check "$(field $T12 status)" "open" "SUBDECK_TASKS=0 skips the task hook"
printf 'not json at all' | bash "$LE" SubagentStop; check "$?" "0" "garbage payload exits 0"
printf '' | bash "$TS" --project "$P" hook SubagentStart; check "$?" "0" "empty payload exits 0"
printf '{}' | bash "$TS" --project "$P" hook Bogus; check "$?" "0" "unknown hook event exits 0"
printf '{"agent_id":"x"}' | bash "$TS" --project "$W/nonexistent/dir" hook StopFailure; check "$?" "0" "missing project dir exits 0"
mkdir -p "$W/lk"; : > "$W/lk/x"
# lock held by someone else: the hook gives up after the wait and exits 0, logging the problem
T12b="$(newtask)"; mkdir -p "$TD/.lock"; printf '%s %s\n' "$$" "$(date +%s)" > "$TD/.lock/owner"
S0=$(date +%s); fire SubagentStart l1 worker-sonnet "" "\"prompt\":\"Task: $T12b\""; S1=$(date +%s)
check "$(field $T12b status)" "open" "busy lock: hook does not write"
[ $((S1 - S0)) -le 9 ] && ok "busy lock: hook waits at most the lock budget" || bad "hook waited $((S1 - S0)) s"
grep -q 'lock busy' "$ST/hook-errors.log" 2>/dev/null && ok "busy lock logged to hook-errors.log" || bad "busy lock logged to hook-errors.log"
rm -rf "$TD/.lock"

# ---- 13. not a git repository ----
NP="$W/nogit"; mkdir -p "$NP"
NST="$( . "$PL/scripts/lib-paths.sh"; sd_state_dir "$NP"; printf '%s' "$SD_STATE" )"
NT="$(bash "$TS" --project "$NP" new job)"
printf '{"hook_event_name":"SubagentStart","session_id":"s","cwd":"%s","agent_id":"ng","agent_type":"worker-sonnet","prompt":"Task: %s"}' "$NP" "$NT" | CLAUDE_PROJECT_DIR="$NP" bash "$LE" SubagentStart
printf '{"hook_event_name":"StopFailure","session_id":"s","cwd":"%s","agent_id":"ng","error_type":"server_error"}' "$NP" | CLAUDE_PROJECT_DIR="$NP" bash "$LE" StopFailure
NB="$(bash "$TS" --project "$NP" show "$NT")"
has "$NB" "files: 0" "no git: files: 0"
has "$NB" "uncommitted: (not a git repository)" "no git: explicit line"

# ---- 14. caps ----
T14="$(newtask)"; fire SubagentStart c1 worker-sonnet "" "\"prompt\":\"Task: $T14\""
LONG="$(printf 'x%.0s' $(seq 1 6000))"
fire SubagentStop c1 worker-sonnet "$LONG\nTested: ran x\nStop: done"
CAP="$(t show $T14 | awk '/^## Report$/{f=1;next} /^## /{f=0} f' | tr -d '\n' | wc -c | tr -d ' ')"
[ "$CAP" -gt 3900 ] && [ "$CAP" -lt 4100 ] && ok "final reply capped at 4000 chars ($CAP incl. header)" || bad "final reply cap ($CAP)"
T14b="$(newtask --writable "")"; fire SubagentStart c2 worker-sonnet "" "\"prompt\":\"Task: $T14b\""
for i in $(seq 1 70); do echo x > "$P/many$i.txt"; done
fire StopFailure c2 worker-sonnet "" '"error_type":"x"'
check "$(t show $T14b | awk '/^uncommitted/{f=1;next} /^diff --stat/{f=0} f' | wc -l | tr -d ' ')" "50" "status part capped at 50 lines"
has "$(t show $T14b)" "uncommitted (git status --porcelain):" "empty writable: whole repo header"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
