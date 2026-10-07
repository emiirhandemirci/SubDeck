#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-verify-checks.sh   (temp git repositories only)
HERE="$(cd "$(dirname "$0")" && pwd)"
VC="$HERE/../scripts/verify-checks.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then ok "$3"; else bad "$3 (no match for: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; fi; }
hasnt() { if printf '%s\n' "$1" | grep -Eq -- "$2"; then bad "$3 (found: $2)"; printf '%s\n' "$1" | sed 's/^/     | /'; else ok "$3"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "${T:?}"' EXIT
unset CLAUDE_PROJECT_DIR
R="$T/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q; g symbolic-ref HEAD refs/heads/main
commit() { g add -A >/dev/null 2>&1; g commit -q -m "$1" >/dev/null 2>&1; g rev-parse HEAD; }
vc() { bash "$VC" --project "$R" "$@"; }

# ---- base: tests in several languages ----
mkdir -p "$R/tests" "$R/src" "$R/spec" "$R/pkg"
cat > "$R/tests/test-a.sh" <<'EOF'
ok "one"
ok "two"
assert x
check y
EOF
cat > "$R/tests/app.test.js" <<'EOF'
describe("x", () => {
  it("a", () => {});
  test("b", () => {});
  it ("c", () => {});
  submit(form);
});
EOF
printf 'def test_one():\n    pass\n\ndef helper():\n    pass\n' > "$R/tests/test_py.py"
printf 'package p\nfunc TestOne(t *testing.T) {}\nfunc helper() {}\n' > "$R/pkg/x_test.go"
printf '#[test]\nfn a() {}\n' > "$R/src/lib_tests.rs"
printf '@Test\nvoid a() {}\n' > "$R/spec/ASpec.java"
echo 'export const x = 1' > "$R/src/app.js"
BASE="$(commit base)"

# ---- usage errors: exit 2, one line on stderr ----
use() { local d="$1"; shift; err="$(bash "$VC" "$@" 2>&1 >/dev/null)"; rc=$?
  [ $rc -eq 2 ] && ok "usage: $d exits 2" || bad "usage: $d exit $rc"
  [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] && ok "usage: $d one stderr line" || bad "usage: $d stderr: $err"; }
use "missing --base" --project "$R"
use "unknown argument" --base "$BASE" --project "$R" --frob
use "unknown base" --base deadbeef0000 --project "$R"
use "unknown head" --base "$BASE" --head no-such-ref --project "$R"
use "not a git repository" --base "$BASE" --project "$T"
use "unreadable report" --base "$BASE" --project "$R" --report "$T/nope.txt"
use "option without value" --base

# ---- nothing changed: all pass ----
out="$(vc --base "$BASE")"; rc=$?
[ $rc -eq 0 ] && ok "no changes: exit 0" || bad "no changes: exit $rc"
has "$out" '^PASS empty-tests no test files added or changed$' "no changes: empty-tests"
has "$out" '^PASS test-count no test files touched$' "no changes: test-count"
has "$out" '^SKIP ran-cmd no claimed commands$' "no claims: ran-cmd skipped"
has "$out" '^SKIP tested-line no report given$' "no report: tested-line skipped"
has "$(printf '%s\n' "$out" | tail -1)" '^verify-checks: 0 failed$' "last line: summary"

# ---- a good change: a test added ----
echo 'ok "three"' >> "$R/tests/test-a.sh"
G1="$(commit good)"
out="$(vc --base "$BASE")"; rc=$?
[ $rc -eq 0 ] && ok "good change: exit 0" || bad "good change: exit $rc"
has "$out" '^PASS empty-tests 1 test file' "good change: empty-tests"
has "$out" '^PASS test-count 4 -> 5 ' "good change: count before/after"

# ---- empty and whitespace-only test files ----
: > "$R/tests/test-empty.sh"
printf '  \n\t\n' > "$R/spec/blank.spec.js"
: > "$R/tests/.gitkeep"
: > "$R/tests/__init__.py"
: > "$R/src/empty.js"
mkdir -p "$R/odd dir"; : > "$R/odd dir/my test.sh"
G2="$(commit empties)"
out="$(vc --base "$G1")"; rc=$?
[ $rc -eq 1 ] && ok "empty tests: exit 1" || bad "empty tests: exit $rc"
has "$out" '^FAIL empty-tests tests/test-empty.sh is empty' "empty test file fails"
has "$out" '^FAIL empty-tests spec/blank.spec.js is empty' "whitespace-only test file fails"
has "$out" '^FAIL empty-tests odd dir/my test.sh is empty' "path with spaces handled"
hasnt "$out" 'gitkeep|__init__|src/empty.js' "dotfiles, __init__.py and non-test files are not flagged"
has "$(printf '%s\n' "$out" | tail -1)" '^verify-checks: 3 failed$' "summary counts each failing file"
out="$(vc --base "$G1" --head "$G1")"
has "$out" '^PASS empty-tests' "--head selects the end of the range"
# committed content counts, not the work tree
echo 'ok "filled locally"' > "$R/tests/test-empty.sh"
has "$(vc --base "$G1" --head "$G2")" '^FAIL empty-tests tests/test-empty.sh' "work-tree edits do not hide an empty committed file"
g checkout -q -- tests/test-empty.sh

# ---- test-count drops ----
g rm -q "tests/test-empty.sh" "spec/blank.spec.js" "odd dir/my test.sh" >/dev/null
G3="$(commit cleanup)"
printf 'ok "one"\n' > "$R/tests/test-a.sh"
cat > "$R/tests/app.test.js" <<'EOF'
describe("x", () => {
  it("a", () => {});
  submit(form);
  // test removed
});
EOF
g rm -q "pkg/x_test.go"
G4="$(commit drop)"
out="$(vc --base "$G3")"; rc=$?
[ $rc -eq 1 ] && ok "dropped tests: exit 1" || bad "dropped tests: exit $rc"
has "$out" '^FAIL test-count test cases dropped: 9 -> 2 \(' "count before/after over touched and deleted files"
has "$out" 'tests/test-a.sh 5 -> 1' "per-file drop named"
has "$out" 'pkg/x_test.go 1 -> 0' "deleted test file counts as a drop"
hasnt "$out" 'app.test.js 4 ' "submit( is not counted as it("
# a rename that keeps the cases is not a drop; patterns of other languages are counted
g mv tests/test_py.py tests/test_renamed.py; G5="$(commit rename)"
has "$(vc --base "$G4")" '^PASS test-count 1 -> 1 ' "rename keeps the count"
printf '#[test]\nfn a() {}\n#[test]\nfn b() {}\n' > "$R/src/lib_tests.rs"
printf '@Test\nvoid a() {}\n@Test\nvoid b() {}\n' > "$R/spec/ASpec.java"
G6="$(commit more)"
has "$(vc --base "$G5")" '^PASS test-count 2 -> 4 ' "rust #[test] and java @Test counted"

# ---- transcripts ----
TR="$T/agent.jsonl"
cat > "$TR" <<'EOF'
{"type":"user","message":{"role":"user","content":"Task: t-3f9a do it"},"uuid":"u0"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"running"},{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"npm   test\n","description":"run tests"}}]},"uuid":"a1"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"12 passed","is_error":false}]},"uuid":"u1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Bash","input":{"description":"quoted","command":"bash -c \"make lint\" && echo & done"}}]},"uuid":"a2"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","content":"ok"}]},"uuid":"u2"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_03","name":"Bash","input":{"command":"./build/app --selftest"}}]},"uuid":"a3"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_04","name":"Read","input":{"file_path":"x","command":"cargo test"}}]},"uuid":"a4"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_04","content":"..."}]},"uuid":"u4"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_09","content":"the text \"tool_use\" and npm run e2e appear here"}]},"uuid":"u9"}
EOF
REP="$T/report.txt"
printf 'Done.\nTested: ran `npm test` -> 12 passed; ran `make lint` -> ok\nStop: done\n' > "$REP"
out="$(vc --base "$G6" --report "$REP" --transcript "$TR")"; rc=$?
[ $rc -eq 0 ] && ok "claimed commands found: exit 0" || bad "claimed commands: exit $rc"
has "$out" '^PASS ran-cmd 2 claimed command\(s\) found' "two backticked claims found (whitespace-normalised, JSON-escaped)"
has "$out" '^PASS tested-line ' "Tested: ran passes"
out="$(vc --base "$G6" --cmd 'npm test' --cmd './build/app --selftest' --cmd 'cargo test' --cmd 'npm run e2e' --transcript "$TR")"; rc=$?
[ $rc -eq 1 ] && ok "unrun claims: exit 1" || bad "unrun claims: exit $rc"
has "$out" '^FAIL ran-cmd not run in the transcript: \./build/app --selftest$' "tool_use without a tool_result fails"
has "$out" '^FAIL ran-cmd not run in the transcript: cargo test$' "a non-Bash tool does not count"
has "$out" '^FAIL ran-cmd not run in the transcript: npm run e2e$' "text inside a tool result does not count"
hasnt "$out" 'transcript: npm test$' "the run command is not flagged"
printf 'Tested: ran npm test -> 12 passed\n' > "$REP"
has "$(vc --base "$G6" --report "$REP" --transcript "$TR")" '^PASS ran-cmd 1 claimed' "claim without backticks: text between 'ran ' and ' -> '"
printf 'Tested: ran `pytest -q` -> 3 passed\r\nStop: done\r\n' > "$REP"
out="$(vc --base "$G6" --report "$REP" --transcript "$TR")"
has "$out" '^FAIL ran-cmd not run in the transcript: pytest -q$' "CRLF report: unrun claim fails"
has "$(vc --base "$G6" --report "$REP")" '^SKIP ran-cmd no transcript given$' "no transcript: skip"
printf '{"event":"exec","cmd":"pytest -q"}\n' > "$T/codex.jsonl"
has "$(vc --base "$G6" --report "$REP" --transcript "$T/codex.jsonl")" '^SKIP ran-cmd unknown transcript format$' "unknown transcript format: skip"
has "$(vc --base "$G6" --report "$REP" --transcript "$T/missing.jsonl")" '^SKIP ran-cmd transcript not readable' "missing transcript: skip"

