#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-run.sh   (run.sh headless runs; fake CLIs only, never a real CLI or the network)
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$HERE/.."
RUN="$PL/scripts/run.sh"
TS="$PL/scripts/tasks.sh"
FAKE="$HERE/fixtures/fake-cli"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2')"; printf '%s\n' "$1" | head -n 40 | sed 's/^/     | /' ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (found '$2')" ;; *) ok "$3" ;; esac; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export SUBDECK_STATE_DIR="$W/state" HOME="$W/home" SUBDECK_ROLES_DIR="$W/roles" SUBDECK_NOTIFY_OS=linux
unset SUBDECK_TASKS_DIR SUBDECK_TASKS SUBDECK_NOTIFY CLAUDE_PROJECT_DIR SUBDECK_PROJECT SUBDECK_RUN SUBDECK_TASK SUBDECK_ROLE
unset FAKE_CLI_LOG FAKE_CLI_REPLY FAKE_CLI_EXIT FAKE_CLI_STDERR FAKE_CLI_SLEEP FAKE_CLI_TOUCH FAKE_CLI_COMMIT FAKE_CLI_MODE
# the env may carry git config entries (GIT_CONFIG_COUNT); start clean so the push blocker lands at index 0
i=0; while [ $i -lt 20 ]; do unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"; i=$((i+1)); done; unset GIT_CONFIG_COUNT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
mkdir -p "$HOME/.subdeck" "$W/roles" "$W/bin"
for c in worker researcher verifier; do printf '# SubDeck %s rules\nstub %s rulebook line\n' "$c" "$c" > "$W/roles/$c.md"; done
export PATH="$FAKE/bin:$PATH"
# fake CLIs must win over any real CLI on PATH
[ "$(command -v codex)" = "$FAKE/bin/codex" ] && [ "$(command -v claude)" = "$FAKE/bin/claude" ] && ok "fake CLIs first on PATH" || bad "fake CLIs not first on PATH"

