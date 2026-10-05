#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-statusline.sh   (temp dirs only)
HERE="$(cd "$(dirname "$0")" && pwd)"
SL="$HERE/../scripts/statusline.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $(printf '%s' "$1" | cat -v))"; fi; }

export TZ=UTC
# independent of the caller: no inherited SUBDECK_* / project vars, and a fresh empty working directory
for v in $(compgen -v | grep -E '^SUBDECK_') CLAUDE_PROJECT_DIR NO_COLOR COLUMNS; do unset "$v"; done
SANDBOX="$(mktemp -d)"; cd "$SANDBOX" || exit 1
export SUBDECK_STATE_DIR="$(mktemp -d)"   # per-project state root (lib-paths.sh), never the real home
sd() { ( . "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$1"; printf '%s' "$SD_STATE" ); }
export SUBDECK_STATUSLINE_TTL=0   # cache off unless a test enables it
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
# JSON built in a variable first: bash 3.2 (macOS) mangles this here-string when nested inside "$(...)" as an argument
J2="{\"workspace\":{\"current_dir\":\"$E\",\"project_dir\":\"$P\"}}"
eq "$(NO_COLOR=1 bash "$SL" <<<"$J2")" "SubDeck ● 2 running  ◐ 1 waiting" "project_dir with .subdeck wins over current_dir"
eq "$(NO_COLOR=1 CLAUDE_PROJECT_DIR="$P" bash "$SL" <<<'{"workspace":{"current_dir":"Z:\nope\x"}}')" "SubDeck ● 2 running  ◐ 1 waiting" "unusable JSON path -> CLAUDE_PROJECT_DIR"

# counts line stays machine-parsable (no failed records here)
eq "$(bash "$HERE/../scripts/status.sh" --counts "$P")" "running=2 waiting=1 failed=0 idle=0 finished=0 stale=0" "status.sh --counts line"

# failed group: an unstopped agent whose transcript ends in an API error is counted and shown in red
printf '%s\n' '{"type":"user","timestamp":"2026-01-03T10:00:00Z","message":{"role":"user","content":"go"}}' '{"type":"assistant","timestamp":"2026-01-03T10:02:00Z","isApiErrorMessage":true,"message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error"}]}}' > "$T/s1/subagents/agent-x1xxxxxx.jsonl"
PF="$(mktemp -d)"; mkdir -p "$PF/.subdeck"; cp "$P/.subdeck/events.jsonl" "$PF/.subdeck/events.jsonl"
ev "$(isoat -97)" SubagentStart x1xxxxxx "$T/s1.jsonl" >> "$PF/.subdeck/events.jsonl"
eq "$(bash "$HERE/../scripts/status.sh" --counts "$PF")" "running=2 waiting=1 failed=1 idle=0 finished=0 stale=0" "status.sh --counts shows failed=1"
eq "$(run "$PF" | sed "s/${ESC}\[[0-9;]*m//g")" "SubDeck ● 2 running  ◐ 1 waiting  ✕ 1 failed" "failed group shown when N > 0"
case "$(run "$PF")" in *"${ESC}[31m"*"✕ 1 failed"*) ok "failed group is red" ;; *) bad "failed group is not red" ;; esac

# chaining
OUT="$(NO_COLOR=1 SUBDECK_STATUSLINE_CHAIN='cat >/dev/null; printf "prev-line\nsecond"' bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$P\"}}")"
eq "$OUT" "SubDeck ● 2 running  ◐ 1 waiting | prev-line" "chain appends first line of previous status line"
OUT="$(NO_COLOR=1 SUBDECK_STATUSLINE_CHAIN='exit 3' bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$P\"}}"; echo "rc=$?")"
eq "$OUT" "$(printf 'SubDeck ● 2 running  ◐ 1 waiting\nrc=0')" "failing chain command is ignored, exit 0"
OUT="$(NO_COLOR=1 SUBDECK_STATUSLINE_CHAIN='grep -o "current_dir[^,}]*"' bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$E\"}}")"
eq "$OUT" "SubDeck | current_dir\":\"$E\"" "chain receives the same stdin"

# cache: reused within the TTL, refreshed after, atomic file, no leftovers
PC="$(mktemp -d)"; PCS="$(sd "$PC")"; mkdir -p "$PCS"   # new layout: events and cache in the state dir
{ ev "$(isoat -100)" SubagentStart r1rrrrrr "$T/s1.jsonl"; } > "$PCS/events.jsonl"
cj() { NO_COLOR=1 SUBDECK_STATUSLINE_TTL=600 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$PC\"}}"; }
eq "$(cj)" "SubDeck ● 1 running" "cache: cold run"
[ -f "$PCS/statusline.cache" ] && ok "cache: file written" || bad "cache: file missing"
grep -Eq '^[0-9]+ running=1 ' "$PCS/statusline.cache" && ok "cache: format '<epoch> <counts>'" || bad "cache: format"
ev "$(isoat -99)" SubagentStart r2rrrrrr "$T/s1.jsonl" >> "$PCS/events.jsonl"
eq "$(cj)" "SubDeck ● 1 running" "cache: warm run reuses the old counts"
eq "$(NO_COLOR=1 SUBDECK_STATUSLINE_TTL=0 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$PC\"}}")" "SubDeck ● 2 running" "cache: TTL=0 bypasses it"
sed "s/^[0-9]* /1 /" "$PCS/statusline.cache" > "$PCS/sc.tmp" && mv "$PCS/sc.tmp" "$PCS/statusline.cache"
eq "$(cj)" "SubDeck ● 2 running" "cache: expired entry is recomputed"
[ "$(ls "$PCS" | grep -c 'statusline.cache\.')" = 0 ] && ok "cache: no tmp leftovers" || bad "cache: tmp leftovers"
printf 'junk' > "$PCS/statusline.cache"
eq "$(cj)" "SubDeck ● 2 running" "cache: corrupt file is ignored"
rm -rf "$PC" "$PCS"

