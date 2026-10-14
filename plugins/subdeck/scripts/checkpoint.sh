#!/usr/bin/env bash
# PreToolUse (arg "pre") + PostToolUse hook for Bash/PowerShell: when a task-linked agent ran a git commit,
# tasks.sh records a checkpoint, only if HEAD moved directly on top of the HEAD remembered before the call.
# Non-commit calls cost nothing but this shell: stdin is read with builtins and only the tool_input command is
# inspected (not the tool output); no process is spawned unless the command contains a git commit. Always exits 0.
IFS= read -r -d '' PAYLOAD
PAYLOAD="${PAYLOAD//$'\r'/}"; PAYLOAD="${PAYLOAD//$'\n'/}"
REST="${PAYLOAD#*\"tool_input\"}"
[ "$REST" = "$PAYLOAD" ] && exit 0
CMD_RE='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
[[ $REST =~ $CMD_RE ]] || exit 0
CMD="${BASH_REMATCH[1]}"
[[ $CMD == *git*commit* ]] || exit 0
[ "${SUBDECK_TASKS:-}" = 0 ] && exit 0
HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
[ -f "$HERE/tasks.sh" ] || exit 0
PROJECT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT" ]; then
  CWD_RE='"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"'
  [[ $PAYLOAD =~ $CWD_RE ]] && PROJECT="${BASH_REMATCH[1]}"
fi
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="$(pwd)"
# "pre" (PreToolUse): remember HEAD before the command; default (PostToolUse): record the checkpoint
EV=Checkpoint; [ "${1:-}" = pre ] && EV=CheckpointPre
printf '%s' "$PAYLOAD" | SUBDECK_METER=0 bash "$HERE/tasks.sh" --project "$PROJECT" hook "$EV" >/dev/null 2>&1
exit 0
