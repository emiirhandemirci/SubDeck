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
check "$(printf '%s\n' "$BODY" | sed -n '2,12p' | cut -d: -f1 | tr '\n' ' ')" "id title status owner agent session transcript blocked-by writable created updated " "writer key order"
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
check "$(t list | cut -f1 | tr '\n' ' ')" "$C $B $A " "list sorted by updated desc"
check "$(t list | awk -F'\t' 'NF==6' | wc -l | tr -d ' ')" "3" "list rows have six TSV columns"
check "$(t ready | cut -f1 | tr '\n' ' ')" "$A " "ready: only the unblocked task"
t set "$A" status=review
check "$(t list --status review | cut -f1)" "$A" "list --status"
t list --status bogus 2>/dev/null; check "$?" "2" "list invalid status exit 2"
t set "$A" status=open
printf 'Verdict: Approved\n' | t append "$A" verification; t done "$A"
check "$(t ready | cut -f1 | tr '\n' ' ')" "$B " "ready: archived blocker counts as done"
JS="$(t list --json)"
check "$(printf '%s' "$JS" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j.version+" "+j.tasks.length+" "+j.dir.endsWith("/tasks")+" "+Object.keys(j.tasks[0]).join(","))')" "1 2 true id,title,status,owner,agent,session,transcript,blockedBy,writable,created,updated,archived,invalid,file" "list --json shape"
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
check "$(SUBDECK_TASKS_DIR="$FIX" t ready | cut -f1 | tr '\n' ' ')" "t-0a01 " "ready on fixtures"
check "$(SUBDECK_TASKS_DIR="$FIX" t list | cut -f1 | sort | tr '\n' ' ')" "t-0a01 t-0b02 t-0c03 t-0d04 t-0e05 t-1a1a " "live fixtures listed, archive and non-hex ignored"
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

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
