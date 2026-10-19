#!/usr/bin/env bash
# Fake headless CLI for SubDeck tests (never a real CLI, never network). Bash 3.2+.
# Usage: fake-cli.sh <tool> [args...]   (normally via bin/<tool>, which execs this script)
# Always reads all of stdin. Behaviour from env:
#   FAKE_CLI_LOG=<dir>      records <n>.<tool>.argv (one arg per line, newline as \n), .stdin, .cwd, .env
#                           (sorted; names SUBDECK_* OPENCODE_* COPILOT_* GIT_CONFIG_* GIT_TERMINAL_PROMPT CLAUDE_PROJECT_DIR,
#                           and CLAUDECODE CLAUDE_* for the session-identity strip test)
#   FAKE_CLI_REPLY=<file>   final message: a path, or a name under replies/ (default worker-done.txt)
#   FAKE_CLI_REPLY_<ROLE>=<file>  same, for runs of that role only (SUBDECK_ROLE, upper case, - as _), e.g. FAKE_CLI_REPLY_VERIFIER
#   FAKE_CLI_EXIT=<n>       exit code (default 0)
#   FAKE_CLI_STDERR=<text>  written to stderr
#   FAKE_CLI_SLEEP=<s>      delay before any output
#   FAKE_CLI_TOUCH=a,b      create/append these paths in cwd;  FAKE_CLI_COMMIT=1 commits them (pathspec commit)
#                           (not for the manager role, SUBDECK_ROLE=manager: a manager turn never edits the worktree)
#   FAKE_CLI_SH=<command>   test-only: run with bash -c in the cwd after FAKE_CLI_TOUCH (rename, push, git dir,
#                           symlink cases); with FAKE_CLI_LOG its exit code goes to <n>.<tool>.sh-exit, its output to .sh-out
#   FAKE_CLI_MODE=quota|auth  canned stderr, exit 1 (gemini auth: 41), no reply
#   FAKE_CLI_QUOTA_MSG=<text> quota mode: this stderr text instead of the canned one (reset-time parsing tests)
#   FAKE_CLI_RUN=<script>   bash script run in the cwd before any output (the fake manager calls tasks.sh/autopilot.sh with it)
#   FAKE_CLI_USAGE=<in>,<out> token usage in the output: claude `usage` object in the result, codex `turn.completed`,
#                           gemini `stats.models`
#   FAKE_CLI_HANG=1         no output; sleep until killed (stuck detection)
#   FAKE_CLI_SESSION=<id>   claude session_id / codex thread_id in the output (default fake-0001 / fake-thread-0001)
# Reply text: `{HEAD}` is replaced by the cwd's `git rev-parse --short=12 HEAD` (verifier fingerprint tests).
# Output: claude one-line JSON (result, session_id fake-0001); gemini pretty JSON {"response":...};
#   codex JSONL events on stdout and the reply written to the -o file; other tools the reply on stdout.

