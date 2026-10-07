#!/usr/bin/env bash
# Fake headless CLI for SubDeck tests (never a real CLI, never network). Bash 3.2+.
# Usage: fake-cli.sh <tool> [args...]   (normally via bin/<tool>, which execs this script)
# Always reads all of stdin. Behaviour from env:
#   FAKE_CLI_LOG=<dir>      records <n>.<tool>.argv (one arg per line, newline as \n), .stdin, .cwd, .env
#                           (sorted; names SUBDECK_* OPENCODE_* COPILOT_* GIT_CONFIG_* GIT_TERMINAL_PROMPT CLAUDE_PROJECT_DIR)
#   FAKE_CLI_REPLY=<file>   final message: a path, or a name under replies/ (default worker-done.txt)
#   FAKE_CLI_EXIT=<n>       exit code (default 0)
#   FAKE_CLI_STDERR=<text>  written to stderr
#   FAKE_CLI_SLEEP=<s>      delay before any output
#   FAKE_CLI_TOUCH=a,b      create/append these paths in cwd;  FAKE_CLI_COMMIT=1 commits them (pathspec commit)
#   FAKE_CLI_MODE=quota|auth  canned stderr, exit 1 (gemini auth: 41), no reply
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
  env | grep -E '^(SUBDECK_[A-Z_]*|OPENCODE_[A-Z_]*|COPILOT_[A-Z_]*|GIT_CONFIG_[A-Z0-9_]*|GIT_TERMINAL_PROMPT|CLAUDE_PROJECT_DIR)=' | LC_ALL=C sort > "$base.env"
  mv -f "$base.argv.tmp" "$base.argv"
fi

[ -n "${FAKE_CLI_SLEEP:-}" ] && sleep "$FAKE_CLI_SLEEP"

if [ -n "${FAKE_CLI_TOUCH:-}" ]; then
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

case "${FAKE_CLI_MODE:-}" in
  quota) echo 'Error: 429 Too Many Requests: rate limit exceeded' >&2; exit 1 ;;
  auth) echo 'Error: not logged in' >&2; [ "$TOOL" = gemini ] && exit 41; exit 1 ;;
esac

REPLY_FILE="${FAKE_CLI_REPLY:-worker-done.txt}"
case "$REPLY_FILE" in */*) ;; *) REPLY_FILE="$FDIR/replies/$REPLY_FILE" ;; esac
REPLY=""; [ -f "$REPLY_FILE" ] && REPLY="$(cat "$REPLY_FILE")"
jesc "$REPLY"

case "$TOOL" in
  claude)
    printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","session_id":"fake-0001"}\n' "$JE" ;;
  gemini)
    printf '{\n  "response": "%s",\n  "stats": {}\n}\n' "$JE" ;;
  codex)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
    printf '{"type":"thread.started","thread_id":"fake-thread-0001"}\n{"type":"turn.started"}\n'
    printf '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"%s"}}\n' "$JE"
    printf '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}\n'
    [ -n "$out" ] && printf '%s\n' "$REPLY" > "$out" ;;
  *)
    [ -n "$REPLY" ] && printf '%s\n' "$REPLY" ;;
esac

[ -n "${FAKE_CLI_STDERR:-}" ] && printf '%s\n' "$FAKE_CLI_STDERR" >&2
exit "${FAKE_CLI_EXIT:-0}"
