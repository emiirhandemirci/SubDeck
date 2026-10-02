#!/usr/bin/env bash
# plugins/subdeck/tests/test-offline.sh — run: bash plugins/subdeck/tests/test-offline.sh
# Builds an offline bundle from HEAD into a temp dir, installs it with a fake `claude` shim on a temp HOME,
# and asserts the copied files, marker, CLI calls (no network tools), mode-current config and uninstall.
# The installers are taken from the working tree when HEAD does not contain them yet.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
hasnt() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then bad "$3 (unexpected match: $2)"; else ok "$3"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# --- build the bundle ---
OUT="$(bash "$ROOT/make-offline-bundle.sh" --ref HEAD --out "$T/dist" 2>&1)"; RC=$?
[ $RC -eq 0 ] && ok "bundle builds" || { bad "bundle builds"; printf '%s\n' "$OUT"; }
has "$OUT" 'SubDeck-[0-9.]+-offline\.zip' "prints the zip path"
has "$OUT" 'SHA-256: [0-9a-f]{64}' "prints the SHA-256"
ZIP="$(ls "$T"/dist/SubDeck-*-offline.zip 2>/dev/null | head -1)"
[ -f "$ZIP" ] || { bad "zip exists"; echo "passed $PASS, failed $FAIL"; exit 1; }
mkdir -p "$T/ex"
if command -v unzip >/dev/null 2>&1; then unzip -q "$ZIP" -d "$T/ex"; else tar -xf "$ZIP" -C "$T/ex"; fi
LIST="$(cd "$T/ex" && find . -type f | sed 's#^\./##')"
has "$LIST" '^install-offline\.ps1$' "zip root has install-offline.ps1"
has "$LIST" '^install-offline\.sh$' "zip root has install-offline.sh"
has "$LIST" '^INSTALL\.cmd$' "zip root has INSTALL.cmd"
has "$LIST" '^OFFLINE-README\.txt$' "zip root has OFFLINE-README.txt"
has "$LIST" '^plugins/subdeck/\.claude-plugin/plugin\.json$' "zip has the plugin"
has "$LIST" '^\.claude-plugin/marketplace\.json$' "zip has the marketplace file"
has "$LIST" '^desk/server\.mjs$' "zip has Desk"
hasnt "$LIST" '^internal/' "zip has no internal/"
hasnt "$LIST" '^dist/' "zip has no dist/"

# --- fake claude + tripwires for network tools ---
SH="$T/shim"; ST="$T/state"; mkdir -p "$SH" "$ST"
cat > "$SH/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_STATE/calls.log"
case "$1 $2 $3" in
  "plugin marketplace list")
    echo "Configured marketplaces:"; echo
    if [ -f "$SHIM_STATE/mkt" ]; then echo "  ❯ subdeck"; echo "    Source: $(cat "$SHIM_STATE/mkt")"; echo; fi ;;
  "plugin marketplace add") echo "Directory ($4)" > "$SHIM_STATE/mkt"; echo "added" ;;
  "plugin marketplace remove") rm -f "$SHIM_STATE/mkt" "$SHIM_STATE/plugin" ;;
  "plugin marketplace update") echo "updated" ;;
  "plugin list "*) echo "Installed plugins:"; [ -f "$SHIM_STATE/plugin" ] && echo "  ❯ subdeck@subdeck"; true ;;
  "plugin install "*) touch "$SHIM_STATE/plugin" ;;
  "plugin update "*) echo "updated" ;;
  "plugin uninstall "*) rm -f "$SHIM_STATE/plugin" ;;
esac
exit 0
EOF
chmod +x "$SH/claude"
for n in curl wget git; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$SHIM_STATE/network.log"\nexit 1\n' "$n" > "$SH/$n"; chmod +x "$SH/$n"; done
export SHIM_STATE="$ST"
H="$T/home"; mkdir -p "$H"
TARGET="$H/.subdeck/offline/SubDeck"
run() { HOME="$H" USERPROFILE="$H" PATH="$SH:$PATH" ANTHROPIC_BASE_URL= bash "$T/ex/install-offline.sh" "$@" 2>&1; }

# --- first install ---
OUT="$(run)"; RC=$?
[ $RC -eq 0 ] && ok "install exit 0" || { bad "install exit 0 ($RC)"; printf '%s\n' "$OUT"; }
[ -f "$TARGET/plugins/subdeck/.claude-plugin/plugin.json" ] && ok "plugin copied to the default target" || bad "plugin copied"
[ -f "$TARGET/desk/server.mjs" ] && ok "Desk copied" || bad "Desk copied"
[ -f "$TARGET/.subdeck-offline-install" ] && ok "marker written" || bad "marker written"
CALLS="$(cat "$ST/calls.log")"
has "$CALLS" '^plugin marketplace add .*SubDeck$' "marketplace add with the target path"
has "$CALLS" '^plugin install subdeck@subdeck$' "plugin install"
hasnt "$CALLS" 'marketplace update|plugin update' "no update on a fresh install"
[ ! -s "$ST/network.log" ] && ok "no network tool called" || { bad "no network tool called"; cat "$ST/network.log"; }
[ ! -f "$H/.subdeck/config.json" ] && ok "no mode written without --mode-current" || bad "no mode written without --mode-current"
has "$OUT" 'Restart Claude Code' "next steps: restart"
has "$OUT" '/subdeck:status' "next steps: status"
has "$OUT" 'hello\.txt' "next steps: smoke test"

