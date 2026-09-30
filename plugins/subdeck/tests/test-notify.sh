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
unset SUBDECK_NOTIFY SUBDECK_NOTIFY_DRYRUN CLAUDE_PROJECT_DIR
run() { HOME="$H" bash "$N" "$@" "$P" </dev/null; }
hook() { # KIND [payload]; dry-run on the given OS (default windows)
  printf '%s' "${2:-{\}}" | HOME="$H" SUBDECK_NOTIFY_DRYRUN=1 SUBDECK_NOTIFY_OS="${TOS:-windows}" CLAUDE_PROJECT_DIR="$P" bash "$N" hook "$1"
}

# defaults
out="$(run show)"; rc=$?
[ $rc -eq 0 ] && ok "show exits 0" || bad "show exit $rc"
has "$out" '^enabled +true +default' "default enabled"
has "$out" '^sound +true +default' "default sound"
has "$out" '^events +waiting,done +default' "default events"

# subcommands preserve other keys; user file
mkdir -p "$H/.subdeck"
echo '{"modelPolicy":{"worker":"haiku"},"other":[1,2,{"a":"b,c"}]}' > "$H/.subdeck/config.json"
out="$(run off)"
has "$out" '^enabled +false +user' "off writes user"
grep -q '"modelPolicy":{"worker":"haiku"}' "$H/.subdeck/config.json" && ok "modelPolicy preserved" || bad "modelPolicy lost"
grep -q '"other":\[1,2,{"a":"b,c"}\]' "$H/.subdeck/config.json" && ok "other member preserved" || bad "other member lost"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$H/.subdeck/config.json" 2>/dev/null && ok "user JSON valid" || bad "user JSON invalid"
out="$(run sound off)"; has "$out" '^sound +false +user' "sound off"
out="$(run events waiting,done,agent)"; has "$out" '^events +waiting,done,agent +user' "events set"
has "$out" '^enabled +false +user' "enabled survives events write"
out="$(run events bogus)"; has "$out" 'unknown event' "bad event rejected"
out="$(run on)"; has "$out" '^enabled +true +user' "on"
grep -q '"modelPolicy"' "$H/.subdeck/config.json" && ok "modelPolicy still there after several writes" || bad "modelPolicy lost later"

# project overrides user, per field
out="$(run off --project)"
has "$out" '^enabled +false +project' "project overrides enabled"
has "$out" '^sound +false +user' "user value survives project override"
[ -f "$P/.subdeck/config.json" ] && ok "project file written" || bad "project file missing"
out="$(run events agent --project)"; has "$out" '^events +agent +project' "project events"
out="$(run on --project)"; has "$out" '^enabled +true +project' "project on"

# garbage config left untouched
G="$(mktemp -d)"; mkdir -p "$G/.subdeck"; echo 'not json' > "$G/.subdeck/config.json"
out="$(HOME="$H" bash "$N" off --project "$G")"
has "$out" 'not a valid JSON object' "invalid config refused"
[ "$(cat "$G/.subdeck/config.json")" = "not json" ] && ok "invalid config untouched" || bad "invalid config modified"

# hook behaviour (reset to a clean home)
rm -rf "$P/.subdeck"; H="$(mktemp -d)"
out="$(hook waiting)"; has "$out" "^DRYRUN windows: powershell.exe .*my-proj: needs your input" "waiting fires (windows)"
has "$out" "SystemSounds" "windows sound present"
has "$out" "SubDeck" "title present"
out="$(hook done)"; has "$out" "my-proj: finished" "done fires"
out="$(hook agent '{"agent_type":"worker-sonnet"}')"; [ -z "$out" ] && ok "agent off by default" || bad "agent fired by default"
HOME="$H" bash "$N" events waiting,done,agent "$P" >/dev/null
out="$(hook agent '{"agent_type":"worker-sonnet"}')"; has "$out" "agent worker-sonnet finished" "agent fires when enabled"
HOME="$H" bash "$N" events done "$P" >/dev/null
out="$(hook waiting)"; [ -z "$out" ] && ok "event filter blocks waiting" || bad "waiting not filtered"
out="$(hook done)"; has "$out" "finished" "event filter allows done"
HOME="$H" bash "$N" sound off "$P" >/dev/null
out="$(hook done)"; hasnt "$out" "SystemSounds" "sound off drops sound"
HOME="$H" bash "$N" off "$P" >/dev/null
out="$(hook done)"; [ -z "$out" ] && ok "disabled fires nothing" || bad "disabled still fired"
HOME="$H" bash "$N" on "$P" >/dev/null
out="$(printf '{}' | HOME="$H" SUBDECK_NOTIFY=0 SUBDECK_NOTIFY_DRYRUN=1 CLAUDE_PROJECT_DIR="$P" bash "$N" hook done)"
[ -z "$out" ] && ok "SUBDECK_NOTIFY=0 disables" || bad "env disable ignored"
out="$(printf '{}' | HOME="$H" SUBDECK_NOTIFY=0 bash "$N" show "$P")"; has "$out" 'SUBDECK_NOTIFY=0' "show mentions env disable"

# OS branches
HOME="$H" bash "$N" sound on "$P" >/dev/null; HOME="$H" bash "$N" events waiting,done "$P" >/dev/null
out="$(TOS=macos hook done)"; has "$out" "^DRYRUN macos: osascript -e 'display notification \"my-proj: finished\" with title \"SubDeck\"'" "macos osascript"
has "$out" "afplay" "macos sound"
out="$(TOS=linux hook waiting)"; has "$out" "^DRYRUN linux: notify-send 'SubDeck' 'my-proj: needs your input'" "linux notify-send"
has "$out" "paplay" "linux sound"

# no content leak; unsafe characters stripped
LEAK='{"message":"SECRETPROMPT rm -rf","transcript_path":"/x/SECRETTRANSCRIPT","cwd":"/x","last_assistant_message":"SECRETREPLY","agent_type":"a'"'"'b;$(x)"}'
for k in waiting done agent; do
  HOME="$H" bash "$N" events waiting,done,agent "$P" >/dev/null
  out="$(hook "$k" "$LEAK")"
  hasnt "$out" "SECRET" "no payload content in $k notification"
done
out="$(hook agent "$LEAK")"; has "$out" "agent abx finished" "agent type sanitised"

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
[ $ms -lt 1000 ] && ok "hook runtime ${ms} ms (< 1000)" || bad "hook runtime ${ms} ms"
# detached run with a slow fake powershell.exe: hook must return without waiting for it
FB="$(mktemp -d)"; printf '#!/usr/bin/env bash\nsleep 3\n' > "$FB/powershell.exe"; chmod +x "$FB/powershell.exe"
s=$(date +%s%N)
printf '{}' | HOME="$H" PATH="$FB:$PATH" SUBDECK_NOTIFY_OS=windows CLAUDE_PROJECT_DIR="$P" bash "$N" hook done >/dev/null 2>&1
e=$(date +%s%N); ms=$(( (e - s) / 1000000 ))
[ $ms -lt 1000 ] && ok "detached: hook returned in ${ms} ms while child sleeps 3 s" || bad "not detached (${ms} ms)"

echo "passed $PASS, failed $FAIL"
[ $FAIL -eq 0 ]