P="$W/proj"; mkdir -p "$P/src"; git -C "$P" init -q
echo base > "$P/a.txt"; echo src > "$P/src/s.js"; git -C "$P" add a.txt src/s.js; git -C "$P" commit -qm base
INITBR="$(git -C "$P" rev-parse --abbrev-ref HEAD)"
ST="$( . "$PL/scripts/lib-paths.sh"; sd_state_dir "$P"; printf '%s' "$SD_STATE" )"
t() { bash "$TS" --project "$P" "$@"; }
r() { bash "$RUN" --project "$P" "$@"; }
field() { t show "$1" | sed -n "s/^$2: //p" | head -n 1; }
ucfg() { printf '%s' "$1" > "$HOME/.subdeck/config.json"; }
pcfg() { mkdir -p "$ST"; printf '%s' "$1" > "$ST/config.json"; }
lastmeta() { local f="" x; for x in "$ST/runs/$1"/*.json; do [ -f "$x" ] && f="$x"; done; cat "$f" 2>/dev/null; }
mval() { lastmeta "$1" | tr -d '\n' | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\).*/\1/p"; }
events() { local n; n="$(grep -c "\"event\":\"$1\"" "$ST/events.jsonl" 2>/dev/null)"; echo "${n:-0}"; }
lastevent() { grep "\"event\":\"$1\"" "$ST/events.jsonl" 2>/dev/null | tail -n 1; }
newtask() { t new "${1:-job}" --writable "${2-a.txt,src}"; }
ROLES_ALL='{"roles":{"worker":{"tool":"codex","model":"gpt-5-codex"},"verifier":{"tool":"claude","model":"opus"},"researcher":{"tool":"gemini","model":"gemini-2.5-pro"}}}'

# ---------- 1. roles ----------
ucfg '{"roles":{"worker":{"tool":"codex","model":"gpt-5-codex","timeout":900},"ui-worker":{"tool":"custom","cmd":"mytool --in {prompt_file}"},"BAD NAME":{"tool":"codex"}}}'
OUT="$(r roles)"
check "$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')" "manager worker worker-heavy researcher verifier ui-worker " "roles: fixed roles first, then free roles (invalid names skipped)"
check "$(printf '%s\n' "$OUT" | grep '^worker	')" "worker	worker	codex	gpt-5-codex	900	user" "roles TSV: mapped worker from user config"
check "$(printf '%s\n' "$OUT" | grep '^researcher	')" "researcher	researcher	-	-	1800	default" "roles TSV: unmapped role shows tool -"
check "$(printf '%s\n' "$OUT" | grep '^ui-worker	' | cut -f2,3)" "worker	custom" "free role class worker"
pcfg '{"roles":{"worker":{"tool":"claude"}}}'
check "$(r roles | grep '^worker	')" "worker	worker	claude	-	1800	project" "per role whole object: project worker replaces user worker (model and timeout not mixed)"
J="$(r roles --json)"
has "$J" '{"role":"worker","class":"worker","tool":"claude","model":"","args":"","timeout":1800,"source":"project","mapped":true}' "roles --json row"
has "$J" '{"role":"manager","class":"manager","tool":"","model":"","args":"","timeout":1800,"source":"default","mapped":false}' "roles --json manager unmapped"
if command -v node >/dev/null 2>&1; then
  printf '%s' "$J" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' && ok "roles --json is valid JSON" || bad "roles --json invalid"
fi
pcfg '{}'; ucfg '{"roles":{"researcher-deep":{"tool":"gemini"},"research-x":{"tool":"gemini"},"verifier-2":{"tool":"codex"}}}'
check "$(r roles | awk -F'\t' 'NR>5{print $1":"$2}' | tr '\n' ' ')" "research-x:researcher researcher-deep:researcher verifier-2:verifier " "class from the role name prefix"

# ---------- 2. dry-run argv per tool ----------
TD="$(newtask "dry")"
dry_argv() { r "$@" --dry-run 2>/dev/null | awk '/^argv:$/{f=1;next} /^env:$/{f=0} f'; }
norm() { # replace run-specific paths with the placeholders of expected/<tool>.argv
  sed -e "s#$ST/worktrees/$TD#<cwd>#g" -e "s#$P#<cwd>#g" -e "s#$ST/runs/$TD/[0-9TZ]*\.last\.txt#<last_file>#g" -e "s#$ST/runs/$TD/[0-9TZ]*\.prompt\.md#<prompt_file>#g"
}
for spec in claude:opus codex:gpt-5-codex gemini:gemini-2.5-pro opencode:anthropic/claude-sonnet-4 copilot:gpt-5 agy:gemini-3-pro; do
  tool="${spec%%:*}"; model="${spec#*:}"
  ucfg "{\"roles\":{\"worker\":{\"tool\":\"$tool\",\"model\":\"$model\"}}}"
  check "$(dry_argv worker "$TD" | norm)" "$(cat "$FAKE/expected/$tool.argv")" "dry-run argv: $tool"
done
ucfg '{"roles":{"worker":{"tool":"custom","model":"my-model","cmd":"mytool --model {model} --in {prompt_file}"}}}'
check "$(dry_argv worker "$TD" | norm)" "$(cat "$FAKE/expected/custom.argv")" "dry-run argv: custom (placeholders single-quoted)"
ucfg '{"roles":{"worker":{"tool":"codex"}}}'
hasnt "$(dry_argv worker "$TD")" "-m" "no model set: no model flag"
ucfg '{"roles":{"worker":{"tool":"codex","model":"m1","args":"--foo a{sp}b -c x=1"}}}'
check "$(dry_argv worker "$TD" | norm | tr '\n' '|')" "codex|exec|-C|<cwd>|-m|m1|-s|workspace-write|--json|-o|<last_file>|--foo|a b|-c|x=1|-|" "user args in their slot, {sp} is a literal space"
ucfg '{"roles":{"worker":{"tool":"opencode"}}}'
DRY="$(r worker "$TD" --dry-run)"; RC=$?
check "$RC" "0" "dry-run exits 0"
has "$DRY" "env:
SUBDECK_RUN=1
SUBDECK_TASK=$TD
SUBDECK_ROLE=worker
SUBDECK_PROJECT=$P
CLAUDE_PROJECT_DIR=$ST/worktrees/$TD
GIT_TERMINAL_PROMPT=0
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0=url.subdeck-no-push://.pushInsteadOf
GIT_CONFIG_VALUE_0=
OPENCODE_PERMISSION={\"bash\":{\"*\":\"allow\",\"git push*\":\"deny\"},\"edit\":\"allow\",\"external_directory\":\"deny\"}" "dry-run env: run vars, push blocker, profile env"
has "$DRY" "worktree: $ST/worktrees/$TD (create)" "dry-run names the worktree it would create"
has "$DRY" "branch: subdeck/$TD" "dry-run branch"
has "$DRY" "timeout: 1800" "dry-run default timeout"
[ ! -e "$ST/runs" ] && [ ! -e "$ST/worktrees" ] && ok "dry-run creates nothing" || bad "dry-run created files"
check "$(field "$TD" status)" "open" "dry-run changes no status"
check "$(events run_start)$(events run_refused)" "00" "dry-run logs no events"
check "$(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=a.b GIT_CONFIG_VALUE_0=1 GIT_CONFIG_KEY_1=c.d GIT_CONFIG_VALUE_1=2 r worker "$TD" --dry-run | grep '^GIT_CONFIG' | tr '\n' ' ')" "GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_2=url.subdeck-no-push://.pushInsteadOf GIT_CONFIG_VALUE_2= " "push blocker appended after git config already in the env"

# ---------- 3. prompt sections ----------
mkdir -p "$ST"; ucfg "$ROLES_ALL"
pcfg '{"guard":{"protectPorts":["8080"],"protectProcs":["redis"]}}'
PR="$(r worker "$TD" --dry-run | sed -n '/^prompt:$/,$p' | sed 1d)"
check "$(printf '%s\n' "$PR" | head -n 1)" "Task: $TD (tasks.sh: $(cd "$PL/scripts" && pwd)/tasks.sh)" "prompt line 1: Task id + tasks.sh path"
check "$(printf '%s\n' "$PR" | sed -n 2p)" "# SubDeck run: worker (worker) via codex gpt-5-codex" "prompt line 2: run heading"
check "$(printf '%s\n' "$PR" | grep '^## ' | tr '\n' '|')" "## Rules|## Headless run|## Writable paths|## Protected resources|## Task file|## Task|## Done when|## Report|## Verification|## Handoff|## Final reply|" "prompt sections in order (task file verbatim inside)"
has "$PR" "stub worker rulebook line" "rulebook included"
has "$PR" "## Writable paths
a.txt
src
" "writable paths one per line"
has "$PR" "protect-ports: 8080
protect-procs: redis" "protected resources from settings.sh json"
has "$PR" "on branch \`subdeck/$TD\`" "headless text names cwd and branch"
has "$PR" "Stop: <done|waiting|quota|timeout|no-progress|blocked>" "worker final reply shape"
has "$PR" "Tested: ran" "worker final reply has Tested"
pcfg '{"roles":{}}'
VP="$(r verifier "$TD" --dry-run 2>/dev/null | sed -n '/^prompt:$/,$p')"
has "$VP" "none (read-only): any change is a violation" "verifier: read-only writable section"
has "$VP" "Verdict: Approved | Needs fixes | Escalate" "verifier final reply shape"
has "$VP" "## Protected resources
none" "no protected resources: none"
has "$(r researcher "$TD" --dry-run | sed -n '/^prompt:$/,$p')" "stub researcher rulebook line" "researcher rulebook"
SUBDECK_ROLES_DIR="$W/nowhere" r worker "$TD" --dry-run >/dev/null 2>&1; check "$?" "2" "missing rulebook: exit 2"

# ---------- 4. a full worker run: stdin prompt, worktree, task status, events, files ----------
T1="$(newtask "first run")"
FAKE_CLI_LOG="$W/log1" FAKE_CLI_TOUCH=a.txt,src/new.js FAKE_CLI_COMMIT=1 r worker "$T1" >/dev/null 2>"$W/err1"; RC=$?
check "$RC" "0" "worker run exits 0"
WT="$ST/worktrees/$T1"
check "$(cat "$W/log1/1.codex.cwd")" "$WT" "CLI ran in the task worktree"
check "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" "subdeck/$T1" "worktree on branch subdeck/<id>"
check "$(git -C "$P" rev-parse --abbrev-ref HEAD)" "$INITBR" "main tree branch unchanged"
check "$(git -C "$P" status --porcelain | wc -l | tr -d ' ')" "0" "main tree untouched"
PF="$(ls "$ST/runs/$T1"/*.prompt.md)"
check "$(cat "$W/log1/1.codex.stdin")" "$(cat "$PF")" "stdin tool: prompt on stdin"
grep -q '^SUBDECK_PROJECT='"$P"'$' "$W/log1/1.codex.env" && grep -q '^SUBDECK_RUN=1$' "$W/log1/1.codex.env" && grep -q "^CLAUDE_PROJECT_DIR=$WT\$" "$W/log1/1.codex.env" && ok "child env carries the run vars" || bad "child env: $(cat "$W/log1/1.codex.env")"
check "$(field "$T1" status)" "review" "Stop: done -> review"
check "$(field "$T1" role)|$(field "$T1" tool)|$(field "$T1" model)|$(field "$T1" branch)|$(field "$T1" worktree)" "worker|codex|gpt-5-codex|subdeck/$T1|$WT" "task records role tool model branch worktree"
case "$(field "$T1" run)" in "$ST/runs/$T1/"*.log) ok "task run= points at the log" ;; *) bad "task run= $(field "$T1" run)" ;; esac
has "$(t show "$T1")" "final reply (worker-run run-$T1-" "final reply appended to Report"
M="$(lastmeta "$T1")"
for k in '"status":"ok"' '"cliExit":0' '"exit":0' '"commits":1' '"uncommitted":0' '"writableCheck":"ok"' '"violations":[]' '"sessionId":"fake-thread-0001"' '"agent":"worker-run"' "\"branch\":\"subdeck/$T1\"" "\"worktree\":\"$WT\"" '"experimental":false' "\"project\":\"$P\""; do
  has "$M" "$k" "meta $k"
