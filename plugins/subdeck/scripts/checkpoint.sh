#!/usr/bin/env bash
# PostToolUse hook for Bash/PowerShell: when a task-linked agent ran a git commit, tasks.sh records a checkpoint.
# Cheap pre-filter first (no work unless the payload mentions a commit); always exits 0.
PAYLOAD="$(cat 2>/dev/null)"
case "$PAYLOAD" in *commit*) ;; *) exit 0 ;; esac
[ "${SUBDECK_TASKS:-}" = 0 ] && exit 0
HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
[ -f "$HERE/tasks.sh" ] || exit 0
PROJECT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT" ]; then
  PROJECT="$(printf '%s' "$PAYLOAD" | tr -d '\r\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="$(pwd)"
printf '%s' "$PAYLOAD" | SUBDECK_METER=0 bash "$HERE/tasks.sh" --project "$PROJECT" hook Checkpoint >/dev/null 2>&1
exit 0
