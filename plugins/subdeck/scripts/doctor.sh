#!/usr/bin/env bash
# SubDeck doctor: one line per check (ok/warn/fail/info) with a fix hint. Always exits 0.
#   bash <plugin>/scripts/doctor.sh [project-dir]
# Test hooks: SUBDECK_INSTALLED_JSON, SUBDECK_LATEST (see version.sh), SUBDECK_STATE_DIR, SUBDECK_DESK_DIR, SUBDECK_HOME.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PL="$(cd "$HERE/.." && pwd)"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECT="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
NOK=0; NWARN=0; NFAIL=0
ok()   { NOK=$((NOK+1));     printf 'ok    %s\n' "$1"; }
warn() { NWARN=$((NWARN+1)); printf 'warn  %s\n        fix: %s\n' "$1" "$2"; }
fail() { NFAIL=$((NFAIL+1)); printf 'fail  %s\n        fix: %s\n' "$1" "$2"; }
info() { printf 'info  %s\n' "$1"; }
tilde() { printf '%s' "$1" | sed "s#^$HOME#~#"; }
echo "SubDeck doctor"

# 1. installed + enabled
IJ="${SUBDECK_INSTALLED_JSON:-$CFG/plugins/installed_plugins.json}"
if [ -f "$IJ" ] && grep -q '"subdeck@subdeck"' "$IJ"; then ok "plugin installed (subdeck@subdeck)"
else fail "plugin subdeck@subdeck not found in installed_plugins.json" "claude plugin marketplace add emiirhandemirci/SubDeck && claude plugin install subdeck@subdeck"; fi
SJ="$CFG/settings.json"
SJC=""; [ -f "$SJ" ] && SJC="$(tr -d '\r\n \t' < "$SJ")"
case "$SJC" in
  *'"subdeck@subdeck":true'*) ok "plugin enabled (settings.json)" ;;
  *'"subdeck@subdeck":false'*) warn "plugin is disabled in settings.json" "claude plugin enable subdeck@subdeck" ;;
  *) warn "no enabled entry for subdeck@subdeck in settings.json (it may be enabled at project scope)" "claude plugin enable subdeck@subdeck" ;;
esac

# 2. hooks
HJ="$PL/hooks/hooks.json"
if [ ! -f "$HJ" ]; then fail "hooks/hooks.json missing" "/subdeck:update (or reinstall the plugin)"
else
  missing=""
  for n in $(sed -n 's/.*run-hook\.cmd\\" *\([a-z][a-z-]*\).*/\1/p' "$HJ" | sort -u); do
    [ -f "$PL/scripts/$n.sh" ] || missing="$missing $n.sh"
  done
  [ -f "$PL/scripts/run-hook.cmd" ] || missing="$missing run-hook.cmd"
  if [ -n "$missing" ]; then fail "hook scripts missing:$missing" "/subdeck:update (or reinstall the plugin)"
  else ok "hooks.json present, every hook script resolves"; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) if [ -f "$PL/scripts/run-hook.cmd" ] && [ ! -x "$PL/scripts/run-hook.cmd" ]; then warn "scripts/run-hook.cmd is not executable" "chmod +x \"$PL/scripts/run-hook.cmd\""; fi ;;
  esac
fi

# 3. agents
miss=""
for a in researcher researcher-current verifier verifier-current worker-current worker-opus worker-sonnet; do
  [ -f "$PL/agents/$a.md" ] || miss="$miss $a"
done
if [ -z "$miss" ]; then ok "7 agent files present"; else fail "agent files missing:$miss" "/subdeck:update (or reinstall the plugin)"; fi

# 4. Node vs Desk minimum (read from desk/server.mjs)
DESK=""
for d in "${SUBDECK_DESK_DIR:-}" "$PL/../../desk" "$CFG/plugins/marketplaces/subdeck/desk" "$HOME/.subdeck/offline/SubDeck/desk"; do
  if [ -n "$d" ] && [ -f "$d/server.mjs" ]; then DESK="$d"; break; fi
done
if ! command -v node >/dev/null 2>&1; then
  warn "Node.js not found (needed by Desk)" "install Node.js from https://nodejs.org"
else
  NV="$(node -v 2>/dev/null | sed 's/^v//')"; NMAJ="${NV%%.*}"
  MIN=""; [ -n "$DESK" ] && MIN="$(sed -n 's/.*major < \([0-9][0-9]*\).*/\1/p' "$DESK/server.mjs" | head -1)"
  if [ -z "$MIN" ]; then info "Node $NV (Desk files not found, minimum not checked)"
  elif [ "$NMAJ" -ge "$MIN" ] 2>/dev/null; then ok "Node $NV (Desk needs >= $MIN)"
  else fail "Node $NV is older than the Desk minimum $MIN" "install a current Node.js LTS from https://nodejs.org"; fi
fi

# 5. state dir writable
. "$HERE/lib-paths.sh" 2>/dev/null
SD_STATE=""
if command -v sd_state_dir >/dev/null 2>&1; then sd_state_dir "$PROJECT" 2>/dev/null; fi
if [ -n "$SD_STATE" ]; then
  if mkdir -p "$SD_STATE" 2>/dev/null && : > "$SD_STATE/.doctor-$$" 2>/dev/null; then
    rm -f "$SD_STATE/.doctor-$$"; ok "state dir writable ($(tilde "$SD_STATE"))"
  else fail "state dir not writable: $(tilde "$SD_STATE")" "check the permissions of ~/.subdeck (or SUBDECK_STATE_DIR)"; fi
else warn "could not resolve the state dir" "reinstall the plugin (scripts/lib-paths.sh missing?)"; fi

# 6. Desk (info only)
DJ="${SUBDECK_HOME:-$HOME}/.subdeck/desk.json"
port=""; [ -f "$DJ" ] && port="$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$DJ" | head -1)"
if [ -n "$port" ] && command -v node >/dev/null 2>&1 && node -e "fetch('http://127.0.0.1:$port/api/sources',{signal:AbortSignal.timeout(2000)}).then(r=>process.exit(r.status===200?0:1),()=>process.exit(1))" 2>/dev/null; then
  info "Desk running at http://127.0.0.1:$port/"
else info "Desk not running (start it with /subdeck:desk)"; fi

# 7. model policy warnings (models.sh)
W="$(bash "$HERE/models.sh" show "$PROJECT" 2>/dev/null | tr -d '\r' | grep '^WARNING:')"
if [ -z "$W" ]; then ok "model policy: no override warnings"
else
  while IFS= read -r l; do
    [ -n "$l" ] && warn "model policy: ${l#WARNING: }" "see /subdeck:settings and your Claude Code settings.json or environment"
  done <<EOL
$W
EOL
fi

# 8. version (offline-tolerant)
V="$(bash "$HERE/version.sh" 2>/dev/null | tr -d '\r' | sed -n 's/^verdict: //p' | head -1)"
case "$V" in
  "up to date") ok "version up to date" ;;
  "") warn "version check failed" "run /subdeck:version" ;;
  latest\ unknown*) info "version: $V" ;;
  *) warn "version: $V" "/subdeck:update" ;;
esac

echo "summary: $NOK ok, $NWARN warn, $NFAIL fail"
exit 0
