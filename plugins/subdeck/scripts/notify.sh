#!/usr/bin/env bash
# SubDeck desktop notification + sound when the user is needed. OS native only, no network.
#
# Hook mode (from hooks.json):   notify.sh hook <waiting|done|agent>     (hook payload on stdin)
# Settings / skill mode:
#   notify.sh [show]                       effective settings + source of each value
#   notify.sh on | off [--project]         enable / disable
#   notify.sh sound on|off [--project]     sound on/off
#   notify.sh events waiting,done,agent [--project]
#   notify.sh test                         fire a sample notification now
# A trailing existing directory argument is the project dir (default $CLAUDE_PROJECT_DIR, else cwd).
# Config key `notify` in ~/.subdeck/config.json (user) and <project>/.subdeck/config.json (project wins):
#   {"notify":{"enabled":true,"sound":true,"events":["waiting","done"]}}   (absent = these defaults)
# Env: SUBDECK_NOTIFY=0 disables everything; SUBDECK_NOTIFY_DRYRUN=1 prints the command instead of running it.
# Only the project folder name and a fixed reason are shown, never prompt or transcript content.
# Other top-level config members (modelPolicy, ...) are preserved verbatim. No jq/node. Always exits 0.

ALL_EVENTS="waiting done agent"
TITLE="SubDeck"

