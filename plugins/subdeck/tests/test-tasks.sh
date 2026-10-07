#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-tasks.sh   (tasks.sh CLI: files, dir resolution, lock, fixtures)
HERE="$(cd "$(dirname "$0")" && pwd)"
TS="$HERE/../scripts/tasks.sh"
FIX="$HERE/fixtures/tasks"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2')" ;; esac; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export SUBDECK_STATE_DIR="$W/state" HOME="$W/home"; mkdir -p "$HOME"
unset SUBDECK_TASKS_DIR CLAUDE_PROJECT_DIR
P="$W/proj"; mkdir -p "$P"
t() { bash "$TS" --project "$P" "$@"; }
sdstate() { ( . "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$1"; printf '%s' "$SD_STATE" ); }
ST="$(sdstate "$P")"

# ---- dir resolution ----
check "$(t dir)" "$ST/tasks" "default dir is <state>/tasks"
[ -d "$ST/tasks" ] && bad "dir does not create the directory" || ok "dir does not create the directory"
mkdir -p "$ST"
mkdir -p "$HOME/.subdeck"; printf '{"tasks":{"dir":"user/rel"}}' > "$HOME/.subdeck/config.json"
check "$(t dir)" "$P/user/rel" "user config relative dir is under the project"
printf '{"tasks":{"dir":"docs\\\\tasks"}}' > "$ST/config.json"
check "$(t dir)" "$P/docs/tasks" "project config wins; backslashes become /"
printf '{"tasks":{"dir":"/abs/place"}}' > "$ST/config.json"
check "$(t dir)" "/abs/place" "absolute dir used as is"
mkdir -p "$P/.subdeck"; rm "$ST/config.json"; printf '{"tasks":{"dir":"legacy/t"}}' > "$P/.subdeck/config.json"
check "$(t dir)" "$P/legacy/t" "legacy project config is read"
printf '{"tasks":{"dir":""}}' > "$ST/config.json"
check "$(t dir)" "$P/legacy/t" "empty dir in the state config falls through"
rm -f "$ST/config.json" "$P/.subdeck/config.json" "$HOME/.subdeck/config.json"
check "$(SUBDECK_TASKS_DIR="$W/envdir/" t dir)" "$W/envdir" "env SUBDECK_TASKS_DIR wins (trailing slash dropped)"
check "$(t dir)" "$ST/tasks" "back to default"

# ---- new / show ----
ID="$(t new "Add retry" --owner worker-sonnet --writable "src/a.js, test/a.test.js" --task "Do the thing
## not a heading" --done-when "npm test passes")"
case "$ID" in t-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ok "new prints an id ($ID)" ;; *) bad "new prints an id ('$ID')" ;; esac
F="$ST/tasks/$ID.md"
[ -f "$F" ] && ok "file created in <state>/tasks" || bad "file created"
BODY="$(t show "$ID")"
has "$BODY" "status: open" "new status open"
has "$BODY" "writable: [src/a.js, test/a.test.js]" "writable list written"
has "$BODY" "    ## not a heading" "heading-like task line indented"
check "$(printf '%s\n' "$BODY" | grep -n '^## ' | cut -d: -f2 | tr '\n' '|')" "## Task|## Done when|## Report|## Verification|## Handoff|" "five sections in order"
check "$(printf '%s\n' "$BODY" | sed -n '2,18p' | cut -d: -f1 | tr '\n' ' ')" "id title status owner agent session transcript blocked-by writable role tool model branch worktree run created updated " "writer key order"
check "$(ls -a "$ST/tasks" | grep -c 'tmp')" "0" "no temp files left"

