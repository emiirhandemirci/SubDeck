#!/usr/bin/env bash
# Checkpoints: when a task-linked agent ran a git commit, tasks.sh records a checkpoint, only if HEAD moved
# directly on top of the HEAD remembered before the call.
#   PostToolUse (hooks.json): checkpoint.sh            -> records the checkpoint
#   PreToolUse: guard.sh sources this file and calls sd_cp_run pre "<payload>" (no second launcher per Bash call)
# Non-commit calls cost nothing but the shell already running: only the tool_input command is inspected (not the
# tool output) with bash builtins; no process is spawned unless the command contains a git commit. Never fails.
CP_HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$CP_HERE" = "${BASH_SOURCE[0]}" ] && CP_HERE="."

# sd_cp_run MODE(pre|post) PAYLOAD : always returns 0, prints nothing
sd_cp_run() {
  local payload="${2//$'\r'/}" rest cmd ev=Checkpoint project cwd_re cmd_re
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
  if [ -z "$project" ]; then
    cwd_re='"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"'
    [[ $payload =~ $cwd_re ]] && project="${BASH_REMATCH[1]}"
  fi
  [ -n "$project" ] && [ -d "$project" ] || project="$(pwd)"
  [ "$1" = pre ] && ev=CheckpointPre
  printf '%s' "$payload" | SUBDECK_METER=0 bash "$CP_HERE/tasks.sh" --project "$project" hook "$ev" >/dev/null 2>&1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  IFS= read -r -d '' CP_PAYLOAD
  sd_cp_run "${1:-post}" "$CP_PAYLOAD"
  exit 0
fi
