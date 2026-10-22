#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-version.sh   (temp dirs, no network)
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
hasnt() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then bad "$3"; else ok "$3"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SUBDECK_STATE_DIR="$T/state" SUBDECK_HOME="$T/home" HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg"
mkdir -p "$T/home" "$T/cfg/plugins" "$T/state"
cat > "$T/inst.json" <<J
{"version":2,"plugins":{"other@x":[{"version":"9.9.9","gitCommitSha":"ffffffffffffffff"}],"subdeck@subdeck":[{"scope":"user","installPath":"/p","version":"0.9.2","lastUpdated":"2026-10-22T10:00:00.000Z","gitCommitSha":"1234567890abcdef"}]}}
J
export SUBDECK_INSTALLED_JSON="$T/inst.json"
V="$HERE/../scripts/version.sh"
o="$(SUBDECK_LATEST="0.9.2 1234567890abcdef" bash "$V")"
has "$o" 'installed: 0\.9\.2 \(commit 1234567, updated 2026-10-22\)' "installed version, short commit, date from installed_plugins.json"
has "$o" 'verdict: up to date' "same version and commit: up to date"
o="$(SUBDECK_LATEST="0.9.3 aaaaaaaaaaaa" bash "$V")"
has "$o" 'verdict: 0\.9\.3 available' "newer version: N.N.N available"
has "$o" 'update: /subdeck:update' "update command shown"
o="$(SUBDECK_LATEST="0.10.0 aaaaaaaaaaaa" bash "$V")"
has "$o" 'verdict: 0\.10\.0 available' "0.10.0 > 0.9.2 (numeric compare)"
o="$(SUBDECK_LATEST="0.9.2 bbbbbbbbbbbbbbbb" bash "$V")"
has "$o" 'verdict: same version but newer commit on main' "same version, other commit"
o="$(SUBDECK_LATEST=offline bash "$V")"
has "$o" 'latest: +unknown \(offline\)' "offline: latest unknown"
hasnt "$o" 'available|newer commit' "offline: no false update verdict"
o="$(SUBDECK_INSTALLED_JSON="$T/none.json" SUBDECK_LATEST=offline bash "$V")"
has "$o" 'installed: [0-9]+\.[0-9]+\.[0-9]+ \(commit unknown' "no installed_plugins.json: falls back to plugin.json"
o="$(bash "$V" --installed)"
[ "$o" = "0.9.2 1234567890abcdef" ] && ok "--installed prints version and full sha" || bad "--installed: $o"
mkdir -p "$T/home/.subdeck"; printf '{"pid":1,"port":1,"version":"0.9.2"}' > "$T/home/.subdeck/desk.json"
o="$(SUBDECK_LATEST=offline bash "$V")"; hasnt "$o" '^desk:' "dead Desk port: silent"
echo; echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
