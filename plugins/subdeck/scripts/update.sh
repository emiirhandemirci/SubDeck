#!/usr/bin/env bash
# SubDeck update: refresh the "subdeck" marketplace and update subdeck@subdeck only. Always exits 0.
# Test hook: SUBDECK_CLAUDE_BIN (path of the claude executable or stub).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD1="claude plugin marketplace update subdeck"
CMD2="claude plugin update subdeck@subdeck"

find_claude() {
  local c
  if [ -n "${SUBDECK_CLAUDE_BIN:-}" ]; then
    [ -x "$SUBDECK_CLAUDE_BIN" ] && printf '%s' "$SUBDECK_CLAUDE_BIN"
    return 0
  fi
  c="$(command -v claude 2>/dev/null)"
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  for c in "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.exe"; do
    if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 0
}

CL="$(find_claude)"
if [ -z "$CL" ]; then
  echo "SubDeck update: the claude command was not found on PATH or in ~/.local/bin."
  echo "Run these two commands in a terminal, then /reload-plugins (or restart):"
  echo "  $CMD1"
  echo "  $CMD2"
  exit 0
fi

echo "before: $(bash "$HERE/version.sh" --installed)   (format: version commit)"
echo "> $CMD1"; "$CL" plugin marketplace update subdeck 2>&1 < /dev/null; r1=$?
echo "> $CMD2"; "$CL" plugin update subdeck@subdeck 2>&1 < /dev/null; r2=$?
echo "after:  $(bash "$HERE/version.sh" --installed)"
if [ "$r1" -ne 0 ] || [ "$r2" -ne 0 ]; then echo "note: a command exited non-zero ($r1, $r2); see its output above."; fi
echo "run /reload-plugins (or restart) to load the new version"
exit 0
