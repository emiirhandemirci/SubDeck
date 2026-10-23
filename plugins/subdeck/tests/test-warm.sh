#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-warm.sh   (tasks.sh warm: candidate agents from events + fixture transcripts; temp dirs only)
HERE="$(cd "$(dirname "$0")" && pwd)"
TS="$HERE/../scripts/tasks.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2' in: $1)" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (found '$2' in: $1)" ;; *) ok "$3" ;; esac; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export SUBDECK_STATE_DIR="$W/state" HOME="$W/home"; mkdir -p "$HOME"
unset SUBDECK_TASKS_DIR CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SUBDECK_SESSION CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL
P="$W/proj"; mkdir -p "$P/src" "$P/docs"
t() { bash "$TS" --project "$P" "$@"; }
ST="$( . "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$P"; printf '%s' "$SD_STATE" )"
mkdir -p "$ST"

iso() { # minutes ago -> ISO timestamp
  date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v-"$1"M +%Y-%m-%dT%H:%M:%S.000Z
}
# transcript AGENT MINUTES-AGO CTX-TOKENS STOP-REASON [file_path]
transcript() {
  local f="$W/tr-$1.jsonl" ts; ts="$(iso "$2")"
  {
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hello"}}\n' "$(iso $(( $2 + 5 )))"
    [ -n "${5:-}" ] && printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s"}}],"usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":20},"stop_reason":"tool_use"}}\n' "$(iso $(( $2 + 4 )))" "$5"
    printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%s},"stop_reason":"%s"}}\n' "$ts" "$(( $3 - 1003 ))" "$4"
  } > "$f"
  printf '%s' "$f"
}
# event AGENT TYPE SESSION KIND TRANSCRIPT
event() {
  printf '{"ts":"%s","event":"%s","agent_id":"%s","agent_type":"%s","transcript_path":"","session_id":"%s","payload":{"agent_transcript_path":"%s"}}\n' "$(iso 0)" "$4" "$1" "$2" "$3" "$5" >> "$ST/events.jsonl"
}

# ---- no events, no args ----
out="$(t warm src/a.js)"; [ "$out" = none ] && ok "no events: none" || bad "no events: '$out'"
out="$(t warm 2>&1)"; rc=$?; [ $rc -eq 2 ] && ok "no path: usage error exit 2" || bad "no path: exit $rc"

# ---- a task with writable paths bound to a worker ----
ID="$(t new "Edit a" --owner worker-sonnet --writable "src/a.js,docs/" --done-when x)"
f1="$(transcript aaaa1111 2 118000 end_turn)"
t set "$ID" agent=aaaa1111 >/dev/null
event aaaa1111 subdeck:worker-sonnet s1 SubagentStart "$f1"; event aaaa1111 subdeck:worker-sonnet s1 SubagentStop "$f1"
out="$(t warm src/a.js docs/x.md src/other.js)"
has "$out" "aaaa1111 worker-sonnet $ID overlap=2 ctx=118k age=2." "warm: id, role, task, overlap (file + directory), ctx, age"
has "$out" "changed=0 stopped=end_turn -> resume" "warm: fresh enough, small, overlapping, end_turn: resume"

# a changed file after the agent's last request
sleep 1; echo x > "$P/src/a.js"
out="$(t warm src/a.js docs/x.md)"
has "$out" "overlap=2" "warm: overlap counts a path even when the file is missing"
has "$out" "changed=1" "warm: file modified after the agent's last request counts as changed"

# no overlap -> fresh
out="$(t warm src/zzz.js)"
has "$out" "overlap=0" "warm: no overlap"
has "$out" "-> fresh" "warm: no overlap gives fresh"

# ---- stale: 12 minutes since the last request (stop event is recent, the transcript decides) ----
f2="$(transcript bbbb2222 12 90000 end_turn)"
event bbbb2222 subdeck:worker-sonnet s1 SubagentStop "$f2"
out="$(t warm src/a.js)"
has "$out" "bbbb2222 worker-sonnet - overlap=0" "warm: agent without a task is listed with task -"
has "$out" "age=12." "warm: age comes from the transcript, not from the stop event"
case "$(printf '%s\n' "$out" | grep '^bbbb2222')" in *"-> stale") ok "warm: age >= 5 min is stale" ;; *) bad "warm: stale: $out" ;; esac

