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
check "$(events task_status)" "5" "events: 1 + 1 + auto-bind of a3 + (open->in-progress, in-progress->review)"
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
check "$(events task_status)" "$((N0 + 2))" "unknown task id: no task file for it, the agent is auto-bound instead (open->in-progress, in-progress->review)"
ls "$TD" | grep -q 't-dead' && bad "no file created for an unknown id" || ok "no file created for an unknown id"

# ---- 11. watchdog: agents with a task (auto-bind) are checked, others are not tracked ----
N0="$(events report_missing)"; reset_notify
fire SubagentStop wd1 worker-sonnet 'finished, bye'
check "$(events report_missing)" "$((N0 + 1))" "worker stop without report: report_missing (the agent was auto-bound)"
has "$(lastevent report_missing)" '"task":"t-' "task is the auto task"
has "$(notified)" "stopped without a report" "watchdog notifies"
fire SubagentStop wd2 researcher 'found stuff\nStop: done'
check "$(events report_missing)" "$((N0 + 1))" "researcher with Stop: line is fine"
fire SubagentStop wd3 subdeck:researcher-current 'found stuff'
check "$(events report_missing)" "$((N0 + 2))" "researcher without Stop: line is flagged (subdeck: prefix ok)"
fire SubagentStop wd4 verifier 'ok'
check "$(events report_missing)" "$((N0 + 2))" "verifier without a task is never tracked"
fire SubagentStop wd5 Explore 'whatever'
check "$(events report_missing)" "$((N0 + 2))" "other agent types without a task are not checked"
fire SubagentStop wd6 "" 'whatever'
check "$(events report_missing)" "$((N0 + 2))" "phantom stop (no agent type) is not checked"
printf '{"tasks":{"reportCheck":false}}' > "$ST/config.json"
fire SubagentStop wd7 worker-sonnet 'no report'
check "$(events report_missing)" "$((N0 + 2))" "tasks.reportCheck=false silences the watchdog"
T11="$(newtask)"; fire SubagentStart rc1 worker-sonnet "" "\"prompt\":\"Task: $T11\""
fire SubagentStop rc1 worker-sonnet 'no report'
check "$(field $T11 status) $(events report_missing)" "blocked $((N0 + 2))" "reportCheck=false: status logic unchanged, no event"
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

# ---- 13b. headless runs: agent_type <class>-run, SUBDECK_TASK_GIT names the Handoff git dir ----
GW="$W/gitwt"; mkdir -p "$GW"; git -C "$GW" init -q; echo x > "$GW/wt-only.txt"
T13="$(newtask --writable "")"
RID="run-$T13-20261007T120000Z"
printf '{"hook_event_name":"SubagentStart","session_id":"%s","agent_id":"%s","agent_type":"worker-run","cwd":"%s","prompt":"Task: %s"}' "$RID" "$RID" "$P" "$T13" | bash "$TS" --project "$P" hook SubagentStart
check "$(field $T13 status)" "in-progress" "worker-run start -> in-progress"
printf '{"hook_event_name":"StopFailure","session_id":"%s","agent_id":"%s","agent_type":"worker-run","cwd":"%s","prompt":"Task: %s","error_type":"timeout"}' "$RID" "$RID" "$P" "$T13" | SUBDECK_TASK_GIT="$GW" bash "$TS" --project "$P" hook StopFailure
B13="$(t show $T13)"
check "$(field $T13 status)" "interrupted" "worker-run StopFailure -> interrupted"
has "$B13" "?? wt-only.txt" "Handoff git status taken from SUBDECK_TASK_GIT"
has "$B13" "interrupted (timeout)" "error type timeout"
T13b="$(newtask)"; t set "$T13b" status=review
printf '{"hook_event_name":"SubagentStop","session_id":"v","agent_id":"v1","agent_type":"verifier-run","cwd":"%s","prompt":"Task: %s","last_assistant_message":"ok\\nVerdict: Approved"}' "$P" "$T13b" | bash "$TS" --project "$P" hook SubagentStop
check "$(field $T13b status)" "review" "verifier-run never changes status"
has "$(t show $T13b)" "verifier reply (verifier-run v1)" "verifier-run verdict appended to Verification"
T13c="$(newtask)"
printf '{"hook_event_name":"SubagentStop","session_id":"r","agent_id":"r1","agent_type":"researcher-run","cwd":"%s","prompt":"Task: %s","last_assistant_message":"Answer\\nStop: done"}' "$P" "$T13c" | bash "$TS" --project "$P" hook SubagentStop
check "$(field $T13c status)" "review" "researcher-run report shape is Stop only"

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

