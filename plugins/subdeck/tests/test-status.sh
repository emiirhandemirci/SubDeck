#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-status.sh   (temp dirs only)
HERE="$(cd "$(dirname "$0")" && pwd)"
STATUS="$HERE/../scripts/status.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
hasnt() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then bad "$3"; else ok "$3"; fi; }

export TZ=UTC
P="$(mktemp -d)"; T="$(mktemp -d)"
mkdir -p "$P/.subdeck/events.d"
ev() { # ts event id type path [msg]
  printf '{"ts":"%s","event":"%s","agent_id":"%s","agent_type":"%s","transcript_path":"%s","session_id":"s1","payload":{"agent_id":"%s","last_assistant_message":"%s"}}\n' "$1" "$2" "$3" "$4" "$5" "$3" "$6"
}
NOWISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# transcripts (synthetic): one tool_use, one text, one big file whose first line is partial
printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}' \
 '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"thinking"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"C:\\Users\\x\\proj\\src\\main.rs","limit":5}}]}}' > "$T/run1.jsonl"
printf '%s\r\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}' \
 '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Now writing the parser \"carefully\""}]}}' > "$T/run2.jsonl"

{
  ev 2026-01-01T10:00:00Z SubagentStart aaaaaaaa11 worker-sonnet "$T/run1.jsonl"
  ev 2026-01-01T10:00:05Z SubagentStart bbbbbbbb22 researcher "$T/run2.jsonl"
  ev 2026-01-01T10:01:00Z SubagentStart cccccccc33 worker-opus ""
  ev 2026-01-01T10:03:05Z SubagentStop  cccccccc33 worker-opus "" 'Fixed the bug in parser.\nSecond line hidden'
  ev 2026-01-01T10:10:00Z SubagentStart dddddddd44 worker-sonnet ""
} > "$P/.subdeck/events.jsonl"
# done via events.d (Stop written before its Start file order does not matter)
ev 2026-01-01T10:12:10Z SubagentStop dddddddd44 worker-sonnet "" 'All done' > "$P/.subdeck/events.d/20260101T101210Z-1-1.json"
ev 2026-01-01T10:20:00Z SubagentStart eeeeeeee55 verifier "" > "$P/.subdeck/events.d/20260101T102000Z-2-2.json"
ev 2026-01-01T10:20:30Z SubagentStop  eeeeeeee55 verifier "" 'Approved' > "$P/.subdeck/events.d/20260101T102030Z-3-3.json"

OUT="$(bash "$STATUS" "$P")"
has "$OUT" '^AGENT +TYPE +STARTED +DURATION +STATE +ACTIVITY' "header"
has "$OUT" '^aaaaaaaa +worker-sonnet +10:00:00 .* running +Read C:.Users.x.proj.src.main\.rs' "running1: tool use + unescaped path"
has "$OUT" '^bbbbbbbb +researcher +10:00:05 .* running +Now writing the parser "carefully"' "running2: last text (CRLF file, last block wins)"
has "$OUT" '^cccccccc +worker-opus +10:01:00 +2m05s +done +Fixed the bug in parser\.$' "done1: first line, duration"
has "$OUT" '^dddddddd +worker-sonnet +10:10:00 +2m10s +done +All done' "done2 via events.d (start jsonl, stop file)"
has "$OUT" '^eeeeeeee +verifier +10:20:00 +30s +done +Approved' "done3 fully in events.d"
[ "$(printf '%s\n' "$OUT" | grep -c ' running ')" = 2 ] && ok "2 running" || bad "2 running"
[ "$(printf '%s\n' "$OUT" | grep -c ' done ')" = 3 ] && ok "3 done" || bad "3 done"
FIRST_DONE="$(printf '%s\n' "$OUT" | grep -n ' done ' | head -1 | cut -d: -f1)"
LAST_RUN="$(printf '%s\n' "$OUT" | grep -n ' running ' | tail -1 | cut -d: -f1)"
[ "$LAST_RUN" -lt "$FIRST_DONE" ] && ok "running listed before done" || bad "running listed before done"

# last-10 limit and --all
for i in $(seq 1 12); do
  n=$(printf '%02d' $i)
  ev "2026-01-02T10:$n:00Z" SubagentStart "z$n$n$n$n$n$n" t "" >> "$P/.subdeck/events.jsonl"
  ev "2026-01-02T10:$n:10Z" SubagentStop  "z$n$n$n$n$n$n" t "" "m$n" >> "$P/.subdeck/events.jsonl"
done
OUT="$(bash "$STATUS" "$P")"
[ "$(printf '%s\n' "$OUT" | grep -c ' done ')" = 10 ] && ok "default: last 10 done" || bad "default: last 10 done"
hasnt "$OUT" '^cccccccc' "default hides oldest done"
OUT="$(bash "$STATUS" --all "$P")"
[ "$(printf '%s\n' "$OUT" | grep -c ' done ')" = 15 ] && ok "--all: every done agent" || bad "--all: every done agent"

# missing transcript for a running agent, malformed line tolerated
P2="$(mktemp -d)"; mkdir -p "$P2/.subdeck"
{ ev 2026-01-01T09:00:00Z SubagentStart ffffffff66 x "$T/nope.jsonl"; echo 'garbage {'; } > "$P2/.subdeck/events.jsonl"
OUT="$(bash "$STATUS" "$P2")"
has "$OUT" '^ffffffff +x +09:00:00 .* running +-$' "missing transcript -> '-'"

# empty / missing
P3="$(mktemp -d)"
[ "$(bash "$STATUS" "$P3")" = "no agents recorded yet" ] && ok "no .subdeck -> message" || bad "no .subdeck -> message"
mkdir -p "$P3/.subdeck"; : > "$P3/.subdeck/events.jsonl"
[ "$(bash "$STATUS" "$P3")" = "no agents recorded yet" ] && ok "empty file -> message" || bad "empty file -> message"

# end-to-end with the real logger
P4="$(mktemp -d)"
echo "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"e2e12345\",\"agent_type\":\"w\",\"transcript_path\":\"$T/run1.jsonl\"}" | CLAUDE_PROJECT_DIR="$P4" bash "$HERE/../scripts/log-event.sh" SubagentStart
OUT="$(bash "$STATUS" "$P4")"
has "$OUT" '^e2e12345 +w +[0-9:]{8} .* running +Read ' "logger -> status end to end"

rm -rf "$P" "$P2" "$P3" "$P4" "$T"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
