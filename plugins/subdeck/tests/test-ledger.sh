#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-ledger.sh   (temp HOME/state; never touches the real ~/.subdeck)
HERE="$(cd "$(dirname "$0")" && pwd)"
LG="$HERE/../scripts/ledger.sh"; LE="$HERE/../scripts/log-event.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has(){ case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2' in '$1')" ;; esac; }
export SUBDECK_STATE_DIR="$(mktemp -d)" HOME="$(mktemp -d)"; P="$(mktemp -d)"
trap 'rm -rf "$SUBDECK_STATE_DIR" "$HOME" "$P"' EXIT
export CLAUDE_PROJECT_DIR="$P"
for i in 1 2 3 4 5 6 7 8 9 10; do echo "line $i" >> "$P/a.txt"; done
echo other > "$P/b.txt"

out="$(bash "$LG" add a.txt:5 "five is special" --agent w1 --task 150)"; has "$out" "added 1" "add"
bash "$LG" add b.txt:1 "b note" >/dev/null
check "$(bash "$LG" list | wc -l | tr -d ' ')" 2 "list shows 2"
check "$(bash "$LG" list --path b.txt)" "2 ok b.txt:1 b note" "list --path"
check "$(bash "$LG" check)" "2 entries, 0 stale" "check: fresh is not stale"
check "$(bash "$LG" list --path b.txt)" "2 ok b.txt:1 b note" "check keeps text of an entry with empty agent/task"
# negative control: file contents are not stored
grep -q "line 5" "$SUBDECK_STATE_DIR"/*/ledger.tsv && bad "contents stored" || ok "no file contents in store"
bash "$LG" add a.txt:99 "x" >/dev/null 2>&1; check "$?" 2 "line beyond EOF rejected"
bash "$LG" add nope.txt:1 "x" >/dev/null 2>&1; check "$?" 2 "missing file rejected"
# change a line within +-2 -> stale; far line -> still ok
sed 's/line 6/line six changed/' "$P/a.txt" > "$P/a.tmp" && mv "$P/a.tmp" "$P/a.txt"   # no sed -i: GNU and BSD disagree
check "$(bash "$LG" check)" "2 entries, 1 stale" "check: change within +-2 marks stale"
has "$(bash "$LG" list --path a.txt)" "stale" "list shows stale"
bash "$LG" add a.txt:10 "far" >/dev/null
sed 's/line 2$/line two/' "$P/a.txt" > "$P/a.tmp" && mv "$P/a.tmp" "$P/a.txt"
check "$(bash "$LG" check)" "3 entries, 1 stale" "change far from cited lines keeps ok"
check "$(bash "$LG" prune --stale)" "pruned 1" "prune --stale"
check "$(bash "$LG" list | wc -l | tr -d ' ')" 2 "2 left after prune"
check "$(bash "$LG" prune --stale)" "pruned 0" "prune again is a no-op"
rm "$P/b.txt"; check "$(bash "$LG" check)" "2 entries, 1 stale" "deleted file is stale"

# handoff
printf '%s' '{"hook_event_name":"SubagentStop","agent_id":"ag1","agent_type":"w","last_assistant_message":"short-name · done\nResult: did \"it\".\nCommits: abc123\nStop: done - ok"}' | bash "$LE" SubagentStop
H="$(ls "$SUBDECK_STATE_DIR"/*/handoff/ag1.txt 2>/dev/null)"
[ -n "$H" ] && ok "handoff file written" || bad "handoff file written"
has "$(cat "$H")" "Stop: done - ok" "handoff has Stop line"
has "$(cat "$H")" 'Result: did "it".' "handoff unescapes quotes"
has "$(cat "$H")" "Commits: abc123" "handoff has Commits"
out="$(bash -c ". '$LG'; ld_handoff '$(dirname "$(dirname "$H")")' ag1")"; has "$out" "Stop: done - ok" "ld_handoff reads it"
# negative controls: SubagentStart and no-message stop write nothing
printf '%s' '{"hook_event_name":"SubagentStart","agent_id":"ag2","last_assistant_message":"Stop: x"}' | bash "$LE" SubagentStart
printf '%s' '{"hook_event_name":"SubagentStop","agent_id":"ag3"}' | bash "$LE" SubagentStop
[ ! -e "$(dirname "$H")/ag2.txt" ] && [ ! -e "$(dirname "$H")/ag3.txt" ] && ok "no handoff for start / empty stop" || bad "unexpected handoff"
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" = 0 ]
