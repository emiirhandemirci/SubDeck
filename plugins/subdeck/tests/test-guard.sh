#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-guard.sh   (temp HOME and project only)
HERE="$(cd "$(dirname "$0")" && pwd)"
G="$HERE/../scripts/guard.sh"
LAUNCH="$HERE/../scripts/run-hook.cmd"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
# wall clock in ms: bash 5 EPOCHREALTIME (no process start), else node (macOS bash 3.2 has no date +%N)
nowms() { if [ -n "${EPOCHREALTIME:-}" ]; then local t="${EPOCHREALTIME/[.,]/}"; echo $(( 10#$t / 1000 )); else node -e "console.log(Date.now())"; fi; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
H="$(mktemp -d)"; P="$(mktemp -d)"; mkdir -p "$P/sub" "$P/build"
(cd "$P" && git init -q 2>/dev/null; git -C "$P" symbolic-ref HEAD refs/heads/main 2>/dev/null)
setbranch() { git -C "$P" symbolic-ref HEAD "refs/heads/$1"; }
unset SUBDECK_GUARD SUBDECK_STATE_DIR SUBDECK_HOME

esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; printf '%s' "$s"; }
bash_json() { printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":"%s","description":"d"},"tool_use_id":"t"}' "$(esc "${2:-$P}")" "${TOOL:-Bash}" "$(esc "$1")"; }
file_json() { printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s","content":"x"},"tool_use_id":"t"}' "$(esc "$P")" "$1" "$(esc "$2")"; }
decision() { # stdin payload -> deny|ask|allow ; also checks exit code 0 and valid shape
  local out rc
  out="$(HOME="$H" CLAUDE_PROJECT_DIR="$P" OS="${TEST_OS-$OS}" bash "$G")"; rc=$?
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
allow	git push -u origin feature
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
ask	git reset --soft HEAD~1
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

# ---- wrappers: options that take an argument are skipped with it ----
while IFS=$'\t' read -r want cmd; do
  [ -n "$want" ] || continue
  expect "$want" "$cmd"
done <<'TABLE'
deny	sudo -u root git push --force
deny	sudo -u root -g wheel git add -A
deny	sudo --user root git push -f
deny	sudo --user=root git push -f
deny	sudo -Eu root rm -rf /
deny	sudo -uroot git push --force
deny	sudo -- git push --force
deny	sudo -C 3 -h host -p pw git push -f
deny	doas -u root rm -rf /
deny	env -u FOO git push -f
deny	env -i PATH=/usr/bin git add .
deny	env - git push -f
deny	env -C /tmp git push --force
deny	nice -n 10 git push --force
deny	nice --adjustment 5 git push -f
deny	nice -10 rm -rf /
deny	time -f %e git push -f
deny	time -o /tmp/t.txt git push --force
deny	command -p git push --force
deny	timeout -s KILL 5 git push --force
deny	timeout -k 5 10 git push -f
deny	timeout --signal KILL 5 git push -f
deny	timeout --signal=KILL 5 git push -f
deny	stdbuf -o L git push -f
deny	xargs -I {} rm -rf ~
deny	exec -a name git push -f
deny	nohup git push --force
deny	sudo -u root nice -n 5 timeout -s TERM 9 git push -f
ask	sudo -u deploy git push
allow	sudo -u root git status
allow	sudo apt-get install -y jq
allow	sudo -u root rm -rf /tmp/cache
allow	env -u FOO ls
allow	nice -n 10 make
allow	timeout -s KILL 5 make test
allow	xargs -I {} rm -rf {}
TABLE

# ---- PowerShell tool: backtick escapes, backslash paths, Remove-Item/rd deletes of protected roots ----
while IFS=$'\t' read -r want cmd; do
  [ -n "$want" ] || continue
  TOOL=PowerShell expect "$want" "${cmd//@P@/$P}" "PowerShell: ${cmd//@P@/<P>}"
done <<'TABLE'
deny	Remove-Item -Recurse -Force ~
deny	Remove-Item -Recurse -Force $HOME
deny	Remove-Item -Recurse -Force $Home\*
deny	Remove-Item -Recurse -Force "$HOME\*"
deny	Remove-Item -Recurse -Force $env:USERPROFILE
deny	Remove-Item -LiteralPath "${env:USERPROFILE}" -Recurse -Force
deny	ri -r -fo ~\
deny	rm -r -Force @P@
deny	rm -Recurse -Force .
deny	Remove-Item -Recurse -Force ..
deny	Remove-Item -Recurse:$true -Force ~
deny	Remove-Item -Rec -Force build, ~
deny	del -Recurse C:\
deny	rmdir -Recurse -Force C:\*
deny	Remove-Item -Path C:\ -Recurse
deny	Remove-Item -Path:C:\ -Recurse
deny	Remove-Item -Recurse -Force \
deny	rm -rf ~
deny	rd /s /q ~
deny	cmd /c rd /s /q C:\
deny	cmd /c "rmdir /s /q C:\"
deny	cmd.exe /C del /s /q \
deny	Set-Location sub; Remove-Item -Recurse ..\..
deny	Remove-Item -Recurse -Force * -Include *
deny	git push --force
deny	git add -A
ask	echo $(git push)
allow	Remove-Item -Recurse -Force node_modules
allow	Remove-Item -Recurse -Force .\build
allow	Remove-Item -Recurse -Force @P@\build
allow	rm -r -fo dist, out
allow	Remove-Item ~\notes.txt
allow	Remove-Item -Force ~
allow	Remove-Item -Recurse -Force ~ -WhatIf
allow	Remove-Item -Recurse -Path . -Include *.log
allow	Remove-Item -Recurse -Filter *.tmp ~
allow	Remove-Item -Recurse -Force C:\Users\me\other\build
allow	rd /s /q build
allow	cmd /c rd /s /q build
allow	cmd /c dir C:\
allow	Get-ChildItem -Recurse | Remove-Item
allow	Write-Host "Use `git add -A` carefully"
allow	Write-Host "line1`nline2"; git status
allow	Write-Output "a`tb `$(git push)"
allow	Write-Host "Path: C:\Users\x\"; Get-ChildItem
allow	git commit -m "fix `"quoted`" thing" -- a.txt
allow	git log --oneline | Select-String push
allow	Get-Content .\README.md
TABLE
TOOL=PowerShell expect deny $'git push `\n  --force origin main' "PowerShell: backtick line continuation is joined"
TOOL=PowerShell expect deny $'git push `\r\n  --force origin main' "PowerShell: backtick CRLF continuation is joined"
expect ask 'echo `git push`' "Bash: backticks are still command substitution"
expect allow 'echo "\`git push -f\`"' "Bash: escaped backticks are literal"

# ---- messages: neutral wording, how to change the rule ----
msg() { bash_json "$1" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G"; }
out="$(msg 'git add -A')"
has "$out" 'git-add-all.*Stage explicit paths' "git-add-all reason is actionable"
printf '%s' "$out" | grep -q 'other agents' && bad "git-add-all reason mentions other agents" || ok "git-add-all reason is neutral"
has "$out" 'To change this rule: /subdeck:settings set git-add-all=ask\|off' "deny reason tells how to change the rule"
has "$(msg 'git push')" 'To change this rule: /subdeck:settings set push=ask\|off \(or protect-branches=' "push (branches mode) reason tells how to change the rule"
has "$(msg 'git reset --hard HEAD~1')" 'To change this rule: /subdeck:settings set history-rewrite=deny\|off' "ask reason tells how to change the rule"
out="$(msg 'git push')"
printf '%s' "$out" | grep -q 'explicit user approval' && bad "push reason uses old wording" || ok "push reason is neutral"
has "$(msg 'rm -rf ~')" 'rm-rf-danger.*Delete specific subdirectories' "rm-rf-danger reason is actionable"

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
UC="$H/.subdeck/config.json"
# project config: state dir outside the project (lib-paths.sh); LC = legacy <project>/.subdeck/config.json
PC="$(HOME="$H"; unset SUBDECK_STATE_DIR SUBDECK_HOME; . "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$P"; printf '%s' "$SD_STATE/config.json")"; LC="$P/.subdeck/config.json"
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
rm -f "$PC"
# legacy <project>/.subdeck/config.json is still read; the state-dir file wins; a cwd-only payload finds both
cfg "$UC" '{}'
cfg "$LC" '{"guard":{"rules":{"push":"deny"}}}'
expect deny 'git push' "legacy project config is read"
cwd_only() { printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$P" "$1" | HOME="$H" CLAUDE_PROJECT_DIR= bash "$G"; }
case "$(cwd_only 'git push')" in *'"deny"'*) ok "cwd-only payload reads the legacy config" ;; *) bad "cwd-only legacy" ;; esac
cfg "$PC" '{"guard":{"rules":{"push":"off"}}}'
expect allow 'git push' "state-dir project config wins over legacy"
[ -z "$(cwd_only 'git push')" ] && ok "cwd-only payload (no CLAUDE_PROJECT_DIR) finds the state-dir config" || bad "cwd-only state dir"
out="$(HOME="$H" bash "$G" cli show "$P")"
has "$out" '^legacy file: ' "show names the legacy file"
has "$out" '^push +off +project' "show: state-dir value wins"
rm -f "$PC" "$LC"; rmdir "$P/.subdeck" 2>/dev/null
cfg "$UC" 'this is { not json'
expect deny 'git add -A' "broken config file ignored, defaults apply"
rm -f "$UC"
got="$(bash_json 'git add -A' | SUBDECK_GUARD=0 HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
[ -z "$got" ] && ok "SUBDECK_GUARD=0 disables" || bad "SUBDECK_GUARD=0 still output"
got="$(bash_json 'git add -A' | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$LAUNCH" guard)"
printf '%s' "$got" | grep -q '"deny"' && ok "run-hook.cmd guard launcher" || bad "launcher got '$got'"

# ---- settings subcommands ----
run() { HOME="$H" bash "$G" cli "$@" "$P"; }
out="$(run)"; has "$out" '^push +branches +default' "show default push branches"
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

# ---- protected-paths (empty by default; configured per project) ----
expect allow 'echo x > CLAUDE.md' "protected-paths inactive without a list"
expect_file allow Write "$P/CLAUDE.md"
cfg "$PC" '{"guard":{"protectedPaths":["CLAUDE.md",".github/workflows/**","migrations/**","*.lock","docs\\SPEC.md","Src/Locked"]}}'
while IFS=$'\t' read -r want cmd; do
  [ -n "$want" ] || continue
  expect "$want" "${cmd//@P@/$P}"
done <<'TABLE'
ask	echo x > CLAUDE.md
ask	echo x >> CLAUDE.md
ask	echo x >CLAUDE.md
ask	> CLAUDE.md
ask	echo x 2> CLAUDE.md
ask	echo x > @P@/CLAUDE.md
ask	echo x > sub/CLAUDE.md
ask	cd sub && echo x > ../CLAUDE.md
ask	rm CLAUDE.md
ask	rm -f -- CLAUDE.md
ask	rm -rf .github
ask	rm -rf .github/workflows
ask	rm .github/workflows/ci.yml
ask	rm migrations/001_init.sql
ask	git rm migrations/001_init.sql
ask	git rm -r --cached migrations
ask	git -C sub rm ../CLAUDE.md
ask	git checkout -- CLAUDE.md
ask	git checkout HEAD -- migrations/002.sql
ask	git restore CLAUDE.md
ask	git mv CLAUDE.md OLD.md
ask	mv notes.txt CLAUDE.md
ask	mv CLAUDE.md notes.txt
ask	cp other.md CLAUDE.md
ask	sed -i 's/a/b/' CLAUDE.md
ask	sed -i.bak -e 's/a/b/' migrations/x.sql
ask	sed --in-place 's/a/b/' package.lock
ask	sed -ni 's/a/b/p' CLAUDE.md
ask	echo y | tee CLAUDE.md
ask	bash -c "echo x > CLAUDE.md"
ask	true && rm yarn.lock
ask	Remove-Item CLAUDE.md
ask	Remove-Item -Path migrations -Recurse
ask	dd if=/dev/zero of=CLAUDE.md
ask	truncate -s 0 CLAUDE.md
ask	rm docs/SPEC.md
allow	cat CLAUDE.md
allow	grep foo CLAUDE.md > out.txt
allow	echo x > notes.md
allow	echo x > /tmp/CLAUDE.md
allow	echo x 2>&1
allow	cp CLAUDE.md /tmp/copy.md
allow	cp CLAUDE.md copy.md
allow	sed 's/a/b/' CLAUDE.md
allow	sed -n 1p CLAUDE.md
allow	git checkout main
allow	git checkout -b feature
allow	git diff CLAUDE.md
allow	git status migrations
allow	git add CLAUDE.md
allow	echo "rm CLAUDE.md"
allow	rm other.txt
allow	rm -rf build/
allow	rm .github/dependabot.yml
allow	rm migrations_old/a.sql
allow	rm CLAUDE.md.bak
TABLE
expect_file ask   Write "$P/CLAUDE.md"
expect_file ask   Edit  "$P/sub/CLAUDE.md"
expect_file ask   MultiEdit "$P/.github/workflows/ci.yml"
expect_file ask   Write "$P/migrations/2024/001.sql"
expect_file ask   Write "$P/yarn.lock"
# case-insensitive matching applies on Windows only
TEST_OS=Windows_NT expect ask 'rm SUB/../claude.MD' "Windows: rm SUB/../claude.MD"
TEST_OS=Windows_NT expect ask 'rm src/locked/a.txt' "Windows: rm src/locked/a.txt"
TEST_OS=Windows_NT expect_file ask Write "$P/docs/spec.md"
TEST_OS=Windows_NT expect_file ask Write "$P/claude.md"
if [ "$OS" != Windows_NT ]; then
  TEST_OS= expect allow 'rm SUB/../claude.MD' "POSIX: protected-path match is case-sensitive"
  TEST_OS= expect_file allow Write "$P/claude.md"
fi
expect_file allow Write "$P/CLAUDE.md.bak"
expect_file allow Write "$P/.github/dependabot.yml"
expect_file allow Write "$P/src/migrations.js"
expect_file allow Write "/tmp/elsewhere/CLAUDE.md"
expect_file allow Write "$H/CLAUDE.md"
# mode, project list replaces user list, env, disabled
cfg "$PC" '{"guard":{"rules":{"protected-paths":"deny"},"protectedPaths":["CLAUDE.md"]}}'
expect deny 'rm CLAUDE.md' "protected-paths=deny"
cfg "$PC" '{"guard":{"rules":{"protected-paths":"off"},"protectedPaths":["CLAUDE.md"]}}'
expect allow 'rm CLAUDE.md' "protected-paths=off"
cfg "$UC" '{"guard":{"protectedPaths":["a.txt","b.txt"]}}'
cfg "$PC" '{"guard":{"protectedPaths":["b.txt"]}}'
expect allow 'rm a.txt' "project list replaces user list"
expect ask   'rm b.txt' "project list entry protected"
cfg "$PC" '{"guard":{"protectedPaths":[]}}'
expect allow 'rm b.txt' "empty project list wins over user list"
rm -f "$PC"
expect ask   'rm a.txt' "user list applies without project list"
cfg "$UC" '{"guard":{"enabled":false,"protectedPaths":["a.txt"]}}'
expect allow 'rm a.txt' "guard disabled skips protected paths"
cfg "$UC" "{\"guard\":{\"protectedPaths\":[\"a.txt\",\"big\u00e9.txt\"]}}"
expect ask   'rm a.txt' "unicode escape in list does not break parsing"
rm -f "$UC"
# Codex (apply_patch, ask becomes deny) and Copilot (lowercase tools, path key, top-level decision)
cfg "$PC" '{"guard":{"protectedPaths":["CLAUDE.md","migrations/**"]}}'
PATCH='*** Begin Patch\n*** Update File: CLAUDE.md\n@@\n-a\n+b\n*** End Patch'
codex_out="$(printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"%s"}}' "$P" "$PATCH" | SUBDECK_TOOL=codex HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$codex_out" '"permissionDecision":"deny".*Ask the user for approval first.*protected-paths' "codex apply_patch on protected file: deny asking the user"
PATCH='*** Begin Patch\n*** Add File: src/ok.js\n+x\n*** Delete File: migrations/001.sql\n*** End Patch'
codex_out="$(printf '{"cwd":"%s","tool_name":"apply_patch","tool_input":{"command":"%s"}}' "$P" "$PATCH" | SUBDECK_TOOL=codex HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$codex_out" 'protected-paths' "codex apply_patch delete of a protected file"
PATCH='*** Begin Patch\n*** Add File: src/ok.js\n+x\n*** End Patch'
codex_out="$(printf '{"cwd":"%s","tool_name":"apply_patch","tool_input":{"command":"%s"}}' "$P" "$PATCH" | SUBDECK_TOOL=codex HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
[ -z "$codex_out" ] && ok "codex apply_patch on an unprotected file is allowed" || bad "codex unprotected patch got: $codex_out"
cop_out="$(printf '{"cwd":"%s","tool_name":"edit","tool_input":{"path":"%s/CLAUDE.md","old_str":"a","new_str":"b"}}' "$P" "$P" | SUBDECK_TOOL=copilot HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$cop_out" '^\{"permissionDecision":"ask".*protected-paths' "copilot edit on protected file: top-level ask"
cop_out="$(printf '{"cwd":"%s","tool_name":"create","tool_input":{"path":"%s/migrations/9.sql","file_text":"x"}}' "$P" "$P" | SUBDECK_TOOL=copilot HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$cop_out" 'protected-paths' "copilot create in a protected directory"
cop_out="$(printf '{"cwd":"%s","tool_name":"bash","tool_input":{"command":"rm CLAUDE.md"}}' "$P" | SUBDECK_TOOL=copilot HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$cop_out" 'protected-paths' "copilot bash rm of a protected file"
cop_out="$(printf '{"cwd":"%s","tool_name":"edit","tool_input":{"path":"%s/src/a.js"}}' "$P" "$P" | SUBDECK_TOOL=copilot HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
[ -z "$cop_out" ] && ok "copilot edit of an unprotected file is allowed" || bad "copilot unprotected got: $cop_out"
rm -f "$PC"
# settings: protect / unprotect / show / preservation
out="$(run protect 'CLAUDE.md,migrations/**')"
has "$out" '^protectedPaths \(user\): CLAUDE.md,migrations/\*\*' "protect lists the globs in show"
grep -q '"protectedPaths":\["CLAUDE.md","migrations/\*\*"\]' "$H/.subdeck/config.json" && ok "protect writes the array" || bad "protect file: $(cat "$H/.subdeck/config.json")"
out="$(run protect 'CLAUDE.md,*.lock' --project)"
has "$out" '^protectedPaths \(project\): CLAUDE.md,\*.lock' "project list wins in show"
out="$(run set protected-paths=deny)"
grep -q '"protectedPaths"' "$H/.subdeck/config.json" && grep -q '"protected-paths":"deny"' "$H/.subdeck/config.json" && ok "set keeps protectedPaths" || bad "set lost list: $(cat "$H/.subdeck/config.json")"
out="$(run off)"; out="$(run on)"
grep -q '"protectedPaths":\["CLAUDE.md","migrations/\*\*"\]' "$H/.subdeck/config.json" && ok "on/off keep protectedPaths" || bad "on/off lost list"
out="$(run unprotect 'CLAUDE.md')"
grep -q '"protectedPaths":\["migrations/\*\*"\]' "$H/.subdeck/config.json" && ok "unprotect removes one entry" || bad "unprotect: $(cat "$H/.subdeck/config.json")"
out="$(run unprotect 'nothing-here')"; has "$out" "is not in" "unprotect of unknown glob notes it"
out="$(run protect 'migrations/**')"; [ "$(grep -o 'migrations' "$H/.subdeck/config.json" | wc -l)" -eq 1 ] && ok "protect does not duplicate" || bad "duplicate entry"
out="$(run protect 'bad"glob')"; has "$out" 'invalid glob' "quote in glob rejected"
out="$(run unprotect 'migrations/**')"
grep -q 'protectedPaths' "$H/.subdeck/config.json" && bad "empty list still written" || ok "removing the last entry drops the key"
cfg "$UC" "{\"modelPolicy\":{\"worker\":\"opus\"},\"guard\":{\"protectedPaths\":[\"x\u00e9.txt\"],\"rules\":{\"future-rule\":\"deny\"}}}"
out="$(run protect 'y.txt')"
grep -q '"protectedPaths":\["x\\u00e9.txt","y.txt"\]' "$UC" && grep -q '"future-rule":"deny"' "$UC" && grep -q '"modelPolicy":{"worker":"opus"}' "$UC" && ok "escaped entries and other keys survive" || bad "round trip damaged: $(cat "$UC")"
out="$(run reset)"; grep -q protectedPaths "$UC" && bad "reset kept list" || ok "reset drops protectedPaths"
rm -f "$UC" "$PC"
# ---- branch-aware push (mode "branches", the default) ----
rm -f "$UC" "$PC"; setbranch feature/x
git -C "$P" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init 2>/dev/null; git -C "$P" tag v1.0 2>/dev/null
expect allow 'git push'                         "branches: bare push on a feature branch"
expect allow 'git push origin feature/x'        "branches: push a feature branch"
expect allow 'git push -u origin HEAD'          "branches: HEAD resolves to the feature branch"
expect allow 'git push origin HEAD:feature/y'   "branches: refspec to a feature branch"
expect allow 'git push origin other:wip'        "branches: src:dst to a feature branch"
expect ask   'git push origin main'             "branches: protected main"
expect ask   'git push origin master'           "branches: protected master"
expect ask   'git push origin release/1.2'      "branches: release/* glob"
expect ask   'git push origin HEAD:main'        "branches: HEAD:main"
expect ask   'git push origin feature/x:refs/heads/main' "branches: explicit refs/heads/main"
expect ask   'git push origin :main'            "branches: delete protected branch"
expect ask   'git push --delete origin main'    "branches: --delete protected branch"
expect ask   'git push --tags'                  "branches: --tags"
expect ask   'git push origin v1.0'             "branches: existing tag by bare name"
expect ask   'git push origin refs/tags/v2'     "branches: refs/tags refspec"
expect ask   'git push origin tag v3'           "branches: push ... tag <name>"
expect ask   'git push --all origin'            "branches: --all"
expect ask   'git push --mirror'                "branches: --mirror"
expect deny  'git push -f origin feature/x'     "branches: force push stays deny"
expect allow 'git status && git push origin feature/x' "branches: chain with an allowed push"
expect ask   'git status && git push origin main' "branches: chain with a protected push"
expect ask   'bash -c "git push origin main"'   "branches: nested shell protected push"
expect allow 'git merge topic'                  "branches: merge on a feature branch"
expect allow 'git reset --soft HEAD~1'          "branches: reset on a feature branch"
setbranch main
expect ask   'git push'                         "branches: bare push on main"
expect ask   'git push -u origin HEAD'          "branches: HEAD resolves to main"
expect allow 'git push origin feature/x'        "branches: feature push while on main"
expect ask   'git merge topic'                  "branches: merge on main"
expect allow 'git merge --abort'                "branches: merge --abort on main"
expect ask   'git reset --soft HEAD~1'          "branches: reset --soft on main"
expect ask   'git reset --mixed HEAD~2'         "branches: reset --mixed on main"
expect ask   'git reset --hard origin/main'     "branches: reset --hard on main"
expect allow 'git reset HEAD src/a.js'          "branches: unstage a path on main"
expect allow 'git reset -- src/a.js'            "branches: reset -- path on main"
expect ask   'git rebase topic'                 "branches: rebase on main"
expect allow 'git rebase --abort'               "branches: rebase --abort on main"
expect ask   "git -C $P push"                   "branches: git -C repo push on main"
setbranch release/2.0
expect ask   'git push'                         "branches: bare push on release/2.0"
setbranch feature/x
expect allow "git -C $P push"                   "branches: git -C repo push on a feature branch"
# no repo / detached: the target is unknown -> ask
NR="$(mktemp -d)"
got="$(printf '{"session_id":"s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"git push"}}' "$NR" | HOME="$H" CLAUDE_PROJECT_DIR="$NR" bash "$G")"
has "$got" '"permissionDecision":"ask".*current branch could not be determined' "branches: unknown branch asks"
rmdir "$NR" 2>/dev/null
# reason text names the cause and the settings key
got="$(bash_json 'git push origin main' | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$got" 'pushing to the protected branch main.*set push=ask\|off' "branches: ask reason names the branch"
# modes ask / off / deny
cfg "$UC" '{"guard":{"rules":{"push":"ask"}}}'
expect ask   'git push origin feature/x'        "mode ask: every push asks"
expect allow 'git merge topic'                  "mode ask: merge is not covered"
cfg "$UC" '{"guard":{"rules":{"push":"off"}}}'
expect allow 'git push origin main'             "mode off: push allowed"
expect allow 'git push --tags'                  "mode off: tags allowed"
expect deny  'git push -f origin main'          "mode off: force push still denied"
cfg "$UC" '{"guard":{"rules":{"push":"branches"},"protectBranches":["prod","hotfix/*"]}}'
expect ask   'git push origin prod'             "custom protectBranches: prod"
expect ask   'git push origin hotfix/9'         "custom protectBranches: hotfix/*"
expect allow 'git push origin main'             "custom protectBranches replaces the default list"
cfg "$PC" '{"guard":{"protectBranches":["main"]}}'
expect ask   'git push origin main'             "project protectBranches wins"
expect allow 'git push origin prod'             "project list replaces the user list"
rm -f "$UC" "$PC"
# payload shapes of the other tools
cx="$(bash_json 'git push origin main' | SUBDECK_TOOL=codex HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$cx" '"permissionDecision":"deny".*Ask the user for approval first' "codex: protected push becomes ask-first deny"
cx="$(bash_json 'git push origin feature/x' | SUBDECK_TOOL=codex HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
[ -z "$cx" ] && ok "codex: feature push allowed" || bad "codex feature push got: $cx"
cp_out="$(printf '{"cwd":"%s","tool_name":"bash","tool_input":{"command":"git push origin main"}}' "$P" | SUBDECK_TOOL=copilot HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$cp_out" '^\{"permissionDecision":"ask".*protected branch main' "copilot: protected push asks (top-level decision)"
cp_out="$(printf '{"cwd":"%s","tool_name":"bash","tool_input":{"command":"git push origin feature/x"}}' "$P" | SUBDECK_TOOL=copilot HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
[ -z "$cp_out" ] && ok "copilot: feature push allowed" || bad "copilot feature push got: $cp_out"
cp_out="$(printf '{"cwd":"%s","tool_name":"powershell","tool_input":{"command":"git push origin main"}}' "$P" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$cp_out" '"permissionDecision":"ask"' "powershell tool name: protected push asks"
# CLI: push mode and protected branch list
out="$(run push off)"; has "$out" '^push +off +user' "cli push off"
out="$(run push branches)"; has "$out" '^push +branches +user' "cli push branches"
out="$(run push deny)"; has "$out" 'error: usage: push' "cli push rejects deny"
out="$(run push)";      has "$out" 'error: usage: push' "cli push needs a value"
out="$(run set push=branches)"; has "$out" '^push +branches +user' "set accepts push=branches"
out="$(run set history-rewrite=branches)"; has "$out" "invalid mode 'branches' for history-rewrite" "branches only valid for push"
out="$(run branches 'main, develop,release/*')"
has "$out" '^protectBranches \(user\): main,develop,release/\*' "cli branches replaces the list"
grep -q '"protectBranches":\["main","develop","release/\*"\]' "$H/.subdeck/config.json" && ok "branches writes the array" || bad "branches file: $(cat "$H/.subdeck/config.json")"
out="$(run set attribution=deny)"
grep -q '"protectBranches"' "$H/.subdeck/config.json" && ok "set keeps protectBranches" || bad "set lost protectBranches"
out="$(run protect 'a.txt')"
grep -q '"protectBranches"' "$H/.subdeck/config.json" && grep -q '"protectedPaths"' "$H/.subdeck/config.json" && ok "protect keeps protectBranches" || bad "protect lost branches"
out="$(run branches 'x"y')"; has "$out" 'invalid branch pattern' "cli branches rejects quotes"
out="$(run branches '')"; has "$out" 'error: usage: branches' "cli branches rejects an empty list"
out="$(run branches 'staging' --project)"; has "$out" '^protectBranches \(project\): staging' "cli branches --project"
out="$(run reset)"; grep -q protectBranches "$H/.subdeck/config.json" 2>/dev/null && bad "reset kept protectBranches" || ok "reset drops protectBranches"
rm -f "$UC" "$PC"
# ---- protected-resources (inactive until guard.protectPorts/Hosts/Procs has an entry) ----
rm -f "$UC" "$PC"
expect allow 'curl http://localhost:8080/health' "protected-resources inactive without lists"
RES_CFG='{"guard":{"protectPorts":["8080","9000"],"protectHosts":["staging.example","10.0.0.5"],"protectProcs":["redis","node"]}}'
cfg "$UC" "$RES_CFG"
# want <TAB> tool <TAB> command ; every ask row is also run against a guard without the rule (negative control below)
RES_TABLE="$(cat <<'TABLE'
ask	Bash	curl http://localhost:8080/health
ask	Bash	curl 'http://127.0.0.1:8080'
ask	Bash	curl "http://LOCALHOST:8080/x"
ask	Bash	wget http://0.0.0.0:9000
ask	Bash	curl http://[::1]:8080/
ask	Bash	curl "http://[::]:8080"
ask	Bash	curl localhost:"8080"/x
ask	Bash	curl localhost\:8080
ask	Bash	npm start -- --port 8080
ask	Bash	vite --port=8080
ask	Bash	PORT=8080 npm start
ask	Bash	env PORT=8080 node server.js
ask	Bash	export DEV_PORT=9000
ask	Bash	docker run -p 8080:80 img
ask	Bash	docker run -p 3000:8080 img
ask	Bash	docker run -p 8080 img
ask	Bash	docker run -p 127.0.0.1:8080:80 img
ask	Bash	lsof -i :8080
ask	Bash	lsof -i:9000
ask	Bash	lsof -iTCP:8080 -sTCP:LISTEN
ask	Bash	fuser 8080/tcp
ask	Bash	fuser -k 9000/tcp
ask	Bash	ssh deploy@staging.example
ask	Bash	curl https://staging.example:8443/api
ask	Bash	scp f.txt user@STAGING.example:/tmp/
ask	Bash	git clone git@staging.example:org/repo.git
ask	Bash	ping -c 1 staging.example.
ask	Bash	psql -h 10.0.0.5 -U app
ask	Bash	pkill redis
ask	Bash	pkill -9 redis
ask	Bash	pkill -HUP -x redis
ask	Bash	pkill -u redis node
ask	Bash	killall REDIS
ask	Bash	kill $(pgrep redis)
ask	Bash	kill -9 `pidof node`
ask	Bash	fuser -k /usr/local/bin/redis
ask	Bash	sudo -u root pkill redis
ask	Bash	timeout 5 killall node
ask	Bash	nohup env -u X pkill -f redis
ask	Bash	echo ok && pkill node
ask	Bash	make build; curl -s localhost:9000 | jq .
ask	Bash	bash -c "pkill redis"
ask	Bash	sh -c 'curl localhost:8080'
ask	Bash	eval "curl localhost:8080"
ask	Bash	x=$(curl -s localhost:8080)
ask	Bash	echo "$(lsof -i :8080)"
ask	PowerShell	Stop-Process -Name redis
ask	PowerShell	Stop-Process -Name:redis -Force
ask	PowerShell	Stop-Process -n mongo,redis
ask	PowerShell	spps -Name REDIS.exe
ask	PowerShell	kill -Name node
ask	PowerShell	taskkill /F /IM redis.exe
ask	PowerShell	taskkill /im node.exe /t
ask	PowerShell	cmd /c "taskkill /IM redis.exe /F"
ask	PowerShell	Invoke-WebRequest -Uri http://localhost:8080/health
ask	PowerShell	Invoke-RestMethod "https://staging.example/api"
ask	PowerShell	$env:PORT=8080; npm start
ask	PowerShell	Test-NetConnection -ComputerName staging.example -Port 443
allow	Bash	mkdir -p build
allow	Bash	mkdir -p 8080-logs
allow	Bash	ssh -p 2222 deploy@other.example
allow	Bash	ssh -p 22 host
allow	Bash	cp -p a b
allow	Bash	docker run -p 3000:80 img
allow	Bash	docker run -p 18080:80 img
allow	Bash	curl http://localhost:3000
allow	Bash	curl localhost:80801
allow	Bash	curl localhost:18080
allow	Bash	curl http://mylocalhost:8080
allow	Bash	curl http://staging.example.org/
allow	Bash	curl http://notstaging.example/
allow	Bash	ls staging.example.d/
allow	Bash	pkill redis-server
allow	Bash	kill 1234
allow	Bash	kill -9 4242
allow	Bash	pgrep -u redis python
allow	Bash	echo 8080
allow	Bash	grep -rn 8080 src
allow	Bash	SUPPORT=8080 make
allow	Bash	app --portal 8080
allow	Bash	python -m http.server 8000
allow	Bash	npm test
allow	PowerShell	Stop-Process -Id 4242
allow	PowerShell	Stop-Process -Name notepad
allow	PowerShell	taskkill /IM notepad.exe
allow	PowerShell	Get-ChildItem -Path C:\src
TABLE
)"
while IFS=$'\t' read -r want tool cmd; do
  [ -n "$want" ] || continue
  TOOL="$tool" expect "$want" "$cmd" "protected-resources ($tool): $cmd"
done <<< "$RES_TABLE"
# neutral message naming the resource and the list
out="$(msg 'curl localhost:8080')"
has "$out" 'SubDeck guard \(protected-resources\): this command uses port 8080, listed in guard.protectPorts; get the user.s approval first and leave it as you found it\.' "message names the port and the list"
has "$(msg 'ssh staging.example')" 'uses host staging.example, listed in guard.protectHosts' "message names the host"
has "$(msg 'pkill redis')" 'uses process redis, listed in guard.protectProcs' "message names the process"
has "$out" 'To change this rule: /subdeck:settings set protected-resources=deny\|off' "message tells how to change the rule"
printf '%s' "$out" | grep -Eqi 'other agents|forbidden|never' && bad "protected-resources message is not neutral" || ok "protected-resources message is neutral"
cx="$(bash_json 'pkill redis' | SUBDECK_TOOL=codex HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
has "$cx" '"permissionDecision":"deny".*Ask the user for approval first.*protected-resources' "codex: protected resource becomes ask-first deny"
expect deny 'git push -f && curl localhost:8080' "deny of another rule still wins over this ask"
# modes, precedence, robustness
cfg "$UC" '{"guard":{"rules":{"protected-resources":"deny"},"protectPorts":["8080"]}}'
expect deny  'curl localhost:8080' "protected-resources=deny"
cfg "$UC" '{"guard":{"rules":{"protected-resources":"off"},"protectPorts":["8080"]}}'
expect allow 'curl localhost:8080' "protected-resources=off"
cfg "$UC" '{"guard":{"protectPorts":["8080"],"protectProcs":["redis"]}}'
cfg "$PC" '{"guard":{"protectPorts":["9000"]}}'
expect allow 'curl localhost:8080' "project protectPorts replaces the user list"
expect ask   'curl localhost:9000' "project protectPorts applies"
expect ask   'pkill redis' "user protectProcs still applies (lists are replaced one by one)"
cfg "$PC" '{"guard":{"protectPorts":[]}}'
expect allow 'curl localhost:8080' "empty project list clears the user list"
rm -f "$PC"
cfg "$UC" '{"guard":{"protectPorts":[8080,"abc","70000","0",""],"protectHosts":["bad host","ok.example"],"protectProcs":["a/b","redis.EXE"]}}'
expect ask   'curl localhost:8080' "numeric JSON port accepted"
expect allow 'curl localhost:70000' "out-of-range port ignored"
expect ask   'curl https://ok.example' "valid host kept next to an invalid one"
expect ask   'pkill redis' "process .exe suffix ignored in config"
cfg "$UC" '{"guard":{"protectPorts":["8080"],'
expect allow 'curl localhost:8080' "broken config: fail open (no lists)"
cfg "$UC" "$RES_CFG"
got="$(bash_json 'pkill redis' | SUBDECK_GUARD=0 HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")"
[ -z "$got" ] && ok "SUBDECK_GUARD=0 disables protected-resources" || bad "SUBDECK_GUARD=0 output: $got"
cfg "$UC" "$(printf '%s' "$RES_CFG" | sed 's/{"guard":{/{"guard":{"enabled":false,/')"
expect allow 'pkill redis' "guard.enabled=false disables protected-resources"
# negative controls: the ask rows above come from this rule; without it (mode off, or a guard with the
# rule's two call sites removed) every one of them is allowed, so the table would fail
cfg "$UC" "$RES_CFG"
MUT="$(mktemp -d)"; cp "$HERE/../scripts/"*.sh "$MUT/"
grep -v 'if (PRON) pr_' "$G" > "$MUT/guard.sh"
[ "$(grep -c 'if (PRON) pr_' "$G")" -eq 2 ] && ok "negative control: mutant drops both call sites" || bad "negative control: call sites changed"
n_ask=0; n_mut=0; n_off=0
while IFS=$'\t' read -r want tool cmd; do
  [ "$want" = ask ] || continue
  n_ask=$((n_ask+1))
  pl="$(TOOL="$tool" bash_json "$cmd")"
  [ -z "$(printf '%s' "$pl" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$MUT/guard.sh")" ] && n_mut=$((n_mut+1))
