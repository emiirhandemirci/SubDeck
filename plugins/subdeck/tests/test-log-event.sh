#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-log-event.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/log-event.sh"
LAUNCH="$HERE/../scripts/run-hook.cmd"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

newproj(){ mktemp -d; }
allparse(){ # file -> count of lines that parse, via node
  node -e '
    const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
    let n=0; for(const x of l){ try{const o=JSON.parse(x); if(o.ts&&o.event&&o.payload!==undefined) n++;}catch(e){} }
    console.log(n+"/"+l.length);' "$1"
}

# 1. single start + stop (via launcher)
P="$(newproj)"
echo '{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"x"}' | CLAUDE_PROJECT_DIR="$P" bash "$LAUNCH" log-event SubagentStart
echo '{"hook_event_name":"SubagentStop","agent_id":"a1","last_assistant_message":"hi\nthere"}' | CLAUDE_PROJECT_DIR="$P" bash "$LAUNCH" log-event SubagentStop
check "$(allparse "$P/.subdeck/events.jsonl")" "2/2" "start+stop: 2 lines, both parse"
rm -rf "$P"

# 2. pretty-printed payload
P="$(newproj)"
printf '{\r\n  "hook_event_name": "SubagentStop",\r\n  "agent_id": "b",\r\n  "x": [1,\r\n 2]\r\n}\r\n' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStop
check "$(allparse "$P/.subdeck/events.jsonl")" "1/1" "multi-line payload stays one line"
rm -rf "$P"

# 3. parallel writers
P="$(newproj)"
for i in $(seq 1 30); do
  ( echo "{\"agent_id\":\"p$i\",\"n\":$i}" | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStart ) &
done
wait
check "$(allparse "$P/.subdeck/events.jsonl")" "30/30" "30 parallel writers: 30 lines, all parse"
if [ -e "$P/.subdeck/events.lock" ]; then bad "no leftover lock"; else ok "no leftover lock"; fi
[ -s "$P/.subdeck/hook-errors.log" ] && bad "no hook errors" || ok "no hook errors"
rm -rf "$P"

# 4. stale lock recovery
P="$(newproj)"
mkdir -p "$P/.subdeck/events.lock"
echo "99999 $(( $(date +%s) - 60 ))" > "$P/.subdeck/events.lock/owner"
echo '{"agent_id":"s"}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStart
check "$(allparse "$P/.subdeck/events.jsonl")" "1/1" "stale lock recovered"
[ -e "$P/.subdeck/events.lock" ] && bad "lock released after stale recovery" || ok "lock released after stale recovery"
rm -rf "$P"

echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