# ---- new validation (exit 2, nothing written) ----
BEFORE="$(ls "$ST/tasks" | wc -l)"
t new "" 2>/dev/null; check "$?" "2" "new with empty title exits 2"
t new "x" --writable "a[1]" 2>/dev/null; check "$?" "2" "new rejects [ in list items"
t new "x" --blocked-by "nope" 2>/dev/null; check "$?" "2" "new rejects non-id blocked-by"
t new "x" --bogus 2>/dev/null; check "$?" "2" "new rejects unknown option"
t new "x" --writable "a,ok
b" 2>/dev/null; check "$?" "2" "new rejects a newline in writable (no silent truncation)"
t new "x" --blocked-by "t-0a01
t-0b02" 2>/dev/null; check "$?" "2" "new rejects a newline in blocked-by"
check "$(ls "$ST/tasks" | wc -l)" "$BEFORE" "failed new wrote nothing"
LT="$(t new "$(printf 'tab\there\r\nnl %0300d' 0)")"
TT="$(t show "$LT" | sed -n 's/^title: //p')"
check "${#TT}" "200" "title cut to 200 chars"
case "$TT" in *$'\t'*|*$'\r'*) bad "title control chars replaced" ;; *) ok "title control chars replaced" ;; esac

# ---- set ----
t set "$ID" status=in-progress agent=a1 "title=New title" blocked-by=t-0a01,t-0b02; check "$?" "0" "set ok"
BODY="$(t show "$ID")"
has "$BODY" "title: New title" "set title"; has "$BODY" "blocked-by: [t-0a01, t-0b02]" "set blocked-by"; has "$BODY" "agent: a1" "set agent"
t set "$ID" status=done 2>/dev/null; check "$?" "2" "set status=done refused (exit 2)"
t set "$ID" status=bogus 2>/dev/null; check "$?" "2" "set invalid status exit 2"
t set "$ID" id=t-ffff 2>/dev/null; check "$?" "2" "set id refused"
t set "$ID" title=ok status=bogus 2>/dev/null
has "$(t show "$ID")" "title: New title" "all pairs validated first (nothing applied)"
t set "$ID" "owner=a
b" 2>/dev/null; check "$?" "2" "newline in scalar rejected"
t set t-aaaa title=x 2>/dev/null; check "$?" "1" "set unknown id exit 1"
t set "$ID" blocked-by= ; check "$(t show "$ID" | sed -n 's/^blocked-by: //p')" "[]" "empty list written as []"

# ---- unknown keys preserved ----
awk '{print} /^owner:/{print "prio: 2"}' "$F" > "$F.x" && mv "$F.x" "$F"
t set "$ID" owner=worker-opus
awk '/^---$/{n++} n==1' "$F" | grep -q '^prio: 2$' && ok "unknown key preserved on rewrite" || bad "unknown key preserved on rewrite"

# ---- append ----
printf 'line one\n## sneaky\nline three\n' | t append "$ID" report
printf 'plan b' | t append "$ID" handoff
BODY="$(t show "$ID")"
has "$BODY" "    ## sneaky" "append indents ## lines"
check "$(printf '%s\n' "$BODY" | grep -c '^### .* note$')" "2" "two note blocks"
check "$(printf '%s\n' "$BODY" | grep -n '^## ' | cut -d: -f2 | tr '\n' '|')" "## Task|## Done when|## Report|## Verification|## Handoff|" "sections intact after append"
printf 'x' | t append "$ID" nosuch 2>/dev/null; check "$?" "2" "append unknown section exit 2"
printf 'src/x.js\n' | t append "$ID" report --label "writable violation (worker codex)"; check "$?" "0" "append --label ok"
has "$(t show "$ID")" " writable violation (worker codex)
src/x.js" "append --label writes the block header"
printf 'x' | t append "$ID" report --label "bad
label" 2>/dev/null; check "$?" "2" "append --label rejects a newline"
printf 'x' | t append "$ID" report --label "## x" 2>/dev/null; check "$?" "2" "append --label rejects a heading"
printf 'x' | t append "$ID" report --labl x 2>/dev/null; check "$?" "2" "append unknown option exit 2"

