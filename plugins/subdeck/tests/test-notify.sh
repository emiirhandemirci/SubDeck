#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-notify.sh   (temp HOME and project only; dry-run, never fires a real notification)
HERE="$(cd "$(dirname "$0")" && pwd)"
N="$HERE/../scripts/notify.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
hasnt() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
H="$(mktemp -d)"; P0="$(mktemp -d)"; P="$P0/my-proj"; mkdir -p "$P"
unset SUBDECK_NOTIFY SUBDECK_NOTIFY_DRYRUN CLAUDE_PROJECT_DIR SUBDECK_STATE_DIR SUBDECK_HOME
# sp HOME PROJECT: the project state dir (config.json, notify.log) outside the project (lib-paths.sh)
sp() { ( HOME="$1"; . "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$2"; printf '%s' "$SD_STATE" ); }
run() { HOME="$H" bash "$N" "$@" "$P" </dev/null; }
hook() { # KIND [payload]; dry-run on the given OS (default windows)
  printf '%s' "${2:-{\}}" | HOME="$H" SUBDECK_NOTIFY_DRYRUN=1 SUBDECK_NOTIFY_OS="${TOS:-windows}" CLAUDE_PROJECT_DIR="$P" bash "$N" hook "$1"
}

# defaults
out="$(run show)"; rc=$?
[ $rc -eq 0 ] && ok "show exits 0" || bad "show exit $rc"
has "$out" '^enabled +false +default' "default disabled"
hasnt "$out" 'sound' "no sound row in show"
has "$out" '^events +waiting,done +default' "default events: waiting,done"

# subcommands preserve other keys; user file
mkdir -p "$H/.subdeck"
echo '{"modelPolicy":{"worker":"haiku"},"other":[1,2,{"a":"b,c"}]}' > "$H/.subdeck/config.json"
out="$(run off)"
has "$out" '^enabled +false +user' "off writes user"
grep -q '"modelPolicy":{"worker":"haiku"}' "$H/.subdeck/config.json" && ok "modelPolicy preserved" || bad "modelPolicy lost"
grep -q '"other":\[1,2,{"a":"b,c"}\]' "$H/.subdeck/config.json" && ok "other member preserved" || bad "other member lost"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$H/.subdeck/config.json" 2>/dev/null && ok "user JSON valid" || bad "user JSON invalid"
out="$(run sound off)"; has "$out" 'no sound option' "sound subcommand reports removal"
out="$(run events waiting,done,agent)"; has "$out" '^events +waiting,done,agent +user' "events set"
has "$out" '^enabled +false +user' "enabled survives events write"
out="$(run events bogus)"; has "$out" 'unknown event' "bad event rejected"
out="$(run on)"; has "$out" '^enabled +true +user' "on"
grep -q '"modelPolicy"' "$H/.subdeck/config.json" && ok "modelPolicy still there after several writes" || bad "modelPolicy lost later"

# project overrides user, per field
out="$(run off --project)"
has "$out" '^enabled +false +project' "project overrides enabled"
has "$out" '^events +waiting,done,agent +user' "user value survives project override"
[ -f "$(sp "$H" "$P")/config.json" ] && [ ! -e "$P/.subdeck" ] && ok "project file written" || bad "project file missing"
out="$(run events agent --project)"; has "$out" '^events +agent +project' "project events"
out="$(run on --project)"; has "$out" '^enabled +true +project' "project on"

# garbage config left untouched
G="$(mktemp -d)"; GS="$(sp "$H" "$G")"; mkdir -p "$GS"; echo 'not json' > "$GS/config.json"
out="$(HOME="$H" bash "$N" off --project "$G")"
has "$out" 'not a valid JSON object' "invalid config refused"
[ "$(cat "$GS/config.json")" = "not json" ] && ok "invalid config untouched" || bad "invalid config modified"