CMD=""; SCOPE=user; PROJECT=""; ARGS=(); BADARGS=()
for a in "$@"; do
  a="${a%$'\r'}"
  case "$a" in
    "") ;;
    --project) SCOPE=project ;;
    --*) BADARGS+=("$a") ;;
    *) if [ -z "$CMD" ]; then CMD="$a"
       elif [ -d "$a" ] && { [ ${#ARGS[@]} -ge 1 ] || [ "$CMD" = show ] || [ "$CMD" = on ] || [ "$CMD" = off ] || [ "$CMD" = test ]; }; then PROJECT="$a"
       else ARGS+=("$a"); fi ;;
  esac
done
[ -n "$CMD" ] || CMD=show
# hook mode reads the payload (no forks: this runs on every Stop/Notification)
PAYLOAD=""
if [ "$CMD" = hook ]; then IFS= read -r -d '' PAYLOAD || true; PAYLOAD="${PAYLOAD//$'\r'/}"; PAYLOAD="${PAYLOAD//$'\n'/}"; fi
if [ -z "$PROJECT" ]; then
  PROJECT="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$PROJECT" ] && [ -n "$PAYLOAD" ]; then
    PROJECT="$(printf '%s' "$PAYLOAD" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  fi
  [ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="$(pwd)"
fi
UFILE="${HOME}/.subdeck/config.json"
PFILE="$PROJECT/.subdeck/config.json"
if [ "$SCOPE" = project ]; then TARGET="$PFILE"; else TARGET="$UFILE"; fi

# Parsing is pure bash (no forks): the hook must stay fast on Windows where every fork costs ~30 ms.
# notify_member FILE: sets NM to the raw notify object ({...}, no nested objects), empty when absent.
notify_member() {
  NM=""
  [ -f "$1" ] || return 0
  local c
  c="$(<"$1")" 2>/dev/null; c="${c//$'\r'/}"; c="${c//$'\n'/}"
  if [[ "$c" =~ \"notify\"[[:space:]]*:[[:space:]]*\{[^\}]*\} ]]; then NM="${BASH_REMATCH[0]}"; fi
}
RE_EN='"enabled"[[:space:]]*:[[:space:]]*(true|false)'
RE_SO='"sound"[[:space:]]*:[[:space:]]*(true|false)'
RE_EV='"events"[[:space:]]*:[[:space:]]*\[([^]]*)\]'
# m_enabled/m_sound/m_events STR: set M_EN/M_SO/M_EV ("-" = empty events list, "" = key absent).
parse_member() {
  M_EN=""; M_SO=""; M_EV=""
  if [[ "$1" =~ $RE_EN ]]; then M_EN="${BASH_REMATCH[1]}"; fi
  if [[ "$1" =~ $RE_SO ]]; then M_SO="${BASH_REMATCH[1]}"; fi
  if [[ "$1" =~ $RE_EV ]]; then
    local inner="${BASH_REMATCH[1]}"
    inner="${inner//\"/}"; inner="${inner// /}"
    if [ -n "$inner" ]; then M_EV="$inner"; else M_EV="-"; fi
  fi
}

# Effective settings: EN SO EV plus sources
resolve_settings() {
  EN=true; SO=true; EV="waiting,done"; SRC_EN=default; SRC_SO=default; SRC_EV=default
  notify_member "$UFILE"; parse_member "$NM"
  if [ -n "$M_EN" ]; then EN="$M_EN"; SRC_EN=user; fi
  if [ -n "$M_SO" ]; then SO="$M_SO"; SRC_SO=user; fi
  if [ -n "$M_EV" ]; then EV="$M_EV"; SRC_EV=user; fi
  notify_member "$PFILE"; parse_member "$NM"
  if [ -n "$M_EN" ]; then EN="$M_EN"; SRC_EN=project; fi
  if [ -n "$M_SO" ]; then SO="$M_SO"; SRC_SO=project; fi
  if [ -n "$M_EV" ]; then EV="$M_EV"; SRC_EV=project; fi
  if [ "$EV" = "-" ]; then EV=""; fi
  return 0
}

# clean STR: keep only safe characters, max 60 (result in CLEAN)
clean() { CLEAN="${1//[^A-Za-z0-9 ._-]/}"; CLEAN="${CLEAN:0:60}"; }

detect_os() {
  if [ -n "$SUBDECK_NOTIFY_OS" ]; then echo "$SUBDECK_NOTIFY_OS"; return; fi
  case "$OSTYPE" in
    msys*|cygwin*|win32*) echo windows ;;
    darwin*) echo macos ;;
    *) echo linux ;;
  esac
}

# fire BODY SOUND(true|false): run detached, or print the command in dry-run mode.
fire() {
  local body="$1" sound="$2" os ps sc
  os="$(detect_os)"
  case "$os" in
    windows)
      ps="\$ErrorActionPreference='Stop'; try { [void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]; [void][Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]; \$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02); \$t=\$x.GetElementsByTagName('text'); [void]\$t.Item(0).AppendChild(\$x.CreateTextNode('$TITLE')); [void]\$t.Item(1).AppendChild(\$x.CreateTextNode('$body')); \$n=[Windows.UI.Notifications.ToastNotification]::new(\$x); [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe').Show(\$n) } catch { try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; \$b=New-Object System.Windows.Forms.NotifyIcon; \$b.Icon=[System.Drawing.SystemIcons]::Information; \$b.Visible=\$true; \$b.ShowBalloonTip(5000,'$TITLE','$body',[System.Windows.Forms.ToolTipIcon]::Info); Start-Sleep -Seconds 6; \$b.Dispose() } catch {} }"
      if [ "$sound" = true ]; then ps="$ps; try { [System.Media.SystemSounds]::Asterisk.Play(); Start-Sleep -Milliseconds 1200 } catch {}"; fi
      if [ -n "$SUBDECK_NOTIFY_DRYRUN" ]; then echo "DRYRUN windows: powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command $ps"; return 0; fi
      command -v powershell.exe >/dev/null 2>&1 || return 0
      ( nohup powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command "$ps" </dev/null >/dev/null 2>&1 & ) 2>/dev/null ;;
    macos)
      sc="display notification \"$body\" with title \"$TITLE\""
      if [ -n "$SUBDECK_NOTIFY_DRYRUN" ]; then
        echo "DRYRUN macos: osascript -e '$sc'"
        if [ "$sound" = true ]; then echo "DRYRUN macos: afplay /System/Library/Sounds/Glass.aiff"; fi
        return 0
      fi
      command -v osascript >/dev/null 2>&1 || return 0
      ( { osascript -e "$sc"; if [ "$sound" = true ] && command -v afplay >/dev/null 2>&1; then afplay /System/Library/Sounds/Glass.aiff; fi; } </dev/null >/dev/null 2>&1 & ) 2>/dev/null ;;
    *)
      if [ -n "$SUBDECK_NOTIFY_DRYRUN" ]; then
        echo "DRYRUN linux: notify-send '$TITLE' '$body'"
        if [ "$sound" = true ]; then echo "DRYRUN linux: paplay /usr/share/sounds/freedesktop/stereo/message.oga || canberra-gtk-play -i message"; fi
        return 0
      fi
      (
        command -v notify-send >/dev/null 2>&1 && notify-send "$TITLE" "$body"
        if [ "$sound" = true ]; then
          if command -v paplay >/dev/null 2>&1 && [ -f /usr/share/sounds/freedesktop/stereo/message.oga ]; then paplay /usr/share/sounds/freedesktop/stereo/message.oga
          elif command -v canberra-gtk-play >/dev/null 2>&1; then canberra-gtk-play -i message; fi
        fi
      ) </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null ;;
  esac
  return 0
}

