#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-statusline.sh   (temp dirs only)
HERE="$(cd "$(dirname "$0")" && pwd)"
SL="$HERE/../scripts/statusline.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $(printf '%s' "$1" | cat -v))"; fi; }

export TZ=UTC
unset NO_COLOR SUBDECK_ASCII SUBDECK_STATUSLINE_CHAIN
P="$(mktemp -d)"; T="$(mktemp -d)"
mkdir -p "$P/.subdeck" "$T/s1/subagents"
ev() { printf '{"ts":"%s","event":"%s","agent_id":"%s","agent_type":"worker-sonnet","transcript_path":"%s","session_id":"s1","payload":{"agent_id":"%s","last_assistant_message":"x"}}\n' "$1" "$2" "$3" "$4" "$3"; }
isoat() { date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
run() { printf '{"session_id":"x","workspace":{"current_dir":"%s"}}' "$1" | bash "$SL"; }

# no .subdeck: just the name
E="$(mktemp -d)"
eq "$(run "$E")" "SubDeck" "no .subdeck -> SubDeck"
eq "$(printf '' | bash "$SL" </dev/null)" "SubDeck" "empty stdin does not crash"
eq "$(printf 'garbage{{' | bash "$SL"; echo "rc=$?")" "$(printf 'SubDeck\nrc=0')" "garbage stdin -> SubDeck, exit 0"

# nothing active (only a finished agent)
{ ev "$(isoat -100)" SubagentStart f1ffffff "$T/s1.jsonl"; ev "$(isoat -90)" SubagentStop f1ffffff "$T/s1.jsonl"; } > "$P/.subdeck/events.jsonl"
eq "$(run "$P")" "SubDeck" "only finished -> SubDeck"

# 2 running, 1 waiting (trailing AskUserQuestion)
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"q":"x"}}]}}' > "$T/s1/subagents/agent-w1wwwwww.jsonl"
for id in r1rrrrrr r2rrrrrr; do printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}' > "$T/s1/subagents/agent-$id.jsonl"; done
{ ev "$(isoat -100)" SubagentStart r1rrrrrr "$T/s1.jsonl"; ev "$(isoat -99)" SubagentStart r2rrrrrr "$T/s1.jsonl"; ev "$(isoat -98)" SubagentStart w1wwwwww "$T/s1.jsonl"; } > "$P/.subdeck/events.jsonl"
ESC=$'\033'
eq "$(run "$P" | sed "s/${ESC}\[[0-9;]*m//g")" "SubDeck ● 2 running  ◐ 1 waiting" "2 running + 1 waiting, zero failed omitted"
OUT="$(run "$P")"
case "$OUT" in *"${ESC}[32m"*"${ESC}[38;5;208m"*) ok "ANSI green + orange present" ;; *) bad "ANSI colours missing" ;; esac
eq "$(run "$P" | NO_COLOR=1 bash -c 'cat' >/dev/null; NO_COLOR=1 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$P\"}}")" "SubDeck ● 2 running  ◐ 1 waiting" "NO_COLOR removes ANSI"
eq "$(SUBDECK_ASCII=1 NO_COLOR=1 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$P\"}}")" "SubDeck * 2 running  ~ 1 waiting" "SUBDECK_ASCII=1 fallback"

# project_dir preferred, falls back to cwd; backslash-escaped JSON paths do not break parsing
eq "$(NO_COLOR=1 bash "$SL" <<<"{\"cwd\":\"$P\"}")" "SubDeck ● 2 running  ◐ 1 waiting" "cwd fallback"
eq "$(NO_COLOR=1 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$E\",\"project_dir\":\"$P\"}}")" "SubDeck ● 2 running  ◐ 1 waiting" "project_dir with .subdeck wins over current_dir"
eq "$(NO_COLOR=1 CLAUDE_PROJECT_DIR="$P" bash "$SL" <<<'{"workspace":{"current_dir":"Z:\nope\x"}}')" "SubDeck ● 2 running  ◐ 1 waiting" "unusable JSON path -> CLAUDE_PROJECT_DIR"

# failed is always 0 for hook-recorded agents; counts line stays machine-parsable
eq "$(bash "$HERE/../scripts/status.sh" --counts "$P")" "running=2 waiting=1 failed=0 idle=0 finished=0 stale=0" "status.sh --counts line"

# chaining
OUT="$(NO_COLOR=1 SUBDECK_STATUSLINE_CHAIN='cat >/dev/null; printf "prev-line\nsecond"' bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$P\"}}")"
eq "$OUT" "SubDeck ● 2 running  ◐ 1 waiting | prev-line" "chain appends first line of previous status line"
OUT="$(NO_COLOR=1 SUBDECK_STATUSLINE_CHAIN='exit 3' bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$P\"}}"; echo "rc=$?")"
eq "$OUT" "$(printf 'SubDeck ● 2 running  ◐ 1 waiting\nrc=0')" "failing chain command is ignored, exit 0"
OUT="$(NO_COLOR=1 SUBDECK_STATUSLINE_CHAIN='grep -o "current_dir[^,}]*"' bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$E\"}}")"
eq "$OUT" "SubDeck | current_dir\":\"$E\"" "chain receives the same stdin"

# speed: 200 agents (100 running with transcripts)
PF="$(mktemp -d)"; mkdir -p "$PF/.subdeck"
{
  for i in $(seq 1 200); do
    id="$(printf 'a%09d' "$i")"
    ev 2026-01-01T10:00:00Z SubagentStart "$id" "$T/s1.jsonl"
    [ $((i % 2)) = 0 ] && ev 2026-01-01T10:01:00Z SubagentStop "$id" "$T/s1.jsonl"
  done
} > "$PF/.subdeck/events.jsonl"
for i in $(seq 1 100); do cp "$T/s1/subagents/agent-r1rrrrrr.jsonl" "$T/s1/subagents/agent-$(printf 'a%09d' $((i*2-1))).jsonl"; done
S0=$(date +%s%N 2>/dev/null); OUT="$(NO_COLOR=1 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$PF\"}}")"; S1=$(date +%s%N 2>/dev/null)
eq "$OUT" "SubDeck ● 100 running" "200 agents: 100 running counted"
case "$S0$S1" in *N*|"") echo "info timing unavailable" ;; *) echo "info 200 agents: $(( (S1 - S0) / 1000000 )) ms" ;; esac

rm -rf "$P" "$T" "$E" "$PF"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
