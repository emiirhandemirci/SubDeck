#!/usr/bin/env bash
# SubDeck version: installed version + commit, latest on GitHub main, one verdict line. Always exits 0.
#   bash <plugin>/scripts/version.sh               full report
#   bash <plugin>/scripts/version.sh --installed   one line: "<version> <commit-sha-or-dash>" (used by update.sh)
# Test hooks: SUBDECK_INSTALLED_JSON (installed_plugins.json path), SUBDECK_LATEST (e.g. "0.9.3 abcdef1234" or "offline"
# to skip the network), SUBDECK_HOME (instead of $HOME for desk.json). bash 3.2 + awk + sed; node only for the fetch.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PL="$(cd "$HERE/.." && pwd)"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
IJ="${SUBDECK_INSTALLED_JSON:-$CFG/plugins/installed_plugins.json}"
REPO="emiirhandemirci/SubDeck"
RAW="https://raw.githubusercontent.com/$REPO/main/plugins/subdeck/.claude-plugin/plugin.json"
GIT_URL="https://github.com/$REPO"

json_ver() { tr -d '\r' < "$1" 2>/dev/null | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'; }

# field of the first subdeck@subdeck entry: version, gitCommitSha, lastUpdated
inst_field() {
  [ -f "$IJ" ] || return 0
  tr '\n\r' '  ' < "$IJ" | awk -v key="$1" '
    { i = match($0, /"subdeck@subdeck"[ \t]*:[ \t]*\[/); if (!i) exit
      r = substr($0, i + RLENGTH); j = index(r, "]"); if (j) r = substr(r, 1, j - 1)
      pat = "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\""
      if (match(r, pat)) { s = substr(r, RSTART, RLENGTH); sub(/^[^:]*:[ \t]*"/, "", s); sub(/"$/, "", s); print s } }'
}

IVER="$(inst_field version)"; ISHA="$(inst_field gitCommitSha)"; IUPD="$(inst_field lastUpdated)"
PVER="$(json_ver "$PL/.claude-plugin/plugin.json")"
[ -n "$IVER" ] || IVER="$PVER"
[ -n "$IVER" ] || IVER="unknown"

if [ "${1:-}" = "--installed" ]; then echo "$IVER ${ISHA:--}"; exit 0; fi

# run a command with a timeout (no coreutils timeout needed); stdout to $2
run_to() { # seconds outfile cmd...
  local s="$1" out="$2" pid n=0 max; shift 2
  "$@" > "$out" 2>/dev/null < /dev/null & pid=$!
  max=$((s * 10))
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$max" ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; fi
  wait "$pid" 2>/dev/null
}

LVER=""; LSHA=""
if [ -n "${SUBDECK_LATEST+x}" ]; then
  if [ "$SUBDECK_LATEST" != offline ]; then
    LVER="${SUBDECK_LATEST%% *}"
    case "$SUBDECK_LATEST" in *" "*) LSHA="${SUBDECK_LATEST#* }" ;; esac
  fi
else
  T="$(mktemp -d 2>/dev/null)"
  if [ -n "$T" ]; then
    if command -v node >/dev/null 2>&1; then
      if run_to 6 "$T/raw" node -e "fetch(process.argv[1],{signal:AbortSignal.timeout(5000)}).then(r=>r.ok?r.text():Promise.reject()).then(t=>process.stdout.write(t),()=>process.exit(1))" "$RAW"; then LVER="$(json_ver "$T/raw")"; fi
    fi
    if command -v git >/dev/null 2>&1; then
      if GIT_TERMINAL_PROMPT=0 run_to 6 "$T/ls" git ls-remote "$GIT_URL" refs/heads/main; then LSHA="$(awk 'NR==1{print $1}' "$T/ls")"; fi
    fi
    rm -rf "$T"
  fi
fi

short() { printf '%s' "$1" | cut -c1-7; }
vnum() { printf '%s' "$1" | awk -F. '{ printf "%d%06d%06d", $1, $2, $3 }'; }

echo "SubDeck version"
if [ -n "$ISHA" ]; then
  line="$IVER (commit $(short "$ISHA")"
  [ -n "$IUPD" ] && line="$line, updated ${IUPD%%T*}"
  echo "  installed: $line)"
else
  echo "  installed: $IVER (commit unknown: not installed from the marketplace?)"
fi
if [ -n "$LVER" ] || [ -n "$LSHA" ]; then
  line="${LVER:-unknown}"
  [ -n "$LSHA" ] && line="$line (commit $(short "$LSHA"))"
  echo "  latest:    $line on github.com/$REPO main"
else
  echo "  latest:    unknown (offline)"
fi

if [ -z "$LVER" ] && [ -z "$LSHA" ]; then V="latest unknown (offline); could not compare"
elif [ -n "$LVER" ] && [ "$IVER" != unknown ] && [ "$(vnum "$LVER")" -gt "$(vnum "$IVER")" ] 2>/dev/null; then V="$LVER available (installed $IVER)"
elif [ -n "$LSHA" ] && [ -n "$ISHA" ] && [ "$LSHA" != "$ISHA" ]; then V="same version but newer commit on main"
else V="up to date"; fi
echo "verdict: $V"
case "$V" in
  "up to date"|latest\ unknown*) ;;
  *) echo "update: /subdeck:update   (then /reload-plugins or restart)" ;;
esac

# Desk (optional, silent when not running)
DJ="${SUBDECK_HOME:-$HOME}/.subdeck/desk.json"
if [ -f "$DJ" ] && command -v node >/dev/null 2>&1; then
  port="$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$DJ" | head -1)"
  dv="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$DJ" | head -1)"
  if [ -n "$port" ] && node -e "fetch('http://127.0.0.1:$port/api/sources',{signal:AbortSignal.timeout(1500)}).then(r=>process.exit(r.status===200?0:1),()=>process.exit(1))" 2>/dev/null; then
    echo "desk:    ${dv:-unknown} running at http://127.0.0.1:$port/"
  fi
fi
exit 0
