#!/usr/bin/env bash
# Append one JSON line per subagent event to <project>/.subdeck/events.jsonl.
# Usage: log-event.sh <SubagentStart|SubagentStop>   (hook payload on stdin)
# No jq/node needed. Uses an mkdir lock; if not acquired in ~5 s, writes the event
# lock-free to .subdeck/events.d/<ts>-<pid>-<rand>.json (never dropped). Always exits 0.
# Envelope lifts agent_id, agent_type, transcript_path, session_id to the top level.

EVENT="${1:-}"
PAYLOAD="$(cat 2>/dev/null)"

if [ -z "$EVENT" ]; then
  EVENT="$(printf '%s' "$PAYLOAD" | tr -d '\r\n' | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p')"
fi
[ -n "$EVENT" ] || EVENT="Unknown"

PROJECT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT" ]; then
  PROJECT="$(printf '%s' "$PAYLOAD" | tr -d '\r\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="$(pwd)"

DIR="$PROJECT/.subdeck"
LOCK="$DIR/events.lock"
mkdir -p "$DIR" 2>/dev/null || exit 0
# Keep .subdeck/ out of the user's git status without touching their .gitignore. Never overwrite.
[ -e "$DIR/.gitignore" ] || printf '# Created by SubDeck: local agent events and state, not for version control.\n*\n' > "$DIR/.gitignore" 2>/dev/null

log_err() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$DIR/hook-errors.log" 2>/dev/null; }

COMPACT="$(printf '%s' "$PAYLOAD" | tr -d '\r\n')"
[ -n "$COMPACT" ] || COMPACT="null"
field() { # first occurrence of a string field; raw JSON string content
  printf '%s' "$COMPACT" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed 's/^[^:]*:[[:space:]]*"\(.*\)"$/\1/'
}
TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
AGENT_TYPE="$(field agent_type)"
[ -n "$AGENT_TYPE" ] || AGENT_TYPE="$(field agent_name)"   # Copilot names the sub-agent agent_name
LINE="$(printf '{"ts":"%s","event":"%s","agent_id":"%s","agent_type":"%s","transcript_path":"%s","session_id":"%s","payload":%s}' "$TS_NOW" "$EVENT" "$(field agent_id)" "$AGENT_TYPE" "$(field transcript_path)" "$(field session_id)" "$COMPACT")"
HAVE_LOCK=0
release() { [ "$HAVE_LOCK" = 1 ] && rm -rf "$LOCK" 2>/dev/null; HAVE_LOCK=0; }
trap 'release' EXIT
trap 'release; exit 0' INT TERM HUP

# epoch seconds into $1; bash < 4.2 (macOS /bin/bash 3.2) has no printf %(...)T
now_s() { printf -v "$1" '%(%s)T' -1 2>/dev/null || printf -v "$1" '%s' "$(date +%s)"; }
now_s START
MISSING=0
while :; do
  if mkdir "$LOCK" 2>/dev/null; then
    HAVE_LOCK=1
    # atomic owner write (tmp + mv): readers never see a partial line
    now_s OTS
    printf '%s %s\n' "$$" "$OTS" > "$LOCK/owner.tmp" 2>/dev/null \
      && mv -f "$LOCK/owner.tmp" "$LOCK/owner" 2>/dev/null
    break
  fi
  # Stale lock detection (older than 10 s; or no owner file for ~2 s).
  now_s NOW
  TS=""
  # accept only a complete line "<pid> <9+ digit epoch>"; anything else counts as missing
  OWNER=""
  if { read -r OWNER < "$LOCK/owner"; } 2>/dev/null && [[ "$OWNER" =~ ^[0-9]+\ ([0-9]{9,})$ ]]; then
    TS="${BASH_REMATCH[1]}"
  fi
  if [ -n "$TS" ]; then
    MISSING=0
    if [ $((NOW - TS)) -gt 10 ]; then
      mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -rf "$LOCK.stale.$$" 2>/dev/null
      continue
    fi
  else
    MISSING=$((MISSING + 1))
    if [ "$MISSING" -gt 40 ]; then
      mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -rf "$LOCK.stale.$$" 2>/dev/null
      MISSING=0
      continue
    fi
  fi
  if [ $((NOW - START)) -ge 5 ]; then
    # Lossless fallback: lock-free write of a unique file; never drop the event.
    mkdir -p "$DIR/events.d" 2>/dev/null
    FB="$DIR/events.d/$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM$RANDOM"
    if printf '%s\n' "$LINE" > "$FB.tmp" 2>/dev/null && mv "$FB.tmp" "$FB.json" 2>/dev/null; then
      log_err "lock busy for $EVENT; wrote fallback $(basename "$FB").json"
    else
      log_err "fallback write failed for $EVENT; event dropped"
    fi
    exit 0
  fi
  sleep 0.05
done

printf '%s\n' "$LINE" >> "$DIR/events.jsonl" 2>/dev/null || log_err "append failed for $EVENT"
release
exit 0
