#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-install-script.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "$1 $2 $3" = "plugin marketplace list" ] && [ -n "${STUB_HAS_MKT:-}" ]; then echo "  subdeck"; fi
exit 0
STUB
chmod +x "$T/bin/claude"
# Minimal PATH with the stub but without a real claude
SAFE="$T/bin:/usr/bin:/bin"
run() { : > "$T/log"; STUB_LOG="$T/log" HOME="$T/home" PATH="$SAFE" bash "$ROOT/install.sh" "$@" > "$T/out" 2>&1; echo $?; }

rc=$(run); [ "$rc" = 0 ] && ok "fresh install exits 0" || bad "fresh install rc=$rc"
grep -qx "plugin marketplace add emiirhandemirci/SubDeck" "$T/log" && grep -qx "plugin install subdeck@subdeck" "$T/log" && ok "fresh: add + install" || bad "fresh: add + install"
grep -q "marketplace update" "$T/log" && bad "fresh: no update" || ok "fresh: no update"
grep -q "Restart Claude Code" "$T/out" && grep -q "/subdeck:desk" "$T/out" && ok "fresh: hints printed" || bad "fresh: hints"

export STUB_HAS_MKT=1
rc=$(run); [ "$rc" = 0 ] && ok "update exits 0" || bad "update rc=$rc"
grep -qx "plugin marketplace update subdeck" "$T/log" && grep -qx "plugin update subdeck@subdeck" "$T/log" && ok "update: marketplace update + plugin update" || bad "update calls"
grep -q "marketplace add" "$T/log" && bad "update: no add" || ok "update: no add"

rc=$(run --uninstall); [ "$rc" = 0 ] && ok "uninstall exits 0" || bad "uninstall rc=$rc"
grep -qx "plugin uninstall subdeck@subdeck" "$T/log" && grep -qx "plugin marketplace remove subdeck" "$T/log" && ok "uninstall calls" || bad "uninstall calls"
unset STUB_HAS_MKT

rm "$T/bin/claude"
rc=$(run); [ "$rc" = 1 ] && ok "claude missing exits 1" || bad "claude missing rc=$rc"
grep -qi "not found" "$T/out" && ok "claude missing message" || bad "claude missing message"

if command -v powershell >/dev/null 2>&1; then
  P="$(cygpath -w "$ROOT/install.ps1" 2>/dev/null || echo "$ROOT/install.ps1")"
  if powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw '$P')) | Out-Null" >/dev/null 2>&1; then ok "install.ps1 parses"; else bad "install.ps1 parse"; fi
else echo "skip install.ps1 parse (no powershell)"; fi
if grep -q $'\r' "${BASH_SOURCE[0]}" "$ROOT/install.sh"; then bad "CRLF in sh files"; else ok "sh files LF"; fi
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