case "$SUBDECK_NOTIFY" in 0|false|off|no) DISABLED_ENV=1 ;; *) DISABLED_ENV=0 ;; esac

# members FILE: each top-level member on its own line (raw), except notify. Returns 1 when not a JSON object.
members() {
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | tr '\n' ' ' | awk '
    { t = t $0 }
    END {
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") exit 0
      n = length(t)
      if (substr(t,1,1) != "{" || substr(t,n,1) != "}") exit 1
      depth = 0; ins = 0; esc = 0; cur = ""
      for (i = 1; i <= n; i++) {
        c = substr(t, i, 1)
        if (ins) { cur = cur c; if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") ins = 0; continue }
        if (c == "\"") { ins = 1; cur = cur c; continue }
        if (c == "{" || c == "[") { depth++; if (depth == 1) continue }
        else if (c == "}" || c == "]") {
          depth--
          if (depth < 0) exit 1
          if (depth == 0) { if (i != n) exit 1; emit(); continue }
        }
        else if (c == "," && depth == 1) { emit(); continue }
        cur = cur c
      }
      if (ins || depth != 0) exit 1
    }
    function emit() {
      gsub(/^[ \t]+|[ \t]+$/, "", cur)
      if (cur != "" && cur !~ /^"notify"[ \t]*:/) print cur
      cur = ""
    }'
}

# write_notify KEY VALUE: set one notify field (en|so|ev) in TARGET, keeping other fields and members.
write_notify() {
  local key="$1" val="$2" others line body="" en so ev nm parts=""
  if ! others="$(members "$TARGET")"; then
    echo "error: $TARGET is not a valid JSON object; left untouched (fix or delete it by hand)."; return 1
  fi
  notify_member "$TARGET"; parse_member "$NM"
  en="$M_EN"; so="$M_SO"; ev="$M_EV"
  case "$key" in en) en="$val" ;; so) so="$val" ;; ev) ev="$val" ;; esac
  if [ -n "$en" ]; then parts="$parts,\"enabled\":$en"; fi
  if [ -n "$so" ]; then parts="$parts,\"sound\":$so"; fi
  if [ -n "$ev" ]; then
    if [ "$ev" = "-" ]; then nm="[]"; else nm="[\"$(printf '%s' "$ev" | sed 's/,/","/g')\"]"; fi
    parts="$parts,\"events\":$nm"
  fi
  mkdir -p "$(dirname "$TARGET")" 2>/dev/null
  while IFS= read -r line; do if [ -n "$line" ]; then body="$body$line,"; fi; done <<< "$others"
  body="$body\"notify\":{${parts#,}},"
  if printf '{%s}\n' "${body%,}" > "$TARGET" 2>/dev/null; then echo "wrote $TARGET"; return 0; fi
  echo "error: could not write $TARGET"; return 1
}

