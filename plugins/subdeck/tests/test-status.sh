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

# Real layout: hook transcript_path = MANAGER transcript <dir>/<sid>.jsonl; the subagent
# transcript is <dir>/<sid>/subagents/agent-<id>.jsonl (+ .meta.json).
mkdir -p "$T/s1/subagents"
# transcripts (synthetic): one tool_use, one text, one big file whose first line is partial
printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}' \
 '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"thinking"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"C:\\Users\\x\\proj\\src\\main.rs","limit":5}}]}}' > "$T/s1/subagents/agent-aaaaaaaa11.jsonl"
printf '%s\r\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}' \
 '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Now writing the parser \"carefully\""}]}}' > "$T/s1/subagents/agent-bbbbbbbb22.jsonl"

{
  ev 2026-01-01T10:00:00Z SubagentStart aaaaaaaa11 worker-sonnet "$T/s1.jsonl"
  ev 2026-01-01T10:00:05Z SubagentStart bbbbbbbb22 researcher "$T/s1.jsonl"
  ev 2026-01-01T10:01:00Z SubagentStart cccccccc33 worker-opus ""
  ev 2026-01-01T10:03:05Z SubagentStop  cccccccc33 worker-opus "" 'Fixed the bug in parser.\nSecond line hidden'
  ev 2026-01-01T10:10:00Z SubagentStart dddddddd44 worker-sonnet ""
} > "$P/.subdeck/events.jsonl"
# done via events.d (Stop written before its Start file order does not matter)
ev 2026-01-01T10:12:10Z SubagentStop dddddddd44 worker-sonnet "" 'All done' > "$P/.subdeck/events.d/20260101T101210Z-1-1.json"
ev 2026-01-01T10:20:00Z SubagentStart eeeeeeee55 verifier "" > "$P/.subdeck/events.d/20260101T102000Z-2-2.json"
ev 2026-01-01T10:20:30Z SubagentStop  eeeeeeee55 verifier "" 'Approved' > "$P/.subdeck/events.d/20260101T102030Z-3-3.json"

OUT="$(bash "$STATUS" "$P")"
has "$OUT" '^AGENT +TITLE +TYPE +STARTED +DURATION +TOKENS +STATE +ACTIVITY' "header"
has "$OUT" '^aaaaaaaa +- +worker-sonnet +10:00:00 .* running +Read C:.Users.x.proj.src.main\.rs' "running1: tool use + unescaped path"
has "$OUT" '^bbbbbbbb +- +researcher +10:00:05 .* running +Now writing the parser "carefully"' "running2: last text (CRLF file, last block wins)"
has "$OUT" '^cccccccc +- +worker-opus +10:01:00 +2m05s +- +done +Fixed the bug in parser\.$' "done1: first line, duration"
has "$OUT" '^dddddddd +- +worker-sonnet +10:10:00 +2m10s +- +done +All done' "done2 via events.d (start jsonl, stop file)"
has "$OUT" '^eeeeeeee +- +verifier +10:20:00 +30s +- +done +Approved' "done3 fully in events.d"
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
has "$OUT" '^ffffffff +- +x +09:00:00 .* stale\? +-$' "missing transcript, old Start -> stale? and '-'"

# empty / missing
P3="$(mktemp -d)"
[ "$(bash "$STATUS" "$P3")" = "no agents recorded yet" ] && ok "no .subdeck -> message" || bad "no .subdeck -> message"
mkdir -p "$P3/.subdeck"; : > "$P3/.subdeck/events.jsonl"
[ "$(bash "$STATUS" "$P3")" = "no agents recorded yet" ] && ok "empty file -> message" || bad "empty file -> message"

# end-to-end with the real logger
cp "$T/s1/subagents/agent-aaaaaaaa11.jsonl" "$T/s1/subagents/agent-e2e12345.jsonl"
P4="$(mktemp -d)"
echo "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"e2e12345\",\"agent_type\":\"w\",\"session_id\":\"s1\",\"transcript_path\":\"$T/s1.jsonl\"}" | CLAUDE_PROJECT_DIR="$P4" bash "$HERE/../scripts/log-event.sh" SubagentStart
OUT="$(bash "$STATUS" "$P4")"
has "$OUT" '^e2e12345 +- +w +[0-9:]{8} .* running +Read ' "logger -> status end to end"

