#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-settings.sh   (temp HOME and project only; never the real ~/.subdeck)
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../scripts/settings.sh"
SK="$HERE/../skills/settings/SKILL.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
hasnt() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then bad "$3 (found: $2)"; else ok "$3"; fi; }
H="$(mktemp -d)"; P="$(mktemp -d)"; SS="$(mktemp -d)"
trap 'rm -rf "${H:?}" "${P:?}" "${SS:?}"' EXIT
unset SUBDECK_NOTIFY SUBDECK_GUARD CLAUDE_CODE_SUBAGENT_MODEL_FORCE SUBDECK_HOME CLAUDE_PROJECT_DIR
export SUBDECK_STATE_DIR="$SS"   # project config and state go to a temp dir, never the real ~/.subdeck
PS="$(HOME="$H"; . "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$P"; printf '%s' "$SD_STATE")"
run() { HOME="$H" bash "$S" "$@" "$P"; }
CFG="$H/.subdeck/config.json"

# ---- compact table ----
out="$(run)"; rc=$?
[ $rc -eq 0 ] && ok "show exits 0" || bad "show exit $rc"
for g in Models Notifications Push Guard "Protected files" Context "Status line"; do has "$out" "^$g\$" "group: $g"; done
has "$out" '^ +worker +sonnet *$' "table: worker default (no source noise)"
has "$out" '^ +escalation +opus *$' "table: escalation default"
has "$out" '^ +mode +auto *$' "table: mode"
has "$out" '^ +notify +off *$' "table: notify off by default"
has "$out" '^ +guard +on *$' "table: guard on"
has "$out" '^ +push +branches *$' "table: push default branches"
has "$out" '^ +protect-branches +main,master,release/\*' "table: protect-branches default"
has "$out" '^ +context +0 \(auto\)' "table: context auto"
has "$out" '^ +statusline +off' "table: statusline off"
has "$out" '^More: /subdeck:settings help$' "table: help pointer"
hasnt "$out" '->' "table: no resolved-model rows"
[ "$(printf '%s\n' "$out" | wc -l)" -le 36 ] && ok "table stays short" || bad "table too long"

# ---- help ----
out="$(run help)"; rc=$?
[ $rc -eq 0 ] && ok "help exits 0" || bad "help exit $rc"
for k in mode worker escalation researcher verifier explore notify notify.events push protect-branches guard git-add-all attribution protect context statusline; do
  has "$out" "^  $k +" "help lists $k"
done
has "$out" 'set key=value' "help: set command"
has "$out" 'reset' "help: reset command"
has "$out" 'ask\|branches\|off' "help: push options"
has "$out" 'Examples' "help: examples"

# ---- set (human table) ----
out="$(run set worker=opus notify=on push=off attribution=deny context=200000)"; rc=$?
[ $rc -eq 0 ] && ok "set exits 0" || bad "set exit $rc: $out"
has "$out" '^ +worker +opus +user' "set: model routed"
has "$out" '^ +notify +on +user' "set: notify on"
has "$out" '^ +push +off +user' "set: push routed"
has "$out" '^ +attribution +deny +user' "set: guard rule"
has "$out" '^ +context +200000 +user' "set: context"
grep -q '"modelPolicy"' "$CFG" && grep -q '"notify"' "$CFG" && grep -q '"guard"' "$CFG" && grep -q '"context":{"window":200000}' "$CFG" && ok "config holds all members" || bad "config members: $(cat "$CFG")"

# ---- json ----
j="$(run json)"; rc=$?
[ $rc -eq 0 ] && ok "json exits 0" || bad "json exit $rc"
has "$j" '^\{"version":1,"scope":"user","project":null,"settings":\[' "json: header, user scope"
has "$j" '"key":"worker","value":"opus","source":"user","group":"models","type":"enum","options":\["sonnet"' "json: worker"
has "$j" '"key":"notify","value":"on","source":"user","group":"notify","type":"bool"' "json: notify bool"
has "$j" '"key":"notify.events","value":\["waiting","done"[^]]*\].*"type":"list"' "json: events list"
has "$j" '"key":"push","value":"off","source":"user","group":"push","type":"enum","options":\["ask","branches","off"\]' "json: push"
has "$j" '"key":"protect-branches","value":\[' "json: protect-branches"
has "$j" '"key":"context","value":200000,"source":"user","group":"context","type":"int"' "json: context int"
has "$j" '"key":"attribution","value":"deny","source":"user","group":"guard"' "json: guard rule"
has "$j" '"key":"protect","value":\[\]' "json: protect list"
has "$j" '"key":"statusline","value":"off"' "json: statusline"
has "$j" '"description":"[^"]+"' "json: descriptions"
if command -v node >/dev/null 2>&1; then
  node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8"));if(o.version!==1||!Array.isArray(o.settings)||o.settings.some(s=>!s.key||!("value"in s)||!s.group||!s.type||!Array.isArray(s.options)))process.exit(1)' <<< "$j" && ok "json parses and is well-formed" || bad "json not well-formed"