# hook behaviour (reset to a clean home)
rm -rf "$P/.subdeck"; H="$(mktemp -d)"
out="$(hook waiting)"; [ -z "$out" ] && ok "default off: nothing fires" || bad "fired while default off"
HOME="$H" bash "$N" on "$P" >/dev/null
out="$(hook waiting)"; has "$out" "^DRYRUN windows: powershell.exe .*my-proj: needs your input" "waiting fires (windows)"
hasnt "$out" "SystemSounds|Media|Beep|Play" "windows: no sound code"
has "$out" "Setting -ne 'Enabled'" "windows: toast checks notifier Setting"
has "$out" "NotifyIcon" "windows: balloon fallback present"
has "$out" "SubDeck" "title present"
out="$(hook done)"; has "$out" "my-proj: finished" "done fires"
out="$(hook agent '{"agent_type":"worker-sonnet","transcript_path":"/x"}')"; [ -z "$out" ] && ok "agent is off by default" || bad "agent fired by default"
HOME="$H" bash "$N" events waiting,done,agent "$P" >/dev/null
out="$(hook agent '{"agent_type":"worker-sonnet","transcript_path":"/x"}')"; has "$out" "agent worker-sonnet finished" "agent fires once opted in"
HOME="$H" bash "$N" events done "$P" >/dev/null
out="$(hook waiting)"; [ -z "$out" ] && ok "event filter blocks waiting" || bad "waiting not filtered"
out="$(hook done)"; has "$out" "finished" "event filter allows done"
HOME="$H" bash "$N" off "$P" >/dev/null
out="$(hook done)"; [ -z "$out" ] && ok "disabled fires nothing" || bad "disabled still fired"
HOME="$H" bash "$N" on "$P" >/dev/null
out="$(printf '{}' | HOME="$H" SUBDECK_NOTIFY=0 SUBDECK_NOTIFY_DRYRUN=1 CLAUDE_PROJECT_DIR="$P" bash "$N" hook done)"
[ -z "$out" ] && ok "SUBDECK_NOTIFY=0 disables" || bad "env disable ignored"
out="$(printf '{}' | HOME="$H" SUBDECK_NOTIFY=0 bash "$N" show "$P")"; has "$out" 'SUBDECK_NOTIFY=0' "show mentions env disable"

# OS branches
HOME="$H" bash "$N" events waiting,done "$P" >/dev/null
out="$(TOS=macos hook done)"; has "$out" "^DRYRUN macos: osascript -e 'display notification \"my-proj: finished\" with title \"SubDeck\"'" "macos osascript"
hasnt "$out" "afplay" "macos: no sound"
out="$(TOS=linux hook waiting)"; has "$out" "^DRYRUN linux: notify-send 'SubDeck' 'my-proj: needs your input'" "linux notify-send"
hasnt "$out" "paplay|canberra" "linux: no sound"

# no content leak; unsafe characters stripped
LEAK='{"message":"SECRETPROMPT rm -rf","transcript_path":"/x/SECRETTRANSCRIPT","cwd":"/x","last_assistant_message":"SECRETREPLY","agent_type":"a'"'"'b;$(x)"}'
for k in waiting done agent idle; do
  HOME="$H" bash "$N" events waiting,done,agent,idle "$P" >/dev/null
  out="$(hook "$k" "$LEAK")"
  hasnt "$out" "SECRET" "no payload content in $k notification"
done
out="$(hook agent "$LEAK")"; has "$out" "agent abx finished" "agent type sanitised"

# old sound key ignored and dropped on the next write
S="$(mktemp -d)"; SS="$(sp "$H" "$S")"; mkdir -p "$SS"; echo '{"notify":{"enabled":true,"sound":true,"events":["done"]},"keep":1}' > "$SS/config.json"
out="$(HOME="$H" bash "$N" show "$S")"; hasnt "$out" 'sound' "old sound key not shown"
HOME="$H" bash "$N" events done,agent "$S" --project >/dev/null
grep -q sound "$SS/config.json" && bad "sound key kept on write" || ok "sound key dropped on write"
grep -q '"keep":1' "$SS/config.json" && ok "other member kept" || bad "other member lost"

# multi-line CRLF config is parsed
C="$(mktemp -d)"; mkdir -p "$C/.subdeck"; printf '{
  "notify": {
    "enabled": true,
    "events": ["agent"]
  }
}
' > "$C/.subdeck/config.json"
out="$(HOME="$H" bash "$N" show "$C")"; has "$out" '^events +agent +project' "CRLF multi-line config parsed"

# test subcommand
out="$(HOME="$H" SUBDECK_NOTIFY_DRYRUN=1 SUBDECK_NOTIFY_OS=linux bash "$N" test "$P")"
has "$out" "notify-send 'SubDeck' 'my-proj: test notification'" "test fires sample"