# legacy <project>/.subdeck and the state dir are merged; the cache goes to the state dir, never the project
PM="$(mktemp -d)"; PMS="$(sd "$PM")"; mkdir -p "$PM/.subdeck"
ev "$(isoat -100)" SubagentStart r1rrrrrr "$T/s1.jsonl" > "$PM/.subdeck/events.jsonl"
eq "$(NO_COLOR=1 SUBDECK_STATUSLINE_TTL=600 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$PM\"}}")" "SubDeck ● 1 running" "legacy-only project counted"
[ -f "$PMS/statusline.cache" ] && ok "legacy-only project: cache in the state dir" || bad "legacy-only: no cache"
mkdir -p "$PMS"; ev "$(isoat -99)" SubagentStart r2rrrrrr "$T/s1.jsonl" > "$PMS/events.jsonl"
eq "$(NO_COLOR=1 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$PM\"}}")" "SubDeck ● 2 running" "legacy and state-dir events merged"
[ "$(ls -A "$PM/.subdeck")" = events.jsonl ] && ok "nothing written into the project" || bad "project written: $(ls -A "$PM/.subdeck")"
E2="$(mktemp -d)"; mkdir -p "$(sd "$E2")"; ev "$(isoat -100)" SubagentStart r1rrrrrr "$T/s1.jsonl" > "$(sd "$E2")/events.jsonl"
eq "$(NO_COLOR=1 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$E\",\"project_dir\":\"$E2\"}}")" "SubDeck ● 1 running" "candidate with a state dir wins"
rm -rf "$PM" "$PMS" "$E2" "$(sd "$E2")"

# speed: cold (cache off) and warm (cache on) with 20 and 200 agents (info only unless SUBDECK_PERF_STRICT=1)
ms_now() { date +%s%N 2>/dev/null; }
perf() { # agents
  local n="$1" PF i id S0 S1 best cold warm k
  PF="$(mktemp -d)"; mkdir -p "$PF/.subdeck"
  {
    for i in $(seq 1 "$n"); do
      id="$(printf 'a%09d' "$i")"
      ev 2026-01-01T10:00:00Z SubagentStart "$id" "$T/s1.jsonl"
      [ $((i % 2)) = 0 ] && ev 2026-01-01T10:01:00Z SubagentStop "$id" "$T/s1.jsonl"
    done
  } > "$PF/.subdeck/events.jsonl"
  for i in $(seq 1 "$n"); do [ $((i % 2)) = 1 ] && cp "$T/s1/subagents/agent-r1rrrrrr.jsonl" "$T/s1/subagents/agent-$(printf 'a%09d' "$i").jsonl"; done
  S0=$(ms_now); OUT="$(NO_COLOR=1 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$PF\"}}")"; S1=$(ms_now)
  eq "$OUT" "SubDeck ● $((n / 2)) running" "$n agents: $((n / 2)) running counted"
  cold=$(( (S1 - S0) / 1000000 ))
  S0=$(ms_now); NO_COLOR=1 SUBDECK_STATUSLINE_TTL=30 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$PF\"}}" >/dev/null
  S1=$(ms_now); cold2=$(( (S1 - S0) / 1000000 ))   # fills the cache
  best=999999
  for k in 1 2 3 4 5; do
    S0=$(ms_now); NO_COLOR=1 SUBDECK_STATUSLINE_TTL=30 bash "$SL" <<<"{\"workspace\":{\"current_dir\":\"$PF\"}}" >/dev/null; S1=$(ms_now)
    warm=$(( (S1 - S0) / 1000000 )); [ "$warm" -lt "$best" ] && best="$warm"
  done
  echo "info $n agents: cold ${cold} ms, warm (best of 5) ${best} ms"
  if [ "${SUBDECK_PERF_STRICT:-0}" = 1 ]; then
    [ "$best" -lt 300 ] && ok "$n agents: warm < 300 ms" || bad "$n agents: warm ${best} ms"
  fi
  rm -rf "$PF"
}
case "$(ms_now)" in *N*|"") echo "info timing unavailable" ;; *) perf 20; perf 200 ;; esac

cd / ; rm -rf "$P" "$T" "$E" "$PF" "$SANDBOX" "$SUBDECK_STATE_DIR"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