fi
jp="$(HOME="$H" bash "$S" json --project "$P")"
has "$jp" '"scope":"project","project":"' "json --project: scope project"
run set worker=sonnet context=0 --project >/dev/null
jp="$(HOME="$H" bash "$S" json --project "$P")"
has "$jp" '"key":"worker","value":"sonnet","source":"project"' "json --project: project source"
has "$jp" '"key":"context","value":0,"source":"project"' "json --project: explicit context 0"
j="$(run json)"
has "$j" '"key":"worker","value":"opus","source":"user"' "json user scope ignores project values"
[ -f "$PS/config.json" ] && [ ! -e "$P/.subdeck" ] && ok "project file written outside the project" || bad "project file missing"

# ---- validation: exit 2, one-line stderr, nothing written ----
before="$(cat "$CFG")"
chk() { # description, expected-stderr regex, args...
  local d="$1" re="$2"; shift 2
  err="$(HOME="$H" bash "$S" set "$@" "$P" 2>&1 >/dev/null)"; rc=$?
  [ $rc -eq 2 ] && ok "$d: exit 2" || bad "$d: exit $rc"
  has "$err" "$re" "$d: message"
  [ "$(printf '%s\n' "$err" | wc -l)" -eq 1 ] && ok "$d: one line" || bad "$d: not one line"
  [ "$(cat "$CFG")" = "$before" ] && ok "$d: nothing written" || bad "$d: config changed"
}
chk "unknown key" "unknown key 'bogus'" bogus=1 worker=haiku
chk "bad notify" "notify must be on or off" notify=maybe worker=haiku
chk "bad mode" "mode must be" mode=zzz worker=haiku
chk "bad model" "worker must be" worker='bad!' notify=off
chk "bad push" "push must be" push=deny worker=haiku
chk "bad rule mode" "attribution must be deny, ask or off" attribution=nope worker=haiku
chk "bad context" "context must be a whole number" context=abc worker=haiku
chk "negative context" "context must be a whole number" context=-5 worker=haiku
chk "bad event" "unknown event 'bogus'" notify.events=waiting,bogus worker=haiku
chk "empty branches" "protect-branches needs" protect-branches= worker=haiku
chk "bad statusline" "statusline must be" statusline=maybe worker=haiku
err="$(HOME="$H" bash "$S" set 2>&1 >/dev/null)"; rc=$?; [ $rc -eq 2 ] && ok "set without pairs: exit 2" || bad "set without pairs: exit $rc"
err="$(HOME="$H" bash "$S" set worker=opus nonexistent-arg 2>&1 >/dev/null)"; rc=$?; [ $rc -eq 2 ] && ok "stray argument: exit 2" || bad "stray argument: exit $rc"

out="$(run set statusline=on)"
has "$out" 'needs your confirmation' "statusline not written by script"
[ ! -e "$H/.claude/settings.json" ] && ok "settings.json untouched" || bad "settings.json created"
mkdir -p "$H/.claude"; echo '{"statusLine":{"type":"command","command":"bash x/scripts/statusline.sh"}}' > "$H/.claude/settings.json"
has "$(run)" '^ +statusline +on' "table: statusline installed"
has "$(run json)" '"key":"statusline","value":"on"' "json: statusline installed"

