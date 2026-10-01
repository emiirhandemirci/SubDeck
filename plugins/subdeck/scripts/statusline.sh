#!/usr/bin/env bash
# SubDeck status line for Claude Code: agent counts for the current project on one line, e.g.
#   SubDeck ● 2 running  ◐ 1 waiting  ✕ 1 failed
# Claude Code runs this with the session JSON on stdin (workspace.project_dir / workspace.current_dir / cwd).
# Zero groups are omitted; just `SubDeck` when nothing is active.
#   SUBDECK_ASCII=1             ASCII symbols (* ~ x) instead of ● ◐ ✕
#   NO_COLOR                    no ANSI colours (green running, orange waiting, red failed)
#   SUBDECK_STATUSLINE_CHAIN    command of a previous status line; it gets the same stdin and its first
#                               output line is appended after " | "
# No jq/node; always exits 0.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
INPUT=""
if [ ! -t 0 ]; then IFS= read -r -d '' INPUT 2>/dev/null; fi   # builtin read: no fork
BS=$'\134'

json_str() { # key -> unescaped string value (first match) in JSTR, empty when absent; pure bash
  JSTR=""
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"(([^\"$BS$BS]|$BS$BS.)*)\""
  if [[ $INPUT =~ $re ]]; then
    JSTR="${BASH_REMATCH[1]}"
    JSTR="${JSTR//"$BS$BS"//}"; JSTR="${JSTR//"$BS"//}"
  fi
}

PROJECT=""
for k in project_dir current_dir cwd; do
  json_str "$k"; d="$JSTR"
  [ -n "$d" ] && [ -d "$d" ] || continue
  [ -n "$PROJECT" ] || PROJECT="$d"
  if [ -d "$d/.subdeck" ]; then PROJECT="$d"; break; fi
done
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

RUN=0; WAIT=0; FAIL=0
if [ -d "$PROJECT/.subdeck" ]; then
  LINE="$(bash "$HERE/status.sh" --counts "$PROJECT" 2>/dev/null)"
  for kv in $LINE; do
    case "$kv" in
      running=[0-9]*) RUN="${kv#*=}" ;;
      waiting=[0-9]*) WAIT="${kv#*=}" ;;
      failed=[0-9]*) FAIL="${kv#*=}" ;;
    esac
  done
fi

G=""; O=""; R=""; Z=""
if [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; O=$'\033[38;5;208m'; R=$'\033[31m'; Z=$'\033[0m'
fi
SR="●"; SW="◐"; SF="✕"
if [ "${SUBDECK_ASCII:-}" = 1 ]; then SR="*"; SW="~"; SF="x"; fi

OUT="SubDeck"; SEP=" "
if [ "$RUN" -gt 0 ] 2>/dev/null; then OUT="$OUT${SEP}${G}${SR} ${RUN} running${Z}"; SEP="  "; fi
if [ "$WAIT" -gt 0 ] 2>/dev/null; then OUT="$OUT${SEP}${O}${SW} ${WAIT} waiting${Z}"; SEP="  "; fi
if [ "$FAIL" -gt 0 ] 2>/dev/null; then OUT="$OUT${SEP}${R}${SF} ${FAIL} failed${Z}"; fi

if [ -n "${SUBDECK_STATUSLINE_CHAIN:-}" ]; then
  PREV="$(printf '%s' "$INPUT" | bash -c "$SUBDECK_STATUSLINE_CHAIN" 2>/dev/null)"
  PREV="${PREV%%$'\n'*}"; PREV="${PREV%$'\r'}"
  if [ -n "$PREV" ]; then OUT="$OUT | $PREV"; fi
fi
printf '%s\n' "$OUT"
exit 0