# ---- 0.8.1: auto-bind, not tracked, report_too_long, quota ----
export SUBDECK_METER=0
rm -f "$ST/config.json"
auto_of() { t list --all --tsv | awk -F'\t' -v a="$1" '$4 == a { print $1 }' | head -n 1; }
printf '{"description":"Fix the parser\\nsecond line"}' > "$W/sessions/$SID/subagents/agent-ab1.meta.json"
N0="$(events task_status)"
fire SubagentStart ab1 subdeck:worker-sonnet ""
TA="$(auto_of ab1)"
[ -n "$TA" ] && ok "auto-bind: a task exists for the worker" || bad "auto-bind: no task"
check "$(field $TA auto)" "true" "auto-bind: auto: true"
check "$(field $TA status)" "in-progress" "auto-bind: in-progress"
check "$(field $TA owner)" "worker-sonnet" "auto-bind: owner without subdeck:"
check "$(field $TA session)" "$SID" "auto-bind: session recorded"
check "$(field $TA transcript)" "$W/sessions/$SID/subagents/agent-ab1.jsonl" "auto-bind: transcript recorded"
check "$(field $TA title)" "Fix the parser second line" "auto-bind: title from meta.json description (sanitized)"
check "$(field $TA writable)" "[]" "auto-bind: empty writable"
has "$(t show $TA)" "## Task" "auto-bind: body sections present"
check "$(events task_status)" "$((N0 + 1))" "auto-bind: one task_status event"
has "$(lastevent task_status)" '"from":"open","to":"in-progress","by":"hook","auto":true' "auto-bind: event carries auto:true"
check "$(t list | grep -c "^$TA in-progress worker-sonnet \[auto\] Fix the parser")" "1" "auto task listed with the [auto] mark"
fire SubagentStart ab1 subdeck:worker-sonnet ""
check "$(t list --all --tsv | awk -F'\t' '$4 == "ab1"' | wc -l | tr -d ' ')" "1" "auto-bind: a repeated start creates no second task"
fire SubagentStop ab1 subdeck:worker-sonnet "$OKMSG"
check "$(field $TA status)" "review" "auto task follows the 0.7 transitions (-> review)"
t done $TA; check "$?" "0" "done on an auto task needs no verdict"
check "$(t show $TA | sed -n 's/^status: //p')" "done" "auto task archived"
# title from the prompt, then the fallback
fire SubagentStart ab2 worker-sonnet "" '"prompt":"Refactor the lexer\nand more"'
check "$(field "$(auto_of ab2)" title)" "Refactor the lexer" "auto-bind: title from the first prompt line"
fire SubagentStart ab3 researcher ""
check "$(field "$(auto_of ab3)" title)" "researcher ab3" "auto-bind: fallback title <type> <id>"
check "$(field "$(auto_of ab3)" owner)" "researcher" "auto-bind: researchers are bound too"
# a fallback title is replaced at stop when the meta description exists
printf '{"description":"Late title"}' > "$W/sessions/$SID/subagents/agent-ab3.meta.json"
fire SubagentStop ab3 researcher 'found it\nStop: done'
check "$(field "$(auto_of ab3)" title)" "Late title" "fallback title replaced by the meta description at stop"
# never auto-bound: verifier, other agents, opt-outs
N1="$(t list --all --tsv | wc -l | tr -d ' ')"
fire SubagentStart v9 subdeck:verifier-opus ""
fire SubagentStart x9 Explore ""
fire SubagentStart x8 general-purpose ""
check "$(t list --all --tsv | wc -l | tr -d ' ')" "$N1" "verifier and other agent types are never auto-bound"
printf '{"tasks":{"autoBind":false}}' > "$ST/config.json"
fire SubagentStart off1 worker-sonnet ""
check "$(auto_of off1)" "" "tasks.autoBind=false: no auto task"
rm -f "$ST/config.json"
SUBDECK_TASKS=0 bash "$TS" --project "$P" hook SubagentStart <<< "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"$SID\",\"agent_id\":\"off2\",\"agent_type\":\"worker-sonnet\",\"cwd\":\"$P\"}"
check "$(auto_of off2)" "" "SUBDECK_TASKS=0: no auto task"
# a task id in the prompt wins: no auto task
TK="$(newtask)"; fire SubagentStart named1 worker-sonnet "" "\"prompt\":\"Task: $TK\""
check "$(auto_of named1)" "$TK" "Task: id in the prompt binds that task, no auto task"
check "$(field $TK auto)" "" "explicit task is not auto"
# Start missed: auto-bind at stop
fire SubagentStop late1 worker-sonnet "$OKMSG"
TL="$(auto_of late1)"
check "$(field $TL status)" "review" "stop without start: auto task created and moved to review"
check "$(field $TL auto)" "true" "stop without start: auto"
# not tracked: no report_missing, no notify
R0="$(events report_missing)"; reset_notify
fire SubagentStop nt1 Explore 'found some things'
fire SubagentStop nt2 subdeck:verifier-opus 'no verdict here'
check "$(events report_missing)" "$R0" "agents without a task are not tracked: no report_missing"
[ -s "$W/notify.out" ] && bad "not tracked: no notification" || ok "not tracked: no notification"
# an auto task without a report: report_missing with its task id
fire SubagentStart nr1 worker-sonnet ""; fire SubagentStop nr1 worker-sonnet 'finished, bye'
check "$(events report_missing)" "$((R0 + 1))" "auto task without a report: report_missing"
has "$(lastevent report_missing)" "\"task\":\"$(auto_of nr1)\"" "report_missing names the auto task"
check "$(field "$(auto_of nr1)" status)" "blocked" "auto task without a report -> blocked"
# report length
L0="$(events report_too_long)"
LONG9='l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nStop: done'
LONG10='l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nTested: ran true -> ok\nStop: done'
fire SubagentStop rl1 worker-sonnet "$LONG9"
check "$(events report_too_long)" "$L0" "9 lines: no report_too_long"
fire SubagentStop rl2 worker-sonnet "\\n\\n$LONG10\\n\\n"
check "$(events report_too_long)" "$((L0 + 1))" "10 lines (blank edges trimmed): report_too_long"
has "$(lastevent report_too_long)" '"lines":10,"limit":9' "report_too_long carries lines and limit"
has "$(lastevent report_too_long)" "\"task\":\"$(auto_of rl2)\"" "report_too_long names the task"
fire SubagentStop rl3 Explore 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk'
has "$(lastevent report_too_long)" '"agent_id":"rl3"' "report_too_long also for agents without a task"
has "$(lastevent report_too_long)" '"task":null' "report_too_long: task null when not tracked"
check "$(field "$(auto_of rl2)" status)" "review" "a long report changes no status"
# quota
grep -v '"event":"quota_recent"' "$ST/events.jsonl" > "$ST/events.tmp"; mv "$ST/events.tmp" "$ST/events.jsonl"
Q0="$(events quota_recent)"; reset_notify
fire SubagentStop qq1 worker-sonnet 'hit the wall\nStop: quota - resets 3pm (UTC)\nTested: not run (quota)'
check "$(events quota_recent)" "$((Q0 + 1))" "Stop: quota logs quota_recent"
has "$(lastevent quota_recent)" '"source":"hook","tool":"claude","reset":"3pm (UTC)","resetAt":null' "quota_recent: raw reset text"
check "$(field "$(auto_of qq1)" status)" "interrupted" "Stop: quota interrupts the task (0.7)"
sleep 0.5
has "$(notified)" "quota limit hit; resets 3pm (UTC)" "quota notification reason"
reset_notify
fire StopFailure qq2 worker-sonnet "" '"error_type":"rate_limit","error":"limit reached, resets at 2026-10-07T15:30:00Z"'
check "$(events quota_recent)" "$((Q0 + 2))" "StopFailure rate_limit logs quota_recent"
has "$(lastevent quota_recent)" '"reset":null,"resetAt":"2026-10-07T15:30:00Z"' "quota_recent: ISO resetAt"
sleep 0.3
[ -s "$W/notify.out" ] && bad "quota notification only once per 60 min" || ok "quota notification only once per 60 min"
printf '{"hook_event_name":"StopFailure","session_id":"s-none","cwd":"%s","error_type":"rate_limit"}' "$P" | bash "$LE" StopFailure
check "$(events quota_recent)" "$((Q0 + 3))" "rate_limit without any task still logs quota_recent"
has "$(lastevent quota_recent)" '"task":null' "quota_recent: task null"
fire StopFailure qq3 worker-sonnet "" '"error_type":"auth"'
check "$(events quota_recent)" "$((Q0 + 3))" "other failure types log no quota_recent"
# run.sh marks its own hook calls: no duplicate quota_recent
printf '{"hook_event_name":"StopFailure","session_id":"r1","agent_id":"run-x","agent_type":"worker-run","cwd":"%s","error_type":"rate_limit"}' "$P" | SUBDECK_QUOTA_LOGGED=1 bash "$TS" --project "$P" hook StopFailure
check "$(events quota_recent)" "$((Q0 + 3))" "SUBDECK_QUOTA_LOGGED=1 skips the hook's quota_recent"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
