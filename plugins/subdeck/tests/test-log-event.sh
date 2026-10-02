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
# state lives outside the project (lib-paths.sh); keep it out of the real home
export SUBDECK_STATE_DIR="$(mktemp -d)"; trap 'rm -rf "$SUBDECK_STATE_DIR"' EXIT
sd(){ ( . "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$1"; printf '%s' "$SD_STATE" ) }
allparse(){ # file -> count of lines that parse, via node
  node -e '
    const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
    let n=0; for(const x of l){ try{const o=JSON.parse(x); if(o.ts&&o.event&&o.payload!==undefined) n++;}catch(e){} }
    console.log(n+"/"+l.length);' "$1"
}
count_all(){ # state dir -> total events across events.jsonl + events.d, all valid
  node -e '
    const fs=require("fs"),p=process.argv[1];let n=0,bad=0;
    const chk=x=>{try{const o=JSON.parse(x);if(o.ts&&o.event&&o.payload!==undefined)n++;else bad++;}catch(e){bad++;}};
    try{fs.readFileSync(p+"/events.jsonl","utf8").split("\n").filter(Boolean).forEach(chk);}catch(e){}
    try{for(const f of fs.readdirSync(p+"/events.d")){ if(!f.endsWith(".json"))continue; const t=fs.readFileSync(p+"/events.d/"+f,"utf8"); if(t.trim().split("\n").length!==1)bad++; chk(t.trim()); }}catch(e){}
    console.log(n+"/"+bad);' "$1"
}


# 1. single start + stop (via launcher)
P="$(newproj)"; D="$(sd "$P")"
echo '{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"x"}' | CLAUDE_PROJECT_DIR="$P" bash "$LAUNCH" log-event SubagentStart
echo '{"hook_event_name":"SubagentStop","agent_id":"a1","last_assistant_message":"hi\nthere"}' | CLAUDE_PROJECT_DIR="$P" bash "$LAUNCH" log-event SubagentStop
check "$(allparse "$D/events.jsonl")" "2/2" "start+stop: 2 lines, both parse"
rm -rf "$P" "$D"

# 2. pretty-printed payload
P="$(newproj)"; D="$(sd "$P")"
printf '{\r\n  "hook_event_name": "SubagentStop",\r\n  "agent_id": "b",\r\n  "x": [1,\r\n 2]\r\n}\r\n' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStop
check "$(allparse "$D/events.jsonl")" "1/1" "multi-line payload stays one line"
rm -rf "$P" "$D"

# 3. parallel writers
P="$(newproj)"; D="$(sd "$P")"
for i in $(seq 1 30); do
  ( echo "{\"agent_id\":\"p$i\",\"n\":$i}" | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStart ) &
done
wait
check "$(count_all "$D")" "30/0" "30 parallel writers: jsonl + events.d == 30, all parse"
# Under heavy host load a writer can legitimately wait out the 5 s lock budget and take the
# lossless fallback; that is allowed. What must never happen: a dropped/failed write, or a
# fallback notice without a matching events.d file.
if grep -qE 'dropped|append failed|fallback write failed' "$D/hook-errors.log" 2>/dev/null; then bad "no dropped events"; else ok "no dropped events"; fi
check "$(cat "$D/hook-errors.log" 2>/dev/null | grep -c "wrote fallback")" "$(ls "$D/events.d" 2>/dev/null | grep -c '\.json$')" "fallback notices match events.d files"
if [ -e "$D/events.lock" ]; then bad "no leftover lock"; else ok "no leftover lock"; fi
rm -rf "$P" "$D"

# 4. stale lock recovery
P="$(newproj)"; D="$(sd "$P")"
mkdir -p "$D/events.lock"
echo "99999 $(( $(date +%s) - 60 ))" > "$D/events.lock/owner"
echo '{"agent_id":"s"}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStart
check "$(allparse "$D/events.jsonl")" "1/1" "stale lock recovered"
[ -e "$D/events.lock" ] && bad "lock released after stale recovery" || ok "lock released after stale recovery"
rm -rf "$P" "$D"

# 5. top-level field lift
P="$(newproj)"; D="$(sd "$P")"
echo '{"hook_event_name":"SubagentStart","agent_id":"agent-7","agent_type":"worker-sonnet","transcript_path":"C:\\Users\\u\\t.jsonl","session_id":"sess-9"}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStart
FIELDS="$(node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").trim());console.log([o.agent_id,o.agent_type,o.transcript_path,o.session_id,o.payload.agent_id].join("|"))' "$D/events.jsonl")"
check "$FIELDS" 'agent-7|worker-sonnet|C:\Users\u\t.jsonl|sess-9|agent-7' "top-level fields lifted"
echo '{"hook_event_name":"SubagentStart"}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStart
FIELDS="$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n");const o=JSON.parse(l[1]);console.log([o.agent_id,o.agent_type,o.transcript_path,o.session_id].join("|"))' "$D/events.jsonl")"
check "$FIELDS" '|||' "absent fields become empty strings"
rm -rf "$P" "$D"

