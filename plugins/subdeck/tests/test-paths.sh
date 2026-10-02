#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-paths.sh
# lib-paths.sh: per-project state key, same results as Desk (desk/test/fixtures/state-keys.tsv).
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$HERE/../scripts/lib-paths.sh"
FIX="$ROOT/desk/test/fixtures/state-keys.tsv"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# shellcheck source=/dev/null
. "$LIB"

# 1. shared fixture (the Desk test reads the same file)
N=0
while IFS=$'\t' read -r pl inp norm key; do
  case "$pl" in ""|\#*) continue ;; esac
  N=$((N+1))
  sd_project_key "$inp" "$pl"
  if [ "$SD_NORM" = "$norm" ] && [ "$SD_KEY" = "$key" ]; then ok "key $pl $inp"
  else bad "key $pl $inp (got '$SD_NORM' '$SD_KEY', want '$norm' '$key')"; fi
done < <(tr -d '\r' < "$FIX")
[ "$N" -ge 20 ] && ok "fixture has $N rows" || bad "fixture rows: $N"

# 2. Windows spellings of one project give one key
K=""; SAME=1
for p in 'E:\x' '/e/x' 'E:/x' 'e:\x\' 'E:\X\\' '/cygdrive/e/x'; do
  sd_project_key "$p" win
  [ -z "$K" ] && K="$SD_KEY"
  [ "$SD_KEY" = "$K" ] || SAME=0
done
check "$SAME" 1 "E:\\x, /e/x, E:/x, trailing slashes and case: one key on Windows"
sd_project_key '/Proj' posix; A="$SD_KEY"; sd_project_key '/proj' posix
[ "$A" != "$SD_KEY" ] && ok "posix keys are case-sensitive" || bad "posix case"

# 3. empty input, key shape
sd_project_key "" posix; check "$SD_KEY" "" "empty path: empty key"
sd_project_key "/a b/\$weird;name" posix
[[ $SD_KEY =~ ^[A-Za-z0-9._-]{1,32}-[0-9a-f]{8}$ ]] && ok "key is filesystem-safe ($SD_KEY)" || bad "key shape $SD_KEY"

# 4. root selection
( unset SUBDECK_STATE_DIR SUBDECK_HOME; HOME="$T/h"; sd_state_root; check "$SD_ROOT" "$T/h/.subdeck/projects" "root defaults to ~/.subdeck/projects" )
( unset SUBDECK_STATE_DIR; HOME="$T/h"; SUBDECK_HOME="$T/sh"; sd_state_root; check "$SD_ROOT" "$T/sh/.subdeck/projects" "SUBDECK_HOME moves the root" )
( SUBDECK_STATE_DIR="$T/st/"; SUBDECK_HOME="$T/sh"; sd_state_root; check "$SD_ROOT" "$T/st" "SUBDECK_STATE_DIR wins" )

# 5. sd_state_dir: new dir + legacy dir, nothing created
mkdir -p "$T/proj"
SUBDECK_STATE_DIR="$T/st" sd_state_dir "$T/proj/"
case "$SD_STATE" in "$T/st/proj-"????????) ok "state dir under the root ($SD_STATE)" ;; *) bad "state dir $SD_STATE" ;; esac
check "$SD_LEGACY" "$T/proj/.subdeck" "legacy dir is <project>/.subdeck"
[ ! -e "$SD_STATE" ] && [ ! -e "$SD_LEGACY" ] && ok "nothing created" || bad "sd_state_dir created a directory"

# 6. cross-check with Desk for a real directory (Windows: bash /x/.. path vs node's native path)
if command -v node >/dev/null 2>&1; then
  SUBDECK_STATE_DIR="$T/st" sd_state_dir "$T/proj"; BK="${SD_STATE##*/}"
  NP="$T/proj"; if command -v cygpath >/dev/null 2>&1; then NP="$(cygpath -w "$T/proj")"; fi
  JK="$(cd "$ROOT/desk" && node --input-type=module -e 'import("./lib/paths.mjs").then(m => console.log(m.stateKey(process.argv[1], process.platform)))' "$NP" 2>/dev/null)"
  check "$BK" "$JK" "bash and Desk agree on a real directory"
else
  ok "node absent: cross-check skipped"
fi

echo "---"; echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