# debug log: real (detached) run with a fake powershell.exe; method and exit code, no content
LP="$(mktemp -d)/logproj"; mkdir -p "$LP"; LH="$(mktemp -d)"; LS="$(sp "$LH" "$LP")"
FP="$(mktemp -d)"; printf '#!/usr/bin/env bash
echo toast
exit 0
' > "$FP/powershell.exe"; chmod +x "$FP/powershell.exe"
HOME="$LH" bash "$N" on "$LP" >/dev/null
printf '{"message":"SECRETPROMPT"}' | HOME="$LH" PATH="$FP:$PATH" SUBDECK_NOTIFY_OS=windows CLAUDE_PROJECT_DIR="$LP" bash "$N" hook done >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q ' done toast 0$' "$LS/notify.log" 2>/dev/null && break; sleep 0.5; done
lg="$(cat "$LS/notify.log" 2>/dev/null)"
has "$lg" '^[0-9T:+-]+ done spawn -$' "log: spawn line"
has "$lg" '^[0-9T:+-]+ done toast 0$' "log: result line with method and exit code"
hasnt "$lg" 'SECRET|logproj' "log: no content or names"
printf '#!/usr/bin/env bash
exit 1
' > "$FP/powershell.exe"
HOME="$LH" PATH="$FP:$PATH" SUBDECK_NOTIFY_OS=windows bash "$N" test "$LP" >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q ' test fail 1$' "$LS/notify.log" 2>/dev/null && break; sleep 0.5; done
has "$(cat "$LS/notify.log")" ' test fail 1$' "log: failure recorded as fail with exit code"
# dry-run writes no log
rm -f "$LS/notify.log"; printf '{}' | HOME="$LH" SUBDECK_NOTIFY_DRYRUN=1 CLAUDE_PROJECT_DIR="$LP" bash "$N" hook done >/dev/null
[ ! -f "$LS/notify.log" ] && ok "dry-run writes no log" || bad "dry-run wrote a log"

# garbage stdin / no args
for g in '' 'garbage' '{"unterminated' '{"cwd":'; do
  printf '%s' "$g" | HOME="$H" SUBDECK_NOTIFY_DRYRUN=1 CLAUDE_PROJECT_DIR="$P" bash "$N" hook done >/dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && ok "exit 0 on stdin '$g'" || bad "exit $rc on stdin '$g'"
done
HOME="$H" bash "$N" hook >/dev/null 2>&1 </dev/null; [ $? -eq 0 ] && ok "hook without kind exits 0" || bad "hook without kind failed"
HOME="$H" bash "$N" nonsense "$P" >/dev/null 2>&1; [ $? -eq 0 ] && ok "unknown subcommand exits 0" || bad "unknown subcommand failed"

# runtime (real detached mode is not exercised here: dry-run path must be fast, and hook returns before the child ends)
s=$(date +%s%N)
printf '{}' | HOME="$H" SUBDECK_NOTIFY_DRYRUN=1 CLAUDE_PROJECT_DIR="$P" bash "$N" hook done >/dev/null
e=$(date +%s%N); ms=$(( (e - s) / 1000000 ))
RT=3000; [ "${SUBDECK_PERF_STRICT:-0}" = 1 ] && RT=1000
[ $ms -lt $RT ] && ok "hook runtime ${ms} ms (< $RT)" || bad "hook runtime ${ms} ms"
# detached run with a slow fake powershell.exe: hook must return without waiting for it
FB="$(mktemp -d)"; printf '#!/usr/bin/env bash\nsleep 3\n' > "$FB/powershell.exe"; chmod +x "$FB/powershell.exe"
# best of 3 (load-robust); the child sleeps 3 s, so anything under 2.5 s proves detaching. SUBDECK_PERF_STRICT=1 demands < 1 s.
LIMIT=2500; [ "${SUBDECK_PERF_STRICT:-0}" = 1 ] && LIMIT=1000
ms=999999
for _ in 1 2 3; do
  s=$(date +%s%N)
  printf '{}' | HOME="$H" PATH="$FB:$PATH" SUBDECK_NOTIFY_OS=windows CLAUDE_PROJECT_DIR="$P" bash "$N" hook done >/dev/null 2>&1
  e=$(date +%s%N); t=$(( (e - s) / 1000000 )); [ $t -lt $ms ] && ms=$t