# ---- run keys (0.8: role tool model branch worktree run) ----
t set "$ID" role=worker tool=codex model=gpt-5-codex branch=subdeck/$ID "worktree=$W/wt dir" run=$W/r.log; check "$?" "0" "set run keys"
RB="$(t show "$ID")"
has "$RB" "role: worker
tool: codex
model: gpt-5-codex
branch: subdeck/$ID
worktree: $W/wt dir
run: $W/r.log
created: " "run keys written in order before created"
check "$(t list --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));const x=j.tasks.find(t=>t.id===process.argv[1]);console.log([x.role,x.tool,x.model,x.branch,x.worktree,x.run].join("|"))' "$ID")" "worker|codex|gpt-5-codex|subdeck/$ID|$W/wt dir|$W/r.log" "list --json carries the run keys"
t set "$ID" "model=a
b" 2>/dev/null; check "$?" "2" "run key with a newline refused"
t set "$ID" tool= ; check "$(t show "$ID" | sed -n 's/^tool: *//p')" "" "run key cleared with an empty value"
printf 'x' | t append t-aaaa report 2>/dev/null; check "$?" "1" "append unknown id exit 1"
R="$(printf '%s\n' "$BODY" | awk '/^## Report$/{f=1;next} /^## /{f=0} f')"
has "$R" "line one" "report text in the Report section"
case "$R" in *"plan b"*) bad "handoff text stays out of Report" ;; *) ok "handoff text stays out of Report" ;; esac

# ---- done ----
t done "$ID" 2>/dev/null; check "$?" "3" "done refused without Verdict: Approved"
[ -f "$F" ] && ok "refused done leaves the file" || bad "refused done leaves the file"
printf 'Verdict: Needs fixes\n' | t append "$ID" verification
t done "$ID" 2>/dev/null; check "$?" "3" "done refused on Needs fixes"
printf 'Verdict: Approved\n' | t append "$ID" verification
t done "$ID"; check "$?" "0" "done with Approved"
[ -f "$ST/tasks/archive/$ID.md" ] && [ ! -f "$F" ] && ok "moved to archive/" || bad "moved to archive/"
has "$(t show "$ID")" "status: done" "show reads the archive"
check "$(t list | grep -c "^$ID")" "0" "archived task not in list"
check "$(t list --all | grep -c "^$ID")" "1" "archived task in list --all"
F2="$(t new "forced")"; t done "$F2" --force; check "$?" "0" "done --force"
[ -f "$ST/tasks/archive/$F2.md" ] && ok "forced task archived" || bad "forced task archived"

# ---- list / ready ----
rm -rf "$ST/tasks"
A="$(t new "first")"; sleep 1; B="$(t new "second" --blocked-by "$A")"; sleep 1; C="$(t new "third" --blocked-by t-ffff)"
check "$(t list --tsv | cut -f1 | tr '\n' ' ')" "$C $B $A " "list sorted by updated desc"
check "$(t list --tsv | awk -F'\t' 'NF==6' | wc -l | tr -d ' ')" "3" "list rows have six TSV columns"
check "$(t ready --tsv | cut -f1 | tr '\n' ' ')" "$A " "ready: only the unblocked task"
t set "$A" status=review
check "$(t list --tsv --status review | cut -f1)" "$A" "list --status"
t list --status bogus 2>/dev/null; check "$?" "2" "list invalid status exit 2"
t set "$A" status=open
printf 'Verdict: Approved\n' | t append "$A" verification; t done "$A"
check "$(t ready --tsv | cut -f1 | tr '\n' ' ')" "$B " "ready: archived blocker counts as done"
JS="$(t list --json)"
check "$(printf '%s' "$JS" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j.version+" "+j.tasks.length+" "+j.dir.endsWith("/tasks")+" "+Object.keys(j.tasks[0]).join(","))')" "1 2 true id,title,status,owner,agent,session,transcript,blockedBy,writable,role,tool,model,branch,worktree,run,created,updated,archived,invalid,auto,pack,grants,covers,verdict,file" "list --json shape"
check "$(t ready --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j.tasks.map(x=>x.id).join())')" "$B" "ready --json"
check "$(t list --all --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j.tasks.filter(x=>x.archived).length)')" "1" "list --all --json marks archived"
rm -rf "$W/empty"; check "$(SUBDECK_TASKS_DIR="$W/empty" t list --json)" "{\"version\":1,\"dir\":\"$W/empty\",\"tasks\":[]}" "empty dir -> empty tasks array"

