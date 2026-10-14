#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-checkpoints.sh   (auto checkpoints on git commit, history, resume-prompt, rewind)
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$HERE/.."
CP="$PL/scripts/checkpoint.sh"
TS="$PL/scripts/tasks.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2')" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (found '$2')" ;; *) ok "$3" ;; esac; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export SUBDECK_STATE_DIR="$W/state" HOME="$W/home" SUBDECK_NOTIFY_OS=linux
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=a@b GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=a@b
unset SUBDECK_TASKS_DIR SUBDECK_TASKS SUBDECK_NOTIFY SUBDECK_TASK_GIT
mkdir -p "$HOME/.subdeck"
P="$W/proj"; mkdir -p "$P"; git -C "$P" init -q 2>/dev/null
echo base > "$P/f.txt"; git -C "$P" add f.txt; git -C "$P" commit -q -m base
export CLAUDE_PROJECT_DIR="$P"
t() { bash "$TS" --project "$P" "$@"; }
# fire AGENT_ID COMMAND : PostToolUse payload through the hook script
fire() {
  local aid="$1" cmd="$2"
  printf '{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}%s,"tool_response":{"stdout":"ok"}}' \
    "$P" "$cmd" "${aid:+,\"agent_id\":\"$aid\"}" | bash "$CP"
  echo $?
}
pre() { # AGENT_ID COMMAND : PreToolUse payload (remembers HEAD before the command)
  printf '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}%s}' \
    "$P" "$2" "${1:+,\"agent_id\":\"$1\"}" | bash "$CP" pre
}
commit() { echo "$1" > "$P/$1.txt"; git -C "$P" add "$1.txt"; git -C "$P" commit -q -m "$2"; git -C "$P" rev-parse --short=10 HEAD; }

ID="$(t new "ckpt job" --owner worker-sonnet --writable "a.txt,b.txt,c.txt")"
t set "$ID" agent=agent01 >/dev/null

# 1. linked agent commit -> checkpoint
pre agent01 'git commit -m a'
H1="$(commit a "add a")"; echo dirty > "$P/wip.txt"
check "$(fire agent01 'git add a.txt && git commit -m \"add a\"')" 0 "hook exits 0"
H="$(t history "$ID")"
has "$H" "commit" "history lists a commit checkpoint"
has "$H" "$H1 add a" "checkpoint has short hash and subject"
B="$(t show "$ID" --section progress)"
has "$B" "files: a.txt" "changed file names recorded"
has "$B" "dirty: wip.txt" "dirty file names recorded"
has "$B" "agent: agent01" "agent id recorded"
hasnt "$B" "echo" "no file content stored"

# 2. negative controls (each uses a fresh, still unrecorded commit, so a wrong attribution would show up)
fire agent01 'git commit -m again' >/dev/null
check "$(t history "$ID" | grep -c commit)" 1 "same HEAD is not recorded twice"
H2="$(commit b "add b")"   # made by the manager, not recorded yet
fire other99 'git commit -m x' >/dev/null
check "$(t history "$ID" | grep -c commit)" 1 "unlinked agent does not checkpoint a fresh commit"
fire "" 'git commit -m x' >/dev/null
check "$(t history "$ID" | grep -c commit)" 1 "no agent id (main session) does not checkpoint a fresh commit"
fire agent01 'git status' >/dev/null
check "$(t history "$ID" | grep -c commit)" 1 "linked agent running git status does not take over the manager's commit"
fire agent01 'ls -la' >/dev/null
check "$(t history "$ID" | grep -c commit)" 1 "a non-commit command does not checkpoint"
printf '{"hook_event_name":"PostToolUse","cwd":"%s","agent_id":"agent01","tool_input":{"command":"git log"},"tool_response":{"stdout":"git commit"}}' "$P" | bash "$CP"
check "$(t history "$ID" | grep -c commit)" 1 "the word commit in the tool output alone does not checkpoint"

# a command that succeeds without committing ("|| true") must not take over the manager's unrecorded commit
pre agent01 'git commit -m nothing || true'
fire agent01 'git commit -m nothing || true' >/dev/null
check "$(t history "$ID" | grep -c commit)" 1 "failed commit followed by || true does not take the manager commit"