done
[ $ms -lt $LIMIT ] && ok "detached: hook returned in ${ms} ms (best of 3) while child sleeps 3 s" || bad "not detached (${ms} ms)"

# ---- noise control: idle kind, agent filter, per-session collapse ----
NH="$(mktemp -d)"; NP="$(mktemp -d)/noisy"; mkdir -p "$NP"; NS="$(sp "$NH" "$NP")"
nh() { # KIND payload -> dry-run output (windows), own home/project
  printf '%s' "$2" | HOME="$NH" SUBDECK_NOTIFY_DRYRUN=1 SUBDECK_NOTIFY_OS=windows CLAUDE_PROJECT_DIR="$NP" bash "$N" hook "$1"
}
HOME="$NH" bash "$N" on "$NP" >/dev/null
out="$(HOME="$NH" bash "$N" show "$NP")"; has "$out" '^events +waiting,done +default' "fresh config: events waiting,done"
out="$(nh idle '{"session_id":"i1","notification_type":"idle_prompt"}')"; [ -z "$out" ] && ok "idle is off by default" || bad "idle fired by default"
out="$(nh waiting '{"session_id":"i2","notification_type":"idle_prompt"}')"; [ -z "$out" ] && ok "idle_prompt routed as waiting is treated as idle (off)" || bad "idle_prompt shown as waiting"
out="$(nh waiting '{"session_id":"i3","notification_type":"permission_prompt"}')"; has "$out" 'noisy: needs your input' "permission_prompt is waiting"
HOME="$NH" bash "$N" events waiting,done,agent,idle "$NP" >/dev/null
out="$(nh idle '{"session_id":"i4","notification_type":"idle_prompt"}')"; has "$out" 'noisy: idle, waiting for you' "idle has its own label when enabled"
hasnt "$out" 'needs your input' "idle never says needs your input"
out="$(nh waiting '{"session_id":"i5","notification_type":"idle_prompt"}')"; has "$out" 'noisy: idle, waiting for you' "idle_prompt under the waiting entry shows as idle"
out="$(HOME="$NH" bash "$N" events bogus,idle "$NP")"; has "$out" 'unknown event' "events list still validated"
# agent filter
out="$(nh agent '{"session_id":"a1","agent_type":"","transcript_path":"/x"}')"; [ -z "$out" ] && ok "agent: empty agent_type skipped" || bad "empty agent_type fired"
out="$(nh agent '{"session_id":"a2","agent_type":"worker"}')"; [ -z "$out" ] && ok "agent: no transcript skipped" || bad "no transcript fired"
out="$(nh agent '{"session_id":"a3","agent_type":"worker","agent_transcript_path":""}')"; [ -z "$out" ] && ok "agent: empty transcript skipped" || bad "empty transcript fired"
out="$(nh agent '{"session_id":"a4","agent_type":"worker","agent_transcript_path":"/t/a.jsonl"}')"; has "$out" 'agent worker finished' "agent: real stop shown"
# collapse within the window, per session
HOME="$NH" bash "$N" events waiting,done,agent,idle "$NP" >/dev/null
J() { printf '{"session_id":"%s","transcript_path":"/t","agent_type":"w","notification_type":"%s"}' "$1" "$2"; }
out="$(nh done "$(J c1 x)")"; has "$out" 'finished' "collapse: first toast shows"
out="$(nh done "$(J c1 x)")"; has "$out" '^DRYRUN collapsed: done' "collapse: same kind in the window is collapsed"
out="$(nh agent "$(J c1 x)")"; has "$out" '^DRYRUN collapsed: agent' "collapse: lower priority (agent after done)"
out="$(nh idle "$(J c1 idle_prompt)")"; has "$out" '^DRYRUN collapsed: idle' "collapse: lowest priority (idle after done)"
out="$(nh waiting "$(J c1 permission_prompt)")"; has "$out" 'needs your input' "collapse: higher priority (waiting after done) still shows"
out="$(nh done "$(J c1 x)")"; has "$out" '^DRYRUN collapsed: done' "collapse: done right after waiting is collapsed"
out="$(nh done "$(J c2 x)")"; has "$out" 'finished' "collapse: another session is independent"
out="$(nh agent "$(J c3 x)")"; has "$out" 'agent w finished' "collapse: agent first"
out="$(nh agent "$(J c3 x)")"; has "$out" '^DRYRUN collapsed: agent' "collapse: parallel sub-agent burst becomes one toast"
out="$(nh done "$(J c3 x)")"; has "$out" 'finished' "collapse: done after agent shows (higher priority)"
out="$(printf '{"transcript_path":"/t"}' | HOME="$NH" SUBDECK_NOTIFY_DRYRUN=1 SUBDECK_NOTIFY_OS=windows CLAUDE_PROJECT_DIR="$NP" bash "$N" hook done)"; has "$out" 'finished' "no session id: no collapse (1)"
out="$(printf '{"transcript_path":"/t"}' | HOME="$NH" SUBDECK_NOTIFY_DRYRUN=1 SUBDECK_NOTIFY_OS=windows CLAUDE_PROJECT_DIR="$NP" bash "$N" hook done)"; has "$out" 'finished' "no session id: no collapse (2)"
out="$(printf '%s' "$(J c4 x)" | HOME="$NH" SUBDECK_NOTIFY_COLLAPSE=0 SUBDECK_NOTIFY_DRYRUN=1 SUBDECK_NOTIFY_OS=windows CLAUDE_PROJECT_DIR="$NP" bash "$N" hook done)"
has "$out" 'finished' "collapse: SUBDECK_NOTIFY_COLLAPSE=0 disables"
# window expiry: an old stamp does not collapse
printf 'c5 1 waiting\n' > "$NS/notify.last"
out="$(nh done "$(J c5 x)")"; has "$out" 'finished' "collapse: expired stamp ignored"
# real (non-dry) collapse is logged with a collapsed marker, plus the notification type on real attempts
FPN="$(mktemp -d)"; printf '#!/usr/bin/env bash\necho toast\nexit 0\n' > "$FPN/powershell.exe"; chmod +x "$FPN/powershell.exe"
rm -f "$NS/notify.log" "$NS/notify.last"
for i in 1 2; do printf '%s' "$(J L1 permission_prompt)" | HOME="$NH" PATH="$FPN:$PATH" SUBDECK_NOTIFY_OS=windows CLAUDE_PROJECT_DIR="$NP" bash "$N" hook waiting >/dev/null 2>&1; done
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q ' waiting toast 0' "$NS/notify.log" 2>/dev/null && break; sleep 0.5; done
lg="$(cat "$NS/notify.log" 2>/dev/null)"
has "$lg" ' waiting spawn - type=permission_prompt$' "log: spawn line carries the notification type"
has "$lg" ' waiting collapsed -( |$)' "log: collapsed attempt keeps a log line"
[ "$(printf '%s\n' "$lg" | grep -c ' waiting spawn ')" -eq 1 ] && ok "log: only one real toast for two events" || bad "two toasts: $lg"
[ ! -e "$NP/.subdeck" ] && ok "noise state stays outside the project" || bad "project folder written"

