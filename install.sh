#!/usr/bin/env bash
# SubDeck installer / updater. Usage: ./install.sh [--uninstall]
# Only talks to the claude CLI; never edits settings files, no sudo.
set -u
REPO="emiirhandemirci/SubDeck"
MKT="subdeck"
PLUGIN="subdeck@subdeck"

CLAUDE="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE" ]; then
  for c in "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.exe"; do
    [ -x "$c" ] && { CLAUDE="$c"; break; }
  done
fi
if [ -z "$CLAUDE" ]; then
  echo "Claude Code CLI not found." >&2
  echo "Install Claude Code first: https://docs.claude.com/en/docs/claude-code/setup" >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  "$CLAUDE" plugin uninstall "$PLUGIN" || exit 1
  "$CLAUDE" plugin marketplace remove "$MKT" || exit 1
  echo "SubDeck uninstalled. Restart Claude Code."
  exit 0
fi

if "$CLAUDE" plugin marketplace list 2>/dev/null | grep -qw "$MKT"; then
  echo "SubDeck marketplace found; updating."
  "$CLAUDE" plugin marketplace update "$MKT" || exit 1
  "$CLAUDE" plugin update "$PLUGIN" || exit 1
else
  "$CLAUDE" plugin marketplace add "$REPO" || exit 1
  "$CLAUDE" plugin install "$PLUGIN" || exit 1
fi

echo
"$CLAUDE" plugin list 2>/dev/null | grep -i -A3 "subdeck" | head -5
echo
echo "Restart Claude Code to load the plugin."
echo "Then try /subdeck:status, or start the dashboard with /subdeck:desk."