# 6. forced fallback: lock held by a live owner, writer must not drop the event
P="$(newproj)"; D="$(sd "$P")"
mkdir -p "$D/events.lock"
hold(){ echo "1 $(date +%s)" > "$D/events.lock/owner.tmp" && mv -f "$D/events.lock/owner.tmp" "$D/events.lock/owner"; }
hold
( for i in 1 2 3 4 5 6 7 8 9 10 11 12; do hold; sleep 0.5; done ) &
HOLDER=$!
echo '{"hook_event_name":"SubagentStop","agent_id":"fb1","agent_type":"t","transcript_path":"/x","session_id":"s"}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStop
wait $HOLDER
NF="$(ls "$D/events.d" 2>/dev/null | grep -c '\.json$')"
check "$NF" "1" "fallback wrote exactly one events.d file"
check "$(count_all "$D")" "1/0" "fallback file is valid one-line JSON"
FB="$(ls "$D/events.d/"*.json | head -1)"
case "$(basename "$FB")" in [0-9]*T[0-9]*Z-[0-9]*-[0-9]*.json) ok "fallback file name pattern";; *) bad "fallback file name pattern ($(basename "$FB"))";; esac
[ -e "$D/events.jsonl" ] && bad "jsonl untouched while lock held" || ok "jsonl untouched while lock held"
ls "$D/events.d" | grep -q '\.tmp$' && bad "no leftover .tmp" || ok "no leftover .tmp"
rm -rf "$P" "$D"

# 6b. partial owner file (mid-write, fresh mtime) must not be read as a stale timestamp:
# a holder completes the owner atomically after 0.5 s and keeps refreshing; writer must fall back, not steal
P="$(newproj)"; D="$(sd "$P")"
mkdir -p "$D/events.lock"
printf '1 17' > "$D/events.lock/owner"
hold(){ echo "1 $(date +%s)" > "$D/events.lock/owner.tmp" && mv -f "$D/events.lock/owner.tmp" "$D/events.lock/owner"; }
( sleep 0.5; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do hold; sleep 0.5; done ) &
HOLDER=$!
echo '{"hook_event_name":"SubagentStop","agent_id":"pp","agent_type":"t","transcript_path":"/x","session_id":"s"}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStop
wait $HOLDER
[ -e "$D/events.jsonl" ] && bad "partial owner: lock not stolen" || ok "partial owner: lock not stolen"
check "$(ls "$D/events.d" 2>/dev/null | grep -c '\.json$')" "1" "partial owner: event went to fallback"
rm -rf "$P" "$D"

# 7. 30 parallel writers, nothing lost regardless of path taken
P="$(newproj)"; D="$(sd "$P")"
for i in $(seq 1 30); do
  ( echo "{\"agent_id\":\"q$i\"}" | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStart ) &
done
wait
check "$(count_all "$D")" "30/0" "30 parallel writers: jsonl + events.d == 30, all parse"
rm -rf "$P" "$D"

# 8. writers never touch the project folder; a legacy <project>/.subdeck is left alone
P="$(newproj)"; D="$(sd "$P")"
mkdir -p "$P/.subdeck"; echo old > "$P/.subdeck/events.jsonl"
echo '{"agent_id":"n1"}' | CLAUDE_PROJECT_DIR="$P" bash "$SCRIPT" SubagentStart
check "$(cat "$P/.subdeck/events.jsonl")" "old" "legacy events.jsonl untouched"
check "$(ls -A "$P/.subdeck")" "events.jsonl" "nothing new in the legacy dir"
check "$(allparse "$D/events.jsonl")" "1/1" "event written to the state dir"
P2="$(newproj)"
echo '{"agent_id":"n2"}' | CLAUDE_PROJECT_DIR="$P2" bash "$SCRIPT" SubagentStart
[ -z "$(ls -A "$P2")" ] && ok "project folder stays empty" || bad "project folder written: $(ls -A "$P2")"
case "$D" in "$SUBDECK_STATE_DIR"/*) ok "state dir is under SUBDECK_STATE_DIR" ;; *) bad "state dir $D" ;; esac
rm -rf "$P" "$P2" "$D"

echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
