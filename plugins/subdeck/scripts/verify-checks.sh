#!/usr/bin/env bash
# SubDeck deterministic verify checks: facts a verifier can check without reading the code.
#
#   verify-checks.sh --base <commit> [--head <ref>] [--report <file>] [--cmd "<command>"]... [--transcript <jsonl>]
#                    [--json] [--project <dir>]
#
#   --base        commit the work started from (required); --head defaults to HEAD
#   --report      the worker's report text (its Tested: lines are checked and their commands claimed)
#   --cmd         a command the worker claims to have run (repeatable)
#   --transcript  the worker's Claude Code transcript (.jsonl) to look the claimed commands up in
#   --project     the git work tree (default $CLAUDE_PROJECT_DIR, else the current directory)
#
# Checks (one output line each, or one per failing file/command):
#   empty-tests  test files added or changed in base..head whose committed content is empty or whitespace
#                (test files: a test/ tests/ __tests__/ spec/ directory, or "test"/"spec" in the name;
#                dotfiles such as .gitkeep and __init__.py are not counted as empty tests)
#   test-count   test cases in the touched or deleted test files, counted at base and head
#                (lines with test( it( def test_ func Test @Test #[test] or a leading ok/check/chk/assert word);
#                FAIL when the total dropped
#   ran-cmd      each claimed command (--cmd; from --report: backticked spans after "ran" on Tested: lines,
#                else the text between "ran " and " -> ") must appear, whitespace-normalised, inside the
#                command of a Bash (or PowerShell) tool call in the transcript that has a tool result;
#                SKIP without a transcript, without claims, or for an unknown transcript format
#   tested-line  --report without a Tested: line FAILs; "Tested: not run" WARNs
# Output: "PASS|FAIL|WARN|SKIP <id> <detail>" lines, then "verify-checks: <n> failed".
#   --json: {"version":1,"checks":[{"id","result","detail"}],"failed":n}
# Exit: 0 no FAIL, 1 any FAIL, 2 usage error (one line on stderr).
# bash 3.2 + git + awk; no jq/node. Read-only: never changes the work tree or the index.

usage() { echo "verify-checks: $1 (usage: verify-checks.sh --base <commit> [--head <ref>] [--report <file>] [--cmd <command>]... [--transcript <jsonl>] [--json] [--project <dir>])" >&2; exit 2; }

BASE=""; HEAD_REF=HEAD; REPORT=""; TRANSCRIPT=""; JSON=0; PROJECT=""; CMDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base|--head|--report|--cmd|--transcript|--project)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case "$1" in
        --base) BASE="$2" ;; --head) HEAD_REF="$2" ;; --report) REPORT="$2" ;;
        --cmd) CMDS+=("$2") ;; --transcript) TRANSCRIPT="$2" ;; --project) PROJECT="$2" ;;
      esac
      shift 2 ;;
    --base=*) BASE="${1#*=}"; shift ;;
    --head=*) HEAD_REF="${1#*=}"; shift ;;
    --report=*) REPORT="${1#*=}"; shift ;;
    --cmd=*) CMDS+=("${1#*=}"); shift ;;
    --transcript=*) TRANSCRIPT="${1#*=}"; shift ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage "unknown argument '$1'" ;;
  esac
done
[ -n "$BASE" ] || usage "--base is required"
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
[ -d "$PROJECT" ] || usage "project directory not found: $PROJECT"
GIT() { git -C "$PROJECT" -c core.quotepath=off "$@"; }
GIT rev-parse --is-inside-work-tree >/dev/null 2>&1 || usage "not a git repository: $PROJECT"
B="$(GIT rev-parse -q --verify "$BASE^{commit}" 2>/dev/null)" || usage "unknown base commit '$BASE'"
HD="$(GIT rev-parse -q --verify "$HEAD_REF^{commit}" 2>/dev/null)" || usage "unknown head ref '$HEAD_REF'"
if [ -n "$REPORT" ] && [ ! -r "$REPORT" ]; then usage "report file not readable: $REPORT"; fi

