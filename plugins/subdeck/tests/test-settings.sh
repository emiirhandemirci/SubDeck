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
for g in Models Notifications Push Guard "Protected files" "Protected resources" Context Tasks Roles "Status line"; do has "$out" "^$g\$" "group: $g"; done
has "$out" '^ +worker +sonnet *$' "table: worker default (no source noise)"
has "$out" '^ +escalation +opus *$' "table: escalation default"
has "$out" '^ +mode +auto *$' "table: mode"
has "$out" '^ +notify +off *$' "table: notify off by default"
has "$out" '^ +guard +on *$' "table: guard on"
has "$out" '^ +push +branches *$' "table: push default branches"
has "$out" '^ +protect-branches +main,master,release/\*' "table: protect-branches default"
has "$out" '^ +context +0 \(auto\)' "table: context auto"
has "$out" '^ +statusline +off' "table: statusline off"
has "$out" '^ +protected-resources +ask *$' "table: protected-resources default ask"
has "$out" '^ +protect-ports +\(none\)' "table: protect-ports empty"
has "$out" '^ +tasks.dir +\(state dir\)' "table: tasks.dir default"
has "$out" '^ +report-check +on *$' "table: report-check default on"
has "$out" '^More: /subdeck:settings help$' "table: help pointer"
hasnt "$out" '->' "table: no resolved-model rows"
[ "$(printf '%s\n' "$out" | wc -l)" -le 48 ] && ok "table stays short" || bad "table too long"

# ---- help ----
out="$(run help)"; rc=$?
[ $rc -eq 0 ] && ok "help exits 0" || bad "help exit $rc"
for k in mode worker escalation researcher verifier explore notify notify.events push protect-branches guard git-add-all attribution protect context statusline protected-resources protect-ports protect-hosts protect-procs tasks.dir report-check; do
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
chk "bad report-check" "report-check must be on or off" report-check=maybe worker=haiku
chk "bad protected-resources" "protected-resources must be deny, ask or off" protected-resources=nope worker=haiku
chk "tasks.dir with .." "'..' segments are not allowed" tasks.dir=../elsewhere worker=haiku
chk "tasks.dir with inner .." "'..' segments are not allowed" 'tasks.dir=docs\..\..\x' worker=haiku
chk "tasks.dir with a quote" "no quotes or control characters" 'tasks.dir=a"b' worker=haiku
chk "tasks.dir with a tab" "no quotes or control characters" "tasks.dir=a$(printf '\t')b" worker=haiku
chk "tasks.dir too long" "at most 200 characters" "tasks.dir=$(printf 'a%.0s' $(seq 201))" worker=haiku
chk "port 70000" "protect-ports: '70000' is not a port" protect-ports=8080,70000 worker=haiku
chk "port 0" "protect-ports: '0' is not a port" protect-ports=0 worker=haiku
chk "port abc" "protect-ports: 'abc' is not a port" protect-ports=abc worker=haiku
chk "host with a space" "protect-hosts: invalid host" 'protect-hosts=ok.example,bad host' worker=haiku
chk "host with a slash" "protect-hosts: invalid host" 'protect-hosts=http://x' worker=haiku
chk "proc with ;" "protect-procs: invalid process name" 'protect-procs=a;b' worker=haiku
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