# ---- UTF-8, JSON escapes, exit codes ----
utf8ok() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; }
nchars() { printf '%s' "$1" | node -e 'let s="";process.stdin.setEncoding("utf8").on("data",d=>s+=d).on("end",()=>console.log([...s].length))'; }
B='\'   # a lone backslash, used to build JSON escapes
U="$(mktemp -d)"; mkdir -p "$U/.subdeck" "$U/s1/subagents"
TR='şğıİöüç'
LONG="$(printf "$TR%.0s" 1 2 3 4 5 6 7 8 9 10 11 12)"   # 84 characters, 2 bytes each
{
  ev 2026-02-01T10:00:00Z SubagentStart u1u1u1u1 "$TR-agent-with-long-name" ""
  ev 2026-02-01T10:00:05Z SubagentStop  u1u1u1u1 "$TR-agent-with-long-name" "" "$LONG"
  ev 2026-02-01T10:01:00Z SubagentStart u2u2u2u2 w ""
  ev 2026-02-01T10:01:05Z SubagentStop  u2u2u2u2 w "" "${B}u015f${B}u011f${B}u0131 ${B}u0130${B}u00f6 ${B}ud83d${B}ude00 x"
  ev 2026-02-01T10:02:00Z SubagentStart u3u3u3u3 w ""
  ev 2026-02-01T10:02:05Z SubagentStop  u3u3u3u3 w "" 'a\\nb \"q\" c\\\\d \/e'
  ev 2026-02-01T10:03:00Z SubagentStart u4u4u4u4 w ""
  ev 2026-02-01T10:03:05Z SubagentStop  u4u4u4u4 w "" "$(printf '😀%.0s' $(seq 1 70))"
  ev 2026-02-01T10:04:00Z SubagentStart u5u5u5u5 w ""
  ev 2026-02-01T10:04:05Z SubagentStop  u5u5u5u5 w "" 'first line\nsecond ş'
} > "$U/.subdeck/events.jsonl"
UO="$(bash "$STATUS" "$U")"
UO2="$(LC_ALL=C.UTF-8 bash "$STATUS" "$U")"; [ "$UO2" = "$UO" ] && ok "utf8: same output under C.UTF-8" || bad "utf8: same output under C.UTF-8"
utf8ok "$UO" && ok "utf8: whole table is valid UTF-8" || bad "utf8: whole table is valid UTF-8"
L1="$(printf '%s\n' "$UO" | grep '^u1u1u1u1')"
ACT1="${L1##*  }"
[ "$(nchars "$ACT1")" = 60 ] && ok "utf8: Turkish text cut to 60 characters" || bad "utf8: Turkish text cut to 60 characters (got $(nchars "$ACT1"): $ACT1)"
case "$ACT1" in *...) ok "utf8: truncation marker";; *) bad "utf8: truncation marker ($ACT1)";; esac
has "$UO" '^u2u2u2u2 +- +w +.* done +şğı İö 😀 x$' "escapes: \uXXXX and surrogate pair decode"
has "$UO" '^u3u3u3u3 +- +w +.* done +a\\nb "q" c\\\\d /e$' "escapes: backslash-n stays literal, quote, escaped backslash and slash decode"
L4="$(printf '%s\n' "$UO" | grep '^u4u4u4u4')"; ACT4="${L4##*  }"
[ "$(nchars "$ACT4")" = 60 ] && ok "utf8: emoji cut to 60 characters" || bad "utf8: emoji cut to 60 characters ($(nchars "$ACT4"))"
has "$UO" '^u5u5u5u5 +- +w +.* done +first line$' "escapes: first line stops at \n"
# column alignment: STATE column starts at the same character offset on every row
OFFS="$(printf '%s' "$UO" | node -e 'let s="";process.stdin.setEncoding("utf8").on("data",d=>s+=d).on("end",()=>{const o=s.split("\n").filter(l=>l&&!l.startsWith("Session:")&&!l.startsWith("AGENT")).map(l=>{const c=[...l];const m=l.match(/ (running|done|stale?|STATE) /);return m?[...l.slice(0,m.index+1)].length:-1});console.log([...new Set(o)].join(","))})')"
case "$OFFS" in *,*|-1) bad "utf8: STATE column aligned in characters ($OFFS)";; *) ok "utf8: STATE column aligned in characters";; esac
# running agent, Turkish transcript text truncated safely
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$LONG\"}]}}" > "$U/s1/subagents/agent-u6u6u6u6.jsonl"
ev 2026-02-01T11:00:00Z SubagentStart u6u6u6u6 w "$U/s1.jsonl" > "$U/.subdeck/events.jsonl"
UO="$(bash "$STATUS" "$U")"
utf8ok "$UO" && ok "utf8: running activity valid UTF-8" || bad "utf8: running activity valid UTF-8"
L6="$(printf '%s\n' "$UO" | grep '^u6u6u6u6')"; [ "$(nchars "${L6##*  }")" = 60 ] && ok "utf8: running activity cut to 60 characters" || bad "utf8: running activity cut to 60 characters"
# also correct when the caller's locale is UTF-8

# exit code 0 on every path
E0="$(mktemp -d)"
bash "$STATUS" "$E0/does-not-exist" >/dev/null 2>&1; [ $? = 0 ] && ok "exit 0: missing .subdeck" || bad "exit 0: missing .subdeck"
mkdir -p "$E0/.subdeck"; : > "$E0/.subdeck/events.jsonl"
bash "$STATUS" "$E0" >/dev/null 2>&1; [ $? = 0 ] && ok "exit 0: empty log" || bad "exit 0: empty log"
ev 2026-02-01T12:00:00Z SubagentStart x1x1x1x1 w "$E0/no-such-transcript.jsonl" > "$E0/.subdeck/events.jsonl"
mkdir "$E0/dir.jsonl"; ev 2026-02-01T12:00:01Z SubagentStart x2x2x2x2 w "$E0/dir.jsonl" >> "$E0/.subdeck/events.jsonl"
bash "$STATUS" "$E0" >/dev/null 2>&1; [ $? = 0 ] && ok "exit 0: unreadable transcript" || bad "exit 0: unreadable transcript"
bash "$STATUS" --bogus --all "$E0" -x >/dev/null 2>&1; [ $? = 0 ] && ok "exit 0: bad args" || bad "exit 0: bad args"
bash "$STATUS" "" "" >/dev/null 2>&1; [ $? = 0 ] && ok "exit 0: empty args" || bad "exit 0: empty args"
printf 'garbage\n{"ts":"x"\n' > "$E0/.subdeck/events.jsonl"
bash "$STATUS" "$E0" >/dev/null 2>&1; [ $? = 0 ] && ok "exit 0: garbage log" || bad "exit 0: garbage log"
rm -rf "$U" "$E0"

# ---- title, tokens, session grouping (synthetic fixtures) ----
G="$(mktemp -d)"; mkdir -p "$G/.subdeck"
PR="$G/proj"; mkdir -p "$PR/sidAAAA1/subagents" "$PR/sidBBBB2/subagents"
# manager transcript with re-emitted ai-title records (last one wins)
printf '%s\n' '{"type":"ai-title","aiTitle":"Old title"}' '{"type":"user","message":{"role":"user","content":"x"}}' '{"type":"ai-title","aiTitle":"Durum raporu: şğı"}' > "$PR/sidAAAA1.jsonl"
SA="$PR/sidAAAA1/subagents"
# multi-line same-requestId usage: streaming snapshots; the LAST line is the definition
printf '%s\n' \
 '{"type":"assistant","requestId":"r1","message":{"role":"assistant","content":[{"type":"text","text":"a"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":5}}}' \
 '{"type":"assistant","requestId":"r1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"/a/b.sh"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":79000,"output_tokens":390,"cache_creation":{"ephemeral_5m_input_tokens":0}}}}' > "$SA/agent-t1t1t1t1.jsonl"
printf '%s' '{"agentType":"worker-sonnet","description":"Türkçe başlık: şğıİöüç uzun bir açıklama metni burada","toolUseId":"tu1"}' > "$SA/agent-t1t1t1t1.meta.json"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":1100000,"output_tokens":1}}}' > "$SA/agent-t2t2t2t2.jsonl"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"no usage here"}]}}' > "$SA/agent-t3t3t3t3.jsonl"
SB="$PR/sidBBBB2/subagents"; printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"b"}]}}' > "$SB/agent-t4t4t4t4.jsonl"
evs() { # ts event id type path session
  printf '{"ts":"%s","event":"%s","agent_id":"%s","agent_type":"%s","transcript_path":"%s","session_id":"%s","payload":{"agent_id":"%s","last_assistant_message":"fin"}}\n' "$1" "$2" "$3" "$4" "$5" "$6" "$3"
}
{
  evs 2026-03-01T10:00:00Z SubagentStart t3t3t3t3 w "$SA/agent-t3t3t3t3.jsonl" sidAAAA1
  evs 2026-03-01T10:00:01Z SubagentStop  t3t3t3t3 w "$SA/agent-t3t3t3t3.jsonl" sidAAAA1
  evs 2026-03-01T10:00:02Z SubagentStart t1t1t1t1 worker-sonnet "$SA/agent-t1t1t1t1.jsonl" sidAAAA1
  evs 2026-03-01T10:00:03Z SubagentStart t4t4t4t4 w "$SB/agent-t4t4t4t4.jsonl" sidBBBB2
  evs 2026-03-01T10:00:04Z SubagentStart t2t2t2t2 w "$SA/agent-t2t2t2t2.jsonl" sidAAAA1
} > "$G/.subdeck/events.jsonl"
GO="$(bash "$STATUS" "$G")"
has "$GO" '^Session: Durum raporu: şğı$' "group header: last aiTitle of manager transcript"
has "$GO" '^Session: sidBBBB2$' "group header: short session id when no ai-title"
[ "$(printf '%s\n' "$GO" | grep -c '^Session:')" = 2 ] && ok "two session groups" || bad "two session groups"
has "$GO" '^t1t1t1t1 +Türkçe başlık: şğıİöüç uzun... +worker-sonnet .* 79\.5k +running +Edit /a/b\.sh' "title clipped to 30 chars, tokens = last line (not sum), running"
has "$GO" '^t2t2t2t2 +- +w .* 1\.1M .*abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij$' "tokens formatted in millions"
has "$GO" '^t3t3t3t3 +- +w .* - +done ' "no usage -> tokens '-'; missing meta -> title '-'"
has "$GO" '^t4t4t4t4 +- +w .* - +running' "second group row"
L="$(printf '%s\n' "$GO" | grep -n -E '^(t1t1|t2t2|t3t3|t4t4)' | cut -d: -f2 | cut -c1-4 | tr '\n' ' ')"
[ "$L" = "t1t1 t2t2 t3t3 t4t4 " ] && ok "running first inside group, groups in first-seen order" || bad "order ($L)"
utf8ok "$GO" && ok "title/session table valid UTF-8" || bad "title/session table valid UTF-8"
# narrow terminal: ACTIVITY shrinks
NO="$(COLUMNS=110 bash "$STATUS" "$G" | grep '^t2t2t2t2')"
case "$NO" in *abcdefghijab...) ok "COLUMNS=110 narrows ACTIVITY";; *) bad "COLUMNS=110 narrows ACTIVITY ($NO)";; esac