RES=(); FAILED=0
add() { # result id detail
  RES+=("$1"$'\t'"$2"$'\t'"$3")
  [ "$1" = FAIL ] && FAILED=$((FAILED + 1))
}

# ---------- test files touched in base..head ----------
is_test() { # path -> 0 when it looks like a test file
  local p b
  p="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; b="${p##*/}"
  case "/$p" in */test/*|*/tests/*|*/__tests__/*|*/spec/*) return 0 ;; esac
  case "$b" in *test*|*spec*) return 0 ;; esac
  return 1
}
CHANGED=(); TOUCHED=()   # CHANGED: added/modified at head; TOUCHED: added/modified/deleted
while IFS= read -r -d '' st && IFS= read -r -d '' path; do
  is_test "$path" || continue
  case "$st" in
    A*|M*|T*) CHANGED+=("$path"); TOUCHED+=("$path") ;;
    D*) TOUCHED+=("$path") ;;
  esac
done < <(GIT diff -z --name-status --no-renames "$B" "$HD" -- 2>/dev/null)

# ---------- empty-tests ----------
n_empty=0
for path in ${CHANGED[@]+"${CHANGED[@]}"}; do
  b="${path##*/}"
  case "$b" in .*|__init__.py) continue ;; esac
  [ "$(GIT cat-file -t "$HD:$path" 2>/dev/null)" = blob ] || continue
  if [ "$(GIT cat-file blob "$HD:$path" 2>/dev/null | tr -d ' \t\r\n\f\v' | head -c 1 | wc -c | tr -d ' ')" = 0 ]; then
    add FAIL empty-tests "$path is empty or whitespace only at ${HEAD_REF}"; n_empty=$((n_empty + 1))
  fi
