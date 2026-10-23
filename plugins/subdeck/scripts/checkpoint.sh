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
  # the child always ends its line with "ok <HEAD or empty>": bash 3.2 (macOS) returns 1, not >128, when read -t
  # times out, so a missing "ok " prefix (timeout or killed child) is what tells a hung git from an unborn branch
  { IFS= read -r -t "$to" pre; rc=$?; } < <(h="$(GIT_OPTIONAL_LOCKS=0 git -C "$g" rev-parse --verify -q HEAD 2>/dev/null </dev/null)"; printf 'ok %s\n' "$h")
  if [ "$rc" -gt 128 ] || [ "${pre:0:3}" != "ok " ]; then rm -f "$pf" 2>/dev/null; return 0; fi
  pre="${pre#ok }"; pre="${pre%$'\r'}";[[ $pre =~ ^[0-9a-f]{40,64}$ ]] || pre=none
  { [ -d "$d" ] || mkdir -p "$d"; } 2>/dev/null || return 0
  if { printf '%s\n' "$pre" > "$pf.$$.tmp" && mv -f "$pf.$$.tmp" "$pf"; } 2>/dev/null; then return 0; fi
  rm -f "$pf.$$.tmp" "$pf" 2>/dev/null
  return 0
}

# Loop detection (sub-agents only, PostToolUse / PostToolUseFailure): a tiny per-agent ring of the last 10 FAILING
# calls (<state>/loop/<agent id>, one line "<key> <W|->", key = cksum of tool name + whitespace-normalised input).
# The 3rd identical failing call inside the window prints a PostToolUse additionalContext telling the agent to stop
# retrying; the line is marked W so it warns once. Calls that did not fail cost only bash builtins (regex tests on the
# payload, no fork, no file access). Atomic write (tmp + mv), never blocks, never fails. Off with config key
# loopDetect=false (project config wins over user config; absent = on).
sd_loop_on() { # 0 when loop detection is not switched off
  local f c
  for f in "${CP_LOOP_PFILE:-}" "${HOME:-}/.subdeck/config.json"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    c="$(cat "$f" 2>/dev/null)" || continue
    if [[ $c =~ \"loopDetect\"[[:space:]]*:[[:space:]]*(true|false) ]]; then [ "${BASH_REMATCH[1]}" = true ]; return; fi
  done
  return 0
}
# sd_loop_check PAYLOAD CMD : prints the warning JSON or nothing; always returns 0
sd_loop_check() {
  local payload="$1" cmd="$2" aid resp="" failed=0 ec_re tool="Bash" key line w warn=0 n=0 d rf project="${CLAUDE_PROJECT_DIR:-}"
  local -a ring
  [[ $payload =~ \"agent_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]+)\" ]] || return 0
  aid="${BASH_REMATCH[1]}"
  if [[ $payload =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"PostToolUseFailure\" ]]; then failed=1
  else
    resp="${payload#*\"tool_response\"}"
    [ "$resp" = "$payload" ] && return 0
    ec_re='"(exit_code|exitCode|returncode|exit_status)"[[:space:]]*:[[:space:]]*(-?[0-9]+)'
    if [[ $resp =~ $ec_re ]]; then [ "${BASH_REMATCH[2]}" = 0 ] || failed=1
    elif [[ $resp =~ \"is_error\"[[:space:]]*:[[:space:]]*true ]] || [[ $resp =~ \"success\"[[:space:]]*:[[:space:]]*false ]]; then failed=1; fi
  fi
  [ "$failed" = 1 ] || return 0
  [ "${SUBDECK_LOOP_DETECT:-}" = 0 ] && return 0
  [[ $payload =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z]+)\" ]] && tool="${BASH_REMATCH[1]}"
  [ -n "$project" ] && [ -d "$project" ] || { [[ $payload =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && project="${BASH_REMATCH[1]}"; }
  [ -n "$project" ] && [ -d "$project" ] || project="$(pwd)"
  project="${project%/}"; [ -n "$project" ] || project="/"
  . "$CP_HERE/lib-paths.sh" 2>/dev/null || return 0
  sd_state_dir "$project"
  [ -n "$SD_KEY" ] || return 0
  CP_LOOP_PFILE="$SD_STATE/config.json"
  sd_loop_on || return 0
  cmd="${cmd//\\n/ }"; cmd="${cmd//\\t/ }"
  while [[ $cmd == *"  "* ]]; do cmd="${cmd//  / }"; done
  key="$(printf '%s|%s' "$tool" "$cmd" | cksum)"; key="${key%% *}"
  d="$SD_STATE/loop"; rf="$d/${aid:0:80}"
  ring=()
  if [ -f "$rf" ]; then
    while IFS= read -r line; do [ -n "$line" ] && ring[${#ring[@]}]="$line"; done < "$rf"
  fi
  ring[${#ring[@]}]="$key -"
  while [ "${#ring[@]}" -gt 10 ]; do ring=("${ring[@]:1}"); done
  for line in "${ring[@]}"; do
    [ "${line%% *}" = "$key" ] || continue
    n=$((n + 1)); [ "${line#* }" = W ] && w=1
  done
  if [ "$n" -ge 3 ] && [ -z "${w:-}" ]; then
    warn=1; ring[${#ring[@]}-1]="$key W"
  fi
  { [ -d "$d" ] || mkdir -p "$d"; } 2>/dev/null || return 0
  { printf '%s\n' "${ring[@]}" > "$rf.$$.tmp" && mv -f "$rf.$$.tmp" "$rf"; } 2>/dev/null || { rm -f "$rf.$$.tmp" 2>/dev/null; return 0; }
  [ "$warn" = 1 ] || return 0
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Same failing command 3 times. Stop retrying; end with `Stop: no-progress` and say what you tried."}}'
  printf '{"agent_id":"%s","tool":"%s","count":%s,"window":10}' "$aid" "$tool" "$n" \
    | CLAUDE_PROJECT_DIR="$project" bash "$CP_HERE/log-event.sh" loop_detected >/dev/null 2>&1
  return 0
}

# sd_cp_run MODE(pre|post) PAYLOAD : always returns 0; prints nothing except a loop warning (see sd_loop_check)
sd_cp_run() {
  local payload="${2//$'\r'/}" rest cmd ev=Checkpoint project cwd_re cmd_re aid_re cwd="" BS=$'\134'
  payload="${payload//$'\n'/}"
  rest="${payload#*\"tool_input\"}"
  [ "$rest" = "$payload" ] && return 0
  cmd_re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ $rest =~ $cmd_re ]] || return 0
  cmd="${BASH_REMATCH[1]}"
  [ "$1" = pre ] || sd_loop_check "$payload" "$cmd"
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