done <<< "$RES_TABLE"
cfg "$UC" "$(printf '%s' "$RES_CFG" | sed 's/{"guard":{/{"guard":{"rules":{"protected-resources":"off"},/')"
while IFS=$'\t' read -r want tool cmd; do
  [ "$want" = ask ] || continue
  pl="$(TOOL="$tool" bash_json "$cmd")"
  [ -z "$(printf '%s' "$pl" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G")" ] && n_off=$((n_off+1))
done <<< "$RES_TABLE"
[ "$n_mut" -eq "$n_ask" ] && ok "negative control: all $n_ask ask rows allowed by the guard without the rule" || bad "negative control: only $n_mut of $n_ask allowed without the rule"
[ "$n_off" -eq "$n_ask" ] && ok "negative control: all $n_ask ask rows allowed with protected-resources=off" || bad "negative control: only $n_off of $n_ask allowed when off"
rm -rf "${MUT:?}"
# CLI: ports / hosts / procs
rm -f "$UC" "$PC"
cfg "$UC" '{"modelPolicy":{"worker":"opus"},"guard":{"rules":{"attribution":"deny","future-rule":"ask"},"protectedPaths":["CLAUDE.md"]}}'
out="$(run ports '8080, 09000,8080')"
has "$out" '^protectPorts \(user\): 8080,9000$' "cli ports: normalised, deduplicated"
grep -q '"protectPorts":\["8080","9000"\]' "$UC" && ok "cli ports writes an array of strings" || bad "ports file: $(cat "$UC")"
out="$(run hosts 'staging.example,10.0.0.5')"; has "$out" '^protectHosts \(user\): staging.example,10.0.0.5' "cli hosts"
out="$(run procs 'redis,node.exe')"; has "$out" '^protectProcs \(user\): redis,node' "cli procs"
grep -q '"protectedPaths":\["CLAUDE.md"\]' "$UC" && grep -q '"future-rule":"ask"' "$UC" && grep -q '"modelPolicy":{"worker":"opus"}' "$UC" && grep -q '"protectHosts"' "$UC" && grep -q '"protectProcs":\["redis","node.exe"\]' "$UC" \
  && ok "cli lists keep every other member" || bad "cli lists damaged config: $(cat "$UC")"