done
if [ $n_empty -eq 0 ]; then
  if [ ${#CHANGED[@]} -eq 0 ]; then add PASS empty-tests "no test files added or changed"
  else add PASS empty-tests "${#CHANGED[@]} test file(s) added or changed, none empty"; fi
fi

# ---------- test-count ----------
COUNT_AWK='
/(^|[^A-Za-z0-9_])(test|it)[ \t]*\(/ || /^[ \t]*def test_/ || /^[ \t]*func Test/ || /@Test/ || /#\[test\]/ || /^[ \t]*(ok|check|chk|assert)[ \t]/ { n++ }
END { print n + 0 }'
count_at() { # rev path -> number of test cases (0 when the file does not exist there)
  if [ "$(GIT cat-file -t "$1:$2" 2>/dev/null)" = blob ]; then GIT cat-file blob "$1:$2" 2>/dev/null | tr -d '\r' | awk "$COUNT_AWK"
  else echo 0; fi
}
before=0; after=0; drops=""
for path in ${TOUCHED[@]+"${TOUCHED[@]}"}; do
  cb="$(count_at "$B" "$path")"; ca="$(count_at "$HD" "$path")"
  before=$((before + cb)); after=$((after + ca))
  [ "$ca" -lt "$cb" ] && drops="$drops${drops:+, }$path $cb -> $ca"
done
if [ ${#TOUCHED[@]} -eq 0 ]; then add PASS test-count "no test files touched"
elif [ $after -lt $before ]; then add FAIL test-count "test cases dropped: $before -> $after ($drops)"
else add PASS test-count "$before -> $after test cases in ${#TOUCHED[@]} touched test file(s)"; fi

# ---------- claims from the report ----------
TESTED_LINES=""
if [ -n "$REPORT" ]; then
  TESTED_LINES="$(tr -d '\r' < "$REPORT" | grep -E '^[[:space:]]*Tested:' )"
fi
CLAIM_AWK='
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function piece(s,  a, out, i, j) {
  a = index(s, " -> ")
  if (a > 0) s = substr(s, 1, a - 1)
  if (index(s, "`") > 0) {
    out = 0
    while ((i = index(s, "`")) > 0) {
      s = substr(s, i + 1); j = index(s, "`"); if (j == 0) break
      if (trim(substr(s, 1, j - 1)) != "") { print trim(substr(s, 1, j - 1)); out = 1 }
      s = substr(s, j + 1)
    }
    return
  }
  if (a > 0 && trim(s) != "") print trim(s)
}
{
  s = $0; sub(/^[ \t]*Tested:[ \t]*/, "", s)
  if (!match(s, /^ran[ \t]+/)) next
  s = substr(s, RLENGTH + 1)
  while (1) {
    if (match(s, /[;,][ \t]*(and[ \t]+)?ran[ \t]+/)) { piece(substr(s, 1, RSTART - 1)); s = substr(s, RSTART + RLENGTH) }
    else { piece(s); break }
  }
}'
CLAIMS=""
for c in ${CMDS[@]+"${CMDS[@]}"}; do CLAIMS="$CLAIMS$c"$'\n'; done
if [ -n "$TESTED_LINES" ]; then CLAIMS="$CLAIMS$(printf '%s\n' "$TESTED_LINES" | awk "$CLAIM_AWK")"$'\n'; fi

# ---------- ran-cmd ----------
SCAN_AWK='
function jdec(s,  out, i, c, h) {
  if (index(s, "\\") == 0) return s
  out = ""
  while ((i = index(s, "\\")) > 0) {
    out = out substr(s, 1, i - 1); c = substr(s, i + 1, 1)
    if (c == "u") { h = tolower(substr(s, i + 2, 4)); out = out ((h == "000a") ? "\n" : (h == "0009") ? "\t" : (h == "0022") ? "\"" : (h == "0027") ? "\047" : (h == "0026") ? "&" : (h == "003c") ? "<" : (h == "003e") ? ">" : "?"); s = substr(s, i + 6); continue }
    if (c == "n") out = out "\n"; else if (c == "t") out = out "\t"; else if (c == "r") out = out "\r"
    else if (c == "b" || c == "f") out = out " "; else out = out c
    s = substr(s, i + 2)
  }
  return out s
}
function wsnorm(s) { gsub(/[ \t\r\n]+/, " ", s); gsub(/^ | $/, "", s); return s }
# one transcript line: records Bash/PowerShell tool_use commands (TU[id]) and tool_result ids (TR[id])
function scan(t,  n, p, c, d, k, s, isk) {
  n = length(t); p = 1; d = 0
  while (p <= n) {
    c = substr(t, p, 1)
    if (c == "{") { d++; TY[d] = ""; NM[d] = ""; ID[d] = ""; CM[d] = ""; KEY[d] = ""; EXPK[d] = 1; ARR[d] = 0; p++; continue }
    if (c == "[") { d++; ARR[d] = 1; KEY[d] = ""; EXPK[d] = 0; p++; continue }
    if (c == "}") {
      if (TY[d] == "tool_use" && (NM[d] == "Bash" || NM[d] == "PowerShell") && ID[d] != "" && CM[d] != "") TU[ID[d]] = CM[d]
      d--; if (d > 0 && !ARR[d]) EXPK[d] = 0; p++; continue
    }
    if (c == "]") { d--; p++; continue }
    if (c == ",") { if (d > 0 && !ARR[d]) EXPK[d] = 1; p++; continue }
    if (c == "\"") {
      if (!match(substr(t, p, 65536 + 0) "", /^"([^"\\]|\\.)*"/)) {
        # long string: find its end by scanning
        k = p + 1
        while (k <= n) { c = substr(t, k, 1); if (c == "\\") k += 2; else if (c == "\"") break; else k++ }
        s = substr(t, p + 1, k - p - 1); p = k + 1
      } else { s = substr(t, p + 1, RLENGTH - 2); p += RLENGTH }
      if (d > 0 && !ARR[d] && EXPK[d]) { KEY[d] = s; EXPK[d] = 0; continue }
      if (d > 0 && !ARR[d]) {
        k = KEY[d]
        if (k == "type") TY[d] = s
        else if (k == "name") NM[d] = s
        else if (k == "id") ID[d] = s
        else if (k == "command" && d > 1 && KEY[d - 1] == "input") CM[d - 1] = jdec(s)
      }
      continue
    }
    p++
  }
}
{
  sub(/\r$/, "")
  if ($0 ~ /"type"[ \t]*:[ \t]*"(assistant|user)"/) KNOWN = 1
  if (index($0, "\"tool_use\"") > 0) scan($0)
  # tool results: only their ids are needed (these lines can be large)
  if (index($0, "\"tool_use_id\"") > 0) {
    r = $0
    while (match(r, /"tool_use_id"[ \t]*:[ \t]*"[^"]*"/)) {
      x = substr(r, RSTART, RLENGTH); sub(/^"tool_use_id"[ \t]*:[ \t]*"/, "", x); sub(/"$/, "", x); TR[x] = 1
      r = substr(r, RSTART + RLENGTH)
    }
  }
}
END {
  if (!KNOWN) { print "UNKNOWN"; exit }
  nc = split(ENVIRON["VC_CLAIMS"], CL, "\n")
  for (i = 1; i <= nc; i++) {
    c = wsnorm(CL[i]); if (c == "" || (c in SEEN)) continue
    SEEN[c] = 1; found = 0
    for (id in TU) if ((id in TR) && index(wsnorm(TU[id]), c) > 0) { found = 1; break }
    print (found ? "FOUND\t" : "MISSING\t") c
  }
}'
if [ -z "$(printf '%s' "$CLAIMS" | tr -d '[:space:]')" ]; then add SKIP ran-cmd "no claimed commands"
elif [ -z "$TRANSCRIPT" ]; then add SKIP ran-cmd "no transcript given"
elif [ ! -r "$TRANSCRIPT" ]; then add SKIP ran-cmd "transcript not readable: $TRANSCRIPT"
else
  out="$(VC_CLAIMS="$CLAIMS" awk "$SCAN_AWK" "$TRANSCRIPT" 2>/dev/null)"
  if [ "$out" = UNKNOWN ] || [ -z "$out" ]; then add SKIP ran-cmd "unknown transcript format"
  else
    nf=0; nok=0
    while IFS=$'\t' read -r r c; do
      case "$r" in
        FOUND) nok=$((nok + 1)) ;;
        MISSING) add FAIL ran-cmd "not run in the transcript: $c"; nf=$((nf + 1)) ;;
      esac
    done <<< "$out"
    [ $nf -eq 0 ] && add PASS ran-cmd "$nok claimed command(s) found in the transcript"
  fi
fi

# ---------- tested-line ----------
if [ -z "$REPORT" ]; then add SKIP tested-line "no report given"
elif [ -z "$TESTED_LINES" ]; then add FAIL tested-line "the report has no Tested: line"
elif printf '%s\n' "$TESTED_LINES" | grep -Eq '^[[:space:]]*Tested:[[:space:]]*not run'; then
  add WARN tested-line "$(printf '%s\n' "$TESTED_LINES" | grep -E '^[[:space:]]*Tested:[[:space:]]*not run' | head -1 | sed 's/^[[:space:]]*//')"
elif printf '%s\n' "$TESTED_LINES" | grep -Eq '^[[:space:]]*Tested:[[:space:]]*ran([[:space:]]|$)'; then add PASS tested-line "Tested: ran ..."
else add WARN tested-line "Tested: line starts with neither 'ran' nor 'not run'"; fi

# ---------- output ----------
jesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; JE="$s"; }
if [ $JSON -eq 1 ]; then
  printf '{"version":1,"checks":['
  first=1
  for r in ${RES[@]+"${RES[@]}"}; do
    res="${r%%$'\t'*}"; rest="${r#*$'\t'}"; id="${rest%%$'\t'*}"; det="${rest#*$'\t'}"
    jesc "$det"
    [ $first -eq 1 ] || printf ','; first=0
    printf '{"id":"%s","result":"%s","detail":"%s"}' "$id" "$res" "$JE"
  done
  printf '],"failed":%d}\n' "$FAILED"
else
  for r in ${RES[@]+"${RES[@]}"}; do
    res="${r%%$'\t'*}"; rest="${r#*$'\t'}"; id="${rest%%$'\t'*}"; det="${rest#*$'\t'}"
    printf '%s %s %s\n' "$res" "$id" "$det"
  done
  echo "verify-checks: $FAILED failed"
fi
[ $FAILED -eq 0 ] || exit 1
exit 0