show() {
  resolve_settings
  echo "SubDeck notifications (defaults < user < project)"
  printf '%-9s %-16s %s\n' KEY VALUE SOURCE
  printf '%-9s %-16s %s\n' enabled "$EN" "$SRC_EN"
  printf '%-9s %-16s %s\n' sound "$SO" "$SRC_SO"
  printf '%-9s %-16s %s\n' events "${EV:-(none)}" "$SRC_EV"
  echo
  echo "user file:    $UFILE$([ -f "$UFILE" ] || echo ' (absent)')"
  echo "project file: $PFILE$([ -f "$PFILE" ] || echo ' (absent)')"
  if [ "$DISABLED_ENV" = 1 ]; then echo "NOTE: SUBDECK_NOTIFY=0 is set in the environment: all notifications are off regardless of config."; fi
  echo "Events: waiting (needs your input), done (manager finished), agent (a sub-agent finished; noisy, off by default)."
  echo "Usage: /subdeck:notify on | off | test | sound on|off | events waiting,done,agent   [--project]"
}

for b in "${BADARGS[@]}"; do echo "warning: ignored argument '$b'"; done

case "$CMD" in
  hook)
    [ "$DISABLED_ENV" = 1 ] && exit 0
    KIND="${ARGS[0]}"
    case "$KIND" in waiting|done|agent) ;; *) exit 0 ;; esac
    resolve_settings
    [ "$EN" = true ] || exit 0
    case ",$EV," in *",$KIND,"*) ;; *) exit 0 ;; esac
    PD="${PROJECT%/}"; clean "${PD##*/}"; NAME="$CLEAN"; [ -n "$NAME" ] || NAME="project"
    case "$KIND" in
      waiting) REASON="needs your input" ;;
      done) REASON="finished" ;;
      agent)
        AT=""
        if [[ "$PAYLOAD" =~ \"agent_type\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then clean "${BASH_REMATCH[1]}"; AT="$CLEAN"; fi
        [ -n "$AT" ] || AT="sub-agent"
        REASON="agent $AT finished" ;;
    esac
    fire "$NAME: $REASON" "$SO"
    exit 0 ;;
  show) show ;;
  on|off)
    if [ "$CMD" = on ]; then V=true; else V=false; fi
    write_notify en "$V"; echo; show ;;
  sound)
    case "${ARGS[0]}" in
      on) write_notify so true; echo; show ;;
      off) write_notify so false; echo; show ;;
      *) echo "error: usage: sound on|off" ;;
    esac ;;
  events)
    L="$(printf '%s' "${ARGS[0]}" | tr -d ' ' | tr 'A-Z' 'a-z')"
    if [ -z "$L" ]; then echo "error: usage: events waiting,done,agent (valid: $ALL_EVENTS)"
    else
      BAD=""; IFS=',' read -ra PARTS <<< "$L"
      for p in "${PARTS[@]}"; do case " $ALL_EVENTS " in *" $p "*) ;; *) BAD="$BAD $p" ;; esac; done
      if [ -n "$BAD" ]; then echo "error: unknown event(s):$BAD (valid: $ALL_EVENTS); nothing written."
      else write_notify ev "$L"; echo; show; fi
    fi ;;
  test)
    resolve_settings
    PD="${PROJECT%/}"; clean "${PD##*/}"; NAME="$CLEAN"; [ -n "$NAME" ] || NAME="project"
    fire "$NAME: test notification" "$SO"
    echo "test notification sent (sound: $SO). Nothing appeared? Check OS notification / focus-assist settings."
    if [ "$DISABLED_ENV" = 1 ]; then echo "NOTE: SUBDECK_NOTIFY=0 disables real hook notifications."; fi
    ;;
  *) echo "error: unknown command '$CMD'"; echo "Usage: /subdeck:notify on | off | test | sound on|off | events waiting,done,agent   [--project]" ;;
esac
exit 0
