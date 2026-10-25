#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-exec-bit.sh
# hooks.json runs "${CLAUDE_PLUGIN_ROOT}/scripts/run-hook.cmd" through a shell, which needs the exec bit on macOS/Linux
# (a git checkout keeps only the mode recorded in the index, so it must be 100755 there).
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
cd "$HERE/../scripts" || exit 1
if ! git ls-files -s run-hook.cmd 2>/dev/null | grep -q .; then echo "skip: not a git checkout"; exit 0; fi
n=0
while read -r mode _ _ f; do
  case "$f" in *.sh|run-hook.cmd) ;; *) continue ;; esac
  n=$((n+1))
  if [ "$mode" = 100755 ]; then ok "$f is 100755"; else bad "$f is $mode in the index (want 100755)"; fi
done < <(git ls-files -s .)
[ "$n" -gt 0 ] && ok "checked $n scripts" || bad "no scripts found"
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" = 0 ]