done
check "$(mval "$T1" base)" "$(git -C "$P" rev-parse HEAD)" "meta base = project HEAD at creation"
if command -v node >/dev/null 2>&1; then lastmeta "$T1" | node -e 'JSON.parse(require("fs").readFileSync(0,"utf8"))' && ok "meta is valid JSON" || bad "meta invalid JSON"; fi
B="$(ls "$ST/runs/$T1"/*.json)"; B="${B%.json}"
for x in log out prompt.md final.txt last.txt json; do [ -f "$B.$x" ] && ok "run file .$x" || bad "run file .$x missing"; done
has "$(cat "$B.final.txt")" "Stop: done - fake run finished" "final message from the codex -o file"
has "$(cat "$B.log")" "[subdeck] run run-$T1-" "log header"
has "$(cat "$B.log")" "[subdeck] end status=ok" "log footer"
[ ! -d "$ST/runs/$T1/.lock" ] && ok "lock released" || bad "lock left behind"
check "$(events run_start) $(events run_end)" "1 1" "run_start and run_end events"
has "$(lastevent run_start)" "\"agent_type\":\"worker-run\"" "run_start agent_type"
has "$(lastevent run_start)" '"modelCheck":"n/a"' "run_start modelCheck n/a for a worker"
has "$(lastevent run_end)" '"status":"ok","cliExit":0,"exit":0' "run_end status"
has "$(lastevent task_status)" "\"to\":\"review\"" "task_status event from the hook"

