#!/usr/bin/env bash
# SubDeck settings: one table of everything, and `set` routing to the existing scripts.
#
#   bash <plugin>/scripts/settings.sh [show]                          compact table
#   bash <plugin>/scripts/settings.sh set key=value ... [--project]   route keys to models.sh / notify.sh / guard.sh
#   bash <plugin>/scripts/settings.sh reset [--project]               reset models, guard and notifications
# A trailing existing directory argument is the project dir (default $CLAUDE_PROJECT_DIR, else cwd).
# Keys: mode|worker|escalation|researcher|verifier|explore  -> models.sh
#       notify=on|off, notify.events=waiting,done,agent      -> notify.sh
#       guard=on|off, <guard rule id>=deny|ask|off           -> guard.sh
#       protect=<glob>[,<glob>], unprotect=<glob>[,<glob>]   -> guard.sh protect|unprotect (guard.protectedPaths)
#       statusline=on|off                                    -> not written here (the skill edits settings.json after confirmation)
# No jq/node. Always exits 0 (a failing injected command would abort the skill).

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_KEYS="mode worker escalation researcher verifier explore"

CMD=""; SCOPE=""; PROJECT=""; PAIRS=(); BAD=()
for a in "$@"; do
  a="${a%$'\r'}"
  case "$a" in
    "") ;;
    --project) SCOPE="--project" ;;
    --*) BAD+=("$a") ;;
    show|set|reset) if [ -z "$CMD" ]; then CMD="$a"; else BAD+=("$a"); fi ;;
    *=*) PAIRS+=("$a") ;;
    *) if [ -d "$a" ]; then PROJECT="$a"; else BAD+=("$a"); fi ;;
  esac
done
[ -n "$CMD" ] || CMD=show
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

M() { bash "$DIR/models.sh" "$@" "$PROJECT"; }
N() { bash "$DIR/notify.sh" "$@" "$PROJECT"; }
G() { bash "$DIR/guard.sh" cli "$@" "$PROJECT"; }

statusline_state() {
  if [ -f "${HOME}/.claude/settings.json" ] && tr -d '\r' < "${HOME}/.claude/settings.json" | grep -q 'statusline\.sh'; then echo installed; else echo "not installed"; fi
}

guard_rules() { G show | awk '$2 ~ /^(deny|ask|off)$/ && $3 ~ /^(default|user|project)$/ { print $1 }'; }

show() {
  local mo no go sl
  mo="$(M show)"; no="$(N show)"; go="$(G show)"; sl="$(statusline_state)"
  echo "SubDeck settings (defaults < user < project)"
  printf '%-18s %-20s %s\n' KEY VALUE SOURCE
  printf '%s\n' "$mo" | awk '$1 ~ /^(mode|worker|escalation|researcher|verifier|explore)$/ && $3 ~ /^(default|user|project)$/ { printf "%-18s %-20s %s\n", $1, $2, $3 }'
  printf '%s\n' "$no" | awk '
    $1 == "enabled" && NF >= 3 { v = ($2 == "true") ? "on" : "off"; printf "%-18s %-20s %s\n", "notify", v, $3 }
    $1 == "events" && NF >= 3 { printf "%-18s %-20s %s\n", "notify.events", $2, $3 }'
  printf '%s\n' "$go" | awk '
    /^enabled:/ { v = ($2 == "yes") ? "on" : "off"; printf "%-18s %-20s %s\n", "guard", v, "(rules below)" }
    /^protectedPaths/ {
      s = "default"; if ($0 ~ /^protectedPaths \(user\)/) s = "user"; else if ($0 ~ /^protectedPaths \(project\)/) s = "project"
      v = $0; sub(/^protectedPaths[^:]*: /, "", v); printf "%-18s %-20s %s\n", "protect", v, s
    }
    $2 ~ /^(deny|ask|off)$/ && $3 ~ /^(default|user|project)$/ { printf "%-18s %-20s %s\n", $1, $2, $3 }'
  printf '%-18s %-20s %s\n' statusline "$sl" "~/.claude/settings.json"
  echo
  echo "Usage: set key=value ... [--project] | reset [--project]   (statusline=on|off is applied by the skill after confirmation)"
  echo "Keys: $MODEL_KEYS | notify=on|off notify.events=waiting,done,agent | guard=on|off $(guard_rules | tr '\n' ' ')| protect=<glob>[,<glob>] unprotect=<glob> | statusline=on|off"
  printf '%s\n' "$mo" | grep -E '^WARNING:' | head -1
}

for b in "${BAD[@]}"; do echo "warning: ignored argument '$b'"; done

case "$CMD" in
  show) show ;;
  set)
    if [ ${#PAIRS[@]} -eq 0 ]; then echo "error: set needs key=value pairs, e.g. set notify=on worker=opus"; exit 0; fi
    RULES=" $(guard_rules | tr '\n' ' ')"
    MP=(); GP=(); NV=""; NE=""; GE=""; SL=""; PR=""; UP=""; ERR=0
    for kv in "${PAIRS[@]}"; do
      k="${kv%%=*}"; v="${kv#*=}"; lv="$(printf '%s' "$v" | tr 'A-Z' 'a-z')"
      case "$k" in
        notify)
          case "$lv" in on|true) NV=on ;; off|false) NV=off ;; *) echo "error: notify must be on or off (got '$v')"; ERR=1 ;; esac ;;
        notify.events) NE="$v" ;;
        guard)
          case "$lv" in on|true) GE=on ;; off|false) GE=off ;; *) echo "error: guard must be on or off (got '$v')"; ERR=1 ;; esac ;;
        protect|unprotect)
          if [ -z "$v" ]; then echo "error: $k needs a glob (e.g. $k=CLAUDE.md,migrations/**)"; ERR=1
          elif [ "$k" = protect ]; then PR="$PR${PR:+,}$v"; else UP="$UP${UP:+,}$v"; fi ;;
        statusline)
          case "$lv" in on|install) SL=on ;; off|remove) SL=off ;; *) echo "error: statusline must be on or off (got '$v')"; ERR=1 ;; esac ;;
        *)
          if [[ " $MODEL_KEYS " == *" $k "* ]]; then MP+=("$k=$v")
          elif [[ "$RULES" == *" $k "* ]]; then GP+=("$k=$v")
          else echo "error: unknown key '$k'"; ERR=1; fi ;;
      esac
    done
    if [ $ERR -ne 0 ]; then echo "nothing written. Run settings without arguments to see the valid keys."; exit 0; fi
    [ ${#MP[@]} -gt 0 ] && M set "${MP[@]}" $SCOPE | head -1
    [ -n "$NV" ] && N "$NV" $SCOPE | head -1
    [ -n "$NE" ] && N events "$NE" $SCOPE | head -1
    [ ${#GP[@]} -gt 0 ] && G set "${GP[@]}" $SCOPE | head -1
    [ -n "$PR" ] && G protect "$PR" $SCOPE | head -1
    [ -n "$UP" ] && G unprotect "$UP" $SCOPE | head -1
    [ -n "$GE" ] && G "$GE" $SCOPE | head -1
    [ -n "$SL" ] && echo "statusline=$SL: not written by this script; it needs your confirmation (handled by the skill)."
    echo; show ;;
  reset)
    M reset $SCOPE | head -1
    G reset $SCOPE | head -1
    N off $SCOPE | head -1
    N events waiting,done,agent $SCOPE | head -1
    echo; show ;;
esac
exit 0
