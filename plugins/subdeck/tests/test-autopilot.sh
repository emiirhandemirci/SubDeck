#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-autopilot.sh   (autopilot.sh supervisor; fake CLIs only, temp HOME/state/projects)
# Clock: SUBDECK_NOW for autopilot.sh; ticks run one by one (never the loop, except the start/stop test).
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$HERE/.."
AP_SH="$PL/scripts/autopilot.sh"; TS="$PL/scripts/tasks.sh"; SET="$PL/scripts/settings.sh"
FAKE="$HERE/fixtures/fake-cli"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2')"; printf '%s\n' "$1" | head -n 30 | sed 's/^/     | /' ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (found '$2')" ;; *) ok "$3" ;; esac; }

W="$(mktemp -d)"
cleanup() {
  # stop only what this test started: loops and runs recorded under the temp state
  local f p
  for f in "$W"/state/*/autopilot/loop.pid "$W"/state/*/autopilot/launched.tsv; do
    [ -f "$f" ] || continue
    while read -r p _; do [[ $p =~ ^[0-9]+$ ]] && kill -TERM "$p" 2>/dev/null; done < "$f"
  done
  sleep 1; rm -rf "$W"
}
trap cleanup EXIT
export SUBDECK_STATE_DIR="$W/state" HOME="$W/home" SUBDECK_HOME="$W/home" SUBDECK_ROLES_DIR="$W/roles" SUBDECK_NOTIFY_OS=linux SUBDECK_NOTIFY_DRYRUN=1 TZ=UTC
unset SUBDECK_TASKS_DIR SUBDECK_TASKS CLAUDE_PROJECT_DIR SUBDECK_PROJECT SUBDECK_RUN SUBDECK_TASK SUBDECK_ROLE SUBDECK_AUTOPILOT SUBDECK_AUTOPILOT_LAUNCH SUBDECK_RUN_BASE
unset FAKE_CLI_LOG FAKE_CLI_REPLY FAKE_CLI_EXIT FAKE_CLI_STDERR FAKE_CLI_SLEEP FAKE_CLI_TOUCH FAKE_CLI_COMMIT FAKE_CLI_MODE FAKE_CLI_RUN FAKE_CLI_USAGE FAKE_CLI_HANG FAKE_CLI_SESSION FAKE_CLI_QUOTA_MSG
i=0; while [ $i -lt 20 ]; do unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"; i=$((i+1)); done; unset GIT_CONFIG_COUNT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
mkdir -p "$HOME/.subdeck" "$W/roles" "$W/bin"
for c in worker researcher verifier manager; do printf '# SubDeck %s rules\nstub\n' "$c" > "$W/roles/$c.md"; done
printf 'You are headless. Act only via tasks.sh and autopilot.sh launch.\n' > "$W/rules.md"
export SUBDECK_AUTOPILOT_PROMPT="$W/rules.md"
# a git wrapper first on PATH logs every push (there must never be one)
REALGIT="$(command -v git)"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = push ] && echo "push $*" >> "%s/push.log"; done\nexec "%s" "$@"\n' "$W" "$REALGIT" > "$W/bin/git"; chmod +x "$W/bin/git"
export PATH="$W/bin:$FAKE/bin:$PATH"
: > "$W/push.log"