# ---- protect lists ----
rm -f "$CFG"; rm -rf "${SS:?}"/*
out="$(run set protect=CLAUDE.md,migrations/**)"
has "$out" '^ +protect +CLAUDE.md,migrations/\*\* +user' "protect: table row"
grep -q '"protectedPaths":\["CLAUDE.md","migrations/\*\*"\]' "$CFG" && ok "protect: array written" || bad "protect config: $(cat "$CFG")"
out="$(run set protect=a.txt)"
has "$out" '^ +protect +a.txt +user' "protect= replaces the list"
out="$(run set protect=a.txt,b.txt unprotect=a.txt)"
has "$out" '^ +protect +b.txt +user' "unprotect removes one entry"
out="$(run set protect=)"
has "$out" '^ +protect +\(none\)' "protect= clears the list"
out="$(run set unprotect= 2>&1)"; rc=$?; [ $rc -eq 2 ] && ok "empty unprotect rejected" || bad "empty unprotect exit $rc"
out="$(run set protect=a.txt push=ask)"
has "$out" '^ +push +ask +user' "protect and a rule in one call"
has "$out" '^ +protect +a.txt +user' "protect and a rule in one call: list"

# ---- push / branches via the real guard.sh ----
out="$(run set push=branches protect-branches=main,dev)"
has "$out" '^ +push +branches' "push=branches"
has "$out" '^ +protect-branches +main,dev' "protect-branches routed to the guard"
has "$(run json)" '"key":"protect-branches","value":\["main","dev"\],"source":"user"' "json: protect-branches value"
grep -q '"protectBranches":\["main","dev"\]' "$CFG" && ok "protect-branches stored as guard.protectBranches" || bad "protectBranches config: $(cat "$CFG")"

# ---- routing stub: exact guard.sh cli calls (independent of the guard implementation) ----
STUB="$(mktemp -d)"; cp "$HERE/../scripts/"*.sh "$STUB/"
cat > "$STUB/guard.sh" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
echo "wrote stub"
STUBEOF
STUB_LOG="$STUB/calls.log"; export STUB_LOG
HOME="$H" bash "$STUB/settings.sh" set push=branches protect-branches=main,rel/* --project "$P" >/dev/null 2>&1
calls="$(cat "$STUB_LOG")"
has "$calls" "^cli push branches --project $P\$" "stub: cli push <mode> --project <dir>"
has "$calls" "^cli branches main,rel/\* --project $P\$" "stub: cli branches <list> --project <dir>"
rm -rf "${STUB:?}"


# ---- sub-script rejection mid-way: snapshot restore leaves every config file byte-identical ----
STUB="$(mktemp -d)"; cp "$HERE/../scripts/"*.sh "$STUB/"
cat > "$STUB/guard.sh" <<'STUBEOF'
#!/usr/bin/env bash
case "$2" in branches) echo "error: stub rejects branches"; exit 0 ;; esac
exec bash "$REAL_GUARD" "$@"
STUBEOF
REAL_GUARD="$HERE/../scripts/guard.sh"; export REAL_GUARD
for scope in "" "--project"; do
  rm -f "$CFG"; rm -rf "${SS:?}"/*
  run set worker=haiku notify=on $scope >/dev/null
  TF="$CFG"; [ -n "$scope" ] && TF="$PS/config.json"
  b1="$(cat "$TF")"; b2="$(cat "$H/.subdeck/config.json" 2>/dev/null)"
  err="$(HOME="$H" bash "$STUB/settings.sh" set worker=opus push=off context=777 protect-branches=main $scope "$P" 2>&1 >/dev/null)"; rc=$?
  [ $rc -eq 2 ] && ok "mid-way rejection${scope:+ $scope}: exit 2" || bad "mid-way rejection exit $rc"
  has "$err" 'stub rejects branches' "mid-way rejection${scope:+ $scope}: message"
  [ "$(cat "$TF")" = "$b1" ] && ok "mid-way rejection${scope:+ $scope}: target file byte-identical" || bad "target changed: $(cat "$TF")"
  [ "$(cat "$H/.subdeck/config.json" 2>/dev/null)" = "$b2" ] && ok "mid-way rejection${scope:+ $scope}: user file byte-identical" || bad "user file changed"
done
# target absent before: stays absent
rm -f "$CFG"; rm -rf "${SS:?}"/*
HOME="$H" bash "$STUB/settings.sh" set worker=opus protect-branches=main "$P" >/dev/null 2>&1
[ ! -e "$CFG" ] && ok "mid-way rejection: absent file stays absent" || bad "file created: $(cat "$CFG")"
rm -rf "${STUB:?}"
# ---- context key keeps other members; reset ----
run set push=ask >/dev/null
out="$(run set context=123456)"
grep -q '"context":{"window":123456}' "$CFG" && ok "context stored as context.window" || bad "context config: $(cat "$CFG")"
grep -q '"guard"' "$CFG" && ok "context write keeps other members" || bad "context write dropped members"
out="$(run set worker=opus)"; grep -q '"context":{"window":123456}' "$CFG" && ok "model write keeps context" || bad "model write dropped context"
out="$(run reset)"
has "$out" '^ +worker +sonnet *$' "reset: models default"
has "$out" '^ +notify +off' "reset: notify off"
has "$out" '^ +context +0 \(auto\)' "reset: context auto"
has "$out" '^ +push +branches' "reset: push default"
run reset --project >/dev/null
has "$(run)" '^ +worker +sonnet *$' "reset --project exits cleanly"

# ---- skill file ----
[ -f "$SK" ] && grep -q '^disable-model-invocation: true' "$SK" && ok "skill is user-only" || bad "skill frontmatter"
grep -q '\${[A-Za-z_]*:-' "$SK" && bad "skill uses \${VAR:-default}" || ok "skill avoids \${VAR:-default}"
grep -q '|| true' "$SK" && ok "injected command ends with || true" || bad "no || true"
grep -q 'help' "$SK" && ok "skill mentions help" || bad "skill does not mention help"
for d in task pr models notify guard statusline; do [ ! -e "$HERE/../skills/$d" ] && ok "skill $d removed" || bad "skill $d still present"; done
for d in desk status settings orchestrator; do [ -f "$HERE/../skills/$d/SKILL.md" ] && ok "skill $d present" || bad "skill $d missing"; done

echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