# ---- fixtures ----
FJ="$(SUBDECK_TASKS_DIR="$FIX" t list --all --json)"
GOT="$(printf '%s' "$FJ" | node -e '
const j=JSON.parse(require("fs").readFileSync(0,"utf8"));
console.log(j.tasks.map(x=>[x.id,x.status,x.blockedBy.join(","),x.writable.join(","),x.archived,x.invalid].join("\t")).sort().join("\n"))')"
WANT="$(tail -n +2 "$FIX/expected.tsv" | sort)"
check "$GOT" "$WANT" "fixtures match expected.tsv (non-hex t-0g07 ignored, CRLF + bare lists + weird status)"
check "$(SUBDECK_TASKS_DIR="$FIX" t ready --tsv | cut -f1 | tr '\n' ' ')" "t-0a01 " "ready on fixtures"
check "$(SUBDECK_TASKS_DIR="$FIX" t list --tsv | cut -f1 | sort | tr '\n' ' ')" "t-0a01 t-0b02 t-0c03 t-0d04 t-0e05 t-1a1a t-2b2b t-3c3c t-4d4d t-4e4e " "live fixtures listed, archive and non-hex ignored"
t show t-0g07 2>/dev/null; check "$?" "1" "show of a non-id exits 1"
SUBDECK_TASKS_DIR="$FIX" t show t-0d04 | grep -q 'interrupted (rate_limit)' && ok "show prints a fixture verbatim" || bad "show prints a fixture verbatim"
# CRLF fixture is only read, never rewritten by a read command
check "$(cd "$FIX" && git status --porcelain -- . 2>/dev/null | wc -l | tr -d ' ')" "0" "reads leave the fixtures untouched"

# ---- rewriting a CRLF file normalises it ----
CD="$W/crlf"; mkdir -p "$CD"; cp "$FIX/t-1a1a.md" "$CD/"
SUBDECK_TASKS_DIR="$CD" t set t-1a1a owner=w
RW="$(cat "$CD/t-1a1a.md")"
case "$RW" in *$'\r'*) bad "rewrite drops CR" ;; *) ok "rewrite drops CR" ;; esac
has "$RW" "prio: 2" "unknown key kept through a CRLF rewrite"
has "$RW" "status: open" "weird status written back as open"
has "$RW" "blocked-by: [t-0a01, t-0b02]" "bare list normalised"

# ---- lock ----
LD="$W/lockdir"; mkdir -p "$LD/.lock"; printf '%s %s\n' "$$" "$(date +%s)" > "$LD/.lock/owner"
S0=$(date +%s)
SUBDECK_TASKS_DIR="$LD" t new "busy" 2>/dev/null; RC=$?
S1=$(date +%s)
check "$RC" "4" "busy lock exits 4"
[ $((S1 - S0)) -ge 4 ] && [ $((S1 - S0)) -le 9 ] && ok "waited about 5 s for the lock" || bad "waited about 5 s for the lock ($((S1 - S0)) s)"
printf '%s %s\n' 99999 "$(( $(date +%s) - 60 ))" > "$LD/.lock/owner"
LID="$(SUBDECK_TASKS_DIR="$LD" t new "after stale")"; check "$?" "0" "stale lock (60 s) is taken over"
[ -d "$LD/.lock" ] && bad "lock released after a write" || ok "lock released after a write"