# reuse: a second run in the same worktree (no reset)
echo keep > "$WT/untracked-keep.txt"
FAKE_CLI_LOG="$W/log1b" r worker "$T1" >/dev/null 2>&1; RC=$?
check "$RC" "0" "second run: a pre-existing untracked file outside writable is not blamed"
check "$(cat "$W/log1b/1.codex.cwd")" "$WT" "worktree reused"
[ -f "$WT/untracked-keep.txt" ] && ok "reuse does not reset the worktree" || bad "worktree was reset"

# ---------- 5. writable violation ----------
T2="$(newtask "violation" "src")"
FAKE_CLI_TOUCH=src/ok.js,secret.txt,deep/x/y.txt r worker "$T2" >/dev/null 2>"$W/err2"; RC=$?
check "$RC" "5" "violation: exit 5"
check "$(field "$T2" status)" "blocked" "violation: task blocked"
B2="$(t show "$T2")"
has "$B2" "writable violation (worker codex)
deep/x/y.txt
secret.txt" "violation block in Report with the paths"
hasnt "$(printf '%s\n' "$B2" | sed -n '/writable violation/,/^$/p')" "src/ok.js" "allowed path not listed"
has "$(lastevent writable_violation)" '"paths":["deep/x/y.txt","secret.txt"],"count":2' "writable_violation event"
has "$(lastmeta "$T2")" '"status":"violation"' "meta status violation"
has "$(lastmeta "$T2")" '"writableCheck":"violation","violations":["deep/x/y.txt","secret.txt"]' "meta violations"
[ -f "$ST/worktrees/$T2/secret.txt" ] && ok "nothing reverted" || bad "violation reverted a file"
has "$(cat "$W/err2")" "writable violation" "violation reported on stderr"
# glob items: * crosses /
T2b="$(newtask "glob" "docs/*.md,lib/**")"
FAKE_CLI_TOUCH=docs/a.md,docs/sub/b.md,lib/x/y.js FAKE_CLI_COMMIT=1 r worker "$T2b" >/dev/null 2>&1; check "$?" "0" "glob writable items match (* crosses /), committed changes checked"
# committed change outside writable is caught too
T2c="$(newtask "committed" "src")"
FAKE_CLI_TOUCH=outside.txt FAKE_CLI_COMMIT=1 r worker "$T2c" >/dev/null 2>&1; check "$?" "5" "committed change outside writable: violation"
has "$(lastmeta "$T2c")" '"commits":1' "meta counts the commit"

# ---------- 6. exit classes and task transitions ----------
T3="$(newtask "quota")"
FAKE_CLI_MODE=quota r worker "$T3" >/dev/null 2>&1; check "$?" "7" "quota: exit 7"
check "$(field "$T3" status)" "interrupted" "quota -> interrupted"
has "$(t show "$T3")" "interrupted (rate_limit)" "quota: Handoff block with rate_limit"
has "$(lastmeta "$T3")" '"status":"quota","cliExit":1,"exit":7' "meta quota"
T4="$(newtask "auth")"
FAKE_CLI_MODE=auth r worker "$T4" >/dev/null 2>"$W/err4"; check "$?" "6" "auth (regex): exit 6"
check "$(field "$T4" status)" "interrupted" "auth -> interrupted"
has "$(t show "$T4")" "interrupted (auth)" "auth: Handoff error type"
has "$(cat "$W/err4")" "codex login" "auth hint from the profile on stderr"
ucfg '{"roles":{"worker":{"tool":"gemini"}}}'
T4b="$(newtask "auth code")"; : > "$W/empty.txt"
FAKE_CLI_EXIT=41 FAKE_CLI_REPLY="$W/empty.txt" r worker "$T4b" >/dev/null 2>&1; check "$?" "6" "auth by exit code (gemini 41) without matching text"
: > "$W/empty.txt"
ucfg "$ROLES_ALL"
T5="$(newtask "failed")"
FAKE_CLI_EXIT=3 FAKE_CLI_REPLY="$W/empty.txt" r worker "$T5" >/dev/null 2>&1; check "$?" "1" "failed: exit 1"
check "$(field "$T5" status)" "interrupted" "failed with no final message -> interrupted"
has "$(t show "$T5")" "interrupted (cli_error)" "failed: cli_error"
has "$(lastmeta "$T5")" '"cliExit":3' "raw CLI exit recorded as cliExit"
T5b="$(newtask "failed with reply")"
FAKE_CLI_EXIT=2 r worker "$T5b" >/dev/null 2>&1; check "$?" "1" "failed with a final message: exit 1"
check "$(field "$T5b" status)" "review" "failed with a final message -> SubagentStop rules (Stop: done -> review)"
T6="$(newtask "no report")"
FAKE_CLI_REPLY=no-report.txt r worker "$T6" >/dev/null 2>&1; check "$?" "0" "no-report: CLI exit 0 -> run exit 0"
check "$(field "$T6" status)" "blocked" "missing report shape -> blocked"
check "$(events report_missing)" "1" "report_missing event"
T7="$(newtask "timeout")"
S0=$SECONDS
FAKE_CLI_SLEEP=31.7 r worker "$T7" --timeout 2 >/dev/null 2>&1; RC=$?
check "$RC" "124" "timeout: exit 124"
[ $((SECONDS - S0)) -le 8 ] && ok "timeout stops the CLI quickly ($((SECONDS - S0)) s)" || bad "timeout took $((SECONDS - S0)) s"
i=0; while [ $i -lt 20 ] && { pgrep -f '^sleep 31\.7$' || pgrep -f '^bash .*fake-cli\.sh codex'; } >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
{ pgrep -f '^sleep 31\.7$' || pgrep -f '^bash .*fake-cli\.sh codex'; } >/dev/null 2>&1 && bad "fake CLI or its child still running after timeout" || ok "process group killed (CLI and its child)"
check "$(field "$T7" status)" "interrupted" "timeout -> interrupted"
has "$(t show "$T7")" "interrupted (timeout)" "timeout Handoff"
has "$(lastmeta "$T7")" '"status":"timeout"' "meta timeout"
T8="$(newtask "missing bin")"
ucfg '{"roles":{"worker":{"tool":"copilot"}}}'
PATH="$W/bin:/usr/bin:/bin" r worker "$T8" >/dev/null 2>"$W/err8"; check "$?" "127" "CLI not on PATH: 127"
has "$(lastevent run_refused)" '"reason":"not-found"' "127 logs run_refused"
check "$(field "$T8" status)" "open" "refusal changes nothing"
ucfg "$ROLES_ALL"

# cancel: TERM to run.sh -> cancelled, 130
T9="$(newtask "cancel")"
FAKE_CLI_SLEEP=30 bash "$RUN" --project "$P" worker "$T9" >/dev/null 2>&1 &
RP=$!
i=0; while [ $i -lt 50 ] && ! grep -q '"status":"running"' "$ST/runs/$T9"/*.json 2>/dev/null; do sleep 0.1; i=$((i+1)); done
sleep 0.5
kill -TERM "$RP"; wait "$RP"; RC=$?
check "$RC" "130" "cancelled: exit 130"
has "$(lastmeta "$T9")" '"status":"cancelled"' "meta cancelled"
check "$(field "$T9" status)" "interrupted" "cancelled -> interrupted"

# ---------- 7. refusals ----------
T10="$(newtask "refusals")"
r manager "$T10" >/dev/null 2>&1; check "$?" "2" "manager role: exit 2"
r worker-heavy "$T10" >/dev/null 2>"$W/e"; check "$?" "2" "unmapped role: exit 2"
has "$(lastevent run_refused)" '"reason":"not-mapped"' "unmapped: run_refused not-mapped"
r worker t-ffff >/dev/null 2>&1; check "$?" "2" "unknown task: exit 2"
r worker nope >/dev/null 2>&1; check "$?" "2" "invalid task id: exit 2"
r 'Bad;role' "$T10" >/dev/null 2>&1; check "$?" "2" "invalid role name: exit 2"
TA="$(newtask "archived")"; t done "$TA" --force
r worker "$TA" >/dev/null 2>&1; check "$?" "2" "archived task: exit 2"
r worker "$T10" --timeout 0 >/dev/null 2>&1; check "$?" "2" "--timeout 0: exit 2"
r worker "$T10" --bogus >/dev/null 2>&1; check "$?" "2" "unknown option: exit 2"
for a in "--yolo" "-y" "--dangerously-bypass-approvals-and-sandbox" "--permission-mode{sp}bypassPermissions" "-s danger-full-access" "--auto" "--allow-all" "--allow-all-paths" "--no-sandbox" "--DANGEROUSLY-x"; do
  ucfg "{\"roles\":{\"worker\":{\"tool\":\"codex\",\"args\":\"--ok $a\"}}}"
  r worker "$T10" --dry-run >/dev/null 2>&1; check "$?" "2" "deny-listed args refused: $a"
done
r worker "$T10" >/dev/null 2>&1
has "$(lastevent run_refused)" '"reason":"deny-args"' "deny-args reason"
for bad in '"tool":"cursor"' '"tool":"codex","model":"bad model"' '"tool":"codex","timeout":10' '"tool":"codex","timeout":"x"' '"tool":"custom","cmd":"no placeholder"' '"tool":"custom"' '"tool":"codex","cmd":"x {prompt_file}"' '"tool":"codex","args":"a\\\"b"'; do
  ucfg "{\"roles\":{\"worker\":{$bad}}}"
  r worker "$T10" --dry-run >/dev/null 2>&1; check "$?" "2" "invalid role config refused: $bad"
done
ucfg "$ROLES_ALL"
check "$(field "$T10" status)" "open" "refusals change no status"

# busy
T11="$(newtask "busy")"
mkdir -p "$ST/runs/$T11/.lock"; printf '%s %s\n' "$$" "$(date +%s)" > "$ST/runs/$T11/.lock/owner"
r worker "$T11" >/dev/null 2>&1; check "$?" "4" "busy: exit 4"
has "$(lastevent run_refused)" '"reason":"busy"' "busy: run_refused busy"
r worker "$T11" --dry-run >/dev/null 2>&1; check "$?" "4" "dry-run reports busy too"
r cleanup "$T11" >/dev/null 2>&1; check "$?" "4" "cleanup refused while a run is active"
sleep 0 & DEAD=$!; wait "$DEAD"
printf '%s %s\n' "$DEAD" "$(date +%s)" > "$ST/runs/$T11/.lock/owner"
r worker "$T11" >/dev/null 2>&1; check "$?" "0" "stale lock (dead pid) is taken over"

# ---------- 8. verifier: different model, status unchanged ----------
T12="$(newtask "verify me")"
r worker "$T12" >/dev/null 2>&1
check "$(field "$T12" status)" "review" "producer run -> review"
ucfg '{"roles":{"worker":{"tool":"codex","model":"gpt-5-codex"},"verifier":{"tool":"codex","model":"GPT-5-Codex"}}}'
r verifier "$T12" >/dev/null 2>"$W/e12"; check "$?" "3" "same model (case-insensitive): exit 3"
has "$(cat "$W/e12")" "verifier codex/gpt-5-codex is the same model that produced $T12" "same-model message"
has "$(lastevent run_refused)" '"reason":"same-model"' "run_refused same-model"
ucfg "$ROLES_ALL"
FAKE_CLI_REPLY=verifier-approved.txt FAKE_CLI_LOG="$W/log12" r verifier "$T12" >/dev/null 2>&1; check "$?" "0" "verifier run ok"
check "$(field "$T12" status)" "review" "verifier never changes status"
check "$(field "$T12" tool)/$(field "$T12" model)" "codex/gpt-5-codex" "verifier does not overwrite the producer"
has "$(t show "$T12")" "verifier reply (verifier-run run-$T12-" "verdict appended to Verification"
check "$(cat "$W/log12/1.claude.cwd")" "$ST/worktrees/$T12" "verifier runs in the task's worktree"
has "$(lastevent run_start)" '"modelCheck":"ok"' "modelCheck ok"
T13="$(newtask "unknown producer")"
FAKE_CLI_REPLY=verifier-approved.txt r verifier "$T13" >/dev/null 2>"$W/e13"; check "$?" "0" "unknown producer: verifier runs"
has "$(cat "$W/e13")" "no producer tool/model recorded" "unknown producer: warning"
has "$(lastevent run_start)" '"modelCheck":"unknown"' "modelCheck unknown"
check "$(cat "$W/log12/1.claude.argv" | head -n 3 | tr '\n' ' ')" "-p --output-format json " "claude argv recorded by the fake"
# a verifier that writes anything is a violation (read-only)
T14="$(newtask "ro")"; t set "$T14" tool=codex model=x
FAKE_CLI_REPLY=verifier-approved.txt FAKE_CLI_TOUCH=a.txt r verifier "$T14" >/dev/null 2>&1; check "$?" "5" "verifier changing a file: violation"
check "$(field "$T14" status)" "blocked" "verifier violation blocks the task"
git -C "$P" checkout -q -- a.txt

# ---------- 9. arg-mode tools, hostile content ----------
HOST='Evil $(touch '"$W"'/pwned) `touch '"$W"'/pwned2` '"'"'q" ; touch '"$W"'/pwned3 #'
T15="$(t new "$HOST" --writable a.txt --task "$HOST
\$HOME \${PATH} && rm -rf / ; \`id\`")"
for tool in opencode copilot agy; do
  ucfg "{\"roles\":{\"worker\":{\"tool\":\"$tool\"}}}"
  rm -rf "$W/log15"
  FAKE_CLI_LOG="$W/log15" r worker "$T15" >/dev/null 2>"$W/e15"
  ARGF="$(ls "$W/log15"/1.*.argv)"
  PF="$(ls -t "$ST/runs/$T15"/*.prompt.md | head -n 1)"
  check "$(grep -cF "Evil \$(touch $W/pwned)" "$ARGF")" "1" "$tool: hostile title passed verbatim inside the prompt argument"
  check "$(sed 's/$/\\n/' "$PF" | tr -d '\n')" "$(grep '^Task: ' "$ARGF")" "$tool: whole prompt is one argv element"
  check "$(wc -c < "$W/log15/1.$tool.stdin" | tr -d ' ')" "0" "$tool: stdin is /dev/null"
done
has "$(cat "$W/e15")" "warning: agy profile is experimental (flags unverified)" "agy: experimental warning on stderr"
has "$(lastevent run_start)" '"experimental":true' "agy: run_start experimental"
ls "$W"/pwned* >/dev/null 2>&1 && bad "hostile content was executed" || ok "hostile content never executed"
# custom: bash -c with the prompt file quoted
ucfg "{\"roles\":{\"worker\":{\"tool\":\"custom\",\"cmd\":\"bash '$FAKE/fake-cli.sh' custom --in {prompt_file} --model {model}\",\"model\":\"my-model\"}}}"
rm -rf "$W/log16"
QS="$W/st'q \$(touch $W/pwned4)"
FAKE_CLI_LOG="$W/log16" SUBDECK_STATE_DIR="$QS" SUBDECK_TASKS_DIR="$ST/tasks" r worker "$T15" --no-worktree >/dev/null 2>&1; check "$?" "0" "custom cmd run ok (state path with a quote and \$(...))"
check "$(sed -n 2p "$W/log16/1.custom.argv")" "$(ls -t "$QS"/*/runs/"$T15"/*.prompt.md | head -n 1)" "custom: {prompt_file} replaced by the single-quoted path"
check "$(sed -n 4p "$W/log16/1.custom.argv")" "my-model" "custom: {model} replaced"
check "$(cat "$W/log16/1.custom.stdin" | wc -c | tr -d ' ')" "0" "custom: stdin is /dev/null"
ls "$W"/pwned* >/dev/null 2>&1 && bad "hostile content executed by custom" || ok "custom: hostile content never executed"
ucfg "$ROLES_ALL"

# ---------- 10. researcher: project dir by default, --worktree creates one ----------
T17="$(newtask "research")"
FAKE_CLI_REPLY=researcher-done.txt FAKE_CLI_LOG="$W/log17" r researcher "$T17" >/dev/null 2>&1; check "$?" "0" "researcher run ok"
check "$(cat "$W/log17/1.gemini.cwd")" "$P" "researcher runs in the project dir (no worktree created)"
[ ! -e "$ST/worktrees/$T17" ] && ok "researcher creates no worktree" || bad "researcher created a worktree"
check "$(field "$T17" status)" "review" "researcher Stop: done -> review"
check "$(field "$T17" role)|$(field "$T17" tool)" "researcher|" "researcher sets role, not tool/model"
FAKE_CLI_REPLY=researcher-done.txt FAKE_CLI_LOG="$W/log17b" r researcher "$T17" --worktree >/dev/null 2>&1
check "$(cat "$W/log17b/1.gemini.cwd")" "$ST/worktrees/$T17" "researcher --worktree creates the worktree"

# ---------- 11. worker --no-worktree, non-git project ----------
T18="$(newtask "in place" "a.txt")"
FAKE_CLI_LOG="$W/log18" FAKE_CLI_TOUCH=a.txt r worker "$T18" --no-worktree >/dev/null 2>&1; check "$?" "0" "--no-worktree run ok"
check "$(cat "$W/log18/1.codex.cwd")" "$P" "--no-worktree runs in the project dir"
git -C "$P" checkout -q -- a.txt
NP="$W/nogit"; mkdir -p "$NP"
NT="$(bash "$TS" --project "$NP" new job)"
bash "$RUN" --project "$NP" worker "$NT" >/dev/null 2>&1; check "$?" "2" "non-git: worker needs --no-worktree"
NST="$( . "$PL/scripts/lib-paths.sh"; sd_state_dir "$NP"; printf '%s' "$SD_STATE" )"
grep -q '"reason":"no-git"' "$NST/events.jsonl" && ok "non-git: run_refused no-git" || bad "non-git: no run_refused"
FAKE_CLI_TOUCH=x.txt bash "$RUN" --project "$NP" worker "$NT" --no-worktree >/dev/null 2>&1; check "$?" "0" "non-git --no-worktree runs"
grep -q '"writableCheck":"skipped"' "$NST/runs/$NT"/*.json && ok "non-git: writable check skipped" || bad "non-git: writableCheck"

# ---------- 12. worktree edge cases, tail, cleanup ----------
T19="$(newtask "wt edge")"
mkdir -p "$ST/worktrees/$T19"
r worker "$T19" >/dev/null 2>&1; check "$?" "2" "worktree path exists but not registered: exit 2"
rmdir "$ST/worktrees/$T19"
OUT="$(r tail "$T1" --lines 3)"
has "$OUT" "status: " "tail: meta header"
has "$OUT" "--- log (last 3 lines)" "tail: log part"
has "$OUT" "--- out (last 3 lines)" "tail: out part"
r tail t-abcd >/dev/null 2>&1; check "$?" "1" "tail without runs: exit 1"
echo dirty >> "$ST/worktrees/$T1/a.txt"
r cleanup "$T1" >/dev/null 2>&1; check "$?" "1" "cleanup refuses a dirty worktree"
r cleanup "$T1" --force >/dev/null 2>&1; check "$?" "0" "cleanup --force removes it"
[ ! -e "$ST/worktrees/$T1" ] && ok "worktree gone" || bad "worktree still there"
git -C "$P" rev-parse --verify -q "refs/heads/subdeck/$T1" >/dev/null && ok "branch kept after cleanup" || bad "branch deleted"
FAKE_CLI_LOG="$W/log20" r worker "$T1" >/dev/null 2>&1
check "$(git -C "$ST/worktrees/$T1" rev-parse --abbrev-ref HEAD)" "subdeck/$T1" "existing branch without worktree: worktree added from the branch"
has "$(git -C "$ST/worktrees/$T1" log --oneline -3)" "fake: touch" "earlier commits of the branch kept"

# ---------- 13. hooks inside a run write to the main project's state ----------
SUBDECK_PROJECT="$P" bash -c '. "$1"; sd_state_dir "$2"; printf "%s" "$SD_STATE"' _ "$PL/scripts/lib-paths.sh" "$ST/worktrees/$T1" > "$W/sd"
check "$(cat "$W/sd")" "$ST" "SUBDECK_PROJECT routes a worktree's state to the main project"

# ---------- 14. bash 3.2 rules ----------
for pat in 'wait -n' '\$\{[A-Za-z_]+,,\}' '\$\{[A-Za-z_]+\^\^\}' 'declare -A' 'local -A' 'mapfile' 'readarray' 'EPOCHSECONDS' 'local -n' 'declare -n' '[^-]timeout [0-9]'; do
  if grep -En "$pat" "$RUN" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then bad "run.sh uses '$pat'"; else ok "run.sh avoids '$pat'"; fi
done
grep -q 'jq' "$RUN" && bad "run.sh mentions jq" || ok "run.sh needs no jq"
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ]'; then
  /bin/bash -n "$RUN" && ok "parses under /bin/bash 3.x" || bad "syntax error under /bin/bash 3.x"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