# ---- tested-line ----
printf 'All done.\nStop: done\n' > "$REP"
out="$(vc --base "$G6" --report "$REP")"; rc=$?
[ $rc -eq 1 ] && ok "no Tested: line: exit 1" || bad "no Tested: line: exit $rc"
has "$out" '^FAIL tested-line the report has no Tested: line$' "no Tested: line fails"
printf '  Tested: not run (no device attached)\nStop: blocked\n' > "$REP"
out="$(vc --base "$G6" --report "$REP")"; rc=$?
[ $rc -eq 0 ] && ok "Tested: not run: exit 0 (warning only)" || bad "Tested: not run: exit $rc"
has "$out" '^WARN tested-line Tested: not run \(no device attached\)$' "Tested: not run warns"

# ---- json ----
printf 'Tested: ran `npm test` -> ok; ran `make deploy` -> ok\n' > "$REP"
j="$(vc --base "$G1" --report "$REP" --transcript "$TR" --json --head "$G2")"; rc=$?
[ $rc -eq 1 ] && ok "json: exit 1 on failures" || bad "json: exit $rc"
has "$j" '^\{"version":1,"checks":\[\{"id":"empty-tests","result":"FAIL","detail":"odd dir/my test.sh is empty' "json: shape and first check"
has "$j" '\{"id":"ran-cmd","result":"FAIL","detail":"not run in the transcript: make deploy"\}' "json: ran-cmd failure"
has "$j" '"failed":4\}$' "json: failed count"
hasnt "$j" 'verify-checks:' "json: no text summary"
if command -v node >/dev/null 2>&1; then
  node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8"));if(o.version!==1||o.failed!==o.checks.filter(c=>c.result==="FAIL").length||o.checks.some(c=>!c.id||!c.detail))process.exit(1)' <<< "$j" && ok "json parses; failed matches" || bad "json invalid"
