#!/usr/bin/env bash
# SubDeck offline installer (Git Bash, macOS, Linux). Run from the unzipped bundle folder. No network access.
# Usage: ./install-offline.sh [--target <dir>] [--mode-current] [--uninstall]
#   --target <dir>   permanent copy of the plugin (default ~/.subdeck/offline/SubDeck)
#   --mode-current   write mode=current so sub-agents use the session's model (non-Claude backends such as GLM)
#   --uninstall      remove the plugin, the marketplace entry and our copy
# Replaces only an older copy of ours (marker file .subdeck-offline-install); never touches other files.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MKT=subdeck
PLUGIN=subdeck@subdeck
MARKER=.subdeck-offline-install
TARGET="${HOME}/.subdeck/offline/SubDeck"
MODE_CURRENT=0; UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) shift; TARGET="${1:-}" ;;
    --target=*) TARGET="${1#--target=}" ;;
    --mode-current) MODE_CURRENT=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; echo "Usage: ./install-offline.sh [--target <dir>] [--mode-current] [--uninstall]" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$TARGET" ] || { echo "--target needs a value" >&2; exit 2; }
case "$TARGET" in /*|[A-Za-z]:*) ;; *) TARGET="$(pwd)/$TARGET" ;; esac
is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
native() { if is_windows; then cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; else printf '%s' "$1"; fi; }

# --- claude CLI ---
CLAUDE=""
if command -v claude >/dev/null 2>&1; then CLAUDE="$(command -v claude)"
else
  for c in "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.exe" "${USERPROFILE:-}/.local/bin/claude.exe"; do
    if [ -f "$c" ]; then CLAUDE="$c"; break; fi
  done
fi
[ -n "$CLAUDE" ] || { echo "ERROR: the 'claude' command was not found. Install Claude Code first, or add its folder (for example ~/.local/bin) to PATH." >&2; exit 1; }
echo "Claude Code: $CLAUDE"

if [ "$UNINSTALL" = 1 ]; then
  "$CLAUDE" plugin uninstall "$PLUGIN" || echo "note: plugin was not installed (or could not be removed)"
  "$CLAUDE" plugin marketplace remove "$MKT" || echo "note: marketplace entry was not present"
  if [ -f "$TARGET/$MARKER" ]; then rm -rf "$TARGET"; echo "Removed $TARGET"
  elif [ -e "$TARGET" ]; then echo "Left $TARGET alone (not an offline copy written by SubDeck)"
  fi
  echo "SubDeck removed. Restart Claude Code."
  exit 0
fi

# --- other prerequisites ---
if ! command -v bash >/dev/null 2>&1; then
  echo "ERROR: bash not found. On Windows install Git for Windows (Git Bash); the plugin hooks need it." >&2; exit 1
fi
if command -v node >/dev/null 2>&1; then
  NV="$(node -v 2>/dev/null | sed 's/^v//')"; NMAJ="${NV%%.*}"; NREST="${NV#*.}"; NMIN="${NREST%%.*}"
  case "$NMAJ$NMIN" in *[!0-9]*|"") NMAJ=0; NMIN=0 ;; esac
  if [ "$NMAJ" -lt 22 ] || { [ "$NMAJ" -eq 22 ] && [ "$NMIN" -lt 13 ]; }; then
    echo "WARNING: Node.js $NV found, Desk needs 22.13 or newer. The plugin works without Desk."
  fi
else
  echo "WARNING: Node.js not found. Desk (the live web view) needs Node.js 22.13 or newer; the plugin works without it."
fi

# --- copy to the permanent place ---
[ -f "$HERE/plugins/subdeck/.claude-plugin/plugin.json" ] && [ -f "$HERE/.claude-plugin/marketplace.json" ] \
  || { echo "ERROR: run this from the unzipped SubDeck bundle folder (plugins/subdeck not found next to the script)." >&2; exit 1; }
SAME=0; [ "$(cd "$TARGET" 2>/dev/null && pwd)" = "$HERE" ] && SAME=1
if [ "$SAME" = 0 ]; then
  if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ] && [ ! -f "$TARGET/$MARKER" ]; then
    echo "ERROR: $TARGET exists and is not a SubDeck offline copy; refusing to overwrite. Use --target <other folder>." >&2; exit 1
  fi
  rm -rf "$TARGET"; mkdir -p "$TARGET" || { echo "ERROR: cannot create $TARGET" >&2; exit 1; }
  cp -R "$HERE/." "$TARGET/" || { echo "ERROR: copy failed" >&2; exit 1; }
fi
VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TARGET/plugins/subdeck/.claude-plugin/plugin.json" | head -1)"
printf 'SubDeck offline copy, version %s. Written by install-offline; safe to replace or delete.\n' "$VER" > "$TARGET/$MARKER"
echo "Copied SubDeck $VER to $TARGET"

# --- marketplace + plugin (local directory: Claude Code reads it in place, no network) ---
NTARGET="$(native "$TARGET")"
norm() { printf '%s' "$1" | tr 'A-Z\' 'a-z/'; }
SRCLINE="$("$CLAUDE" plugin marketplace list 2>/dev/null | awk -v m="$MKT" '$NF == m {f=1; next} f && /Source:/ {print; exit}')"
LISTED=0; "$CLAUDE" plugin marketplace list 2>/dev/null | grep -Eq "(^|[[:space:]])${MKT}[[:space:]]*$" && LISTED=1
if [ "$LISTED" = 1 ] && printf '%s' "$(norm "$SRCLINE")" | grep -qF "$(norm "$NTARGET")"; then
  "$CLAUDE" plugin marketplace update "$MKT" || { echo "ERROR: marketplace update failed" >&2; exit 1; }
else
  if [ "$LISTED" = 1 ]; then
    echo "Replacing the existing '$MKT' marketplace entry with the local copy"
    "$CLAUDE" plugin marketplace remove "$MKT" || { echo "ERROR: could not remove the old marketplace entry" >&2; exit 1; }
  fi
  "$CLAUDE" plugin marketplace add "$NTARGET" || { echo "ERROR: marketplace add failed" >&2; exit 1; }
fi
if "$CLAUDE" plugin list 2>/dev/null | grep -qF "$PLUGIN"; then
  "$CLAUDE" plugin update "$PLUGIN" || { echo "ERROR: plugin update failed" >&2; exit 1; }
else
  "$CLAUDE" plugin install "$PLUGIN" || { echo "ERROR: plugin install failed" >&2; exit 1; }
fi

# --- model mode ---
if [ "$MODE_CURRENT" = 1 ]; then
  bash "$TARGET/plugins/subdeck/scripts/models.sh" set mode=current
elif [ -n "${ANTHROPIC_BASE_URL:-}" ] && ! printf '%s' "$ANTHROPIC_BASE_URL" | grep -Eqi '^https?://([^/]*\.)?(anthropic\.com|claude\.com)(/|:|$)'; then
  echo "NOTE: ANTHROPIC_BASE_URL points to a non-Anthropic backend. Recommended: re-run with --mode-current"
  echo "      (or run /subdeck:settings set mode=current) so sub-agents use your session's model."
fi

cat <<EOF

SubDeck $VER installed from $TARGET (no network used).
Next steps:
  1. Restart Claude Code (or run /reload-plugins in a running session).
  2. Run /subdeck:status to check the plugin, and /subdeck:desk for the live web view (needs Node.js 22.13+).
  3. Smoke test in a throwaway folder: ask "Use a worker to create hello.txt containing hello, then verify it."
Update: unzip a newer bundle and run this installer again. Remove: ./install-offline.sh --uninstall
EOF
exit 0
