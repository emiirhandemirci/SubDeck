#!/usr/bin/env bash
# SubDeck help: the user commands, the most used settings keys and where the User Guide is. Always exits 0.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat <<'TXT'
SubDeck commands
  /subdeck:desk [stop|status]   start, locate or stop Desk, the local dashboard of agent sessions
  /subdeck:status [--all]       live table of running and recent sub-agents
  /subdeck:settings             show or change settings (models, guard, notifications, tasks)
  /subdeck:version              installed version and commit, latest on GitHub, update hint
  /subdeck:update               update the SubDeck plugin from its marketplace
  /subdeck:doctor               health check with a fix hint per item
  /subdeck:help                 this list

Most used settings (/subdeck:settings set key=value; add --project for this project only)
TXT
HELP="$(bash "$HERE/settings.sh" help 2>/dev/null | tr -d '\r')"
for k in mode worker verifier notify guard push protect-branches context; do
  printf '%s\n' "$HELP" | awk -v k="$k" '
    $1 == k { r = $0; sub(/^[ \t]+[^ \t]+[ \t]+/, "", r); printf "  %-17s %s\n", $1, r; getline; sub(/^[ \t]+/, ""); printf "  %-17s %s\n", "", $0; exit }'
done
cat <<'TXT'

All keys: /subdeck:settings help
User Guide: https://github.com/emiirhandemirci/SubDeck/blob/main/docs/USER_GUIDE.md
TXT
exit 0