fi

# ---- read-only ----
st="$(g status --porcelain)"; hb="$(g rev-parse HEAD)"
vc --base "$BASE" --report "$REP" --transcript "$TR" >/dev/null
[ "$(g status --porcelain)" = "$st" ] && [ "$(g rev-parse HEAD)" = "$hb" ] && ok "read-only: work tree and HEAD unchanged" || bad "verify-checks changed the repository"
# CLAUDE_PROJECT_DIR is the default project
out="$(CLAUDE_PROJECT_DIR="$R" bash "$VC" --base "$G5")"; has "$out" '^PASS test-count' "CLAUDE_PROJECT_DIR default"

# ---- negative controls: with a check's FAIL turned into PASS, the scenarios above no longer fail ----
MUT="$T/mut"; mkdir -p "$MUT"
for id in empty-tests test-count ran-cmd tested-line; do
  sed "s/add FAIL $id /add PASS $id /" "$VC" > "$MUT/vc-$id.sh"
done
printf 'Tested: ran `cargo test` -> ok\n' > "$REP"
mo() { bash "$MUT/vc-$1.sh" --project "$R" "${@:2}"; }
o="$(mo empty-tests --base "$G1" --head "$G2")"; hasnt "$o" '^FAIL empty-tests' "negative control: without the empty-tests rule the empty files pass"
o="$(mo test-count --base "$G3" --head "$G4")"; hasnt "$o" '^FAIL test-count' "negative control: without the test-count rule the drop passes"
o="$(mo ran-cmd --base "$G6" --report "$REP" --transcript "$TR")"; hasnt "$o" '^FAIL ran-cmd' "negative control: without the ran-cmd rule the unrun claim passes"
printf 'Stop: done\n' > "$REP"
o="$(mo tested-line --base "$G6" --report "$REP")"; hasnt "$o" '^FAIL tested-line' "negative control: without the tested-line rule a missing line passes"
for id in empty-tests test-count ran-cmd tested-line; do
  cmp -s "$VC" "$MUT/vc-$id.sh" && bad "negative control: mutation for $id changed nothing" || ok "negative control: mutation for $id applied"
done

echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
