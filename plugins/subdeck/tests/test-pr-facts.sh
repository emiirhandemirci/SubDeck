#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-pr-facts.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../skills/pr/pr-facts.sh"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok   $1"; }
bad()   { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has()   { if printf '%s' "$1" | grep -q -F -- "$2"; then ok "$3"; else bad "$3 (missing '$2')"; fi; }
hasnt() { if printf '%s' "$1" | grep -q -F -- "$2"; then bad "$3 (found '$2')"; else ok "$3"; fi; }

newrepo() {
  local d; d="$(mktemp -d)"
  ( cd "$d" && git init -q -b main . && git config user.email t@t && git config user.name t \
    && echo a > a.txt && git add a.txt && git commit -q -m "first" ) >/dev/null 2>&1
  echo "$d"
}

# 1. clean tree, no upstream
R="$(newrepo)"; OUT="$(bash "$SCRIPT" "$R"; echo "rc=$?")"
has "$OUT" "main" "clean: branch shown"
has "$OUT" "(clean)" "clean: status clean"
has "$OUT" "(none; showing all commits" "clean: no-upstream fallback"
has "$OUT" "first" "clean: commit listed"
has "$OUT" "(no attribution lines)" "clean: no attribution"
has "$OUT" "rc=0" "clean: exit 0"
rm -rf "$R"

# 2. dirty tree
R="$(newrepo)"; echo b > "$R/b.txt"; echo c >> "$R/a.txt"
OUT="$(bash "$SCRIPT" "$R"; echo "rc=$?")"
has "$OUT" "?? b.txt" "dirty: untracked shown"
has "$OUT" " M a.txt" "dirty: modified shown"
has "$OUT" "rc=0" "dirty: exit 0"
rm -rf "$R"

# 3. attribution
R="$(newrepo)"
( cd "$R" && echo x > x.txt && git add x.txt && git commit -q -m "feat: x" -m "Co-Authored-By: Someone <s@x>" )
OUT="$(bash "$SCRIPT" "$R"; echo "rc=$?")"
has "$OUT" "ATTRIBUTION FOUND" "attribution: flagged"
has "$OUT" "feat: x" "attribution: commit named"
hasnt "$OUT" "(no attribution lines)" "attribution: no clean message"
has "$OUT" "rc=0" "attribution: exit 0"
rm -rf "$R"

# 4. with upstream: only unpushed commits
R="$(newrepo)"; B="$(mktemp -d)"; git init -q --bare "$B" >/dev/null 2>&1
( cd "$R" && git remote add origin "$B" && git push -q -u origin main 2>/dev/null
  echo y > y.txt && git add y.txt && git commit -q -m "unpushed one" )
OUT="$(bash "$SCRIPT" "$R"; echo "rc=$?")"
has "$OUT" "origin/main" "upstream: shown"
has "$OUT" "unpushed one" "upstream: unpushed commit listed"
hasnt "$OUT" " first" "upstream: pushed commit not listed"
rm -rf "$R" "$B"

# 5. not a repo
D="$(mktemp -d)"; OUT="$(bash "$SCRIPT" "$D"; echo "rc=$?")"
has "$OUT" "not a git repository" "non-repo: message"
has "$OUT" "rc=0" "non-repo: exit 0"
rm -rf "$D"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
