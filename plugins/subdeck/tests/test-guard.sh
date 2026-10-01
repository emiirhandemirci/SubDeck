#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-guard.sh   (temp HOME and project only)
HERE="$(cd "$(dirname "$0")" && pwd)"
G="$HERE/../scripts/guard.sh"
LAUNCH="$HERE/../scripts/run-hook.cmd"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
H="$(mktemp -d)"; P="$(mktemp -d)"; mkdir -p "$P/sub" "$P/build"
unset SUBDECK_GUARD

esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; printf '%s' "$s"; }
bash_json() { printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"d"},"tool_use_id":"t"}' "$(esc "${2:-$P}")" "$(esc "$1")"; }
file_json() { printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s","content":"x"},"tool_use_id":"t"}' "$(esc "$P")" "$1" "$(esc "$2")"; }
decision() { # stdin payload -> deny|ask|allow ; also checks exit code 0 and valid shape
  local out rc
  out="$(HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"; rc=$?
  [ $rc -eq 0 ] || { echo "exit$rc"; return; }
  if [ -z "$out" ]; then echo allow; return; fi
  if ! printf '%s' "$out" | grep -Eq '^\{"hookSpecificOutput":\{"hookEventName":"PreToolUse","permissionDecision":"(deny|ask)","permissionDecisionReason":"[^"]*(\\"[^"]*)*"\}\}$'; then echo "badshape:$out"; return; fi
  printf '%s' "$out" | sed 's/.*"permissionDecision":"\([a-z]*\)".*/\1/'
}
expect() { # want command [label]
  local got; got="$(bash_json "$2" | decision)"
  if [ "$got" = "$1" ]; then ok "$1: ${3:-$2}"; else bad "${3:-$2} (got $got, want $1)"; fi
}
expect_file() { # want tool path
  local got; got="$(file_json "$2" "$3" | decision)"
  if [ "$got" = "$1" ]; then ok "$1: $2 $3"; else bad "$2 $3 (got $got, want $1)"; fi
}

# ---- table: want <TAB> command ; @P@ = project root ----
while IFS=$'\t' read -r want cmd; do
  [ -n "$want" ] || continue
  case "$want" in \#*) continue ;; esac
  expect "$want" "${cmd//@P@/$P}"
done <<'TABLE'
deny	git add -A
deny	git add --all
deny	git add .
deny	git add -- .
deny	git add -u
deny	git -C /some/dir add -A
deny	GIT_AUTHOR_NAME=x git add .
deny	cd sub && git add :/
allow	git add src/a.js
allow	git add src/a.js src/b.js && git commit -m "x" -- src/a.js src/b.js
allow	git add ./src/a.js
deny	git commit -am "msg"
deny	git commit -a -m msg
deny	git commit --all -m msg
allow	git commit -m "-a is fine" -- a.txt
allow	git commit -ma -- a.txt
deny	git push --force
deny	git push -f origin main
deny	git push --force-with-lease origin main
deny	git push origin +main
deny	git push -uf origin main
deny	/usr/bin/git push --force
ask	git push
ask	git push -u origin feature
ask	git status; git push origin main
ask	false || git push
ask	git fetch | git push
ask	bash -c "git push origin main"
deny	sh -c 'git push -f'
ask	echo "$(git push)"
ask	x=`git push`
ask	eval git push
allow	echo "git push --force"
allow	echo git push is disabled here
allow	git log --oneline | grep push
allow	git status # git push -f
ask	git reset --hard HEAD~1
allow	git reset --soft HEAD~1
ask	git rebase -i main
allow	git rebase --abort
ask	git filter-repo --path x
ask	git filter-branch --tree-filter true HEAD
ask	git clean -fdx
allow	git clean -n
deny	rm -rf /
deny	rm -rf ~
deny	rm -rf $HOME
deny	rm -rf "$HOME/"
deny	rm -rf ${HOME}/*
deny	rm -rf ..
deny	rm -rf /*
deny	rm -rf C:/
deny	rm -rf C:\
deny	rm -rf @P@
deny	rm -rf .
deny	rm -rf *
deny	cd sub && rm -rf ../..
deny	rm -fr -- /
deny	sudo rm -r /
deny	rm -r --no-preserve-root /x
deny	rm -rf "$CLAUDE_PROJECT_DIR"
allow	cd build && rm -rf *
allow	rm -rf node_modules
allow	rm -rf build/ dist
allow	rm -rf /tmp/some-cache-dir
allow	rm -rf @P@/build
allow	rm -f /
allow	rm -rf $SOME_UNKNOWN_VAR
allow	git status
allow	ls -la
TABLE

# multi-line commands, heredocs, env assignments
expect deny  $'echo hi\ngit add .' "newline-separated git add ."
expect allow $'cat <<EOF > notes.txt\ngit push --force\nrm -rf /\nEOF\necho done' "heredoc body is not a command"
expect ask   $'cat <<-EOF > n.txt\n\tgit push -f\n\tEOF\ngit push' "command after <<- heredoc is checked"
expect allow $'git commit -m "$(cat <<\'EOF\'\nfix \"quoted\" thing\ngit push --force\n\nCo-Authored-By: X <x@y>\nEOF\n)" -- a.txt' "commit with heredoc message (attribution off)"
expect deny  'git push -f && git push' "deny wins over ask"
expect allow 'git status 2>&1 > /dev/null' "redirections"

# file tools
expect_file ask   Write "$P/.env"
expect_file allow Write "$P/.env.example"
expect_file ask   Write "$P/.env.local"
expect_file ask   Edit  "$P/certs/server.pem"
expect_file ask   Write "$P/tls.key"
expect_file ask   Write "$H/.ssh/id_rsa"
expect_file ask   MultiEdit "$P/id_ed25519.pub"
expect_file ask   Write "$P/credentials-prod.json"
expect_file ask   Edit  'C:\proj\.env'
expect_file allow Write "$P/src/app.js"
expect_file allow Write "$P/environment.ts"
got="$(printf '{"tool_name":"Read","cwd":"%s","tool_input":{"file_path":"%s/.env"}}' "$P" "$P" | decision)"
[ "$got" = allow ] && ok "other tools are ignored" || bad "Read tool got $got"

# ---- robustness ----
for payload in '' 'not json' '{"tool_name":"Bash","tool_input":{"command":"git push"' '[1,2]' '{"tool_name":"Bash"}'; do
  got="$(printf '%s' "$payload" | decision)"
  [ "$got" = allow ] && ok "malformed/partial payload -> allow: '${payload:0:20}'" || bad "malformed payload '$payload' got $got"
done
got="$(printf '{\n  "tool_name": "Bash",\r\n  "cwd": "%s",\n  "tool_input": {\n    "command": "git push -f"\n  }\n}\n' "$P" | decision)"
[ "$got" = deny ] && ok "pretty-printed payload parsed" || bad "pretty payload got $got"
got="$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git \\u0070ush -f"}}' "$P" | decision)"
[ "$got" = deny ] && ok "unicode escapes decoded" || bad "unicode escape got $got"

# ---- config precedence, env disable ----
cfg() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
UC="$H/.subdeck/config.json"; PC="$P/.subdeck/config.json"
cfg "$UC" '{"guard":{"rules":{"push":"off"}}}'
expect allow 'git push' "user push=off"
cfg "$PC" '{"guard":{"rules":{"push":"deny"}}}'
expect deny 'git push' "project push=deny beats user off"
rm -f "$PC"
cfg "$UC" '{"modelPolicy":{"worker":"opus"},"guard":{"enabled":true,"rules":{"attribution":"deny"}}}'
expect deny  $'git commit -m "x\n\nCo-Authored-By: A <a@b>" -- f' "attribution=deny blocks Co-Authored-By"
expect deny  'git commit -m "Generated with a tool" -- f' "attribution=deny blocks Generated with"
expect allow 'git commit -m "plain" -- f' "attribution=deny allows clean message"
expect allow 'echo Co-Authored-By' "attribution only applies to git commit"
cfg "$UC" '{"guard":{"enabled":false}}'
expect allow 'git add -A' "user enabled=false"
cfg "$PC" '{"guard":{"enabled":true}}'
expect deny 'git add -A' "project enabled=true beats user false"
rm -f "$PC"; cfg "$UC" 'this is { not json'
expect deny 'git add -A' "broken config file ignored, defaults apply"
rm -f "$UC"
got="$(bash_json 'git add -A' | SUBDECK_GUARD=0 HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
[ -z "$got" ] && ok "SUBDECK_GUARD=0 disables" || bad "SUBDECK_GUARD=0 still output"
got="$(bash_json 'git add -A' | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$LAUNCH" guard)"
printf '%s' "$got" | grep -q '"deny"' && ok "run-hook.cmd guard launcher" || bad "launcher got '$got'"

# ---- settings subcommands ----
run() { HOME="$H" bash "$G" cli "$@" "$P"; }
out="$(run)"; has "$out" '^push +ask +default' "show default push ask"
has "$out" '^attribution +off +default' "show default attribution off"
cfg "$UC" '{"desk":{"days":30,"note":"a,b}"},"modelPolicy":{"worker":"opus"},"list":[1,2]}'
out="$(run set push=off attribution=DENY)"
has "$out" '^push +off +user' "set writes user push=off"
has "$out" '^attribution +deny +user' "set lowercases mode"
grep -q '"modelPolicy":{"worker":"opus"}' "$UC" && grep -q '"desk":{"days":30,"note":"a,b}"}' "$UC" && grep -q '"list":\[1,2\]' "$UC" \
  && ok "other members kept verbatim" || bad "other members lost: $(cat "$UC")"
if command -v node >/dev/null 2>&1; then
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(j.guard.rules.push!=="off"||j.modelPolicy.worker!=="opus")process.exit(1)' "$UC" \
    && ok "config JSON valid" || bad "config JSON invalid: $(cat "$UC")"
fi
out="$(run set history-rewrite=deny --project)"
has "$out" '^history-rewrite +deny +project' "set --project"
has "$out" '^push +off +user' "user value survives project set"
out="$(run off --project)"; has "$out" '^enabled: no \(project\)' "off --project"
grep -q '"rules":{"history-rewrite":"deny"}' "$PC" && ok "off keeps rules" || bad "off lost rules: $(cat "$PC")"
out="$(run on --project)"; has "$out" '^enabled: yes \(project\)' "on --project"
out="$(run set bogus=deny)"; has "$out" "error: unknown rule 'bogus'" "unknown rule rejected"
out="$(run set push=block)"; has "$out" "error: invalid mode 'block' for push" "invalid mode rejected"
out="$(run set)"; has "$out" 'error: set needs' "set without pairs"
out="$(run reset --project)"; [ ! -f "$PC" ] && ok "reset --project removes file with only guard" || bad "project file remains"
out="$(run reset)"; has "$out" 'other settings kept' "reset keeps other members"
grep -q guard "$UC" && bad "guard still in user file" || ok "guard removed from user file"
grep -q '"modelPolicy":{"worker":"opus"}' "$UC" && ok "modelPolicy survives reset" || bad "modelPolicy lost on reset"
cfg "$UC" '{"desk": {"days": 3}, oops'; b4="$(cat "$UC")"
out="$(run set push=off)"; has "$out" 'left untouched' "broken file not rewritten"
[ "$b4" = "$(cat "$UC")" ] && ok "broken file unchanged" || bad "broken file modified"
rm -f "$UC"
out="$(run frobnicate)"; has "$out" "warning: ignored argument 'frobnicate'" "unknown arg warned"


# ---- unknown rule ids survive rewrites ----
cfg "$UC" '{"notify":{"sound":false},"guard":{"enabled":true,"rules":{"future-rule":"deny","push":"off","odd":{"a":[1,2],"b":"x,y"}}},"modelPolicy":{"worker":"opus"}}'
out="$(run)"; has "$out" '^unknown \(ignored\): future-rule \(user\), odd \(user\)' "show lists unknown ids"
out="$(run set attribution=deny)"
grep -q '"future-rule":"deny"' "$UC" && grep -q '"odd":{"a":\[1,2\],"b":"x,y"}' "$UC" && ok "set keeps unknown ids verbatim" || bad "unknown ids lost on set: $(cat "$UC")"
grep -q '"push":"off"' "$UC" && grep -q '"attribution":"deny"' "$UC" && ok "set keeps known rules too" || bad "known rules wrong: $(cat "$UC")"
grep -q '"notify":{"sound":false}' "$UC" && grep -q '"modelPolicy":{"worker":"opus"}' "$UC" && ok "notify and modelPolicy survive set" || bad "other keys lost: $(cat "$UC")"
out="$(run off)"; grep -q '"future-rule":"deny"' "$UC" && grep -q '"enabled":false' "$UC" && ok "off keeps unknown ids" || bad "off lost unknown: $(cat "$UC")"
out="$(run on)"; grep -q '"future-rule":"deny"' "$UC" && grep -q '"enabled":true' "$UC" && ok "on keeps unknown ids" || bad "on lost unknown: $(cat "$UC")"
out="$(run set future-rule=ask)"; has "$out" "error: unknown rule 'future-rule'" "set of unknown id still rejected"
grep -q '"future-rule":"deny"' "$UC" && ok "rejected set leaves file intact" || bad "file changed by rejected set"
out="$(run reset)"; grep -q 'future-rule' "$UC" && bad "reset kept guard" || ok "reset drops the guard member"
grep -q '"notify":{"sound":false}' "$UC" && ok "notify survives reset" || bad "notify lost on reset"
# CRLF config with unknown id and other keys
printf '{\r\n  "modelPolicy": {"worker":"opus"},\r\n  "notify": {"sound":true},\r\n  "guard": {\r\n    "rules": {\r\n      "future-rule": "ask",\r\n      "push": "off"\r\n    }\r\n  }\r\n}\r\n' > "$UC"
for c in "set attribution=deny" "off" "on"; do
  out="$(run $c)"
  grep -q '"future-rule":"ask"' "$UC" && grep -q '"modelPolicy": *{"worker":"opus"}' "$UC" && grep -q '"notify": *{"sound":true}' "$UC" && grep -q '"push":"off"' "$UC" \
    && ok "CRLF config survives: $c" || bad "CRLF config damaged by $c: $(cat "$UC")"
done
if command -v node >/dev/null 2>&1; then
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(j.guard.rules["future-rule"]!=="ask")process.exit(1)' "$UC" \
    && ok "rewritten CRLF config is valid JSON" || bad "invalid JSON after CRLF rewrite"
fi
rm -f "$UC"
# ---- timing ----
PAY="$(bash_json 'git add src/a.js && git commit -m "feat: x" -- src/a.js && git push origin main')"
s=$(date +%s%N); for i in 1 2 3 4 5 6 7 8 9 10; do printf '%s' "$PAY" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G" > /dev/null; done; e=$(date +%s%N)
avg=$(( (e - s) / 10000000 ))
echo "info: average hook time ${avg} ms (Bash payload)"
[ "$avg" -lt 400 ] && ok "hook time under 400 ms (${avg} ms)" || bad "hook too slow: ${avg} ms"
BIG="$(head -c 300000 /dev/zero | tr '\0' 'a')"
BPAY="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/big.txt","content":"%s"}}' "$P" "$P" "$BIG")"
s=$(date +%s%N); printf '%s' "$BPAY" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G" > /dev/null; e=$(date +%s%N)
ms=$(( (e - s) / 1000000 )); echo "info: 300 KB Write payload ${ms} ms"
[ "$ms" -lt 1500 ] && ok "large Write payload fast enough (${ms} ms)" || bad "large payload slow: ${ms} ms"

rm -rf "$H" "$P"
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