# stale detection
S="$(mktemp -d)"; mkdir -p "$S/.subdeck" "$S/s1/subagents"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"x"}]}}' > "$S/s1/subagents/agent-s1s1s1s1.jsonl"
cp "$S/s1/subagents/agent-s1s1s1s1.jsonl" "$S/s1/subagents/agent-s2s2s2s2.jsonl"; touch -d '2 hours ago' "$S/s1/subagents/agent-s2s2s2s2.jsonl"
{
  ev 2026-01-01T10:00:00Z SubagentStart s1s1s1s1 w "$S/m.jsonl"
  ev 2026-01-01T10:00:00Z SubagentStart s2s2s2s2 w "$S/m.jsonl"
  ev 2026-01-01T10:00:00Z SubagentStart s3s3s3s3 w "$S/m.jsonl"
  ev "$NOWISO" SubagentStart s4s4s4s4 w "$S/m.jsonl"
} > "$S/.subdeck/events.jsonl"
SO="$(bash "$STATUS" "$S")"
has "$SO" '^s1s1s1s1 .* running ' "fresh transcript -> running"
has "$SO" '^s2s2s2s2 .* stale\? ' "old mtime -> stale?"
has "$SO" '^s3s3s3s3 .* stale\? ' "missing transcript + old Start -> stale?"
has "$SO" '^s4s4s4s4 .* running ' "missing transcript + recent Start -> running"
SO="$(SUBDECK_STALE_MIN=1000000 bash "$STATUS" "$S")"
has "$SO" '^s2s2s2s2 .* running ' "SUBDECK_STALE_MIN overrides threshold"
rm -rf "$S" "$G"