# ---- tasks keys (written here into the "tasks" member) ----
rm -f "$CFG"; rm -rf "${SS:?}"/*
cfg_raw() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
out="$(run set 'tasks.dir=docs\tasks' report-check=off)"; rc=$?
[ $rc -eq 0 ] && ok "set tasks keys exits 0" || bad "set tasks keys exit $rc: $out"
grep -q '"tasks":{"dir":"docs/tasks","reportCheck":false}' "$CFG" && ok "tasks member written, backslash stored as /" || bad "tasks config: $(cat "$CFG")"
has "$out" '^ +tasks.dir +docs/tasks +user' "table: tasks.dir value"
has "$out" '^ +report-check +off +user' "table: report-check off"
j="$(run json)"
has "$j" '"key":"tasks.dir","value":"docs/tasks","source":"user","group":"tasks","type":"string","options":\[\]' "json: tasks.dir"
has "$j" '"key":"report-check","value":"off","source":"user","group":"tasks","type":"bool","options":\["on","off"\]' "json: report-check"
out="$(run set report-check=on)"
grep -q '"tasks":{"dir":"docs/tasks","reportCheck":true}' "$CFG" && ok "report-check=on keeps tasks.dir" || bad "tasks config: $(cat "$CFG")"
out="$(run set tasks.dir=)"
grep -q '"tasks":{"reportCheck":true}' "$CFG" && ok "tasks.dir= removes the dir member" || bad "tasks config: $(cat "$CFG")"
has "$out" '^ +tasks.dir +\(state dir\)' "tasks.dir= back to the state dir"
cfg_raw "$CFG" '{"modelPolicy":{"worker":"opus"},"tasks":{"prio":{"x":[1,2]},"dir":"old"},"desk":{"days":3}}'
out="$(run set report-check=off)"
grep -q '"tasks":{"prio":{"x":\[1,2\]},"dir":"old","reportCheck":false}' "$CFG" && grep -q '"modelPolicy":{"worker":"opus"}' "$CFG" && grep -q '"desk":{"days":3}' "$CFG" \
  && ok "tasks write keeps unknown tasks keys and other members" || bad "tasks write damaged config: $(cat "$CFG")"
out="$(run set tasks.dir=/abs/tasks --project)"
grep -q '"tasks":{"dir":"/abs/tasks"}' "$PS/config.json" && ok "tasks.dir --project goes to the project config" || bad "project tasks: $(cat "$PS/config.json" 2>/dev/null)"
has "$(HOME="$H" bash "$S" json --project "$P")" '"key":"tasks.dir","value":"/abs/tasks","source":"project"' "json --project: project tasks.dir wins"
cfg_raw "$CFG" '{"tasks": {"dir": "x"}, oops'; b4="$(cat "$CFG")"
err="$(run set report-check=off 2>&1 >/dev/null)"; rc=$?
[ $rc -eq 2 ] && [ "$(cat "$CFG")" = "$b4" ] && ok "broken file: tasks write refused, file unchanged" || bad "broken file: exit $rc, $(cat "$CFG")"
rm -f "$CFG"; rm -rf "${SS:?}"/*
out="$(run set tasks.dir=docs/tasks worker=opus)"
out="$(run reset)"
grep -q '"tasks"' "$CFG" 2>/dev/null && bad "reset kept the tasks member" || ok "reset removes the tasks member"
has "$out" '^ +report-check +on *$' "reset: report-check default"

# ---- protected resources (routed to guard.sh cli ports|hosts|procs) ----
rm -f "$CFG"; rm -rf "${SS:?}"/*
out="$(run set protect-ports=8080,09000 protect-hosts=staging.example protect-procs=redis,node.exe protected-resources=deny)"; rc=$?
[ $rc -eq 0 ] && ok "set resource lists exits 0" || bad "set resource lists exit $rc: $out"
grep -q '"protectPorts":\["8080","9000"\]' "$CFG" && grep -q '"protectHosts":\["staging.example"\]' "$CFG" && grep -q '"protectProcs":\["redis","node.exe"\]' "$CFG" && grep -q '"protected-resources":"deny"' "$CFG" \
  && ok "resource lists stored under guard" || bad "resource config: $(cat "$CFG")"
has "$out" '^ +protect-ports +8080,9000 +user' "table: protect-ports"
has "$out" '^ +protected-resources +deny +user' "table: protected-resources mode"
j="$(run json)"
has "$j" '"key":"protect-ports","value":\["8080","9000"\],"source":"user","group":"resources","type":"list"' "json: protect-ports"
has "$j" '"key":"protect-hosts","value":\["staging.example"\],"source":"user","group":"resources","type":"list"' "json: protect-hosts"
has "$j" '"key":"protect-procs","value":\["redis","node.exe"\],"source":"user","group":"resources","type":"list"' "json: protect-procs"
has "$j" '"key":"protected-resources","value":"deny","source":"user","group":"guard","type":"enum","options":\["deny","ask","off"\]' "json: protected-resources"
for k in tasks.dir report-check protected-resources protect-ports protect-hosts protect-procs; do
  [ "$(printf '%s' "$j" | grep -o "\"key\":\"$k\"" | wc -l)" -eq 1 ] && ok "json lists $k once" || bad "json: $k count"
done
hj="$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"curl http://localhost:8080/x"}}' "$P" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$HERE/../scripts/guard.sh")"
has "$hj" '"permissionDecision":"deny".*protected-resources' "guard hook uses the lists written by settings"
out="$(run set protect-ports=9000 --project)"
has "$(HOME="$H" bash "$S" json --project "$P")" '"key":"protect-ports","value":\["9000"\],"source":"project"' "project protect-ports replaces the user list"
out="$(run set protect-ports=)"
grep -q protectPorts "$CFG" && bad "protect-ports= kept the list" || ok "protect-ports= clears the list"
grep -q '"protectHosts":\["staging.example"\]' "$CFG" && ok "clearing ports keeps hosts" || bad "hosts lost: $(cat "$CFG")"
run reset --project >/dev/null; rm -f "$CFG"

# ---- routing stub: exact guard.sh cli calls (independent of the guard implementation) ----
STUB="$(mktemp -d)"; cp "$HERE/../scripts/"*.sh "$STUB/"
cat > "$STUB/guard.sh" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
echo "wrote stub"
STUBEOF
STUB_LOG="$STUB/calls.log"; export STUB_LOG
HOME="$H" bash "$STUB/settings.sh" set push=branches protect-branches=main,rel/* --project "$P" >/dev/null 2>&1
HOME="$H" bash "$STUB/settings.sh" set protect-ports=8080,9000 protect-hosts= --project "$P" >/dev/null 2>&1
calls="$(cat "$STUB_LOG")"
has "$calls" "^cli ports 8080,9000 --project $P\$" "stub: cli ports <list> --project <dir>"
has "$calls" "^cli hosts  --project $P\$" "stub: cli hosts '' (empty clears) --project <dir>"
has "$calls" "^cli push branches --project $P\$" "stub: cli push <mode> --project <dir>"
has "$calls" "^cli branches main,rel/\* --project $P\$" "stub: cli branches <list> --project <dir>"
rm -rf "${STUB:?}"


# ---- sub-script rejection mid-way: snapshot restore leaves every config file byte-identical ----
STUB="$(mktemp -d)"; cp "$HERE/../scripts/"*.sh "$STUB/"
cat > "$STUB/guard.sh" <<'STUBEOF'
#!/usr/bin/env bash
case "$2" in branches|procs) echo "error: stub rejects $2"; exit 0 ;; esac
exec bash "$REAL_GUARD" "$@"
STUBEOF
REAL_GUARD="$HERE/../scripts/guard.sh"; export REAL_GUARD
for scope in "" "--project"; do
  rm -f "$CFG"; rm -rf "${SS:?}"/*
  run set worker=haiku notify=on $scope >/dev/null
  TF="$CFG"; [ -n "$scope" ] && TF="$PS/config.json"
  b1="$(cat "$TF")"; b2="$(cat "$H/.subdeck/config.json" 2>/dev/null)"
  err="$(HOME="$H" bash "$STUB/settings.sh" set worker=opus push=off context=777 tasks.dir=t report-check=off protect-ports=8080 protect-branches=main $scope "$P" 2>&1 >/dev/null)"; rc=$?
  [ $rc -eq 2 ] && ok "mid-way rejection${scope:+ $scope}: exit 2" || bad "mid-way rejection exit $rc"
  has "$err" 'stub rejects branches' "mid-way rejection${scope:+ $scope}: message"
  [ "$(cat "$TF")" = "$b1" ] && ok "mid-way rejection${scope:+ $scope}: target file byte-identical" || bad "target changed: $(cat "$TF")"
  [ "$(cat "$H/.subdeck/config.json" 2>/dev/null)" = "$b2" ] && ok "mid-way rejection${scope:+ $scope}: user file byte-identical" || bad "user file changed"
  err="$(HOME="$H" bash "$STUB/settings.sh" set tasks.dir=t protect-ports=8080 protect-procs=redis $scope "$P" 2>&1 >/dev/null)"; rc=$?
  [ $rc -eq 2 ] && [ "$(cat "$TF")" = "$b1" ] && ok "mid-way rejection of procs${scope:+ $scope}: nothing written (tasks, ports)" || bad "procs rejection: exit $rc, $(cat "$TF")"
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

# ---- roles (config member "roles"; per role the whole object of one scope wins) ----
rm -f "$CFG"; rm -rf "${SS:?}"/*
out="$(run)"
has "$out" '^ +worker +\(in-session\)$' "roles: unmapped worker shows (in-session)"
has "$out" '^ +manager +\(in-session\)$' "roles: manager listed"
j="$(run json)"
has "$j" '"key":"roles.worker.tool","value":"","source":"default","group":"roles","type":"enum","options":\["claude","codex","gemini","agy","opencode","copilot","custom"\]' "roles json: default tool row"
has "$j" '"key":"roles.worker.timeout","value":1800,"source":"default","group":"roles","type":"int"' "roles json: timeout default 1800"
[ "$(printf '%s' "$j" | grep -o '"group":"roles"' | wc -l)" -eq 25 ] && ok "roles json: 5 fixed roles x 5 fields" || bad "roles json row count"
[ "$(printf '%s' "$j" | grep -o '"key":"roles.manager.tool"' | wc -l)" -eq 1 ] && ok "roles json: manager row once" || bad "manager row count"
case "$j" in *'"key":"report-check"'*'"key":"roles.manager.tool"'*) ok "roles json: group after tasks" ;; *) bad "roles group order" ;; esac
out="$(run set roles.worker.tool=codex roles.worker.model=gpt-5-codex 'roles.worker.args=--x{sp}y  -c' roles.worker.timeout=0600 roles.ui-worker.tool=custom 'roles.ui-worker.cmd=mytool "a" --in {prompt_file}' roles.verifier.tool=claude roles.verifier.model=opus)"; rc=$?
[ $rc -eq 0 ] && ok "roles set exits 0" || bad "roles set exit $rc: $out"
has "$out" '^ +worker +codex gpt-5-codex +user$' "roles show: mapped worker"
has "$out" '^ +verifier +claude opus +user$' "roles show: verifier"
has "$out" '^ +ui-worker +custom +user$' "roles show: free role, custom without model"
has "$out" '^ +researcher +\(in-session\)$' "roles show: researcher unmapped"
grep -q '"worker":{"tool":"codex","model":"gpt-5-codex","args":"--x{sp}y -c","timeout":600}' "$CFG" && ok "roles stored (args normalized, timeout number)" || bad "roles config: $(cat "$CFG")"
grep -q '"cmd":"mytool \\"a\\" --in {prompt_file}"' "$CFG" && ok "cmd stored JSON-escaped" || bad "cmd config: $(cat "$CFG")"
j="$(run json)"
has "$j" '"key":"roles.worker.args","value":"--x\{sp\}y -c","source":"user"' "roles json: args value"
has "$j" '"key":"roles.worker.timeout","value":600,"source":"user"' "roles json: timeout set"
has "$j" '"key":"roles.ui-worker.cmd","value":"mytool \\"a\\" --in \{prompt_file\}","source":"user","group":"roles","type":"string"' "roles json: cmd escaped, free role row"
case "$j" in *'"key":"roles.verifier.timeout"'*'"key":"roles.ui-worker.tool"'*) ok "roles json: free roles after fixed" ;; *) bad "free role order" ;; esac
if command -v node >/dev/null 2>&1; then
  node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8"));const c=o.settings.find(s=>s.key==="roles.ui-worker.cmd");if(c.value!=="mytool \"a\" --in {prompt_file}")process.exit(1)' <<< "$j" && ok "roles json parses, cmd round-trips" || bad "roles json parse"
fi
# precedence: whole object per role, never mixed
out="$(run set roles.worker.tool=gemini --project)"
has "$out" '^ +worker +gemini +project$' "roles precedence: project object replaces user object (no model mixed in)"
has "$out" '^ +verifier +claude opus +user$' "roles precedence: other roles stay user"
jp="$(HOME="$H" bash "$S" json --project "$P")"
has "$jp" '"key":"roles.worker.model","value":"","source":"project"' "roles json: project wins whole object (model empty)"
has "$jp" '"key":"roles.worker.timeout","value":1800,"source":"project"' "roles json: project timeout default, not user's 600"
has "$j" '"key":"roles.worker.tool","value":"codex","source":"user"' "roles json: user view unchanged"
grep -q '"worker":{"tool":"gemini"}' "$PS/config.json" && ok "roles project file written" || bad "project roles: $(cat "$PS/config.json")"
run set roles.worker.model=gemini-2.5-pro --project >/dev/null
grep -q '"worker":{"tool":"gemini","model":"gemini-2.5-pro"}' "$PS/config.json" && ok "roles set merges into the same scope's object" || bad "scope merge: $(cat "$PS/config.json")"
# other members and unknown role keys survive
cfg_raw "$CFG" '{"desk":{"days":3},"roles":{"worker":{"tool":"codex","note":"x"},"zed":{"tool":"agy"}}}'
run set roles.worker.model=m1 roles.new-one.tool=copilot >/dev/null
grep -q '"desk":{"days":3}' "$CFG" && grep -q '"worker":{"tool":"codex","model":"m1","note":"x"}' "$CFG" && grep -q '"zed":{"tool":"agy"}' "$CFG" && grep -q '"new-one":{"tool":"copilot"}' "$CFG" \
  && ok "roles write keeps other members, unknown keys and roles" || bad "roles write damaged config: $(cat "$CFG")"
has "$(run json)" '"key":"roles.zed.tool","value":"agy"' "roles json: unknown-to-set free role listed"
# empty tool removes the role at that scope
out="$(run set roles.worker.tool=)"
grep -q '"worker"' "$CFG" && bad "tool= left the role" || ok "roles.<r>.tool= removes the role object"
grep -q '"zed":{"tool":"agy"}' "$CFG" && ok "removal keeps other roles" || bad "removal damaged: $(cat "$CFG")"
has "$out" '^ +worker +gemini gemini-2.5-pro +project$' "roles show: user role removed, project role remains"
run set roles.zed.tool= roles.new-one.tool= >/dev/null
grep -q '"roles"' "$CFG" && bad "empty roles member kept" || ok "last role removed drops the roles member"
# validation (one line, exit 2, nothing written)
cfg_raw "$CFG" '{"roles":{"worker":{"tool":"codex"}}}'; before="$(cat "$CFG")"
chk "roles bad tool" "roles.worker.tool must be one of" roles.worker.tool=cursor
chk "roles bad name" "invalid role name 'Bad'" roles.Bad.tool=codex
chk "roles name too long" "invalid role name" "roles.a$(printf 'b%.0s' $(seq 24)).tool=codex"
chk "roles unknown field" "unknown key 'roles.worker.mode'" roles.worker.mode=x
chk "roles bad model" "roles.worker.model: invalid model id" 'roles.worker.model=-bad'
chk "roles model with space" "roles.worker.model: invalid model id" 'roles.worker.model=a b'
chk "roles args too long" "roles.worker.args: at most 300" "roles.worker.args=$(printf 'a%.0s' $(seq 301))"
chk "roles args quote" "roles.worker.args: quotes and backslashes" 'roles.worker.args=--a "b"'
chk "roles args single quote" "roles.worker.args: quotes and backslashes" "roles.worker.args=--a 'b'"
chk "roles args backslash" "roles.worker.args: quotes and backslashes" 'roles.worker.args=--a\b'
chk "roles args control" "control characters" "roles.worker.args=--a$(printf '\t')b"
for tok in --dangerously-skip-permissions --permission-mode=bypassPermissions --yolo --sandbox=danger-full-access -y --auto --allow-all --allow-all-paths --no-sandbox; do
  chk "roles args deny $tok" "roles.worker.args: '$tok' is not allowed" "roles.worker.args=--ok $tok"
done
chk "roles args deny among tokens" "is not allowed" 'roles.worker.args=-s workspace-write --yolo'
chk "roles timeout low" "roles.worker.timeout must be 60-86400" roles.worker.timeout=59
chk "roles timeout high" "roles.worker.timeout must be 60-86400" roles.worker.timeout=86401
chk "roles timeout text" "roles.worker.timeout must be 60-86400" roles.worker.timeout=abc
chk "roles model without tool" "set roles.nobody.tool first" roles.nobody.model=x
chk "roles timeout without tool" "set roles.nobody.tool first" roles.nobody.timeout=100
chk "roles cmd with non-custom tool" "only works with tool custom" 'roles.worker.cmd=x {prompt_file}'
chk "roles custom without cmd" "roles.c.cmd is required with tool custom" roles.c.tool=custom
chk "roles cmd without placeholder" "roles.c.cmd must contain {prompt_file}" roles.c.tool=custom 'roles.c.cmd=mytool --in x'
chk "roles cmd too long" "roles.c.cmd: at most 500" roles.c.tool=custom "roles.c.cmd={prompt_file}$(printf 'a%.0s' $(seq 500))"
chk "roles remove with other keys" "cannot set other keys while removing" roles.worker.tool= roles.worker.model=x
chk "roles invalid does not write valid pair" "roles.worker.tool must be one of" roles.zz.tool=codex roles.worker.tool=nope
# tool change away from custom drops the cmd; custom role keeps its cmd on a model change
run set roles.c.tool=custom 'roles.c.cmd=run {prompt_file}' >/dev/null
run set roles.c.model=m2 >/dev/null
grep -q '"c":{"tool":"custom","model":"m2","cmd":"run {prompt_file}"}' "$CFG" && ok "custom role keeps cmd on model change" || bad "custom keep: $(cat "$CFG")"
run set roles.c.tool=codex >/dev/null
grep -q '"c":{"tool":"codex","model":"m2"}' "$CFG" && ok "tool change away from custom drops cmd" || bad "custom drop: $(cat "$CFG")"
# corrupt file refused for roles keys
cfg_raw "$CFG" '{"roles": {"worker": {"tool": "x"}, oops'; b4="$(cat "$CFG")"
err="$(run set roles.worker.tool=codex 2>&1 >/dev/null)"; rc=$?
[ $rc -eq 2 ] && [ "$(cat "$CFG")" = "$b4" ] && ok "broken file: roles write refused, file unchanged" || bad "broken roles file: exit $rc"
# mid-way rejection rolls the roles write back (guard stub rejects branches)
STUB="$(mktemp -d)"; cp "$HERE/../scripts/"*.sh "$STUB/"
cat > "$STUB/guard.sh" <<'STUBEOF'
#!/usr/bin/env bash
case "$2" in branches) echo "error: stub rejects $2"; exit 0 ;; esac
exec bash "$REAL_GUARD" "$@"
STUBEOF
REAL_GUARD="$HERE/../scripts/guard.sh"; export REAL_GUARD
cfg_raw "$CFG" '{"roles":{"worker":{"tool":"codex"}}}'; b4="$(cat "$CFG")"
HOME="$H" bash "$STUB/settings.sh" set roles.worker.model=x roles.verifier.tool=claude protect-branches=main "$P" >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && [ "$(cat "$CFG")" = "$b4" ] && ok "roles write rolled back on a later failure" || bad "roles rollback: exit $rc, $(cat "$CFG")"
rm -rf "${STUB:?}"
# show/help/reset
has "$(run help)" '^  roles\.<role>\.tool +claude\|codex\|gemini\|agy\|opencode\|copilot\|custom' "help: roles.<role>.tool"
for f in model args cmd timeout; do has "$(run help)" "^  roles\.<role>\.$f " "help: roles.<role>.$f"; done
has "$(run help)" 'set roles.worker.tool=codex roles.worker.model=gpt-5-codex --project' "help: roles example"
hasnt "$(run help)" '^  roles\.worker\.' "help: no per-role rows"
run set roles.worker.tool=codex >/dev/null; run set roles.worker.tool=gemini --project >/dev/null
run reset >/dev/null
grep -q '"roles"' "$CFG" 2>/dev/null && bad "reset kept roles" || ok "reset removes the roles member"
grep -q '"roles"' "$PS/config.json" && ok "reset (user) leaves the project roles" || bad "project roles lost"
run reset --project >/dev/null
grep -q '"roles"' "$PS/config.json" 2>/dev/null && bad "reset --project kept roles" || ok "reset --project removes the roles member"
rm -f "$CFG"; rm -rf "${SS:?}"/*

# ---- skill file ----
[ -f "$SK" ] && grep -q '^disable-model-invocation: true' "$SK" && ok "skill is user-only" || bad "skill frontmatter"
grep -q '\${[A-Za-z_]*:-' "$SK" && bad "skill uses \${VAR:-default}" || ok "skill avoids \${VAR:-default}"
grep -q '|| true' "$SK" && ok "injected command ends with || true" || bad "no || true"
grep -q 'help' "$SK" && ok "skill mentions help" || bad "skill does not mention help"
for d in task pr models notify guard statusline; do [ ! -e "$HERE/../skills/$d" ] && ok "skill $d removed" || bad "skill $d still present"; done
for d in desk status settings orchestrator; do [ -f "$HERE/../skills/$d/SKILL.md" ] && ok "skill $d present" || bad "skill $d missing"; done

echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
