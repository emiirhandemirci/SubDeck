#!/usr/bin/env bash
# SessionStart hook: prints the one-line SubDeck hint as additionalContext, or nothing when switched off.
# Off with `/subdeck:settings set session-hint=off` (config key sessionHint=false; project config wins over user config;
# absent = on). Pure bash, no forks beyond one read of the config files; always exits 0 and never blocks the session.
HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
PROJECT="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT" ] && [ ! -t 0 ]; then
  PAYLOAD="$(cat 2>/dev/null)"; PAYLOAD="${PAYLOAD//$'\r'/}"; PAYLOAD="${PAYLOAD//$'\n'/}"
  if [[ $PAYLOAD =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then PROJECT="${BASH_REMATCH[1]}"; fi
fi
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="$(pwd)"
FILES=()
if . "$HERE/lib-paths.sh" 2>/dev/null; then sd_state_dir "$PROJECT"; [ -n "$SD_KEY" ] && FILES[${#FILES[@]}]="$SD_STATE/config.json"; fi
FILES[${#FILES[@]}]="$PROJECT/.subdeck/config.json"
FILES[${#FILES[@]}]="${HOME:-}/.subdeck/config.json"
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  c="$(<"$f")" 2>/dev/null || continue
  if [[ $c =~ \"sessionHint\"[[:space:]]*:[[:space:]]*(true|false) ]]; then
    [ "${BASH_REMATCH[1]}" = false ] && exit 0
    break
  fi
done
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"SubDeck: when delegating to sub-agents, load the subdeck:orchestrator skill first."}}'
exit 0