TOOL="${1:-unknown}"; [ $# -gt 0 ] && shift
FDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STDIN="$(cat 2>/dev/null)"

jesc() { # STR -> JE (JSON string body)
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"
  JE="$s"
}

if [ -n "${FAKE_CLI_LOG:-}" ]; then
  mkdir -p "$FAKE_CLI_LOG"
  n=1; while [ -e "$FAKE_CLI_LOG/$n.$TOOL.argv" ]; do n=$((n + 1)); done
  base="$FAKE_CLI_LOG/$n.$TOOL"
  : > "$base.argv.tmp"
  for a in "$@"; do printf '%s\n' "${a//$'\n'/\\n}" >> "$base.argv.tmp"; done
  printf '%s' "$STDIN" > "$base.stdin"
  pwd > "$base.cwd"
  env | grep -E '^(SUBDECK_[A-Z_]*|OPENCODE_[A-Z_]*|COPILOT_[A-Z_]*|GIT_CONFIG_[A-Z0-9_]*|GIT_TERMINAL_PROMPT|CLAUDE_PROJECT_DIR|CLAUDECODE|CLAUDE_PID|CLAUDE_[A-Z0-9_]*)=' | LC_ALL=C sort > "$base.env"
  mv -f "$base.argv.tmp" "$base.argv"
fi

[ -n "${FAKE_CLI_SLEEP:-}" ] && sleep "$FAKE_CLI_SLEEP"

if [ -n "${FAKE_CLI_TOUCH:-}" ] && [ "${SUBDECK_ROLE:-}" != manager ]; then
  IFS=, read -ra TOUCH <<< "$FAKE_CLI_TOUCH"
  for p in "${TOUCH[@]}"; do
    [ -n "$p" ] || continue
    case "$p" in */*) mkdir -p "${p%/*}" ;; esac
    printf 'fake %s\n' "$TOOL" >> "$p"
  done
  if [ "${FAKE_CLI_COMMIT:-}" = 1 ]; then
    git add -- "${TOUCH[@]}" >/dev/null 2>&1
    git -c user.email=fake@cli.invalid -c user.name=fake-cli commit -q -m "fake: touch ${FAKE_CLI_TOUCH}" -- "${TOUCH[@]}" >/dev/null 2>&1
  fi
fi

if [ -n "${FAKE_CLI_SH:-}" ]; then
  bash -c "$FAKE_CLI_SH" > "${base:-/dev/null}${base:+.sh-out}" 2>&1
  rc=$?
  [ -n "${base:-}" ] && printf '%s\n' "$rc" > "$base.sh-exit"
fi

if [ -n "${FAKE_CLI_RUN:-}" ]; then
  bash "$FAKE_CLI_RUN" > "${base:-/dev/null}${base:+.run-out}" 2>&1
fi

if [ "${FAKE_CLI_HANG:-}" = 1 ]; then
  while :; do sleep 1; done
fi

case "${FAKE_CLI_MODE:-}" in
  quota) printf '%s\n' "${FAKE_CLI_QUOTA_MSG:-Error: 429 Too Many Requests: rate limit exceeded}" >&2; exit 1 ;;
  auth) echo 'Error: not logged in' >&2; [ "$TOOL" = gemini ] && exit 41; exit 1 ;;
esac

RV="FAKE_CLI_REPLY_$(printf "%s" "${SUBDECK_ROLE:-}" | tr "a-z-" "A-Z_")"
REPLY_FILE="${!RV:-${FAKE_CLI_REPLY:-worker-done.txt}}"
case "$REPLY_FILE" in */*) ;; *) REPLY_FILE="$FDIR/replies/$REPLY_FILE" ;; esac
REPLY=""; [ -f "$REPLY_FILE" ] && REPLY="$(cat "$REPLY_FILE")"
case "$REPLY" in *"{HEAD}"*) REPLY="${REPLY//\{HEAD\}/$(git rev-parse --short=12 HEAD 2>/dev/null)}" ;; esac
jesc "$REPLY"
UIN=1; UOUT=1; UJ=""
if [ -n "${FAKE_CLI_USAGE:-}" ]; then UIN="${FAKE_CLI_USAGE%%,*}"; UOUT="${FAKE_CLI_USAGE#*,}"; fi

case "$TOOL" in
  claude)
    [ -n "${FAKE_CLI_USAGE:-}" ] && UJ=",\"usage\":{\"input_tokens\":$UIN,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":7,\"output_tokens\":$UOUT}"
    printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","session_id":"%s"%s}\n' "$JE" "${FAKE_CLI_SESSION:-fake-0001}" "$UJ" ;;
  gemini)
    [ -n "${FAKE_CLI_USAGE:-}" ] && UJ="\"models\": {\"gemini-x\": {\"tokens\": {\"prompt\": $UIN, \"candidates\": $UOUT}}}"
    printf '{\n  "response": "%s",\n  "stats": {%s}\n}\n' "$JE" "$UJ" ;;
  codex)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
    printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.started"}\n' "${FAKE_CLI_SESSION:-fake-thread-0001}"
    printf '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"%s"}}\n' "$JE"
    printf '{"type":"turn.completed","usage":{"input_tokens":%s,"cached_input_tokens":0,"output_tokens":%s}}\n' "$UIN" "$UOUT"
    [ -n "$out" ] && printf '%s\n' "$REPLY" > "$out" ;;
  *)
    [ -n "$REPLY" ] && printf '%s\n' "$REPLY" ;;
esac

[ -n "${FAKE_CLI_STDERR:-}" ] && printf '%s\n' "$FAKE_CLI_STDERR" >&2
exit "${FAKE_CLI_EXIT:-0}"