T0=1760000000   # 2025-10-09T08:53:20Z (a Thursday)
mkproj() { # name -> P, ST
  P="$W/$1"; mkdir -p "$P/src"; "$REALGIT" -C "$P" init -q; echo base > "$P/a.txt"; echo s > "$P/src/s.js"
  "$REALGIT" -C "$P" add a.txt src/s.js; "$REALGIT" -C "$P" commit -qm base
  ST="$( . "$PL/scripts/lib-paths.sh"; sd_state_dir "$P"; printf '%s' "$SD_STATE" )"; APD="$ST/autopilot"
}
t()  { SUBDECK_METER=0 bash "$TS" --project "$P" "$@"; }
ap() { SUBDECK_NOW="${NOWV:-$T0}" bash "$AP_SH" --project "$P" "$@"; }
pset() { bash "$SET" set "$@" --project "$P" >/dev/null 2>&1; }
ucfg() { printf '%s' "$1" > "$HOME/.subdeck/config.json"; }
events() { local n; n="$(grep -c "\"event\":\"$1\"" "$ST/events.jsonl" 2>/dev/null)"; echo "${n:-0}"; }
lastevent() { grep "\"event\":\"$1\"" "$ST/events.jsonl" 2>/dev/null | tail -n 1; }
field() { t show "$1" | sed -n "s/^$2: //p" | head -n 1; }
# wait until no run of the project is running (bounded: 90 s)
waitruns() {
  local i=0 f busy
  while [ $i -lt 450 ]; do
    busy=0
    for f in "$ST"/runs/t-*/*.json "$APD"/turns/*.json; do [ -f "$f" ] && grep -q '"status":"running"' "$f" && busy=1; done
    if [ -f "$APD/launched.tsv" ]; then while read -r p _; do [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && busy=1; done < "$APD/launched.tsv"; fi
    [ "$busy" = 0 ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
ROLES='{"roles":{"manager":{"tool":"claude","model":"opus"},"worker":{"tool":"codex","model":"gpt-5-codex"},"verifier":{"tool":"claude","model":"sonnet"}},"notify":{"enabled":true}}'
ucfg "$ROLES"
# parts: `bash test-autopilot.sh [start cycle queue stuck budget killint final ...]` runs only those (default all). Each part
# builds its own projects; a full run is slow on Windows (process starts), so run the parts in parallel or one by one.
PARTS="$*"
want() { [ -z "$PARTS" ] || case " $PARTS " in *" $1 "*) return 0 ;; esac; return 1; }

if want start; then
# ---------- 1. start checks ----------
mkproj p1
OUT="$(ap start 2>&1)"; check "$?" "2" "start: not enabled -> exit 2"
has "$OUT" "autopilot.enabled is off" "start: not enabled message"
bash "$SET" set autopilot.enabled=on >/dev/null 2>&1; check "$?" "2" "enabled at user scope refused by settings"
printf '{"autopilot":{"enabled":true}}' > "$HOME/.subdeck/config.json"
ap start >/dev/null 2>&1; check "$?" "2" "start: user-scope enabled is ignored"
ucfg "$ROLES"; pset autopilot.enabled=on
ucfg '{"roles":{"worker":{"tool":"codex"},"verifier":{"tool":"claude"}}}'
OUT="$(ap start 2>&1)"; check "$?" "2" "start: unmapped manager -> exit 2"
has "$OUT" "roles.manager is not mapped" "start: unmapped manager message"
ucfg "$ROLES"
mkdir -p "$W/nogit"; NG="$( . "$PL/scripts/lib-paths.sh"; sd_state_dir "$W/nogit"; printf '%s' "$SD_STATE")"
bash "$SET" set autopilot.enabled=on --project "$W/nogit" >/dev/null 2>&1
SUBDECK_NOW=$T0 bash "$AP_SH" --project "$W/nogit" start >/dev/null 2>&1; check "$?" "2" "start: non-git project -> exit 2"
ucfg '{"roles":{"manager":{"tool":"claude","model":"opus"},"worker":{"tool":"codex","model":"m"},"verifier":{"tool":"codex","model":"m"}}}'
OUT="$(ap start 2>&1)"; RC=$?
has "$OUT" "warning: the verifier uses the same tool and model" "start: same verifier model only warns"
has "$OUT" "warning: notifications are off" "start: notifications off warning"
check "$RC" "0" "start with warnings succeeds"
has "$OUT" "autopilot started: pid" "start prints the pid"
has "$OUT" "branch autopilot/20251009" "default branch autopilot/<date of first start>"
HEAD0="$("$REALGIT" -C "$P" rev-parse HEAD)"; BR0="$("$REALGIT" -C "$P" rev-parse --abbrev-ref HEAD)"
[ -d "$ST/worktrees/_autopilot" ] && ok "autopilot worktree created" || bad "autopilot worktree missing"
check "$("$REALGIT" -C "$ST/worktrees/_autopilot" rev-parse --abbrev-ref HEAD)" "autopilot/20251009" "worktree on the autopilot branch"
ap start >/dev/null 2>&1; check "$?" "4" "start again: a live loop -> exit 4"
OUT="$(ap stop)"; has "$OUT" "autopilot stopped" "stop"
[ -f "$APD/STOP" ] && ok "stop writes the kill switch file" || bad "no STOP file"
i=0; while [ -f "$APD/loop.pid" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
[ ! -f "$APD/loop.pid" ] && ok "loop exits on stop (loop.pid removed)" || bad "loop still running"
check "$(ap tick; echo $?)" "0" "tick under the kill switch exits 0"
has "$(cat "$APD/status.json")" '"state":"stopped"' "kill switch: state stopped"
ucfg "$ROLES"
OUT="$(ap start 2>&1)"; has "$OUT" "branch autopilot/20251009" "second start reuses the branch"
[ ! -f "$APD/STOP" ] && ok "start removes the project kill switch" || bad "STOP still there"
ap stop >/dev/null; i=0; while [ -f "$APD/loop.pid" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
OUT="$(ap start --new-branch 2>&1)"; has "$OUT" "branch autopilot/20251009-2" "--new-branch: dated branch with suffix"
ap stop >/dev/null; i=0; while [ -f "$APD/loop.pid" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
: > "$HOME/.subdeck/autopilot.STOP"
ap start >/dev/null 2>&1; check "$?" "3" "global kill switch: start exit 3"
ap tick; has "$(cat "$APD/status.json")" '"reasons":["global-stop"]' "global kill switch: stopped"
rm -f "$HOME/.subdeck/autopilot.STOP"
check "$("$REALGIT" -C "$P" rev-parse HEAD) $("$REALGIT" -C "$P" rev-parse --abbrev-ref HEAD) $("$REALGIT" -C "$P" status --porcelain | grep -v '^??' | wc -l | tr -d ' ')" "$HEAD0 $BR0 0" "user's checkout untouched by start/stop"
fi

if want cycle; then
# ---------- 2. a full cycle: dispatch worker -> review -> verifier Approved -> done -> integrated (ff) ----------
mkproj p2; pset autopilot.enabled=on autopilot.manager-gap=0
ap start >/dev/null 2>&1; ap stop >/dev/null; i=0; while [ -f "$APD/loop.pid" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done; rm -f "$APD/STOP"
APWT="$ST/worktrees/_autopilot"; BR="$("$REALGIT" -C "$APWT" rev-parse --abbrev-ref HEAD)"
A="$(t new "Add feature" --writable src --done-when "src/f.js exists")"
N="$(t new "No end" --writable src)"
OUT="$(ap launch worker "$N")"; check "$?" "2" "launch: task without Done when refused"
has "$OUT" "refused: no-done-when" "launch refusal reason no-done-when"
OUT="$(ap launch manager "$A")"; check "$?" "2" "launch: manager role refused"
OUT="$(ap launch verifier "$A")"; has "$OUT" "refused: status open" "launch: verifier needs review"
export FAKE_CLI_TOUCH=src/f.js FAKE_CLI_COMMIT=1 FAKE_CLI_REPLY=verifier-approved-head.txt
# worker reply must be a worker report: use a per-tool reply via FAKE_CLI_RUN-free route: codex gets worker-done (default)
unset FAKE_CLI_REPLY
D="$(ap dry-run)"
has "$D" "would: queue worker $A" "dry-run: would queue the ready task"
has "$D" "would: launch worker $A" "dry-run: would launch it"
hasnt "$D" "queue worker $N" "dry-run: task without Done when is not dispatched"
[ ! -d "$APD/queue" ] || [ -z "$(ls "$APD/queue")" ] && ok "dry-run queued nothing" || bad "dry-run wrote a queue entry"
NOWV=$((T0 + 60)) ap tick
waitruns || bad "worker run did not finish"
check "$(field "$A" status)" "review" "worker run finished: task in review"
check "$(events autopilot_launch)" "1" "one launch event"
has "$(lastevent autopilot_launch)" "\"task\":\"$A\",\"role\":\"worker\",\"tool\":\"codex\"" "launch event payload"
grep -q "SUBDECK_RUN_BASE" "$APD/launch.log" && bad "launch.log leaks env" || ok "launch.log clean"
check "$("$REALGIT" -C "$P" merge-base "subdeck/$A" "$BR")" "$("$REALGIT" -C "$P" rev-parse "$BR")" "worker worktree based on the autopilot branch"
# verifier: claude sonnet replies Approved with the worktree HEAD
export FAKE_CLI_REPLY=verifier-approved-head.txt; unset FAKE_CLI_TOUCH FAKE_CLI_COMMIT
NOWV=$((T0 + 120)) ap tick
waitruns
check "$(field "$A" status)" "review" "verifier ran; status unchanged until the next tick"
NOWV=$((T0 + 180)) ap tick
[ -f "$(t dir)/archive/$A.md" ] && ok "Approved verdict -> tasks.sh done (archived)" || bad "task not done after Approved"
has "$(cat "$APD/integrated.tsv" 2>/dev/null)" "$A	ff" "integration: fast-forward"
check "$("$REALGIT" -C "$APWT" rev-parse HEAD)" "$("$REALGIT" -C "$P" rev-parse "subdeck/$A")" "autopilot branch at the task tip"
check "$(events autopilot_integrate)" "1" "one integrate event"
unset FAKE_CLI_REPLY

# ---------- 3. idempotence (2.1) ----------
waitruns
NOWV=$((T0 + 240)) ap tick; waitruns
NOWV=$((T0 + 300)) ap tick; waitruns
E1="$(wc -l < "$ST/events.jsonl")"; L1="$(wc -l < "$APD/ledger.tsv")"; S1="$(sed 's/"lastTickAt":"[^"]*"//' "$APD/status.json")"
Q1="$(ls "$APD/queue" 2>/dev/null | wc -l)"
NOWV=$((T0 + 300)) ap tick
check "$(wc -l < "$ST/events.jsonl")" "$E1" "idempotent tick: no new event"
check "$(wc -l < "$APD/ledger.tsv")" "$L1" "idempotent tick: no ledger row"
check "$(ls "$APD/queue" 2>/dev/null | wc -l)" "$Q1" "idempotent tick: queue unchanged"
check "$(sed 's/"lastTickAt":"[^"]*"//' "$APD/status.json")" "$S1" "idempotent tick: status.json differs only in lastTickAt"

# ---------- 4. manager turn: trigger, fingerprint skip, gap ----------
B="$(t new "Blocked thing" --writable src --done-when "x")"; t set "$B" status=blocked
TB="$(events autopilot_turn_start)"; NOWV=$((T0 + 400)) ap tick; waitruns
T1="$(events autopilot_turn_start)"
check "$T1" "$((TB + 1))" "manager turn started for a blocked task"
ls "$APD/turns/"*.prompt.md >/dev/null 2>&1 && ok "turn prompt written" || bad "no turn prompt"
PF="$(ls "$APD/turns/"*.prompt.md | tail -n 1)"
has "$(cat "$PF")" "# SubDeck autopilot turn" "prompt header"
has "$(cat "$PF")" "You are headless" "prompt carries the rules file"
for s in "## Limits now" "## Tasks" "## Ready" "## Queue and active runs" "## Needs attention" "## Since last turn" "## Last digest" "## Final reply"; do has "$(cat "$PF")" "$s" "prompt section $s"; done
NOWV=$((T0 + 460)) ap tick; waitruns
check "$(events autopilot_turn_end)" "$T1" "turn end recorded"
has "$(lastevent autopilot_turn_end)" '"status":"ok"' "turn end status ok"
NOWV=$((T0 + 520)) ap tick
check "$(events autopilot_turn_start)" "$T1" "same fingerprint: no new turn"
pset autopilot.manager-gap=60
t set "$B" title="Blocked thing 2"
NOWV=$((T0 + 580)) ap tick
check "$(events autopilot_turn_start)" "$T1" "manager gap: no turn inside the gap"
NOWV=$((T0 + 580 + 3600)) ap tick; waitruns
check "$(events autopilot_turn_start)" "$((T1 + 1))" "after the gap and a changed fingerprint: a new turn"
NOWV=$((T0 + 4300)) ap tick; waitruns
pset autopilot.manager-gap=0
# dirty manager worktree -> manual pause
echo dirt > "$APWT/dirt.txt"
t set "$B" title="Blocked thing 3"
NOWV=$((T0 + 4400)) ap tick; waitruns
NOWV=$((T0 + 4460)) ap tick
has "$(cat "$APD/status.json")" '"manager-dirty"' "dirty autopilot worktree after a turn -> manager-dirty pause"
has "$(cat "$APD/status.json")" '"state":"paused"' "manager-dirty pauses the loop"
rm -f "$APWT/dirt.txt"; ap resume >/dev/null
NOWV=$((T0 + 4500)) ap tick; waitruns
hasnt "$(cat "$APD/status.json")" '"manager-dirty"' "resume clears manager-dirty"
t set "$B" status=open; t done "$B" --force >/dev/null 2>&1
fi

if want queue; then
# ---------- 5. queue: validation, max-parallel, max-runs-day ----------
mkproj p3; pset autopilot.enabled=on autopilot.max-parallel=1 autopilot.max-runs-day=2
X1="$(t new "x1" --writable src --done-when d)"; X2="$(t new "x2" --writable src --done-when d)"; X3="$(t new "x3" --writable src --done-when d)"
export FAKE_CLI_SLEEP=3
NOWV=$T0 ap tick
check "$(events autopilot_launch)" "1" "max-parallel 1: one launch"
check "$(ls "$APD/queue" | wc -l | tr -d ' ')" "2" "the other two stay queued"
OUT="$(ap launch worker "$X2")"; has "$OUT" "refused: already queued" "launch: already queued refused"
NOWV=$((T0 + 1)) ap tick
check "$(events autopilot_launch)" "1" "slot busy: still one launch"
waitruns; unset FAKE_CLI_SLEEP
NOWV=$((T0 + 60)) ap tick; waitruns
check "$(events autopilot_launch)" "2" "slot free: the next one launches"
NOWV=$((T0 + 120)) ap tick; waitruns
check "$(events autopilot_launch)" "2" "max-runs-day 2: no third launch today"
NOWV=$((T0 + 86400)) ap tick; waitruns
check "$(events autopilot_launch)" "3" "next day: the third launches"
# a queue entry that became invalid is dropped
X4="$(t new "x4" --writable src --done-when d)"; : > "$APD/queue/$T0-0000-$X4-worker"; t ask "$X4" --by user "wait?"
NOWV=$((T0 + 86500)) ap tick
has "$(lastevent autopilot_queue)" "\"result\":\"dropped\"" "invalid queue entry dropped"
[ ! -e "$APD/queue/$T0-0000-$X4-worker" ] && ok "dropped entry deleted" || bad "dropped entry still there"
OUT="$(ap launch worker "$X4")"; has "$OUT" "refused: needs-user" "needs-user task never launched"
fi

if want stuck; then
# ---------- 6. stuck detection, orphan, report_missing ----------
mkproj p4; pset autopilot.enabled=on autopilot.stuck-minutes=5 autopilot.max-parallel=8
S="$(t new "stuck" --writable src --done-when d)"
export FAKE_CLI_HANG=1
NOWV=$T0 ap tick; unset FAKE_CLI_HANG
i=0; while [ -z "$(ls "$ST/runs/$S/"*.json 2>/dev/null)" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
sleep 1
NOWV=$((T0 + 120)) ap tick
check "$(events autopilot_stuck)" "0" "not stuck before stuck-minutes"
NOWV=$(( $(date +%s) + 400 )) ap tick
check "$(events autopilot_stuck)" "1" "no growth for stuck-minutes -> stuck event"
has "$(lastevent autopilot_stuck)" '"reason":"no-growth"' "stuck reason no-growth"
waitruns
NOWV=$(( $(date +%s) + 460 )) ap tick
check "$(field "$S" status)" "interrupted" "stuck run cancelled -> task interrupted"
check "$(field "$S" strikes)" "1" "stuck run -> one strike"
t show "$S" --section handoff | grep -q 'interrupted' && ok "stuck: Handoff written" || bad "stuck: no Handoff"
# orphan: a running meta whose pid is gone
O="$(t new "orphan" --writable src --done-when d)"; t set "$O" status=in-progress
mkdir -p "$ST/runs/$O"; printf '{"version":1,"task":"%s","role":"worker","class":"worker","tool":"codex","model":"","runId":"run-%s-20251009T000000Z","pid":999999,"startedAt":"2025-10-09T00:00:00Z","endedAt":null,"status":"running"}\n' "$O" "$O" > "$ST/runs/$O/20251009T000000Z.json"
NOWV=$(( $(date +%s) + 500 )) ap tick
check "$(field "$O" status)" "interrupted" "orphaned run -> interrupted"
check "$(field "$O" strikes)" "1" "orphan -> strike"
has "$(grep "run-$O-" "$APD/ledger.tsv")" "orphaned" "orphan ledger row"
# report_missing: an ok run whose reply had no report
R="$(t new "nore" --writable src --done-when d)"
export FAKE_CLI_REPLY=no-report.txt
NOWV=$(( $(date +%s) + 600 )) ap tick; waitruns; unset FAKE_CLI_REPLY
NOWV=$(( $(date +%s) + 660 )) ap tick
check "$(field "$R" strikes)" "1" "report_missing -> strike"
check "$(field "$R" status)" "interrupted" "report_missing -> interrupted"

# ---------- 7. 3-strike rule (strikes and needsFixes) ----------
K="$(t new "three" --writable src --done-when d)"
t strike "$K" --reason failed --run r1 >/dev/null; t strike "$K" --reason failed --run r2 >/dev/null; t strike "$K" --reason failed --run r3 >/dev/null
NOWV=$(( $(date +%s) + 700 )) ap tick
check "$(field "$K" status)" "needs-user" "strikes >= 3 -> needs-user"
has "$(field "$K" question)" "3 failed attempts (3 stuck/failed runs, 0 verifier Needs fixes)" "3-strike question"
t answer "$K" "retry once more" >/dev/null
NOWV=$(( $(date +%s) + 760 )) ap tick
hasnt "$(field "$K" status)" "needs-user" "answered: not asked again at the same counts"
fi
if want verify3; then
mkproj p5; pset autopilot.enabled=on
V="$(t new "verify thrice" --writable src --done-when d)"
export FAKE_CLI_TOUCH=src/v.js FAKE_CLI_COMMIT=1
NOWV=$T0 ap tick; waitruns; unset FAKE_CLI_TOUCH FAKE_CLI_COMMIT
export FAKE_CLI_REPLY_VERIFIER=verifier-needs-fixes.txt
n=0; while [ $n -lt 3 ]; do
  NOWV=$((T0 + 100 + n * 300)) ap tick; waitruns          # verifier (or worker after fixes)
  NOWV=$((T0 + 150 + n * 300)) ap tick; waitruns          # verdict -> open; worker relaunched
  n=$((n + 1))
done
unset FAKE_CLI_REPLY_VERIFIER
for k in 1 2 3 4; do NOWV=$((T0 + 1200 + k * 60)) ap tick; waitruns; [ "$(field "$V" status)" = needs-user ] && break; done
check "$(field "$V" status)" "needs-user" "three verifier Needs fixes -> needs-user"
has "$(t show "$V" --section task)" "verifier findings" "Needs fixes findings appended to Task"
has "$(field "$V" question)" "3 verifier Needs fixes" "question names the verifier failures"
OUT="$(ap launch worker "$V")"; has "$OUT" "refused: needs-user" "needs-user task never launched"
fi

if want budget; then
# ---------- 8. budget: tokens per day, pause and resume at day rollover ----------
mkproj p6; pset autopilot.enabled=on autopilot.budget.tokens-day=100
U1="$(t new "u1" --writable src --done-when d)"
export FAKE_CLI_USAGE=80,40
NOWV=$T0 ap tick; waitruns; unset FAKE_CLI_USAGE
U2="$(t new "u2" --writable src --done-when d)"
NOWV=$((T0 + 60)) ap tick
has "$(grep "$U1" "$APD/ledger.tsv")" "	80	40	true" "ledger row carries fake usage"
has "$(cat "$APD/status.json")" '"state":"paused"' "tokens-day reached -> paused"
has "$(cat "$APD/status.json")" '"budget-day"' "reason budget-day"
has "$(cat "$APD/status.json")" '"tokens":120,"tokensLimit":100' "status budget tokens"
has "$(lastevent autopilot_budget)" '"action":"pause"' "autopilot_budget pause event"
check "$(events autopilot_launch)" "1" "paused: nothing new launched"
DAY2=$(( (T0 / 86400 + 1) * 86400 + 60 ))
NOWV=$DAY2 ap tick; waitruns
has "$(lastevent autopilot_budget)" '"action":"resume"' "next local day: budget resume"
[ "$(events autopilot_launch)" -gt 1 ] && ok "after rollover the queue moves again" || bad "no launch after the budget day rollover"

# ---------- 9. quota pause: retry-after, backoff, reset on ok; auth manual pause ----------
mkproj p7; pset autopilot.enabled=on
Q="$(t new "q" --writable src --done-when d)"
export FAKE_CLI_MODE=quota FAKE_CLI_QUOTA_MSG="Error: 429 rate limit, retry after 120s"
NOWV=$T0 ap tick; waitruns
NOWV=$((T0 + 10)) ap tick
PA="$(cat "$APD/status.json")"
has "$PA" '"kind":"quota","tool":"codex"' "quota run -> codex paused"
has "$(lastevent autopilot_quota)" '"attempts":1,"action":"pause"' "quota event attempts 1"
UNT="$(grep -o 'quota:codex:[0-9]*' "$APD/state.txt" | cut -d: -f3)"
[ "$UNT" -ge $((T0 + 10 + 120)) ] && [ "$UNT" -lt $((T0 + 10 + 240)) ] && ok "retry-after 120 s (+ jitter < 120 s)" || bad "retry-after until $UNT"
check "$(field "$Q" strikes)" "" "quota never strikes"
NOWV=$((T0 + 60)) ap tick
check "$(events autopilot_launch)" "1" "codex paused: no launch"
unset FAKE_CLI_QUOTA_MSG
NOWV=$((T0 + 400)) ap tick; waitruns
has "$(lastevent autopilot_quota)" '"action":"resume"' "quota pause expires -> resume"
NOWV=$((T0 + 460)) ap tick
UNT="$(grep -o 'quota:codex:[0-9]*:[0-9]*' "$APD/state.txt")"
A2="${UNT##*:}"; U2T="$(printf '%s' "$UNT" | cut -d: -f3)"
check "$A2" "2" "second quota: attempts 2"
[ "$U2T" -ge $((T0 + 460 + 3600)) ] && [ "$U2T" -lt $((T0 + 460 + 3720)) ] && ok "unknown reset: backoff 30 min * 2" || bad "backoff until $U2T"
unset FAKE_CLI_MODE
NOWV=$((T0 + 460 + 3800)) ap tick; waitruns
NOWV=$((T0 + 460 + 3860)) ap tick
has "$(grep -o 'quota:codex:[0-9]*:[0-9]*' "$APD/state.txt")" ":0" "ok run resets the attempts"
mkproj p8; pset autopilot.enabled=on
AU="$(t new "auth" --writable src --done-when d)"
export FAKE_CLI_MODE=auth
NOWV=$T0 ap tick; waitruns; unset FAKE_CLI_MODE
NOWV=$((T0 + 60)) ap tick
has "$(cat "$APD/status.json")" '"auth:codex"' "auth -> manual pause auth:codex"
NOWV=$((T0 + 99999)) ap tick
has "$(cat "$APD/status.json")" '"auth:codex"' "auth pause does not clear by time"
ap resume --tool codex >/dev/null
NOWV=$((T0 + 100000)) ap tick; waitruns
hasnt "$(cat "$APD/status.json")" '"auth:codex"' "resume --tool clears auth"
fi

if want killint; then
# ---------- 10. kill switch during work, stop --now, quiet hours ----------
mkproj p9; pset autopilot.enabled=on autopilot.quiet-hours=08-10
QH="$(t new "quiet" --writable src --done-when d)"
NOWV=$T0 ap tick
has "$(cat "$APD/status.json")" '"quiet"' "quiet hours (08:53 UTC inside 08-10) -> reason quiet"
check "$(events autopilot_launch)" "0" "quiet hours: no launch"
pset autopilot.quiet-hours=22-07
NOWV=$T0 ap tick
check "$(events autopilot_launch)" "1" "outside a wrapping window: launch"
waitruns
export FAKE_CLI_HANG=1
QH2="$(t new "hang" --writable src --done-when d)"
NOWV=$((T0 + 60)) ap tick
i=0; while [ -z "$(ls "$ST/runs/$QH2/"*.json 2>/dev/null)" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
unset FAKE_CLI_HANG
ap stop --now >/dev/null
waitruns && ok "stop --now ends the active run" || bad "active run still running after stop --now"
grep -q '"status":"cancelled"' "$ST/runs/$QH2/"*.json && ok "stopped run is cancelled" || bad "run not cancelled"
NOWV=$((T0 + 120)) ap tick
check "$(field "$QH2" strikes)" "" "stop --now never strikes"
OUT="$(ap launch worker "$QH2")"; has "$OUT" "refused: stopped" "launch refused under the kill switch"
rm -f "$APD/STOP"

# ---------- 11. integration: cherry-pick, conflict, changed-after-verify ----------
mkproj p10; pset autopilot.enabled=on
ap start >/dev/null 2>&1; ap stop >/dev/null; i=0; while [ -f "$APD/loop.pid" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done; rm -f "$APD/STOP"
APWT="$ST/worktrees/_autopilot"
mkdone() { # title file content -> id; worker commits <file>, verifier Approved at the branch tip, done
  local id; id="$(t new "$1" --writable "$2" --done-when d)"
  FAKE_CLI_TOUCH="$2" FAKE_CLI_COMMIT=1 SUBDECK_AUTOPILOT=1 SUBDECK_AUTOPILOT_LAUNCH=1 SUBDECK_RUN_BASE="$("$REALGIT" -C "$APWT" rev-parse --abbrev-ref HEAD)" bash "$PL/scripts/run.sh" --project "$P" worker "$id" >/dev/null 2>&1
  FAKE_CLI_REPLY=verifier-approved-head.txt bash "$PL/scripts/run.sh" --project "$P" verifier "$id" >/dev/null 2>&1
  t done "$id" >/dev/null 2>&1
  printf '%s' "$id"
}
C1="$(mkdone "c1" src/c1.js)"
echo other > "$APWT/other.txt"; "$REALGIT" -C "$APWT" add other.txt; "$REALGIT" -C "$APWT" commit -qm "other work on the autopilot branch"
NOWV=$T0 ap tick
has "$(cat "$APD/integrated.tsv")" "$C1	picked" "diverged branch: cherry-pick"
"$REALGIT" -C "$APWT" log -1 --format=%B | grep -q "cherry picked from commit" && ok "cherry-pick -x keeps the source" || bad "no -x trailer"
C2="$(mkdone "c2" src/s.js)"
echo conflict > "$APWT/src/s.js"; "$REALGIT" -C "$APWT" commit -qam "conflicting change"
NOWV=$((T0 + 60)) ap tick
has "$(cat "$APD/integrated.tsv")" "$C2	conflict" "conflict recorded"
[ -z "$("$REALGIT" -C "$APWT" status --porcelain)" ] && ok "conflict: cherry-pick aborted, worktree clean" || bad "worktree dirty after conflict"
has "$(t list)" "Integrate $C2" "conflict -> a new task"
has "$(t list --status needs-user)" "Integrate $C2" "the new task waits for the user"
C3="$(mkdone "c3" src/c3.js)"
"$REALGIT" -C "$ST/worktrees/$C3" commit -q --allow-empty -m "after verify"
NOWV=$((T0 + 120)) ap tick
has "$(cat "$APD/integrated.tsv")" "$C3	changed-after-verify" "commit after the verdict -> changed-after-verify"
NOWV=$((T0 + 180)) ap tick
check "$(grep -c "	$C3	" "$APD/integrated.tsv")" "1" "integration attempted once per task"

# ---------- 12. digest + notify once per date ----------
pset autopilot.digest-hour=8
NOWV=$T0 ap tick
DG="$APD/digest/2025-10-09.md"
[ -f "$DG" ] && ok "digest file written" || bad "digest missing"
for s in "# Autopilot digest 2025-10-09 (p10)" "## Needs you" "## Done and verified" "## In review" "## Interrupted or blocked" "## Budget" "## Branch" "## Manager notes"; do has "$(cat "$DG")" "$s" "digest section $s"; done
has "$(cat "$DG")" "Integrate $C2" "digest lists the needs-user task"
has "$(cat "$DG")" "$C1 c1 (picked)" "digest lists done task with integration result"
DN="$(events autopilot_digest)"
NOWV=$((T0 + 3600)) ap tick
check "$(events autopilot_digest)" "$DN" "digest notified once per date"
has "$(lastevent autopilot_digest)" '"notified":true' "digest notification attempted (notify dry-run keeps no log)"
has "$(cat "$APD/status.json")" '"digests":["2025-10-09"]' "status lists digests"
fi

if want final; then
# ---------- 13. status command, dry-run writes nothing, no push, checkout untouched ----------
mkproj p11; pset autopilot.enabled=on
U_BEFORE="$("$REALGIT" -C "$P" rev-parse HEAD) $("$REALGIT" -C "$P" rev-parse --abbrev-ref HEAD) $("$REALGIT" -C "$P" status --porcelain | wc -l | tr -d ' ')"
ap start >/dev/null 2>&1; ap stop >/dev/null; i=0; while [ -f "$APD/loop.pid" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done; rm -f "$APD/STOP"
Z1="$(t new "z1" --writable src --done-when d)"; Z2="$(t new "z2" --writable src --done-when d)"; t ask "$Z2" --by user "which one?"
NOWV=$T0 ap tick; waitruns
NOWV=$((T0 + 60)) ap tick; waitruns
OUT="$(ap status)"; check "$?" "0" "status exit 0 when enabled"
has "$OUT" "autopilot: " "status: state line"
has "$OUT" "needs you: $Z2" "status: needs-user list"
J="$(ap status --json)"
if command -v node >/dev/null 2>&1; then
  printf '%s' "$J" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));if(j.version!==1||!Array.isArray(j.needsUser))process.exit(1)' && ok "status --json is valid JSON" || bad "status --json invalid"
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$APD/status.json" && ok "status.json is valid JSON" || bad "status.json invalid"
fi
treehash() { (cd "$ST" && find . -type f ! -name '*.log' -print0 | sort -z | xargs -0 cksum | cksum); }
H1="$(treehash)"; NOWV=$((T0 + 7200)) ap dry-run >/dev/null; check "$(treehash)" "$H1" "dry-run writes nothing (state tree unchanged)"
pset autopilot.enabled=off
ap status >/dev/null; check "$?" "2" "status exit 2 when not enabled"
check "$(wc -c < "$W/push.log" | tr -d ' ')" "0" "no git push ever"
check "$("$REALGIT" -C "$P" rev-parse HEAD) $("$REALGIT" -C "$P" rev-parse --abbrev-ref HEAD) $("$REALGIT" -C "$P" status --porcelain | wc -l | tr -d ' ')" "$U_BEFORE" "user's checkout untouched after autopilot work"
check "$("$REALGIT" -C "$P" log --oneline | wc -l | tr -d ' ')" "1" "user's branch has no autopilot commits"
fi

if want start2; then
# ---------- 14. bash 3.2 rules ----------
for pat in 'wait -n' '\$\{[A-Za-z_]+,,\}' '\$\{[A-Za-z_]+\^\^\}' 'declare -A' 'local -A' 'mapfile' 'readarray' 'EPOCHSECONDS' 'local -n' 'declare -n' '[^-]timeout [0-9]' '\|&' '&>>'; do
  if grep -En "$pat" "$AP_SH" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then bad "autopilot.sh uses '$pat'"; else ok "autopilot.sh avoids '$pat'"; fi
done
grep -qw 'jq' "$AP_SH" && bad "autopilot.sh mentions jq" || ok "autopilot.sh needs no jq"
grep -nE 'git .*push' "$AP_SH" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null && bad "autopilot.sh runs git push" || ok "autopilot.sh has no git push"
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]'; then
  /bin/bash -n "$AP_SH" && ok "parses under /bin/bash 3.x" || bad "syntax error under /bin/bash 3.x"
fi
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
