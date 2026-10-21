#!/usr/bin/env bash
# SubDeck knowledge ledger: findings tied to a file line, with a hash of the cited lines so a stale finding is
# detected instead of trusted. Never stores file contents, only the cksum of the cited line +-2 lines.
# Usage: ledger.sh [--project <dir>] <command>
#   add <file>:<line> "<finding>" [--agent A] [--task T]   store a finding (file relative to the project, or absolute)
#   list [--path P]                                        one line per entry: id status path:line finding
#   check                                                  re-hash; mark entries whose cited lines changed as stale
#   prune --stale                                          drop stale entries
# State: <state dir>/ledger.tsv (see lib-paths.sh). Fields (tab separated): id ts path line hash agent task status finding.
# Also sourceable: ld_handoff <state-dir> <agent-id> prints the handoff record log-event.sh wrote for that agent
# (<state>/handoff/<agent-id>.txt), for tasks.sh resume-prompt. Bash 3.2+, no jq/node.

LD_HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$LD_HERE" = "${BASH_SOURCE[0]}" ] && LD_HERE="."

# ld_handoff STATE_DIR AGENT_ID -> prints the record (nothing when absent)
ld_handoff() {
  local f="$1/handoff/${2//[^A-Za-z0-9._-]/}.txt"
  [ -n "$2" ] && [ -f "$f" ] && cat "$f" 2>/dev/null
  return 0
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0 2>/dev/null || true

die() { printf 'ledger: %s\n' "$2" >&2; exit "$1"; }

PROJECT="${CLAUDE_PROJECT_DIR:-}"
if [ "${1:-}" = --project ]; then PROJECT="${2:-}"; shift 2 2>/dev/null; fi
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="$(pwd)"
. "$LD_HERE/lib-paths.sh" || die 1 "lib-paths.sh missing"
sd_state_dir "$PROJECT"
[ -n "$SD_KEY" ] || die 1 "no project key"
STORE="$SD_STATE/ledger.tsv"

# hash FILE LINE -> cksum of lines LINE-2..LINE+2 (CR stripped so CRLF checkouts hash the same)
hash_at() {
  local a=$(( $2 - 2 )); [ "$a" -lt 1 ] && a=1
  sed -n "${a},$(( $2 + 2 ))p" "$1" 2>/dev/null | tr -d '\r' | cksum | cut -d' ' -f1,2 | tr ' ' '-'
}
resolve() { case "$1" in /*|[A-Za-z]:*) RP="$1" ;; *) RP="$PROJECT/$1" ;; esac; }
clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }

cmd_add() {
  local agent="${SUBDECK_AGENT:-}" task="${SUBDECK_TASK:-}" loc="" text="" a
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      --agent) agent="${2:-}"; shift ;;
      --task) task="${2:-}"; shift ;;
      *) if [ -z "$loc" ]; then loc="$a"; elif [ -z "$text" ]; then text="$a"; else die 2 "unexpected argument '$a'"; fi ;;
    esac
    shift
  done
  [[ $loc =~ ^(.+):([0-9]+)$ ]] || die 2 'usage: add <file>:<line> "<finding>"'
  local path="${BASH_REMATCH[1]}" line="${BASH_REMATCH[2]}"
  [ -n "$text" ] || die 2 'usage: add <file>:<line> "<finding>"'
  resolve "$path"
  [ -f "$RP" ] || die 2 "file not found: $path"
  [ "$line" -ge 1 ] || die 2 "line must be >= 1"
  local n; n="$(wc -l < "$RP" | tr -d ' ')"
  [ "$line" -le $(( n + 1 )) ] || die 2 "line $line is beyond the end of $path ($n lines)"
  path="${path//\\//}"
  case "$path" in "$PROJECT"/*) path="${path#"$PROJECT"/}" ;; esac
  mkdir -p "$SD_STATE" || die 1 "cannot create state dir"
  local id=1
  [ -f "$STORE" ] && id=$(( $(awk -F'\t' 'BEGIN{m=0} $1+0>m{m=$1+0} END{print m}' "$STORE") + 1 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$line" "$(hash_at "$RP" "$line")" \
    "$(clean "$agent")" "$(clean "$task")" ok "$(clean "$text")" >> "$STORE"
  printf 'added %s %s:%s\n' "$id" "$path" "$line"
}

cmd_list() {
  local p=""
  while [ $# -gt 0 ]; do
    case "$1" in --path) p="${2:-}"; shift ;; *) die 2 "unknown option $1" ;; esac
    shift
  done
  [ -f "$STORE" ] || return 0
  awk -F'\t' -v p="$p" 'p == "" || $3 == p { printf "%s %s %s:%s %s\n", $1, $8, $3, $4, $9 }' "$STORE"
}

cmd_check() {
  [ -f "$STORE" ] || { echo "ledger empty"; return 0; }
  local tmp="$STORE.tmp.$$" id ts path line hash agent task st text nh total=0 stale=0
  : > "$tmp"
  while IFS=$'\t' read -r id ts path line hash agent task st text; do
    [ -n "$id" ] || continue
    total=$((total + 1))
    resolve "$path"
    if [ -f "$RP" ]; then nh="$(hash_at "$RP" "$line")"; else nh=missing; fi
    if [ "$nh" = "$hash" ]; then st=ok; else st=stale; fi
    [ "$st" = stale ] && stale=$((stale + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$ts" "$path" "$line" "$hash" "$agent" "$task" "$st" "$text" >> "$tmp"
  done < "$STORE"
  mv -f "$tmp" "$STORE"
  printf '%s entries, %s stale\n' "$total" "$stale"
}

cmd_prune() {
  [ "${1:-}" = --stale ] || die 2 "usage: prune --stale"
  [ -f "$STORE" ] || { echo "pruned 0"; return 0; }
  local before after
  before="$(wc -l < "$STORE" | tr -d ' ')"
  awk -F'\t' '$8 != "stale"' "$STORE" > "$STORE.tmp.$$" && mv -f "$STORE.tmp.$$" "$STORE"
  after="$(wc -l < "$STORE" | tr -d ' ')"
  printf 'pruned %s\n' $(( before - after ))
}

CMD="${1:-}"; [ $# -gt 0 ] && shift
case "$CMD" in
  add) cmd_add "$@" ;;
  list) cmd_list "$@" ;;
  check) cmd_check ;;
  prune) cmd_prune "$@" ;;
  *) die 2 "usage: ledger.sh [--project <dir>] <add|list|check|prune> ..." ;;
esac
