#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-models.sh   (temp HOME and project only)
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$HERE/../scripts/models.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
H="$(mktemp -d)"; P="$(mktemp -d)"
unset ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL
run() { HOME="$H" bash "$M" "$@" "$P"; }
validjson() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(!j.modelPolicy)process.exit(1)' "$1" 2>/dev/null; }

out="$(run show)"; rc=$?
[ $rc -eq 0 ] && ok "show exits 0" || bad "show exit $rc"
has "$out" '^worker +sonnet +default' "default worker sonnet"
has "$out" '^escalation +opus +default' "default escalation opus"
has "$out" '^explore +haiku +default' "default explore haiku"
has "$out" '^mode +auto +default' "default mode auto"
has "$out" 'worker +sonnet -> latest sonnet' "alias resolution line"

out="$(run set worker=haiku verifier=opus)"; rc=$?
[ $rc -eq 0 ] && ok "set exits 0" || bad "set exit $rc"
[ -f "$H/.subdeck/config.json" ] && ok "user file written" || bad "user file missing"
validjson "$H/.subdeck/config.json" && ok "user JSON valid" || bad "user JSON invalid"
[ "$(wc -l < "$H/.subdeck/config.json")" -le 1 ] && ok "compact single line" || bad "not compact"
out="$(run show)"
has "$out" '^worker +haiku +user' "user worker haiku"
has "$out" '^verifier +opus +user' "user verifier opus"
has "$out" '^researcher +sonnet +default' "untouched key stays default"

out="$(run set worker=claude-sonnet-5-5 mode=current --project)"
validjson "$P/.subdeck/config.json" && ok "project JSON valid" || bad "project JSON invalid"
out="$(run show)"
has "$out" '^worker +claude-sonnet-5-5 +project' "project overrides user"
has "$out" '^mode +current +project' "project mode"
has "$out" '^verifier +opus +user' "user value survives project override"
has "$out" 'worker +claude-sonnet-5-5 -> pinned id' "full id shown as pinned"

out="$(run set worker=haiku --project)"; out="$(run show)"
has "$out" '^mode +current +project' "set merges into existing project file"

out="$(ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5 HOME="$H" bash "$M" show "$P")"
has "$out" 'escalation +opus -> claude-opus-5-5 \(env' "env mapping shown"

out="$(run set bogus=opus)"; rc=$?
[ $rc -eq 0 ] && ok "invalid key exits 0" || bad "invalid key exit $rc"
has "$out" "error: unknown key 'bogus'" "invalid key message"
out="$(run set 'worker=bad;x')"; rc=$?
[ $rc -eq 0 ] && ok "invalid value exits 0" || bad "invalid value exit $rc"
has "$out" "error: invalid value 'bad;x' for worker" "invalid value message"
out="$(run set mode=fast)"
has "$out" "invalid value 'fast' for mode" "invalid mode message"
before="$(cat "$H/.subdeck/config.json")"
out="$(run set worker=opus bogus=x)"
[ "$before" = "$(cat "$H/.subdeck/config.json")" ] && ok "nothing written when any pair invalid" || bad "partial write"
out="$(run set)"; has "$out" 'error: set needs' "set without pairs"

out="$(run reset --project)"; rc=$?
[ $rc -eq 0 ] && ok "reset exits 0" || bad "reset exit $rc"
[ ! -f "$P/.subdeck/config.json" ] && ok "project file removed" || bad "project file remains"
out="$(run show)"
has "$out" '^worker +haiku +user' "user survives project reset"
out="$(run reset)"; [ ! -f "$H/.subdeck/config.json" ] && ok "user file removed" || bad "user file remains"
out="$(run reset)"; has "$out" 'nothing to remove' "reset twice is harmless"
out="$(run frobnicate)"; rc=$?; [ $rc -eq 0 ] && ok "unknown arg exits 0" || bad "unknown arg exit $rc"
has "$out" "warning: ignored argument 'frobnicate'" "unknown arg warned"

rm -rf "$H" "$P"
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