# 3. second commit + manual step share one history
pre agent01 'git commit -m b2'
H2="$(commit b2 "add b2")"; fire agent01 'git commit -m b2' >/dev/null
t step "$ID" --done "added a and b" --next "add c" >/dev/null
pre agent01 'git commit -m c'
H3="$(commit c "add c")"; fire agent01 'git commit -m c' >/dev/null
H="$(t history "$ID")"
check "$(printf '%s\n' "$H" | wc -l | tr -d ' ')" 4 "history: 3 commits + 1 step"
has "$H" "step" "manual step in the same history"
check "$(printf '%s\n' "$H" | sed -n 3p | awk '{print $3}')" step "step sits between the commits (time order)"
has "$(t history "$ID" --tsv)" "$H2" "history --tsv carries the hash"

# 4. resume-prompt
R="$(t resume-prompt "$ID")"
has "$R" "Last done: added a and b" "resume-prompt: Last done"
has "$R" "Next: add c" "resume-prompt: Next"
has "$R" "$H1 add a" "resume-prompt: commits already done"
has "$R" "do not redo" "resume-prompt: do-not-redo wording"
has "$R" "wip.txt" "resume-prompt: uncommitted files"
has "$R" "Transcript:" "resume-prompt: transcript line"

# 5. rewind is dry by default
HEAD0="$(git -C "$P" rev-parse HEAD)"
D="$(t rewind "$ID" "$H1")"; check $? 0 "rewind dry exits 0" 2>/dev/null
has "$D" "git -C" "dry run prints git revert commands"
has "$D" "revert --no-edit $H3" "dry run: newest commit first"
has "$D" "Dry run: nothing changed" "dry run says so"
check "$(git -C "$P" rev-parse HEAD)" "$HEAD0" "dry run: HEAD unchanged"
check "$(git -C "$P" status --porcelain | wc -l | tr -d ' ')" 1 "dry run: tree unchanged (only the untracked wip file)"

# 6. --apply refuses a dirty tree
t rewind "$ID" "$H1" --apply >/dev/null 2>&1; check $? 3 "rewind --apply refuses a dirty tree (exit 3)"
check "$(git -C "$P" rev-parse HEAD)" "$HEAD0" "refused apply: HEAD unchanged"
t rewind "$ID" nosuchcp >/dev/null 2>&1; check $? 2 "unknown checkpoint is a usage error"

# 7. --apply on a clean tree creates revert commits only
rm -f "$P/wip.txt"
OUT="$(t rewind "$ID" "$H1" --apply 2>&1)"; check $? 0 "rewind --apply exits 0" 2>/dev/null
check "$(git -C "$P" rev-list --count "$HEAD0..HEAD")" 2 "two revert commits created"
check "$([ -f "$P/c.txt" ] && echo y || echo n)" n "c.txt reverted"
check "$([ -f "$P/b2.txt" ] && echo y || echo n)" n "b2.txt reverted"
check "$([ -f "$P/a.txt" ] && echo y || echo n)" y "a.txt (the checkpoint) kept"
check "$(git -C "$P" merge-base --is-ancestor "$HEAD0" HEAD && echo y)" y "history not rewritten (old HEAD is an ancestor)"
has "$(git -C "$P" log -1 --format=%s)" "Revert" "revert commit subject"
has "$(t history "$ID")" "rewind" "history records the rewind"
R="$(t resume-prompt "$ID")"
has "$R" "Reverted by a rewind" "resume-prompt lists reverted commits separately"
D="$(t rewind "$ID" "$H1")"
has "$D" "Nothing to revert" "a second rewind finds nothing left to revert"

# 7b. two linked agents share one tree: a HEAD already recorded for task 1 is not recorded again for task 2
ID2="$(t new "second job" --owner worker-sonnet --writable "e.txt")"
t set "$ID2" agent=agent02 >/dev/null
pre agent02 'git commit -m e || true'
pre agent01 'git commit -m e'
H5="$(commit e "add e")"; fire agent01 'git commit -m e' >/dev/null
has "$(t history "$ID")" "$H5 add e" "agent01 got its own commit"
fire agent02 'git commit -m e || true' >/dev/null
check "$(t history "$ID2" | grep -c commit)" 0 "a HEAD recorded for another task is not recorded again"

# 8. speed of the hook for a commit (loose bound for slow Windows process spawns)
pre agent01 'git commit -m d'
H4="$(commit d "add d")"
S=$(date +%s%N 2>/dev/null); fire agent01 'git commit -m d' >/dev/null; E=$(date +%s%N 2>/dev/null)
case "$S$E" in *N*|"") ok "timing skipped (no %N)" ;; *) MS=$(( (E - S) / 1000000 )); if [ "$MS" -lt 5000 ]; then ok "hook took ${MS} ms"; else bad "hook took ${MS} ms"; fi ;; esac

echo "passed: $PASS failed: $FAIL"
[ "$FAIL" = 0 ]