out="$(run set history-rewrite=deny)"; grep -q '"protectPorts":\["8080","9000"\]' "$UC" && ok "set keeps protectPorts" || bad "set lost protectPorts"
out="$(run protect 'a.txt')"; grep -q '"protectHosts":\["staging.example","10.0.0.5"\]' "$UC" && ok "protect keeps protectHosts" || bad "protect lost protectHosts"
b4="$(cat "$UC")"
out="$(run ports '8080,70000')"; has "$out" "error: invalid port '70000'" "cli ports rejects 70000"
out="$(run ports '0')"; has "$out" "error: invalid port '0'" "cli ports rejects 0"
out="$(run hosts 'a b')"; has "$out" "error: invalid host" "cli hosts rejects spaces"
out="$(run hosts 'x/y')"; [ "$(cat "$UC")" = "$b4" ] && ok "cli hosts: a path-like word is not a list" || bad "cli hosts wrote x/y"
out="$(run procs 'a;b')"; has "$out" "error: invalid process name" "cli procs rejects ;"
[ "$(cat "$UC")" = "$b4" ] && ok "rejected lists write nothing" || bad "rejected list changed the file"
out="$(run ports '')"; has "$out" '^protectPorts: \(none\)' "cli ports '' removes the list"
grep -q protectPorts "$UC" && bad "empty ports list still written" || ok "empty ports list drops the member"
out="$(run procs 'redis' --project)"; has "$out" '^protectProcs \(project\): redis$' "cli procs --project"
has "$out" '^protected-resources +ask +default' "show lists the rule"
if command -v node >/dev/null 2>&1; then
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(!Array.isArray(j.guard.protectHosts))process.exit(1)' "$UC" && ok "config with lists is valid JSON" || bad "invalid JSON: $(cat "$UC")"
fi
out="$(run reset)"; grep -q 'protectHosts' "$UC" && bad "reset kept protectHosts" || ok "reset drops the lists"
rm -f "$UC" "$PC"
# ---- timing (best of N runs; strict limits only with SUBDECK_PERF_STRICT=1, generous otherwise) ----
if [ "${SUBDECK_PERF_STRICT:-0}" = 1 ]; then LIM1=400; LIM2=1500; else LIM1=1500; LIM2=3000; fi
best_ms() { # runs payload -> minimum wall ms
  local n="$1" pl="$2" i s e m best=999999
  for i in $(seq "$n"); do
    s=$(nowms); printf '%s' "$pl" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$G" > /dev/null; e=$(nowms)
    m=$(( e - s )); [ "$m" -lt "$best" ] && best=$m
  done
  echo "$best"
}
PAY="$(bash_json 'git add src/a.js && git commit -m "feat: x" -- src/a.js && git push origin main')"
avg="$(best_ms 7 "$PAY")"
echo "info: best hook time ${avg} ms (Bash payload)"
[ "$avg" -lt "$LIM1" ] && ok "hook time under ${LIM1} ms (${avg} ms)" || bad "hook too slow: ${avg} ms"
cfg "$UC" "$RES_CFG"
RPAY="$(bash_json 'PORT=8080 npm start & sleep 2; curl -s http://localhost:3000/health | grep ok && pkill -f node-dev; ssh deploy@other.example uptime')"
ms="$(best_ms 7 "$RPAY")"; echo "info: best hook time ${ms} ms (protected-resources lists configured)"
[ "$ms" -lt "$LIM1" ] && ok "hook time with resource lists under ${LIM1} ms (${ms} ms)" || bad "hook with resource lists too slow: ${ms} ms"
rm -f "$UC"
BIG="$(head -c 300000 /dev/zero | tr '\0' 'a')"
BPAY="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/big.txt","content":"%s"}}' "$P" "$P" "$BIG")"
ms="$(best_ms 3 "$BPAY")"; echo "info: 300 KB Write payload best ${ms} ms"
[ "$ms" -lt "$LIM2" ] && ok "large Write payload fast enough (${ms} ms)" || bad "large payload slow: ${ms} ms"

rm -rf "$H" "$P"
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