# legacy <project>/.subdeck/config.json: read below the state-dir file, never written; no log in the project
LG="$(mktemp -d)/legacy-proj"; mkdir -p "$LG/.subdeck"; LGH="$(mktemp -d)"
echo '{"notify":{"enabled":true,"events":["done"]}}' > "$LG/.subdeck/config.json"; LB="$(cat "$LG/.subdeck/config.json")"
out="$(HOME="$LGH" bash "$N" show "$LG")"
has "$out" '^enabled +true +project' "legacy project config is read"
has "$out" '^legacy file: ' "show names the legacy file"
out="$(HOME="$LGH" bash "$N" events agent --project "$LG")"
has "$out" '^events +agent +project' "state-dir project file wins over legacy"
has "$out" '^enabled +true +project' "legacy key not in the new file still applies"
[ "$LB" = "$(cat "$LG/.subdeck/config.json")" ] && ok "legacy file never written" || bad "legacy file modified"
HOME="$LGH" SUBDECK_NOTIFY_DRYRUN= SUBDECK_NOTIFY_OS=none bash "$N" test "$LG" >/dev/null 2>&1
[ "$(ls -A "$LG/.subdeck")" = config.json ] && ok "nothing new in the project folder" || bad "project folder written: $(ls -A "$LG/.subdeck")"

echo "passed $PASS, failed $FAIL"
[ $FAIL -eq 0 ]