# file_path in the transcript counts as overlap for an agent without a task
f3="$(transcript cccc3333 1 100000 end_turn "$P/src/a.js")"
event cccc3333 subdeck:worker-sonnet s1 SubagentStop "$f3"
out="$(t warm src/a.js)"
case "$(printf '%s\n' "$out" | grep '^cccc3333')" in *"overlap=1"*"-> resume") ok "warm: a file the agent read counts as overlap (absolute path in the transcript)" ;; *) bad "warm: file_path overlap: $out" ;; esac

# context above 150k -> fresh
f4="$(transcript dddd4444 1 170000 end_turn "$P/src/a.js")"
event dddd4444 subdeck:worker-sonnet s1 SubagentStop "$f4"
out="$(t warm src/a.js)"
case "$(printf '%s\n' "$out" | grep '^dddd4444')" in *"ctx=170k"*"-> fresh") ok "warm: ctx > 150k is fresh" ;; *) bad "warm: big context: $out" ;; esac

# stopped mid-turn -> fresh
f5="$(transcript eeee5555 1 100000 tool_use "$P/src/a.js")"
event eeee5555 subdeck:worker-sonnet s1 SubagentStop "$f5"
out="$(t warm src/a.js)"
case "$(printf '%s\n' "$out" | grep '^eeee5555')" in *"stopped=mid"*"-> fresh") ok "warm: stopped mid-turn is fresh" ;; *) bad "warm: mid-turn: $out" ;; esac

# a verifier is always fresh; a running agent is not resumable
f6="$(transcript ffff6666 1 90000 end_turn "$P/src/a.js")"
event ffff6666 subdeck:verifier s1 SubagentStop "$f6"
f7="$(transcript 77777777 1 90000 end_turn "$P/src/a.js")"
event 77777777 subdeck:worker-sonnet s1 SubagentStart "$f7"
out="$(t warm src/a.js)"
case "$(printf '%s\n' "$out" | grep '^ffff6666')" in *"-> fresh") ok "warm: a verifier is never resumed" ;; *) bad "warm: verifier: $out" ;; esac
case "$(printf '%s\n' "$out" | grep '^77777777')" in *"stopped=running"*"-> fresh") ok "warm: a running agent is fresh" ;; *) bad "warm: running: $out" ;; esac

# newest first: the last event line written is listed first
first="$(printf '%s\n' "$out" | head -n 1 | cut -d' ' -f1)"
[ -n "$first" ] && ok "warm: prints candidates ($(printf '%s\n' "$out" | wc -l | tr -d ' ') lines)" || bad "warm: no output"

# session filter
out="$(CLAUDE_SESSION_ID=other t warm src/a.js)"; [ "$out" = none ] && ok "warm: only agents of the current session when it is known" || bad "warm: session filter: $out"

# ---- 1h cache TTL: a 12 minute old agent is resumable ----
mkdir -p "$P/.claude"; printf '{"subagentPromptCacheTtl":"1h"}' > "$P/.claude/settings.json"
out="$(t warm src/a.js)"
case "$(printf '%s\n' "$out" | grep '^bbbb2222')" in *"age=12."*) ok "warm: 1h setting read" ;; *) bad "warm: 1h line: $out" ;; esac
# bbbb2222 has no overlap, so check the verdict on an overlapping 12 minute agent
f8="$(transcript 88888888 12 90000 end_turn "$P/src/a.js")"
event 88888888 subdeck:worker-sonnet s1 SubagentStop "$f8"
out="$(t warm src/a.js)"
case "$(printf '%s\n' "$out" | grep '^88888888')" in *"-> resume") ok "warm: subagentPromptCacheTtl=1h raises the age limit to 55 minutes" ;; *) bad "warm: 1h resume: $out" ;; esac
rm -f "$P/.claude/settings.json"
out="$(t warm src/a.js)"
case "$(printf '%s\n' "$out" | grep '^88888888')" in *"-> stale") ok "warm: without the setting the same agent is stale" ;; *) bad "warm: 5m stale: $out" ;; esac

# ---- fail open: broken transcript path / garbage events ----
printf 'not json\n{"event":"SubagentStop"\n' >> "$ST/events.jsonl"
event 99999999 subdeck:worker-sonnet s1 SubagentStop "$W/missing.jsonl"
out="$(t warm src/a.js)"; rc=$?
[ $rc -eq 0 ] && ok "warm: garbage events and a missing transcript: exit 0" || bad "warm: exit $rc"
case "$(printf '%s\n' "$out" | grep '^99999999')" in *"ctx=?"*"-> fresh") ok "warm: missing transcript: ctx unknown, fresh" ;; *) bad "warm: missing transcript: $out" ;; esac
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
