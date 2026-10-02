#!/usr/bin/env bash
# Build an offline install bundle: dist/SubDeck-<version>-offline.zip
# Usage: ./make-offline-bundle.sh [--ref <git-ref>] [--out <dir>]
# Contents: the tracked files of the ref (git archive; untracked and private folders never included),
# install-offline.ps1, install-offline.sh, INSTALL.cmd (double-click wrapper) and OFFLINE-README.txt at the zip root.
# Prints the zip path and its SHA-256. Needs git; no zip tool required (git archive writes the zip).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REF=HEAD
OUT="$HERE/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) shift; REF="${1:-}" ;;
    --ref=*) REF="${1#--ref=}" ;;
    --out) shift; OUT="${1:-}" ;;
    --out=*) OUT="${1#--out=}" ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; echo "Usage: ./make-offline-bundle.sh [--ref <git-ref>] [--out <dir>]" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$REF" ] || { echo "--ref needs a value" >&2; exit 2; }
cd "$HERE"
git rev-parse --verify --quiet "$REF^{commit}" >/dev/null || { echo "Unknown git ref: $REF" >&2; exit 1; }

VERSION="$(git show "$REF:plugins/subdeck/.claude-plugin/plugin.json" 2>/dev/null | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$VERSION" ] || { echo "Cannot read the plugin version at $REF" >&2; exit 1; }
SHORT="$(git rev-parse --short "$REF")"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
EXTRA=()

# installers: use the copies in the ref; fall back to the working tree for an older ref that lacks them
for f in install-offline.ps1 install-offline.sh; do
  if ! git cat-file -e "$REF:$f" 2>/dev/null; then
    [ -f "$HERE/$f" ] || { echo "Missing $f" >&2; exit 1; }
    EXTRA+=("--add-file=$HERE/$f")
  fi
done

printf '@echo off\r\ncd /d "%%~dp0"\r\npowershell -NoProfile -ExecutionPolicy Bypass -File "%%~dp0install-offline.ps1" %%*\r\npause\r\n' > "$TMP/INSTALL.cmd"
EXTRA+=("--add-file=$TMP/INSTALL.cmd")

cat > "$TMP/OFFLINE-README.txt" <<EOF
SubDeck $VERSION offline bundle (built from $SHORT)

Installs SubDeck into Claude Code on a machine with no internet access. Nothing is downloaded.

Requirements on the target machine
  - Claude Code (the "claude" command)
  - Git for Windows (Git Bash; the plugin hooks are bash scripts) - on macOS/Linux bash is enough
  - Node.js 22.13 or newer, only for the Desk web view (optional)

Install (Windows)
  1. Unzip this folder to any place (it is copied to a permanent folder afterwards).
  2. Double-click INSTALL.cmd, or in PowerShell:  .\install-offline.ps1
     Using a non-Claude backend (for example GLM)?  .\install-offline.ps1 -ModeCurrent
  3. Restart Claude Code, then run /subdeck:status

Install (Git Bash, macOS, Linux)
  ./install-offline.sh            (add --mode-current for a non-Claude backend)

Options
  -Target <dir> / --target <dir>   permanent copy location (default ~/.subdeck/offline/SubDeck)
  -ModeCurrent / --mode-current    sub-agents use the session's model (writes mode=current)
  -Uninstall / --uninstall         remove the plugin, the marketplace entry and the copy

Smoke test after restart: ask Claude Code, in a throwaway folder:
  "Use a worker to create hello.txt containing hello, then verify it."
Open the live view with /subdeck:desk.

Full guide: docs/USER_GUIDE.md, section "Offline install (no internet)".
EOF
EXTRA+=("--add-file=$TMP/OFFLINE-README.txt")

mkdir -p "$OUT"
ZIP="$OUT/SubDeck-$VERSION-offline.zip"
rm -f "$ZIP"
git archive --format=zip -9 -o "$ZIP" "${EXTRA[@]}" "$REF" -- . ':(exclude)internal'

if command -v sha256sum >/dev/null 2>&1; then SUM="$(sha256sum "$ZIP" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then SUM="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
else SUM="(no sha256 tool found)"; fi
echo "Bundle: $ZIP"
echo "SHA-256: $SUM"
