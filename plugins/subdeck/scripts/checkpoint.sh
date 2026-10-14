#!/usr/bin/env bash
# Checkpoints: when a task-linked agent ran a git commit, tasks.sh records a checkpoint, only if HEAD moved
# directly on top of the HEAD remembered before the call.
#   PostToolUse (hooks.json): checkpoint.sh            -> records the checkpoint
#   PreToolUse: the guard prints its decision first, then runs `checkpoint.sh pre-args AGENT_ID CWD PROJECT`
#   (no second launcher per Bash call; only for a commit-like command of a sub-agent that it did not deny).
#   `checkpoint.sh pre` (payload on stdin) does the same for other callers.
# Non-commit calls cost nothing but the shell already running: only the tool_input command is inspected (not the
# tool output) with bash builtins; no process is spawned unless the command contains a git commit. Never fails.
CP_HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$CP_HERE" = "${BASH_SOURCE[0]}" ] && CP_HERE="."

# sd_cp_pre AGENT_ID CWD PROJECT : remember HEAD of the agent's repository before its command, in
# <state>/checkpoint-pre/<agent id> ("none" on an unborn branch). No locks and no tasks.sh: one git call that
# is waited for at most 0.5 s (1 s on bash 3), then a write to a temp file renamed into place. When git is too
# slow or the write fails, any older remembered HEAD is removed (PostToolUse then records nothing: fail closed).
# Always returns 0, prints nothing.
sd_cp_pre() {
  local aid="${1//[^A-Za-z0-9._-]/}" g="$2" project="$3" pre="" rc=0 to=1 d pf
  [ -n "$aid" ] || return 0
  [ "${SUBDECK_TASKS:-}" = 0 ] && return 0
  [ -f "$CP_HERE/tasks.sh" ] || return 0
  # the same project and git directory as the PostToolUse side (checkpoint.sh -> tasks.sh cp_main)
  [ -n "$project" ] && [ -d "$project" ] || project="$(pwd)"
  project="${project%/}"; [ -n "$project" ] || project="/"
  [ -n "$g" ] && [ -d "$g" ] || g="${SUBDECK_TASK_GIT:-}"
  [ -n "$g" ] && [ -d "$g" ] || g="$project"
  . "$CP_HERE/lib-paths.sh" 2>/dev/null || return 0
  sd_state_dir "$project"
  [ -n "$SD_KEY" ] || return 0
  d="$SD_STATE/checkpoint-pre"; pf="$d/$aid"
  [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] && to=0.5
  { IFS= read -r -t "$to" pre; rc=$?; } < <(GIT_OPTIONAL_LOCKS=0 git -C "$g" rev-parse --verify -q HEAD 2>/dev/null </dev/null)
  if [ "$rc" -gt 128 ]; then rm -f "$pf" 2>/dev/null; return 0; fi
  pre="${pre%$'\r'}"; [[ $pre =~ ^[0-9a-f]{40,64}$ ]] || pre=none
  { [ -d "$d" ] || mkdir -p "$d"; } 2>/dev/null || return 0
  if { printf '%s\n' "$pre" > "$pf.$$.tmp" && mv -f "$pf.$$.tmp" "$pf"; } 2>/dev/null; then return 0; fi
  rm -f "$pf.$$.tmp" "$pf" 2>/dev/null
  return 0
}

# sd_cp_run MODE(pre|post) PAYLOAD : always returns 0, prints nothing
sd_cp_run() {
  local payload="${2//$'\r'/}" rest cmd ev=Checkpoint project cwd_re cmd_re aid_re cwd="" BS=$'\134'
  payload="${payload//$'\n'/}"
  rest="${payload#*\"tool_input\"}"
  [ "$rest" = "$payload" ] && return 0
  cmd_re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ $rest =~ $cmd_re ]] || return 0
  cmd="${BASH_REMATCH[1]}"
  [[ $cmd == *git*commit* ]] || return 0
  [ "${SUBDECK_TASKS:-}" = 0 ] && return 0
  [ -f "$CP_HERE/tasks.sh" ] || return 0
  project="${CLAUDE_PROJECT_DIR:-}"
  if [ "$1" = pre ]; then
    aid_re='"agent_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)"'
    [[ $payload =~ $aid_re ]] || return 0
    local aid="${BASH_REMATCH[1]}"
    cwd_re="\"cwd\"[[:space:]]*:[[:space:]]*\"(([^\"$BS$BS]|$BS$BS.)*)\""
    if [[ $payload =~ $cwd_re ]]; then cwd="${BASH_REMATCH[1]}"; cwd="${cwd//"$BS$BS"/$BS}"; fi
    [ -n "$project" ] || project="$cwd"
    sd_cp_pre "$aid" "$cwd" "$project"
    return 0
  fi
  if [ -z "$project" ]; then
    cwd_re='"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"'
    [[ $payload =~ $cwd_re ]] && project="${BASH_REMATCH[1]}"
  fi
  [ -n "$project" ] && [ -d "$project" ] || project="$(pwd)"
  printf '%s' "$payload" | SUBDECK_METER=0 bash "$CP_HERE/tasks.sh" --project "$project" hook "$ev" >/dev/null 2>&1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = pre-args ]; then sd_cp_pre "${2:-}" "${3:-}" "${4:-}"; exit 0; fi
  IFS= read -r -d '' CP_PAYLOAD
  sd_cp_run "${1:-post}" "$CP_PAYLOAD"
  exit 0
fi