# --- non-Claude backend hint ---
OUT="$(HOME="$H" USERPROFILE="$H" PATH="$SH:$PATH" ANTHROPIC_BASE_URL=http://glm.intranet.example:8080/anthropic bash "$T/ex/install-offline.sh" 2>&1)"
has "$OUT" 'mode-current' "recommends --mode-current for a non-Anthropic backend"
[ ! -f "$H/.subdeck/config.json" ] && ok "hint alone writes nothing" || bad "hint alone writes nothing"

# --- re-install with --mode-current: update path, config written, our copy replaced ---
echo stale > "$TARGET/stale.txt"
: > "$ST/calls.log"
OUT="$(run --mode-current)"; RC=$?
[ $RC -eq 0 ] && ok "re-install exit 0" || { bad "re-install exit 0"; printf '%s\n' "$OUT"; }
CALLS="$(cat "$ST/calls.log")"
has "$CALLS" '^plugin marketplace update subdeck$' "marketplace update when already ours"
has "$CALLS" '^plugin update subdeck@subdeck$' "plugin update when installed"
hasnt "$CALLS" 'marketplace add|marketplace remove|plugin install' "no add/remove/install on update"
[ ! -e "$TARGET/stale.txt" ] && ok "older copy of ours replaced" || bad "older copy of ours replaced"
CFG="$(cat "$H/.subdeck/config.json" 2>/dev/null)"
has "$CFG" '"mode":"current"' "mode=current written to ~/.subdeck/config.json"

# --- a GitHub-sourced marketplace entry is replaced by the local copy ---
echo "GitHub (emiirhandemirci/SubDeck)" > "$ST/mkt"; : > "$ST/calls.log"
run >/dev/null
CALLS="$(cat "$ST/calls.log")"
has "$CALLS" '^plugin marketplace remove subdeck$' "remote marketplace entry removed first"
has "$CALLS" '^plugin marketplace add ' "then added from the local copy"
[ ! -s "$ST/network.log" ] && ok "still no network tool called" || bad "still no network tool called"

# --- foreign target is never overwritten ---
FT="$T/foreign"; mkdir -p "$FT"; echo mine > "$FT/keep.txt"
OUT="$(run --target "$FT")"; RC=$?
[ $RC -ne 0 ] && ok "refuses a non-SubDeck target (exit $RC)" || bad "refuses a non-SubDeck target"
[ -f "$FT/keep.txt" ] && [ ! -e "$FT/plugins" ] && ok "foreign folder untouched" || bad "foreign folder untouched"
has "$OUT" 'not a SubDeck offline copy' "message for a foreign target"

# --- custom target ---
CT="$T/custom/SubDeck"
run --target "$CT" >/dev/null
[ -f "$CT/.subdeck-offline-install" ] && ok "--target honoured" || bad "--target honoured"
rm -rf "$CT"

# --- prerequisites ---
OUT="$(HOME="$H" USERPROFILE="$H" PATH="/usr/bin:/bin" bash "$T/ex/install-offline.sh" 2>&1)"; RC=$?
[ $RC -ne 0 ] && has "$OUT" "'claude' command was not found" "clear message when claude is missing" || bad "missing claude must fail"

# --- uninstall ---
: > "$ST/calls.log"
OUT="$(run --uninstall)"; RC=$?
[ $RC -eq 0 ] && ok "uninstall exit 0" || bad "uninstall exit 0"
CALLS="$(cat "$ST/calls.log")"
has "$CALLS" '^plugin uninstall subdeck@subdeck$' "plugin uninstalled"
has "$CALLS" '^plugin marketplace remove subdeck$' "marketplace removed"
[ ! -e "$TARGET" ] && ok "our copy removed" || bad "our copy removed"
[ -f "$H/.subdeck/config.json" ] && ok "user config kept" || bad "user config kept"

# --- Windows PowerShell installer (only where powershell.exe exists) ---
if command -v powershell.exe >/dev/null 2>&1; then
  PSH="$T/pshome"; mkdir -p "$PSH" "$T/psshim"
  printf '@echo off\r\nbash "%s" %%*\r\n' "$(cygpath -m "$SH/claude" 2>/dev/null || echo "$SH/claude")" > "$T/psshim/claude.cmd"
  PSPATH="$(cygpath -w "$T/psshim" 2>/dev/null);$PATH"
  OUT="$(HOME="$PSH" USERPROFILE="$PSH" PATH="$PSPATH" SHIM_STATE="$ST" ANTHROPIC_BASE_URL= powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$T/ex/install-offline.ps1")" -ModeCurrent 2>&1)"; RC=$?
  [ $RC -eq 0 ] && ok "ps1 install exit 0" || { bad "ps1 install exit 0 ($RC)"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }
  [ -f "$PSH/.subdeck/offline/SubDeck/.subdeck-offline-install" ] && ok "ps1 copied + marker" || bad "ps1 copied + marker"
  has "$(cat "$PSH/.subdeck/config.json" 2>/dev/null)" '"mode":"current"' "ps1 -ModeCurrent writes config"
  OUT="$(HOME="$PSH" USERPROFILE="$PSH" PATH="$PSPATH" SHIM_STATE="$ST" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$T/ex/install-offline.ps1")" -Uninstall 2>&1)"
  [ ! -e "$PSH/.subdeck/offline/SubDeck" ] && ok "ps1 -Uninstall removes the copy" || { bad "ps1 -Uninstall removes the copy"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }
else
  echo "skip ps1 tests (no powershell.exe)"
fi

echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