# TYPE column: leading plugin namespace stripped for display
N="$(mktemp -d)"; mkdir -p "$N/.subdeck"
ev 2026-01-01T10:00:00Z SubagentStart nsnsnsns1 subdeck:worker-sonnet "" > "$N/.subdeck/events.jsonl"
NO="$(bash "$STATUS" "$N")"
has "$NO" '^nsnsnsns +- +worker-sonnet ' "TYPE strips plugin namespace"
printf '%s
' "$NO" | grep -q 'subdeck:' && bad "namespace not shown" || ok "namespace not shown"
rm -rf "$N"

# skill file: injection form, exact allowed-tools, project dir passed explicitly
SK="$HERE/../skills/status/SKILL.md"
grep -qF 'allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" *)' "$SK" && ok "skill: allowed-tools exact form" || bad "skill: allowed-tools exact form"
grep -qF 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" $ARGUMENTS "${CLAUDE_PROJECT_DIR}" || true' "$SK" && ok "skill: injection passes project dir, never fails" || bad "skill: injection passes project dir, never fails"
grep -q '^```!$' "$SK" && ok "skill: injection fence" || bad "skill: injection fence"

# waiting: Notification newer than the transcript's last write, or a trailing blocking tool call
isoat() { date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
PW="$(mktemp -d)"; mkdir -p "$PW/.subdeck"
for id in w1wwwwww w2wwwwww w3wwwwww w4wwwwww w5wwwwww; do
  printf '%s
' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}' > "$T/s1/subagents/agent-$id.jsonl"
done
# 05: trailing AskUserQuestion, no notification
printf '%s
' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[]}}]}}' > "$T/s1/subagents/agent-w5wwwwww.jsonl"
nt() { printf '{"ts":"%s","event":"Notification","agent_id":"%s","agent_type":"","transcript_path":"","session_id":"%s","payload":{"notification_type":"%s","message":"secret text"}}
' "$1" "$2" "$3" "$4"; }
{
  for id in w1wwwwww w2wwwwww w3wwwwww w4wwwwww w5wwwwww; do ev "$(isoat -100)" SubagentStart "$id" worker-sonnet "$T/s1.jsonl"; done
  nt "$(isoat 20)" "" s1 permission_prompt      # after the last transcript write -> 01..04 waiting (session key), unless resolved below
} > "$PW/.subdeck/events.jsonl"
OUT="$(bash "$STATUS" "$PW")"
has "$OUT" '^w1wwwwww .* waiting ' "waiting: permission_prompt newer than transcript write"
has "$OUT" '^w5wwwwww .* waiting ' "waiting: trailing AskUserQuestion tool call"
hasnt "$OUT" 'secret text' "waiting: notification message never shown"
PR="$(mktemp -d)"; mkdir -p "$PR/.subdeck"
{ ev "$(isoat -100)" SubagentStart w1wwwwww worker-sonnet "$T/s1.jsonl"; nt "$(isoat -60)" "" s1 permission_prompt; } > "$PR/.subdeck/events.jsonl"
OUT="$(bash "$STATUS" "$PR")"
has "$OUT" '^w1wwwwww .* running ' "resolved: transcript written after the notification -> running"
PI="$(mktemp -d)"; mkdir -p "$PI/.subdeck"
{ ev "$(isoat -100)" SubagentStart w2wwwwww worker-sonnet "$T/s1.jsonl"; nt "$(isoat 20)" "" s1 idle_prompt; } > "$PI/.subdeck/events.jsonl"
OUT="$(bash "$STATUS" "$PI")"
has "$OUT" '^w2wwwwww .* running ' "idle_prompt is not waiting"
PA="$(mktemp -d)"; mkdir -p "$PA/.subdeck"
{ ev "$(isoat -100)" SubagentStart w3wwwwww worker-sonnet "$T/s1.jsonl"; ev "$(isoat -99)" SubagentStart w4wwwwww worker-sonnet "$T/s1.jsonl"; nt "$(isoat 20)" w3wwwwww s1 elicitation_dialog; } > "$PA/.subdeck/events.jsonl"
OUT="$(bash "$STATUS" "$PA")"
has "$OUT" '^w3wwwwww .* waiting ' "agent-keyed notification -> that agent waiting"
has "$OUT" '^w4wwwwww .* running ' "agent-keyed notification leaves the other agent running"
rm -rf "$PW" "$PR" "$PI" "$PA"

rm -rf "$P" "$P2" "$P3" "$P4" "$T"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