# ---- concurrency ----
CC="$W/conc"; mkdir -p "$CC"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do ( SUBDECK_TASKS_DIR="$CC" t new "job $i" >> "$CC.out" ) & done
wait
check "$(sort -u "$CC.out" | wc -l | tr -d ' ')" "12" "12 parallel new: 12 distinct ids"
check "$(ls "$CC" | grep -c '^t-.*\.md$')" "12" "12 files"
check "$(ls -a "$CC" | grep -c 'tmp')" "0" "no temp files after parallel writes"

# ---- ids ----
check "$(cat "$CC.out" | grep -Ec '^t-[0-9a-f]{4,6}$')" "12" "ids are t- + 4..6 lower hex"

# ---- 0.8.1: terse output, link, verify, grant, pack, writable, show --section, done lists, metering ----
export SUBDECK_METER=0
D1="$W/d081"; export SUBDECK_TASKS_DIR="$D1"
mkauto() { awk '{ print } /^run: /{ print "auto: true" }' "$D1/$1.md" > "$D1/$1.tmp" && mv "$D1/$1.tmp" "$D1/$1.md"; }
A1="$(t new "Alpha task with a rather long title that goes on and on and on and on well past seventy chars" --writable src/a.js --pack w1)"
B1="$(t new "Beta" --owner worker-sonnet --writable src/b.js)"
C1="$(t new "Gamma")"
check "$(t list | grep -c "^$B1 open worker-sonnet Beta$")" "1" "terse list: id status owner title"
check "$(t list | grep "^$C1" )" "$C1 open - Gamma" "terse list: no owner is -"
check "$(t list | grep "^$A1" | cut -d' ' -f4- | wc -c | tr -d ' ')" "74" "terse list: title cut to 70 chars + ... + newline"
has "$(t list | grep "^$A1")" "..." "terse list: cut title ends with ..."
check "$(t list --tsv | awk -F'\t' 'NF==6' | wc -l | tr -d ' ')" "3" "list --tsv keeps six TSV columns"
check "$(t show $A1 | sed -n 's/^pack: //p')" "w1" "new --pack writes pack"
t new "x" --pack "Bad Name" >/dev/null 2>&1; check "$?" "2" "new --pack invalid exits 2"
t set $B1 pack=w2; check "$(t show $B1 | sed -n 's/^pack: //p')" "w2" "set pack="
t set $B1 pack= ; check "$(t show $B1 | grep -c '^pack:')" "0" "set pack= clears"
t set $B1 pack=BAD >/dev/null 2>&1; check "$?" "2" "set pack invalid exits 2"
# show --section
printf 'first\nsecond\n' | t append $A1 report
check "$(t show $A1 --section report | tail -n +2)" "first
second" "show --section report: body only (after the block header)"
check "$(t show $A1 --section done-when | wc -l | tr -d ' ')" "0" "show --section of an empty section prints nothing"
t show $A1 --section bogus >/dev/null 2>&1; check "$?" "2" "show --section bogus exits 2"
# grant
t grant $A1 docs/x.md,src/q.js --reason "needs the docs" ; check "$?" "0" "grant exits 0"
check "$(t show $A1 | sed -n 's/^grants: //p')" "[docs/x.md, src/q.js]" "grants written"
has "$(t show $A1 --section report)" "path: docs/x.md" "grant report block lists the path"
has "$(t show $A1 --section report)" "reason: needs the docs" "grant report block has the reason"
t grant $A1 docs/x.md --reason "again"; check "$(t show $A1 | sed -n 's/^grants: //p')" "[docs/x.md, src/q.js]" "grant dedups"
t grant $A1 ../etc --reason r >/dev/null 2>&1; check "$?" "2" "grant refuses .. segments"
t grant $A1 /abs --reason r >/dev/null 2>&1; check "$?" "2" "grant refuses absolute paths"
t grant $A1 a/../b --reason r >/dev/null 2>&1; check "$?" "2" "grant refuses an inner .. segment"
t grant $A1 ok.txt >/dev/null 2>&1; check "$?" "2" "grant needs --reason"
t grant $A1 ok.txt --reason "$(printf 'x%.0s' $(seq 1 201))" >/dev/null 2>&1; check "$?" "2" "grant reason max 200"
t grant t-ffff ok.txt --reason r >/dev/null 2>&1; check "$?" "1" "grant unknown task exits 1"
# writable
check "$(t writable $A1 | tr '\n' ' ')" "src/a.js docs/x.md src/q.js " "writable = writable + grants"
check "$(t writable $C1 | wc -l | tr -d ' ')" "0" "empty writable prints nothing"
t writable t-ffff >/dev/null 2>&1; check "$?" "1" "writable unknown task exits 1"
t set $A1 agent=ag-1 >/dev/null; check "$(t writable --agent ag-1 | tr '\n' ' ')" "src/a.js docs/x.md src/q.js " "writable --agent"
t writable --agent nobody >/dev/null 2>&1; check "$?" "1" "writable --agent without a task exits 1"
# verify
t verify $A1,$B1 --verdict Needs-fixes --by v-1 --fingerprint "abc+clean"; check "$?" "0" "verify exits 0"
check "$(t show $A1 --section verification | grep -c '^Verdict: Needs fixes')" "1" "verify writes Needs fixes"
check "$(t show $B1 | sed -n 's/^covers: //p')" "[$A1, $B1]" "covers = all ids of the call"
has "$(t show $B1 --section verification)" "Covers: $A1, $B1" "verify block has Covers"
has "$(t show $B1 --section verification)" "Fingerprint: abc+clean" "verify block has Fingerprint"
t done $A1,$B1 >/dev/null 2>&1; check "$?" "3" "done refused after Needs fixes"
check "$(t show $A1 | sed -n 's/^status: //p')" "open" "refused done moved nothing"
t verify --covers $A1,$B1 --verdict Approved --by v-1; check "$(t show $A1 --section verification | grep -c '^Fingerprint: -')" "1" "verify --covers without fingerprint writes -"
t verify $A1,t-ffff --verdict Approved --by v-1 >/dev/null 2>&1; check "$?" "1" "verify unknown id exits 1"
check "$(t show $A1 --section verification | grep -c '^Verdict:')" "2" "verify with an unknown id wrote nothing"
t verify $A1 --verdict Maybe --by v-1 >/dev/null 2>&1; check "$?" "2" "verify bad verdict exits 2"
t verify $A1 --verdict Approved --by v-1 --fingerprint "$(printf 'a\001b')" >/dev/null 2>&1; check "$?" "2" "verify fingerprint control char exits 2"
check "$(t list --all --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));const x=j.tasks.find(t=>t.id===process.argv[1]);console.log([x.verdict,x.pack,x.grants.join("+"),x.covers.length,x.auto].join("|"))' "$A1")" "Approved|w1|docs/x.md+src/q.js|2|false" "list --json carries verdict, pack, grants, covers, auto"
t done $A1,$B1; check "$?" "0" "done a,b with latest verdict Approved"
check "$(ls "$D1/archive" | wc -l | tr -d ' ')" "2" "both archived"
# link
AU="$(t new "auto one")"; t set $AU agent=zz9 status=in-progress >/dev/null
mkauto $AU
check "$(t show $AU | grep -c '^auto: true')" "1" "auto key kept through a rewrite"
t link $C1 zz9 --session s-1 --transcript /tmp/x.jsonl; check "$?" "0" "link exits 0"
check "$(t show $C1 | sed -n 's/^agent: //p')" "zz9" "link sets agent"
check "$(t show $C1 | sed -n 's/^session: //p')" "s-1" "link sets session"
check "$(t show $C1 | sed -n 's/^status: //p')" "open" "link leaves the status"
check "$(ls "$D1/archive" | grep -c "$AU")" "1" "link archives the auto task of that agent"
has "$(cat "$D1/archive/$AU.md")" "linked to $C1" "archived auto task has the link note"
t link $AU zz9 >/dev/null 2>&1; check "$?" "2" "link to an archived task exits 2"
t link $C1 "bad id" >/dev/null 2>&1; check "$?" "2" "link bad agent id exits 2"
# done: auto needs no verdict, multi-id is all-or-nothing
AU2="$(t new "auto two")"; mkauto $AU2
t done $AU2; check "$?" "0" "done on an auto task needs no verdict"
N1="$(t new n1)"; N2="$(t new n2)"; printf 'Verdict: Approved\n' | t append $N1 verification
t done $N1,$N2 >/dev/null 2>&1; check "$?" "3" "done a,b refused when one has no verdict"
check "$(t show $N1 | sed -n 's/^status: //p')" "open" "nothing moved on refusal"
t done $N1,$N2 --force; check "$?" "0" "done --force"
# pack
PF="$W/contract.md"; printf '# Contract\nintro\n## Goal\nBuild x\n## Rules\nbe nice\n## Other\nz\n' > "$PF"
mkdir -p "$P/src"; printf 'a\nb\nc\n' > "$P/src/f.js"; printf 'x\n' > "$P/src/g.js"
git -C "$P" init -q 2>/dev/null; git -C "$P" add src
TK1="$(t new "Pack task" --writable src/f.js)"
PK="$(t pack w9 --from "$PF" --section goal --section RULES --map src/f.js,src,missing.txt --tasks $TK1)"; check "$?" "0" "pack exits 0"
check "$PK" "$D1/packs/w9.md" "pack prints the absolute path"
has "$(cat "$PK")" "# Context pack: w9" "pack heading"
has "$(cat "$PK")" "### Goal" "pack: selected section, heading demoted"
hasnt_() { case "$1" in *"$2"*) bad "$3 (found '$2')" ;; *) ok "$3" ;; esac; }
hasnt_ "$(cat "$PK")" "Other" "pack: unselected section left out"
has "$(cat "$PK")" "src/f.js (3 lines)" "pack: file map line count"
has "$(cat "$PK")" "src/g.js (1 lines)" "pack: dir expanded via git ls-files"
has "$(cat "$PK")" "missing.txt (missing)" "pack: missing path"
check "$(grep -A1 '^## Decisions' "$PK" | tail -n 1)" "none" "pack: decisions none"
has "$(cat "$PK")" "- $TK1 Pack task (writable: src/f.js)" "pack: task line"
check "$(t show $TK1 | sed -n 's/^pack: //p')" "w9" "pack sets pack on --tasks"
t pack BAD --from "$PF" >/dev/null 2>&1; check "$?" "2" "pack invalid wave exits 2"
t pack w8 --from /nonexistent >/dev/null 2>&1; check "$?" "2" "pack unreadable --from exits 2"
t pack w8 --from "$PF" --tasks t-ffff >/dev/null 2>&1; check "$?" "1" "pack unknown task exits 1"
[ -e "$D1/packs/w8.md" ] && bad "failed pack wrote nothing" || ok "failed pack wrote nothing"
t pack w7 --from "$PF" >/dev/null; has "$(cat "$D1/packs/w7.md")" "## Other" "pack without --section: whole file"
head -c 80000 /dev/zero | tr '\0' 'x' > "$W/big.md"; t pack w6 --from "$W/big.md" >/dev/null
check "$(tail -n 1 "$D1/packs/w6.md")" "[pack truncated at 64 KB]" "pack truncated at 64 KB"
check "$(t list | grep -c 'packs')" "0" "packs/ is ignored by list"
unset SUBDECK_TASKS_DIR
# metering
unset SUBDECK_METER
rm -f "$ST/events.jsonl"
M1="$(t new "meter")" ; OUTB="$(t list)"
check "$(grep -c '"event":"tasks_cli"' "$ST/events.jsonl")" "2" "metering: one tasks_cli event per call"
BY="$(grep '"event":"tasks_cli"' "$ST/events.jsonl" | tail -n 1 | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')"
check "$BY" "$(printf '%s\n' "$OUTB" | wc -c | tr -d ' ')" "metering: bytes = bytes written"
has "$(grep '"event":"tasks_cli"' "$ST/events.jsonl" | tail -n 1)" '"cmd":"list"' "metering: cmd"
t show $M1 >/dev/null; has "$(grep '"event":"tasks_cli"' "$ST/events.jsonl" | tail -n 1)" '"ids":1' "metering: ids counted"
t show t-ffff >/dev/null 2>&1; has "$(grep '"event":"tasks_cli"' "$ST/events.jsonl" | tail -n 1)" '"exit":1' "metering: exit code"
SUBDECK_METER=0 t list >/dev/null; check "$(grep -c '"event":"tasks_cli"' "$ST/events.jsonl")" "4" "SUBDECK_METER=0 skips metering"
# ready quota warning
NOWZ="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"quota_recent","agent_id":"a","agent_type":"subdeck:worker-sonnet","transcript_path":"","session_id":"s","payload":{"agent_id":"a","agent_type":"subdeck:worker-sonnet","session_id":"s","task":null,"source":"hook","tool":"claude","reset":"3pm (UTC)","resetAt":null}}\n' "$NOWZ" > "$ST/events.jsonl"
check "$(SUBDECK_METER=0 t ready 2>&1 >/dev/null | head -n 1 | sed 's/hit [0-9:]*Z/hit HH:MMZ/')" "warning: quota limit hit HH:MMZ (subdeck:worker-sonnet); resets 3pm (UTC); check before launching agents" "ready: quota warning on stderr"
check "$(SUBDECK_METER=0 t ready 2>/dev/null | grep -c warning)" "0" "ready: warning not on stdout"
has "$(SUBDECK_METER=0 t ready --json 2>/dev/null)" '"quota":{"at":"'"$NOWZ"'","reset":"3pm (UTC)","resetAt":null}' "ready --json: quota member"
printf '{"ts":"2020-01-01T00:00:00Z","event":"quota_recent","agent_id":"a","agent_type":"","transcript_path":"","session_id":"s","payload":{"agent_id":"a","tool":"codex","reset":null,"resetAt":null}}\n' > "$ST/events.jsonl"
check "$(SUBDECK_METER=0 t ready 2>&1 >/dev/null | wc -l | tr -d ' ')" "0" "ready: an old quota event gives no warning"
has "$(SUBDECK_METER=0 t ready --json 2>/dev/null)" '"quota":null' "ready --json: quota null"
FUT="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"2020-01-01T00:00:00Z","event":"quota_recent","agent_id":"a","agent_type":"","transcript_path":"","session_id":"s","payload":{"agent_id":"a","tool":"codex","reset":null,"resetAt":"%s"}}\n' "$FUT" > "$ST/events.jsonl"
has "$(SUBDECK_METER=0 t ready 2>&1 >/dev/null)" "(codex); resets $FUT;" "ready: a resetAt in the future warns (tool shown without agent_type)"
rm -f "$ST/events.jsonl"
# fixtures: new files
check "$(SUBDECK_TASKS_DIR="$FIX" SUBDECK_METER=0 t list --all --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j.tasks.filter(x=>["t-3c3c","t-4d4d","t-4e4e"].includes(x.id)).map(x=>[x.id,x.auto,x.pack,x.grants.join("+"),x.covers.join("+"),x.verdict].join(",")).sort().join(" "))')" "t-3c3c,true,,,, t-4d4d,false,w1,docs/x.md,t-4d4d+t-4e4e,Approved t-4e4e,false,w1,,t-4d4d+t-4e4e,Needs fixes" "fixtures: v081 keys read"
check "$(cd "$FIX" && git status --porcelain -- . 2>/dev/null | wc -l | tr -d ' ')" "0" "reads leave the fixtures untouched (v081)"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
