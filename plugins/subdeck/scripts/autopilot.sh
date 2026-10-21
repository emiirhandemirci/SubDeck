#!/usr/bin/env bash
# SubDeck autopilot: a deterministic supervisor (no LLM in it) that works a project's task queue unattended, one tick
# at a time, with bash + files only (no server, no database). Off by default: per project `autopilot.enabled=on`.
# Bash 3.2+, bash + awk + sed + git + cksum; no JSON tool, no node, no coreutils timeout.
#
# Usage: autopilot.sh [--project <dir>] <command>
#   start [--new-branch]   checks, autopilot branch + worktree, detached loop (<ap>/loop.pid); exit 2 check failed,
#                          3 global kill switch, 4 a live loop exists
#   stop [--now]           kill switch file <ap>/STOP + TERM to the loop; --now also stops active runs and the manager turn
#   status [--json]        state, reasons, branch, next tick, active, queue, budget, needs-user (exit 2 when not enabled)
#   tick                   one tick in the foreground (OS schedulers, tests); always exit 0 except usage (2)
#   dry-run                what one tick would do (`would: ...` lines, manager prompt after `--- manager prompt ---`); writes nothing
#   launch <role> <task>   enqueue a run (the manager's only way to start work); prints `queued` or `refused: <reason>`;
#                          exit 0 queued, 2 refused, 4 lock busy
#   resume [--tool <t>]    clear manual pauses (auth, manager-dirty, integration); budget and quota pauses clear by time
# <ap> = <state>/autopilot (lib-paths.sh). Files: state.txt status.json ledger.tsv integrated.tsv asked.tsv launched.tsv
#   queue/ turns/ digest/<date>.md loop.log launch.log STOP. Global kill switch: ${SUBDECK_HOME:-$HOME}/.subdeck/autopilot.STOP.
# One tick: 0 lock, 1 kill switch / enabled, 2 collect finished runs (ledger, quota/auth pauses, strikes, verdicts),
#   3 health of active runs (orphan, stuck -> TERM own run.sh pid), 4 3-strike rule -> needs-user, 5 integrate verified
#   work into the autopilot branch, 6 pauses (budget, quota, quiet hours, manual), 7 dispatch ready/interrupted/review
#   tasks + launch the queue, 8 manager turn, 9 digest, 10 status.json + state.txt.
# Deterministic dispatch: a ready task with a "Done when" gets the worker role (or its own worker-class role), an
#   interrupted one its last role again, a review task the verifier; a verifier verdict Approved -> tasks.sh done,
#   Needs fixes -> findings appended to Task and status open, Escalate -> needs-user. The autopilot never marks a task
#   done without a verifier Approved verdict (tasks.sh done enforces it), never pushes, merges into another branch,
#   rebases or resets, and never changes the user's checkout (only worktree add, rev-parse, log, status run there).
# Env: SUBDECK_NOW=<epoch> (clock, tests), SUBDECK_AUTOPILOT_PROMPT=<file> (rules text, default autopilot-prompt.md),
#   TZ (local time for days, weeks, quiet hours and the digest hour).

LC_COLLATE=C
HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
HERE="$(cd "$HERE" 2>/dev/null && pwd)"
. "$HERE/lib-paths.sh" 2>/dev/null || { echo "autopilot.sh: lib-paths.sh missing" >&2; exit 2; }
SELF="$HERE/autopilot.sh"
TASKS_SH="$HERE/tasks.sh"; RUN_SH="$HERE/run.sh"; LOG_EVENT="$HERE/log-event.sh"; NOTIFY_SH="$HERE/notify.sh"; SETTINGS_SH="$HERE/settings.sh"
US=$'\037'; TAB=$'\t'; NL=$'\n'; SEP="$US"
ID_RE='^t-[0-9a-f]{4,12}$'; ROLE_RE='^[a-z][a-z0-9-]{0,23}$'

die() { printf 'autopilot.sh: %s\n' "$2" >&2; exit "$1"; }
jesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$TAB/\\t}"; s="${s//$NL/\\n}"; s="${s//$'\r'/}"; JE="$s"; }
jstr() { jesc "$1"; printf '"%s"' "$JE"; }

# ---------- arguments ----------
PROJECT=""; POS=(); OPT_NEW=0; OPT_NOW=0; OPT_JSON=0; OPT_TOOL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die 2 "--project needs a directory"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --new-branch) OPT_NEW=1; shift ;;
    --now) OPT_NOW=1; shift ;;
    --json) OPT_JSON=1; shift ;;
    --tool) [ $# -ge 2 ] || die 2 "--tool needs a value"; OPT_TOOL="$2"; shift 2 ;;
    --*) die 2 "unknown option $1" ;;
    *) POS[${#POS[@]}]="$1"; shift ;;
  esac
done
CMD="${POS[0]:-}"
USAGE="usage: autopilot.sh [--project <dir>] start [--new-branch] | stop [--now] | status [--json] | tick | dry-run | launch <role> <task-id> | resume [--tool <t>]"
[ -n "$CMD" ] || die 2 "$USAGE"
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
[ -d "$PROJECT" ] || die 2 "project directory not found: $PROJECT"
PROJECT="$(cd "$PROJECT" && pwd)"
unset SUBDECK_PROJECT
sd_state_dir "$PROJECT"; STATE="$SD_STATE"
AP="$STATE/autopilot"; APWT="$STATE/worktrees/_autopilot"
GSTOP="${SUBDECK_HOME:-$HOME}/.subdeck/autopilot.STOP"
NOW="${SUBDECK_NOW:-}"; [[ $NOW =~ ^[0-9]+$ ]] || NOW="$(date +%s)"
DRY=0; [ "$CMD" = dry-run ] && DRY=1
export SUBDECK_METER=0   # tasks.sh: no tasks_cli event per call (ticks must be idempotent)

# ---------- time (local via one offset; no date(1) per row) ----------
tz_offset() { # -> OFF seconds east of UTC
  local z; z="$(date +%z 2>/dev/null)"
  OFF=0
  if [[ $z =~ ^([+-])([0-9]{2})([0-9]{2})$ ]]; then
    OFF=$(( 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 )); [ "${BASH_REMATCH[1]}" = - ] && OFF=$((-OFF))
  fi
}
tz_offset
civil() { # days since 1970-01-01 -> CY CM CD
  local z=$(( $1 + 719468 )) era doe yoe y doy mp d m
  era=$(( (z >= 0 ? z : z - 146096) / 146097 )); doe=$(( z - era * 146097 ))
  yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 )); y=$(( yoe + era * 400 ))
  doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) )); mp=$(( (5 * doy + 2) / 153 ))
  d=$(( doy - (153 * mp + 2) / 5 + 1 )); m=$(( mp < 10 ? mp + 3 : mp - 9 )); [ "$m" -le 2 ] && y=$((y + 1))
  CY=$y; CM=$m; CD=$d
}
LDAY=$(( (NOW + OFF) / 86400 ))            # local day number
LWEEK=$(( (LDAY + 3) / 7 ))               # ISO week number (Monday start) since the epoch
LHOUR=$(( ((NOW + OFF) % 86400) / 3600 ))
civil "$LDAY"; printf -v TODAY '%04d-%02d-%02d' "$CY" "$CM" "$CD"; printf -v TODAYC '%04d%02d%02d' "$CY" "$CM" "$CD"
NEXT_DAY=$(( (LDAY + 1) * 86400 - OFF )); NEXT_WEEK=$(( ((LWEEK + 1) * 7 - 3) * 86400 - OFF ))
iso_of() { # epoch -> ISO UTC in ISO
  local d=$(( $1 / 86400 )) s=$(( $1 % 86400 ))
  civil "$d"; printf -v ISO '%04d-%02d-%02dT%02d:%02d:%02dZ' "$CY" "$CM" "$CD" $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
}
iso_of "$NOW"; NOW_ISO="$ISO"
mtime() { # file -> MT epoch ("" when missing)
  MT=""; [ -e "$1" ] || return 0
  MT="$(stat -c %Y "$1" 2>/dev/null)" || MT=""
  [[ $MT =~ ^[0-9]+$ ]] || MT="$(stat -f %m "$1" 2>/dev/null)"
  [[ $MT =~ ^[0-9]+$ ]] || MT=""
}

# ---------- config (settings.sh json: scope rules live there) ----------
cfg_load() {
  local j
  j="$(bash "$SETTINGS_SH" json --project "$PROJECT" 2>/dev/null)"
  CFG_ROWS="$(printf '%s' "$j" | awk 'BEGIN { RS = "\001" } {
    n = split($0, P, "{\"key\":\"")
    for (i = 2; i <= n; i++) { k = P[i]; sub(/".*/, "", k); v = P[i]; sub(/^[^"]*","value":/, "", v)
      if (substr(v, 1, 1) == "\"") { v = substr(v, 2); sub(/".*/, "", v) } else sub(/,.*/, "", v)
      s = P[i]; sub(/.*"source":"/, "", s); sub(/".*/, "", s)
      printf "%s\037%s\037%s\n", k, v, s } }')"
  cget() { local k v s; C_V="$2"; C_S=default; while IFS="$SEP" read -r k v s; do [ "$k" = "$1" ] && { C_V="$v"; C_S="$s"; return 0; }; done <<< "$CFG_ROWS"; }
  cget autopilot.enabled off; C_ENABLED="$C_V"; [ "$C_S" = project ] || C_ENABLED=off
  cget autopilot.branch ""; C_BRANCH="$C_V"
  cget autopilot.max-parallel 2; C_MAXPAR="$C_V"
  cget autopilot.max-runs-day 20; C_MAXRUNS="$C_V"
  cget autopilot.max-turns-day 48; C_MAXTURNS="$C_V"
  cget autopilot.stuck-minutes 30; C_STUCK="$C_V"
  cget autopilot.tick-seconds 60; C_TICK="$C_V"
  cget autopilot.manager-gap 5; C_GAP="$C_V"
  cget autopilot.digest-hour 8; C_DIGESTH="$C_V"
  cget autopilot.quiet-hours ""; C_QUIET="$C_V"
  cget autopilot.budget.tokens-day 0; C_TOKD="$C_V"
  cget autopilot.budget.tokens-week 0; C_TOKW="$C_V"
  cget autopilot.budget.runs-week 0; C_RUNSW="$C_V"
  cget notify off; C_NOTIFY="$C_V"
  for v in C_MAXPAR C_MAXRUNS C_MAXTURNS C_STUCK C_TICK C_GAP C_DIGESTH C_TOKD C_TOKW C_RUNSW; do
    eval "[[ \${$v} =~ ^[0-9]+\$ ]] || $v=0"
  done
}
# roles: run.sh roles --json -> RL_<role>_tool / RL_<role>_model / RL_<role>_class
roles_load() {
  local j r
  j="$(bash "$RUN_SH" --project "$PROJECT" roles --json 2>/dev/null)"
  ROLE_NAMES=""
  while IFS="$SEP" read -r r c t m; do
    [[ $r =~ $ROLE_RE ]] || continue
    ROLE_NAMES="$ROLE_NAMES $r"
    r="${r//-/_}"; printf -v "RL_${r}_class" '%s' "$c"; printf -v "RL_${r}_tool" '%s' "$t"; printf -v "RL_${r}_model" '%s' "$m"
  done < <(printf '%s' "$j" | awk 'BEGIN { RS = "\001" } { n = split($0, P, "{\"role\":\"")
    for (i = 2; i <= n; i++) { r = P[i]; sub(/".*/, "", r)
      c = P[i]; sub(/.*"class":"/, "", c); sub(/".*/, "", c); t = P[i]; sub(/.*"tool":"/, "", t); sub(/".*/, "", t)
      m = P[i]; sub(/.*"model":"/, "", m); sub(/".*/, "", m); printf "%s\037%s\037%s\037%s\n", r, c, t, m } }')
}
rtool() { local r="${1//-/_}"; eval "RT=\${RL_${r}_tool:-}; RM=\${RL_${r}_model:-}; RC=\${RL_${r}_class:-}"; }

# ---------- state.txt ----------
ST_KEYS="branch base worktree startedAt lastTickAt lastTurnStart lastTurnEnd lastTurnFp lastTurnStatus digestNotified digestHash stuckKilled pauses stateLine"
state_load() {
  local k v line
  for k in $ST_KEYS; do printf -v "S_$k" '%s' ""; done
  S_EXTRA=""
  [ -f "$AP/state.txt" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; [ -n "$line" ] || continue
    k="${line%%=*}"; v="${line#*=}"
    case " $ST_KEYS " in *" $k "*) printf -v "S_$k" '%s' "$v" ;; *) S_EXTRA="$S_EXTRA$line$NL" ;; esac
  done < "$AP/state.txt"
}
state_save() {
  [ "$DRY" = 1 ] && return 0
  local k v tmp="$AP/.state.txt.$$"
  { for k in $ST_KEYS; do eval "v=\${S_$k}"; printf '%s=%s\n' "$k" "$v"; done; printf '%s' "$S_EXTRA"; } > "$tmp" 2>/dev/null && mv -f "$tmp" "$AP/state.txt" 2>/dev/null
}

# ---------- side effects (all go through these; dry-run prints them) ----------
ACTIONS=0
would() { printf 'would: %s\n' "$1"; }
ev() { # kind body (JSON members without braces)
  ACTIONS=$((ACTIONS + 1))
  [ "$DRY" = 1 ] && { would "event $1"; return 0; }
  printf '{"agent_id":"autopilot","session_id":"autopilot","agent_type":"autopilot",%s}' "$2" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$LOG_EVENT" "$1" >/dev/null 2>&1
  return 0
}
ev_quiet() { # an event that is not a tick action (state changes)
  [ "$DRY" = 1 ] && { would "event $1"; return 0; }
  printf '{"agent_id":"autopilot","session_id":"autopilot","agent_type":"autopilot",%s}' "$2" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$LOG_EVENT" "$1" >/dev/null 2>&1
}
notify() { # kind notification_type
  [ "$DRY" = 1 ] && { would "notify $2"; return 0; }
  printf '{"session_id":"autopilot","cwd":%s,"agent_type":"autopilot","notification_type":"%s"}' "$(jstr "$PROJECT")" "$2" \
    | CLAUDE_PROJECT_DIR="$PROJECT" bash "$NOTIFY_SH" hook "$1" >/dev/null 2>&1
  return 0
}
tk() { # tasks.sh mutation (autopilot identity: never answer, never done --force)
  ACTIONS=$((ACTIONS + 1))
  [ "$DRY" = 1 ] && { would "tasks.sh $*"; return 0; }
  SUBDECK_AUTOPILOT=1 bash "$TASKS_SH" --project "$PROJECT" "$@"
}
tkr() { bash "$TASKS_SH" --project "$PROJECT" "$@" 2>/dev/null; }   # read-only tasks.sh
fwrite() { # path content (atomic)
  [ "$DRY" = 1 ] && return 0
  printf '%s' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null
}
fappend() { [ "$DRY" = 1 ] && return 0; printf '%s\n' "$2" >> "$1" 2>/dev/null; }

# ---------- lock ----------
HAVE_LOCK=0
lock_take() { # wait-seconds -> 0 taken, 1 busy
  local w="${1:-0}" i=0 owner pid ep
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$AP" 2>/dev/null || return 1
  while :; do
    if mkdir "$AP/.lock" 2>/dev/null; then
      printf '%s %s\n' "$$" "$NOW" > "$AP/.lock/owner"; HAVE_LOCK=1; return 0
    fi
    owner=""; { read -r owner < "$AP/.lock/owner"; } 2>/dev/null
    pid="${owner%% *}"; ep="${owner#* }"
    if [[ $pid =~ ^[0-9]+$ ]] && { ! kill -0 "$pid" 2>/dev/null || { [[ $ep =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - ep )) -gt 600 ] && [ $(( NOW - ep )) -gt 600 ]; }; }; then
      rm -rf "$AP/.lock" 2>/dev/null; continue
    fi
    if [ -z "$pid" ]; then
      mtime "$AP/.lock"; [ -n "$MT" ] && [ $(( $(date +%s) - MT )) -gt 600 ] && { rm -rf "$AP/.lock" 2>/dev/null; continue; }
    fi
    [ "$i" -ge $((w * 5)) ] && return 1
    sleep 0.2; i=$((i + 1))
  done
}
lock_release() { [ "$HAVE_LOCK" = 1 ] && rm -rf "$AP/.lock" 2>/dev/null; HAVE_LOCK=0; }
trap 'lock_release' EXIT

# ---------- data readers ----------
# tasks_load: TASKS lines (TSV) id status title role tool model branch worktree strikes needsFixes verdict question archived updated transcript blockedBy
TFIELDS="id,status,title,role,tool,model,branch,worktree,strikes,needsFixes,verdict,question,archived,updated,transcript,blockedBy"
TJSON_AWK='
function rs(   s, c, e) { i++; s = ""
  while (i <= n) { c = substr(t, i, 1)
    if (c == "\\") { e = substr(t, i + 1, 1); i += 2; if (e == "n" || e == "t" || e == "r") s = s " "; else if (e == "u") { s = s "?"; i += 4 } else s = s e }
    else if (c == "\"") { i++; break } else { s = s c; i++ } }
  return s }
function out(   k, line) { line = ""; for (k = 1; k <= nf; k++) line = line (k > 1 ? "\037" : "") V[FL[k]]; print line }
BEGIN { RS = "\001"; nf = split(F, FL, ",") }
{ t = $0; n = length(t); i = index(t, "\"tasks\":["); if (!i) exit; i += 9
  while (i <= n) { c = substr(t, i, 1)
    if (c == "{") { split("", V); i++; ex = 1; key = ""
      while (i <= n) { c = substr(t, i, 1)
        if (c == "\"") { s = rs(); if (ex) { key = s; ex = 0 } else V[key] = s }
        else if (c == ",") { ex = 1; i++ }
        else if (c == "[") { i++; a = ""; while (i <= n && substr(t, i, 1) != "]") { if (substr(t, i, 1) == "\"") { s = rs(); a = a (a == "" ? "" : ",") s } else i++ } i++; V[key] = a }
        else if (c == "}") { i++; out(); break }
        else if (c ~ /[-0-9a-z]/) { l = ""; while (i <= n && substr(t, i, 1) ~ /[-0-9a-zA-Z.+]/) { l = l substr(t, i, 1); i++ } V[key] = l }
        else i++ } }
    else if (c == "]") break
    else i++ } }'
tasks_load() {
  TASKS="$(tkr list --all --json | awk -v F="$TFIELDS" "$TJSON_AWK")"
  READY="$(tkr ready --json | awk -v F="id" "$TJSON_AWK")"
}
task_get() { # id -> T_ fields from TASKS (returns 1 when unknown)
  local line
  while IFS="$SEP" read -r T_id T_status T_title T_role T_tool T_model T_branch T_worktree T_strikes T_nf T_verdict T_question T_arch T_updated T_transcript T_blocked; do
    [ "$T_id" = "$1" ] && return 0
  done <<< "$TASKS"
  T_id=""; return 1
}
# metas: <state>/runs/t-*/*.json and <ap>/turns/*.json not yet in the ledger -> METAS TSV
# file runId kind task role class tool model status exit pid startedAt endedAt tokIn tokOut known
META_AWK='
function g(k,   r) { r = "\"" k "\":\"[^\"]*\""; if (match(L, r)) return substr(L, RSTART + length(k) + 4, RLENGTH - length(k) - 5)
  r = "\"" k "\":[^,}]*"; if (match(L, r)) { v = substr(L, RSTART + length(k) + 3, RLENGTH - length(k) - 3); return (v == "null") ? "" : v } return "" }
FNR == 1 { if (L != "") emit(); L = ""; FN = FILENAME }
{ L = L $0 }
END { if (L != "") emit() }
function emit(   tk, ti, to, kn) {
  tk = L; ti = 0; to = 0; kn = "false"
  if (match(tk, /"tokens":\{[^}]*\}/)) { tk = substr(tk, RSTART, RLENGTH)
    if (match(tk, /"in":[0-9]+/)) ti = substr(tk, RSTART + 5, RLENGTH - 5)
    if (match(tk, /"out":[0-9]+/)) to = substr(tk, RSTART + 6, RLENGTH - 6)
    if (tk ~ /"known":true/) kn = "true" }
  printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", FN, g("runId"), (g("class") == "manager" ? "turn" : "task"), g("task"), g("role"), g("class"), g("tool"), g("model"), g("status"), g("exit"), g("pid"), g("startedAt"), g("endedAt"), ti, to, kn }'
ledger_ids() { LEDGER_IDS=" "; [ -f "$AP/ledger.tsv" ] && LEDGER_IDS=" $(cut -f2 "$AP/ledger.tsv" | tr '\n' ' ')"; }
metas_load() {
  local f b d files=()
  ledger_ids
  for f in "$STATE"/runs/t-*/*.json "$AP"/turns/*.json; do
    [ -f "$f" ] || continue
    b="${f##*/}"; b="${b%.json}"; d="${f%/*}"; d="${d##*/}"
    case "$f" in "$AP"/turns/*) case "$LEDGER_IDS" in *" turn-$b "*) continue ;; esac ;;
      *) case "$LEDGER_IDS" in *" run-$d-$b "*) continue ;; esac ;; esac
    files[${#files[@]}]="$f"
  done
  METAS=""
  [ ${#files[@]} -gt 0 ] && METAS="$(LC_ALL=C awk "$META_AWK" "${files[@]}" 2>/dev/null)"
}
launched_load() { LAUNCHED=""; [ -f "$AP/launched.tsv" ] && LAUNCHED="$(cat "$AP/launched.tsv" 2>/dev/null)"; }
own_pid() { case "$NL$LAUNCHED" in *"$NL$1$TAB"*) return 0 ;; esac; return 1; }

# ---------- pauses: "<kind>:<tool|*>:<untilEpoch|0>:<attempts>" comma list in S_pauses ----------
pause_get() { # kind tool -> PU_UNTIL PU_ATT (returns 1 when absent)
  local p k t u a; local -a arr
  IFS=, read -ra arr <<< "$S_pauses"
  for p in ${arr[@]+"${arr[@]}"}; do
    IFS=: read -r k t u a <<< "$p"
    [ "$k" = "$1" ] && [ "$t" = "$2" ] && { PU_UNTIL="$u"; PU_ATT="$a"; return 0; }
  done
  PU_UNTIL=""; PU_ATT=""; return 1
}
pause_set() { # kind tool until attempts
  pause_del "$1" "$2"; S_pauses="$S_pauses${S_pauses:+,}$1:$2:$3:$4"
}
pause_del() { # kind tool
  local p k t u a out=""; local -a arr
  IFS=, read -ra arr <<< "$S_pauses"
  for p in ${arr[@]+"${arr[@]}"}; do IFS=: read -r k t u a <<< "$p"; { [ "$k" = "$1" ] && [ "$t" = "$2" ]; } || out="$out${out:+,}$p"; done
  S_pauses="$out"
}
tool_paused() { # tool -> 0 when a quota or auth pause holds for it
  pause_get quota "$1" && [ "${PU_UNTIL:-0}" -gt "$NOW" ] && return 0
  pause_get auth "$1" && return 0
  return 1
}
# retry seconds from a quota message (contract sec. 4.3), the run's reset time (lib-paths sd_parse_reset), else backoff
quota_until() { # tail-text attempts -> QUNTIL
  local t="$1" att="$2" re='(retry[- ]after|try again in|resets? in)[^0-9]{0,5}([0-9]+) ?(s|sec|m|min|h|hour)' n u sec jit low
  low="$(printf '%s' "$t" | tr 'A-Z' 'a-z')"
  sec=""
  if [[ $low =~ $re ]]; then
    n=$((10#${BASH_REMATCH[2]})); u="${BASH_REMATCH[3]}"
    case "$u" in s|sec) sec=$n ;; m|min) sec=$((n * 60)) ;; h|hour) sec=$((n * 3600)) ;; esac
  fi
  if [ -z "$sec" ]; then
    sd_parse_reset "$t"
    if [ -n "$SDR_RESETAT" ]; then sd_iso_epoch "$SDR_RESETAT"; [ -n "$SD_EPOCH" ] && [ "$SD_EPOCH" -gt "$NOW" ] && sec=$((SD_EPOCH - NOW)); fi
  fi
  if [ -z "$sec" ]; then
    sec=1800; n=1; while [ "$n" -lt "$att" ] && [ "$sec" -lt 21600 ]; do sec=$((sec * 2)); n=$((n + 1)); done
    [ "$sec" -gt 21600 ] && sec=21600
  fi
  # deterministic jitter (0-119 s) so several projects do not all resume in the same second
  jit="$(printf '%s:%s' "$PROJECT" "$att" | cksum)"; jit=$(( ${jit%% *} % 120 ))
  QUNTIL=$((NOW + sec + jit))
}

# ---------- budget (one awk pass over the ledger) ----------
budget_compute() {
  local r
  r="$( { [ -f "$AP/ledger.tsv" ] && cat "$AP/ledger.tsv"; } | awk -F'\t' -v off="$OFF" -v day="$LDAY" -v week="$LWEEK" '
    function ep(s,   y, m, d, H, M, S, era, yoe, mp, doy, doe) {
      if (s !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}/) return -1
      y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0; H = substr(s, 12, 2) + 0; M = substr(s, 15, 2) + 0; S = substr(s, 18, 2) + 0
      if (m <= 2) y -= 1; era = int(y / 400); yoe = y - era * 400; mp = (m + 9) % 12
      doy = int((153 * mp + 2) / 5) + d - 1; doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return (era * 146097 + doe - 719468) * 86400 + H * 3600 + M * 60 + S }
    { e = ep($1); if (e < 0) next; ld = int((e + off) / 86400); lw = int((ld + 3) / 7)
      tok = ($12 == "true") ? $10 + $11 : 0
      if ($3 == "task") { if (ld == day) { rd++; if ($12 != "true") ud++ } if (lw == week) rw++ }
      if ($3 == "turn" && ld == day) td++
      if (ld == day) kd += tok; if (lw == week) kw += tok }
    END { printf "%d %d %d %d %d %d", rd, td, kd, kw, rw, ud }')"
  read -r B_RUNSD B_TURNSD B_TOKD B_TOKW B_RUNSW B_UNKD <<< "$r"
  B_RUNSD=$((B_RUNSD + ACTIVE_TASKS)); B_TURNSD=$((B_TURNSD + ACTIVE_TURN)); B_RUNSW=$((B_RUNSW + ACTIVE_TASKS))
}
in_quiet() {
  [[ $C_QUIET =~ ^([0-9]{2})-([0-9]{2})$ ]] || return 1
  local s=$((10#${BASH_REMATCH[1]})) e=$((10#${BASH_REMATCH[2]}))
  [ "$s" = "$e" ] && return 1
  if [ "$s" -lt "$e" ]; then [ "$LHOUR" -ge "$s" ] && [ "$LHOUR" -lt "$e" ]; else [ "$LHOUR" -ge "$s" ] || [ "$LHOUR" -lt "$e" ]; fi
}

# ---------- active runs ----------
# ACTIVE lines: runId kind task role tool pid startedAt metafile ; from running metas (+ own launches without a meta yet)
active_load() {
  local f rid kind task role cls tool model st ex pid sa ea ti to kn
  ACTIVE=""; ACTIVE_TASKS=0; ACTIVE_TURN=0
  while IFS="$SEP" read -r f rid kind task role cls tool model st ex pid sa ea ti to kn; do
    [ -n "$f" ] && [ "$st" = running ] && [ -z "$ea" ] || continue
    ACTIVE="$ACTIVE$rid$SEP$kind$SEP$task$SEP$role$SEP$tool$SEP$pid$SEP$sa$SEP$f$NL"
    if [ "$kind" = turn ]; then ACTIVE_TURN=$((ACTIVE_TURN + 1)); else ACTIVE_TASKS=$((ACTIVE_TASKS + 1)); fi
  done <<< "$METAS"
  # own launches whose run.sh has not written a meta yet still hold a slot
  local lp le lt lr
  while IFS="$TAB" read -r lp le lt lr; do
    [[ $lp =~ ^[0-9]+$ ]] && kill -0 "$lp" 2>/dev/null || continue
    case "$ACTIVE" in *"$SEP$lp$SEP"*) continue ;; esac
    if [ "$lt" = - ]; then
      # a turn whose meta is there but not yet listed above is covered; otherwise count it
      ACTIVE="${ACTIVE}launch-$le$SEP""turn$SEP$SEP$lr$SEP$SEP$lp$SEP$SEP$NL"; ACTIVE_TURN=$((ACTIVE_TURN + 1))
    else
      ACTIVE="${ACTIVE}launch-$le$SEP""task$SEP$lt$SEP$lr$SEP$SEP$lp$SEP$SEP$NL"; ACTIVE_TASKS=$((ACTIVE_TASKS + 1))
    fi
  done <<< "$LAUNCHED"
}
is_active() { # task role(optional) -> 0 when a run of it is active
  local rid kind task role rest
  while IFS="$SEP" read -r rid kind task role rest; do
    [ "$kind" = task ] && [ "$task" = "$1" ] && { [ -z "${2:-}" ] || [ "$role" = "$2" ]; } && return 0
  done <<< "$ACTIVE"
  return 1
}
qparse() { # queue entry name <epoch>-<seq4>-<id>-<role> -> Q_EPOCH Q_ID Q_ROLE
  local r="${1#*-}"; Q_EPOCH="${1%%-*}"; r="${r#*-}"; r="${r#t-}"
  Q_ID="t-${r%%-*}"; Q_ROLE="${r#*-}"
}
queued() { # task -> 0 when an entry exists
  local f; for f in "$AP"/queue/*-"$1"-*; do [ -f "$f" ] && return 0; done; return 1
}

# ---------- launch validation (launch command and queue re-validation) ----------
validate_launch() { # role task -> 0 ok, else VREASON
  local role="$1" id="$2" dw
  VREASON=""
  [[ $role =~ $ROLE_RE ]] || { VREASON="invalid role"; return 1; }
  [[ $id =~ $ID_RE ]] || { VREASON="invalid task id"; return 1; }
  rtool "$role"
  [ -n "$RT" ] || { VREASON="role $role is not mapped"; return 1; }
  [ "$RC" = manager ] && { VREASON="manager is not launchable"; return 1; }
  task_get "$id" || { VREASON="task not found"; return 1; }
  [ "$T_arch" = true ] && { VREASON="task is done"; return 1; }
  [ "$T_status" = needs-user ] && { VREASON="needs-user"; return 1; }
  case "$RC" in
    worker|researcher) case "$T_status" in open|interrupted) ;; *) VREASON="status $T_status (needs open or interrupted)"; return 1 ;; esac
      if [ "$RC" = worker ]; then
        dw="$(tkr show "$id" --section done-when | tr -d '[:space:]')"
        [ -n "$dw" ] || { VREASON="no-done-when: the task needs a Done when section"; return 1; }
      fi ;;
    verifier) [ "$T_status" = review ] || { VREASON="status $T_status (needs review)"; return 1; } ;;
  esac
  return 0
}

# ---------- kill switch ----------
# ---------- PID registry: <state>/pids.tsv = "pid<TAB>startKey<TAB>name<TAB>task<TAB>owner<TAB>epoch" ----------
# Every child SubDeck starts is recorded; stop/exit paths signal ONLY a registered pid that is still alive AND whose
# start key (process start time) still matches, so a recycled pid or a foreign process is never touched. Never by name.
PIDREG="$STATE/pids.tsv"
reg_key() { # pid -> RKEY (process start time as an opaque string; empty when unknown)
  local s=""
  RKEY=""
  [[ $1 =~ ^[0-9]+$ ]] || return 0
  if [ -r "/proc/$1/stat" ]; then s="$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}')"; fi
  [ -n "$s" ] || s="$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | head -n 1)"
  RKEY="$s"
}
reg_add() { # pid name task owner (a pid whose start key cannot be read is not registered, so it is never killed)
  # a child that execs right after the fork changes its start time (Windows): take the key once two reads agree
  local prev="" n=0
  while [ $n -lt 10 ]; do reg_key "$1"; [ -n "$RKEY" ] && [ "$RKEY" = "$prev" ] && break; prev="$RKEY"; n=$((n + 1)); sleep 0.1; done
  [ -n "$RKEY" ] || return 0
  mkdir -p "${PIDREG%/*}" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$RKEY" "${2//[$'\t\n']/_}" "${3:--}" "${4//[$'\t\n']/_}" "$(date +%s)" >> "$PIDREG" 2>/dev/null
}
reg_kill() { # owner-glob [signal] -> signals live, key-matching rows of that owner; rewrites the file without dead/killed rows
  local pid key name task owner ep keep="" sig="${2:-TERM}"
  [ -f "$PIDREG" ] || return 0
  while IFS=$'\t' read -r pid key name task owner ep; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    reg_key "$pid"; [ "$RKEY" = "$key" ] || continue
    # shellcheck disable=SC2254
    case "$owner" in $1) kill "-$sig" "$pid" 2>/dev/null; continue ;; esac
    keep="$keep$pid"$'\t'"$key"$'\t'"$name"$'\t'"$task"$'\t'"$owner"$'\t'"$ep"$'\n'
  done < "$PIDREG"
  printf '%s' "$keep" > "$PIDREG.tmp" 2>/dev/null && mv -f "$PIDREG.tmp" "$PIDREG" 2>/dev/null
  return 0
}
reg_list() { # prints "pid name task owner" of live, key-matching rows
  local pid key name task owner ep
  [ -f "$PIDREG" ] || return 0
  while IFS=$'\t' read -r pid key name task owner ep; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    reg_key "$pid"; [ "$RKEY" = "$key" ] || continue
    printf '%s %s %s %s\n' "$pid" "$name" "$task" "$owner"
  done < "$PIDREG"
}
killed() { [ -f "$AP/STOP" ] || [ -f "$GSTOP" ]; }

# =====================================================================================================================
# tick
# =====================================================================================================================
REASONS=""; STATE_NAME=""
add_reason() { case ",$REASONS," in *",$1,"*) ;; *) REASONS="$REASONS${REASONS:+,}$1" ;; esac; }

strike() { # task reason runId
  local n
  [ -n "$1" ] || return 0
  task_get "$1" || return 0
  [ "$T_arch" = true ] && return 0
  if [ "$DRY" = 1 ]; then tk strike "$1" --reason "$2" --run "$3"; return 0; fi
  n="$(tk strike "$1" --reason "$2" --run "$3" 2>/dev/null)"
  [[ $n =~ ^[0-9]+$ ]] || return 0
  ev autopilot_strike "\"task\":$(jstr "$1"),\"strikes\":$n,\"reason\":$(jstr "$2"),\"runId\":$(jstr "$3")"
}
run_tail() { # metafile -> tail text of its log and out
  local b="${1%.json}"
  { tail -n 100 "$b.log" 2>/dev/null; tail -n 100 "$b.out" 2>/dev/null; } | grep -v '^\[subdeck\] '
}

# step 2 + verdict handling
collect_finished() {
  local f rid kind task role cls tool model st ex pid sa ea ti to kn row dirty
  while IFS="$SEP" read -r f rid kind task role cls tool model st ex pid sa ea ti to kn; do
    [ -n "$f" ] && [ -n "$ea" ] || continue
    [ -n "${SUBDECK_NOW:-}" ] && ea="$NOW_ISO"   # test clock: the ledger uses the tick clock so day and week budgets are deterministic
    row="$ea$TAB$rid$TAB$kind$TAB${task:--}$TAB$role$TAB$tool$TAB${model:--}$TAB$st$TAB${ex:-0}$TAB${ti:-0}$TAB${to:-0}$TAB$kn"
    fappend "$AP/ledger.tsv" "$row"; ACTIONS=$((ACTIONS + 1))
    [ "$DRY" = 1 ] && would "ledger $rid $st"
    case "$st" in
      quota)
        pause_get quota "$tool"; local att=$(( ${PU_ATT:-0} + 1 ))
        quota_until "$(run_tail "$f")" "$att"
        pause_set quota "$tool" "$QUNTIL" "$att"; iso_of "$QUNTIL"
        ev autopilot_quota "\"tool\":$(jstr "$tool"),\"until\":\"$ISO\",\"attempts\":$att,\"action\":\"pause\"" ;;
      auth)
        pause_set auth "$tool" 0 0; notify waiting autopilot_paused ;;
      failed|timeout|violation)
        [ "$kind" = task ] && strike "$task" "$st" "$rid" ;;
      cancelled)
        case ",$S_stuckKilled," in *",$rid,"*) [ "$kind" = task ] && strike "$task" stuck "$rid" ;; esac ;;
      ok)
        pause_get quota "$tool" && pause_set quota "$tool" "$PU_UNTIL" 0
        if [ "$kind" = task ] && [ -f "$STATE/events.jsonl" ] && grep '"event":"report_missing"' "$STATE/events.jsonl" 2>/dev/null | grep -qF "\"$rid\""; then
          task_get "$task" && case "$T_status" in in-progress|blocked) tk interrupt "$task" --reason report_missing --run "$rid" >/dev/null 2>&1 ;; esac
          strike "$task" report_missing "$rid"
          ev autopilot_stuck "\"task\":$(jstr "$task"),\"runId\":$(jstr "$rid"),\"reason\":\"report_missing\",\"idleMinutes\":0,\"action\":\"interrupted\""
        elif [ "$kind" = task ] && [ "$cls" = verifier ]; then
          verdict_apply "$task" "$rid"
        fi ;;
    esac
    if [ "$kind" = turn ]; then
      dirty=false
      [ -d "$APWT" ] && [ -n "$(git -C "$APWT" status --porcelain 2>/dev/null)" ] && dirty=true
      S_lastTurnEnd="$NOW"; S_lastTurnStatus="$st"
      if [ "$dirty" = true ]; then pause_set manual manager-dirty 0 0; notify waiting autopilot_paused; fi
      ev autopilot_turn_end "\"turnId\":$(jstr "$rid"),\"status\":$(jstr "$st"),\"exit\":${ex:-0},\"tokensIn\":${ti:-0},\"tokensOut\":${to:-0},\"dirty\":$dirty"
    fi
  done <<< "$METAS"
}
# a finished verifier run: Approved -> done; Needs fixes -> findings into Task, open; Escalate -> needs-user
verdict_apply() { # task runId
  local id="$1" v blk
  tasks_load; task_get "$id" || return 0
  [ "$T_arch" = true ] && return 0
  [ "$T_status" = review ] || return 0
  v="$T_verdict"
  case "$v" in
    Approved) tk done "$id" >/dev/null 2>&1 ;;
    "Needs fixes")
      blk="$(tkr show "$id" --section verification | awk '/^### /{b=""} {b=b $0 "\n"} END{printf "%s", b}' | head -n 60)"
      printf '%s\n' "$blk" | tk append "$id" task --label "verifier findings ($2)" >/dev/null 2>&1
      tk set "$id" status=open >/dev/null 2>&1 ;;
    Escalate) tk ask "$id" --by autopilot "The verifier escalated $id (run $2); read its Verification block and decide: retry, rescope or drop?" >/dev/null 2>&1 ;;
  esac
}
# step 3
health_check() {
  local rid kind task role tool pid sa f idle lm tr killed_list="$S_stuckKilled" changed=0
  while IFS="$SEP" read -r rid kind task role tool pid sa f; do
    [ -n "$f" ] || continue
    if ! { [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; }; then
      # orphan: run.sh is gone without an end; record it so it is handled once
      fappend "$AP/ledger.tsv" "$NOW_ISO$TAB$rid$TAB$kind$TAB${task:--}$TAB$role$TAB$tool$TAB-$TAB""orphaned$TAB""1$TAB""0$TAB""0$TAB""false"
      ACTIONS=$((ACTIONS + 1)); [ "$DRY" = 1 ] && would "ledger $rid orphaned"
      if [ "$kind" = task ]; then
        task_get "$task" && case "$T_status" in in-progress|blocked) tk interrupt "$task" --reason orphaned --run "$rid" >/dev/null 2>&1 ;; esac
        strike "$task" orphan "$rid"
      else S_lastTurnEnd="$NOW"; S_lastTurnStatus=orphaned; fi
      ev autopilot_stuck "\"task\":$( [ -n "$task" ] && jstr "$task" || printf null),\"runId\":$(jstr "$rid"),\"reason\":\"orphan\",\"idleMinutes\":0,\"action\":\"interrupted\""
      continue
    fi
    case ",$killed_list," in *",$rid,"*) continue ;; esac
    lm=0
    mtime "${f%.json}.log"; [ -n "$MT" ] && [ "$MT" -gt "$lm" ] && lm="$MT"
    mtime "${f%.json}.out"; [ -n "$MT" ] && [ "$MT" -gt "$lm" ] && lm="$MT"
    if [ "$kind" = task ] && task_get "$task" && [ -n "$T_transcript" ]; then mtime "$T_transcript"; [ -n "$MT" ] && [ "$MT" -gt "$lm" ] && lm="$MT"; fi
    [ "$lm" -gt 0 ] || continue
    idle=$(( (NOW - lm) / 60 ))
    [ $(( NOW - lm )) -ge $(( C_STUCK * 60 )) ] || continue
    own_pid "$pid" || continue          # only runs this autopilot started
    ACTIONS=$((ACTIONS + 1))
    if [ "$DRY" = 1 ]; then would "TERM $pid ($rid stuck ${idle} min)"; else kill -TERM "$pid" 2>/dev/null; fi
    killed_list="$killed_list${killed_list:+,}$rid"; changed=1
    ev autopilot_stuck "\"task\":$( [ -n "$task" ] && jstr "$task" || printf null),\"runId\":$(jstr "$rid"),\"reason\":\"no-growth\",\"idleMinutes\":$idle,\"action\":\"cancelled\""
  done <<< "$ACTIVE"
  [ "$changed" = 1 ] && S_stuckKilled="$killed_list"
  # keep the stuck list short: only run ids that are still active
  if [ -n "$S_stuckKilled" ]; then
    local keepk="" x; local -a ka; IFS=, read -ra ka <<< "$S_stuckKilled"
    for x in "${ka[@]}"; do case "$ACTIVE" in *"$x$SEP"*) keepk="$keepk${keepk:+,}$x" ;; *) case "$METAS" in *"$SEP$x$SEP"*) keepk="$keepk${keepk:+,}$x" ;; esac ;; esac; done
    S_stuckKilled="$keepk"
  fi
  # own launches that ended: forgotten; one that never wrote a run file (run.sh refused it) costs a strike
  local lp le lt lr keep="" hit gone=0
  while IFS="$TAB" read -r lp le lt lr; do
    [ -n "$lp" ] || continue
    if kill -0 "$lp" 2>/dev/null; then keep="$keep$lp$TAB$le$TAB$lt$TAB$lr$NL"; continue; fi
    gone=1; hit=0
    if [ "$lt" != - ]; then
      for f in "$STATE/runs/$lt"/*.json; do [ -f "$f" ] || continue; mtime "$f"; [ -n "$MT" ] && [ "$MT" -ge $((le - 5)) ] && hit=1; done
      [ "$hit" = 0 ] && strike "$lt" launch-refused "launch-$le-$lt"
    fi
  done <<< "$LAUNCHED"
  if [ "$gone" = 1 ]; then fwrite "$AP/launched.tsv" "$keep"; LAUNCHED="${keep%$NL}"; fi
}
# step 4
strike_rule() {
  local id st title role tool model br wt sk nf vd q ar up tr bl prev q2
  while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
    [ -n "$id" ] && [ "$ar" != true ] && [ "$st" != needs-user ] || continue
    sk="${sk:-0}"; nf="${nf:-0}"
    [ "$sk" -ge 3 ] || [ "$nf" -ge 3 ] || continue
    prev="$(grep "^$id$TAB" "$AP/asked.tsv" 2>/dev/null | tail -n 1)"
    [ "$prev" = "$id$TAB$sk$TAB$nf" ] && continue   # asked at these counts already (answered since): wait for a new failure
    local fr=$(( sk ))
    q2="3 failed attempts ($fr stuck/failed runs, $nf verifier Needs fixes); retry, rescope or drop?"
    tk ask "$id" --by autopilot "$q2" >/dev/null 2>&1
    fappend "$AP/asked.tsv" "$id$TAB$sk$TAB$nf"
  done <<< "$TASKS"
}
# step 5
integrate() {
  local id st title role tool model br wt sk nf vd q ar up tr bl ver fp tip res newtip cand c
  [ -n "$S_branch" ] && [ -d "$APWT" ] || return 0
  while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
    [ "$ar" = true ] && [ "$st" = done ] || continue
    grep -q "^[^$TAB]*$TAB$id$TAB" "$AP/integrated.tsv" 2>/dev/null && continue
    if [ "$br" != "subdeck/$id" ] || ! git -C "$PROJECT" rev-parse --verify --quiet "refs/heads/$br" >/dev/null 2>&1; then
      continue    # tasks without a branch: nothing to integrate (result none, not recorded)
    fi
    tip="$(git -C "$PROJECT" rev-parse "$br" 2>/dev/null)"
    ver="$(tkr show "$id" --section verification)"
    fp="$(printf '%s\n' "$ver" | awk '
      /Fingerprint:[ \t]*HEAD=/ { s = $0; sub(/.*HEAD=/, "", s); sub(/[^0-9a-fA-F].*/, "", s); last = s }
      /^[ \t]*Verdict:[ \t]*Approved/ { ok = last }
      END { print ok }')"
    res=""
    if [ ${#fp} -lt 7 ] || [ "${tip#"$fp"}" = "$tip" ]; then res=changed-after-verify; fi
    if [ -z "$res" ]; then
      if [ "$DRY" = 1 ]; then would "integrate $br into $S_branch"; ACTIONS=$((ACTIONS + 1)); continue; fi
      if [ -z "$(git -C "$APWT" rev-list "HEAD..$br" 2>/dev/null)" ]; then res=empty
      elif git -C "$APWT" merge --ff-only -q "$br" >/dev/null 2>&1; then res=ff
      else
        cand="$(git -C "$APWT" rev-list --reverse --cherry-pick --right-only --no-merges "HEAD...$br" 2>/dev/null)"
        if [ -z "$cand" ]; then res=empty
        else
          res=picked
          for c in $cand; do
            if ! git -C "$APWT" cherry-pick -x "$c" >/dev/null 2>&1; then git -C "$APWT" cherry-pick --abort >/dev/null 2>&1; res=conflict; break; fi
          done
          if [ "$res" = conflict ]; then
            # leave the branch as it was before this task's picks
            :
          fi
        fi
      fi
    fi
    newtip="$(git -C "$APWT" rev-parse HEAD 2>/dev/null)"
    fappend "$AP/integrated.tsv" "$NOW_ISO$TAB$id$TAB$res$TAB$newtip"; ACTIONS=$((ACTIONS + 1))
    ev autopilot_integrate "\"task\":$(jstr "$id"),\"branch\":$(jstr "$br"),\"result\":\"$res\",\"tip\":$(jstr "$newtip")"
    case "$res" in
      conflict|changed-after-verify)
        local nid
        nid="$(tk new "Integrate $id into $S_branch" --done-when "subdeck/$id is on $S_branch or dropped" 2>/dev/null)"
        [ "$DRY" = 1 ] && nid="t-new"
        [[ $nid =~ $ID_RE ]] && tk ask "$nid" --by autopilot "$br $res on $S_branch; resolve by hand or drop?" >/dev/null 2>&1 ;;
    esac
  done <<< "$TASKS"
}
# step 7a: deterministic dispatch
enqueue() { # role task -> queue entry (lock held by the tick)
  local seq=0 f
  while :; do printf -v f '%s/queue/%s-%04d-%s-%s' "$AP" "$NOW" "$seq" "$2" "$1"; [ -e "$f" ] || break; seq=$((seq + 1)); done
  ACTIONS=$((ACTIONS + 1))
  if [ "$DRY" = 1 ]; then would "queue $1 $2"; QUEUE_DRY="$QUEUE_DRY$1 $2$NL"; return 0; fi
  mkdir -p "$AP/queue" 2>/dev/null; : > "$f"
  ev autopilot_queue "\"task\":$(jstr "$2"),\"role\":$(jstr "$1"),\"result\":\"queued\",\"reason\":\"dispatch\""
}
dispatch() {
  local id st title role tool model br wt sk nf vd q ar up tr bl r
  while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
    [ -n "$id" ] && [ "$ar" != true ] || continue
    queued "$id" && continue
    case "$QUEUE_DRY" in *" $id$NL"*) continue ;; esac
    is_active "$id" && continue
    [ "${sk:-0}" -ge 3 ] || [ "${nf:-0}" -ge 3 ] && continue
    # usage-limit runs never strike: the tool is paused until reset + backoff and the task resumes in its own session;
    # at most 3 such resumes per task per day (the 4th limit run of the day parks the task until tomorrow)
    if [ -f "$AP/ledger.tsv" ] && [ "$(awk -F"$TAB" -v d="${NOW_ISO%%T*}" -v t="$id" '$4 == t && $8 == "quota" && index($1, d) == 1 { n++ } END { print n + 0 }' "$AP/ledger.tsv" 2>/dev/null)" -ge 4 ]; then
      if [ "$DRY" != 1 ] && ! grep -qxF "${NOW_ISO%%T*} $id" "$AP/qcap.txt" 2>/dev/null; then
        printf '%s %s\n' "${NOW_ISO%%T*}" "$id" >> "$AP/qcap.txt" 2>/dev/null
        ev autopilot_quota_cap "\"task\":$(jstr "$id"),\"resumes\":3,\"action\":\"parked until tomorrow\""
      fi
      continue
    fi
    r=""
    case "$st" in
      open) case "$NL$READY$NL" in *"$NL$id$NL"*) r=worker ;; esac ;;
      interrupted) r=worker ;;
      review) r=verifier ;;
    esac
    [ -n "$r" ] || continue
    if [ "$r" = worker ] && [ -n "$role" ]; then rtool "$role"; { [ "$RC" = worker ] || [ "$RC" = researcher ]; } && [ -n "$RT" ] && r="$role"; fi
    validate_launch "$r" "$id" || continue
    enqueue "$r" "$id"
  done <<< "$TASKS"
}
# step 7b: launch the queue
launch_queue() {
  local f b rest id role
  [ -d "$AP/queue" ] || return 0
  for f in "$AP"/queue/*; do
    [ -f "$f" ] || continue
    qparse "${f##*/}"; id="$Q_ID"; role="$Q_ROLE"
    if ! validate_launch "$role" "$id" || is_active "$id"; then
      [ -z "$VREASON" ] && VREASON="already active"
      ACTIONS=$((ACTIONS + 1))
      if [ "$DRY" = 1 ]; then would "drop $role $id ($VREASON)"; else rm -f "$f"; fi
      ev autopilot_queue "\"task\":$(jstr "$id"),\"role\":$(jstr "$role"),\"result\":\"dropped\",\"reason\":$(jstr "$VREASON")"
      continue
    fi
    rtool "$role"
    tool_paused "$RT" && break
    [ "$ACTIVE_TASKS" -ge "$C_MAXPAR" ] && break
    [ "$B_RUNSD" -ge "$C_MAXRUNS" ] && break
    in_quiet && break
    ACTIONS=$((ACTIONS + 1))
    if [ "$DRY" = 1 ]; then
      would "launch $role $id"
      printf '%s\n' "--- run.sh $role $id --dry-run ---"
      SUBDECK_AUTOPILOT=1 SUBDECK_AUTOPILOT_LAUNCH=1 SUBDECK_RUN_BASE="${S_branch:-HEAD}" bash "$RUN_SH" --project "$PROJECT" "$role" "$id" --dry-run 2>&1 | awk '/^argv:$/{f=1} /^env:$/{f=0} f'
    else
      local pid
      set -m
      nohup env SUBDECK_AUTOPILOT=1 SUBDECK_AUTOPILOT_LAUNCH=1 SUBDECK_RUN_BASE="${S_branch:-HEAD}" bash "$RUN_SH" --project "$PROJECT" "$role" "$id" >> "$AP/launch.log" 2>&1 < /dev/null &
      pid=$!
      reg_add "$pid" run.sh "$id" ap-run
      set +m
      rm -f "$f"
      fappend "$AP/launched.tsv" "$pid$TAB$(date +%s)$TAB$id$TAB$role"
      LAUNCHED="$LAUNCHED${LAUNCHED:+$NL}$pid$TAB$(date +%s)$TAB$id$TAB$role"
      ev autopilot_launch "\"task\":$(jstr "$id"),\"role\":$(jstr "$role"),\"tool\":$(jstr "$RT"),\"pid\":$pid"
    fi
    ACTIVE_TASKS=$((ACTIVE_TASKS + 1)); B_RUNSD=$((B_RUNSD + 1))
  done
}
# dry-run only: entries dispatch would have queued are launched virtually (same limits as launch_queue)
launch_dry() {
  local role id
  while IFS=' ' read -r role id; do
    [ -n "$id" ] || continue
    rtool "$role"
    tool_paused "$RT" && break
    [ "$ACTIVE_TASKS" -ge "$C_MAXPAR" ] && break
    [ "$B_RUNSD" -ge "$C_MAXRUNS" ] && break
    in_quiet && break
    would "launch $role $id"
    printf '%s\n' "--- run.sh $role $id --dry-run ---"
    SUBDECK_AUTOPILOT=1 SUBDECK_AUTOPILOT_LAUNCH=1 SUBDECK_RUN_BASE="${S_branch:-HEAD}" bash "$RUN_SH" --project "$PROJECT" "$role" "$id" --dry-run 2>&1 | awk '/^argv:$/{f=1} /^env:$/{f=0} f'
    ACTIVE_TASKS=$((ACTIVE_TASKS + 1)); B_RUNSD=$((B_RUNSD + 1))
  done <<< "$QUEUE_DRY"
}
# step 8: manager turn
fingerprint() {
  local s
  s="$(printf '%s\n' "$TASKS" | awk -F"$SEP" '$13 != "true" && $1 != "" { print $1, $2, $14 }' | sort)"
  s="$s|$(printf '%s\n' "$TASKS" | awk -F"$SEP" '$13 == "true"' | grep -c .)|$(printf '%s\n' "$ACTIVE" | cut -d "$SEP" -f1 | grep . | sort | tr '\n' ' ')"
  FP="$(printf '%s' "$s" | cksum)"; FP="${FP%% *}"
}
cap_lines() { # max -> stdin capped with a cut marker
  awk -v m="$1" 'NR <= m { print } END { if (NR > m) printf "[... cut %d lines]\n", NR - m }'
}
build_prompt() { # -> stdout
  local rules="${SUBDECK_AUTOPILOT_PROMPT:-$HERE/autopilot-prompt.md}" id st title role tool model br wt sk nf vd q ar up tr bl n=0
  printf '# SubDeck autopilot turn %s\n' "$NOW_ISO"
  printf 'Project: %s\nBranch: %s (worktree %s, your cwd)\nTasks: %s --project %s\nAutopilot: %s --project %s\n\n' \
    "$PROJECT" "$S_branch" "$APWT" "$TASKS_SH" "$PROJECT" "$SELF" "$PROJECT"
  printf '## Rules\n'; tr -d '\r' < "$rules"; printf '\n'
  printf '## Limits now\nfree slots: %s\nruns left today: %s\nturns left today: %s\n' \
    "$(( C_MAXPAR - ACTIVE_TASKS > 0 ? C_MAXPAR - ACTIVE_TASKS : 0 ))" "$(( C_MAXRUNS - B_RUNSD > 0 ? C_MAXRUNS - B_RUNSD : 0 ))" "$(( C_MAXTURNS - B_TURNSD > 0 ? C_MAXTURNS - B_TURNSD : 0 ))"
  if [ "$C_TOKD" -gt 0 ]; then printf 'tokens left today: %s\n' "$(( C_TOKD - B_TOKD > 0 ? C_TOKD - B_TOKD : 0 ))"; else printf 'tokens left today: unlimited\n'; fi
  if [ "$C_TOKW" -gt 0 ]; then printf 'tokens left this week: %s\n' "$(( C_TOKW - B_TOKW > 0 ? C_TOKW - B_TOKW : 0 ))"; else printf 'tokens left this week: unlimited\n'; fi
  printf 'paused tools: %s\nquiet hours: %s\n\n' "${PAUSED_TOOLS:-none}" "${C_QUIET:-none}"
  printf '## Tasks\n'; tkr list --tsv | cap_lines 200; printf '\n'
  printf '## Ready\n'; tkr ready --tsv | cap_lines 100; printf '\n'
  printf '## Queue and active runs\n'
  for f in "$AP"/queue/*; do [ -f "$f" ] && printf 'queued %s\n' "${f##*/}"; done
  printf '%s\n' "$ACTIVE" | awk -F"$SEP" -v now="$NOW" 'NF > 1 { print $3, $4, $5, $1 }'
  printf '\n## Needs attention\n'
  { while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
      [ "$ar" = true ] && continue
      case "$st" in
        review) printf '### %s review\n' "$id"; tkr show "$id" --section verification | awk '/Verdict:/{b=""} {b=b $0 "\n"} END{printf "%s", b}' | tail -n 60 ;;
        interrupted) printf '### %s interrupted\n' "$id"; tkr show "$id" --section handoff | awk '/^### /{b=""} {b=b $0 "\n"} END{printf "%s", b}' | head -n 60 ;;
        blocked) printf '### %s blocked\n' "$id"; tkr show "$id" --section report | awk '/^### /{b=""} {b=b $0 "\n"} END{printf "%s", b}' | head -n 60 ;;
      esac
    done <<< "$TASKS"; } | cap_lines 400
  printf '\n## Since last turn\n'
  local lts=""; [ -n "$S_lastTurnStart" ] && { iso_of "$S_lastTurnStart"; lts="$ISO"; }
  [ -f "$AP/ledger.tsv" ] && awk -F'\t' -v t="$lts" '$1 >= t { print $4, $5, $6, $8, $9 }' "$AP/ledger.tsv" | cap_lines 100
  printf '\n## Project handoff\n'; [ -f "$PROJECT/HANDOFF.md" ] && head -n 200 "$PROJECT/HANDOFF.md" | tr -d '\r'
  printf '\n## Last digest\n'; local ld; ld="$(ls "$AP/digest" 2>/dev/null | sort | tail -n 1)"; [ -n "$ld" ] && head -n 150 "$AP/digest/$ld"
  printf '\n## Final reply\nEnd with `Launched: <role> <id>` lines, `Asked: <id>` lines, then `Stop: done|waiting|blocked - <why>`.\n'
}
manager_turn() {
  local rules="${SUBDECK_AUTOPILOT_PROMPT:-$HERE/autopilot-prompt.md}" pf live=0 n
  rtool manager; [ -n "$RT" ] || return 0
  [ "$ACTIVE_TURN" -gt 0 ] && return 0
  [ "$STATE_NAME" = paused ] && return 0
  tool_paused "$RT" && return 0
  in_quiet && return 0
  [ "$B_TURNSD" -lt "$C_MAXTURNS" ] || return 0
  [ $(( NOW - ${S_lastTurnEnd:-0} )) -ge $(( C_GAP * 60 )) ] || return 0
  fingerprint
  [ "$FP" != "$S_lastTurnFp" ] || return 0
  # work exists: a live task in open interrupted review blocked, or an empty queue with ready tasks
  n="$(printf '%s\n' "$TASKS" | awk -F"$SEP" '$13 != "true" && ($2 == "open" || $2 == "interrupted" || $2 == "review" || $2 == "blocked")' | grep -c .)"
  [ "$n" -gt 0 ] || return 0
  [ -n "$S_branch" ] && [ -d "$APWT" ] || return 0
  S_lastTurnFp="$FP"
  if [ ! -f "$rules" ]; then
    ev autopilot_turn_end "\"turnId\":null,\"status\":\"refused\",\"exit\":2,\"tokensIn\":0,\"tokensOut\":0,\"dirty\":false"
    return 0
  fi
  ACTIONS=$((ACTIONS + 1))
  if [ "$DRY" = 1 ]; then
    would "manager turn ($RT ${RM:-default}, fingerprint $FP)"
    printf -- '--- manager prompt ---\n'; build_prompt
    return 0
  fi
  mkdir -p "$AP/turns" 2>/dev/null
  pf="$AP/turns/$(date -u +%Y%m%dT%H%M%SZ).prompt.md"
  build_prompt | head -c 122880 > "$pf"
  set -m
  nohup env SUBDECK_AUTOPILOT=1 SUBDECK_PROJECT="$PROJECT" SUBDECK_RUN_BASE="$S_branch" bash "$RUN_SH" --project "$PROJECT" manager-turn --prompt-file "$pf" --cwd "$APWT" --out-dir "$AP/turns" >> "$AP/launch.log" 2>&1 < /dev/null &
  local pid=$!
  reg_add "$pid" run.sh manager-turn ap-run
  set +m
  fappend "$AP/launched.tsv" "$pid$TAB$(date +%s)$TAB-$TAB""manager"
  S_lastTurnStart="$NOW"; ACTIVE_TURN=1
  ev autopilot_turn_start "\"turnId\":$(jstr "${pf##*/}"),\"tool\":$(jstr "$RT"),\"model\":$(jstr "$RM"),\"fingerprint\":\"$FP\""
}
# step 9: digest
digest_text() {
  local id st title role tool model br wt sk nf vd q ar up tr bl any
  printf '# Autopilot digest %s (%s)\n\n' "$TODAY" "${PROJECT##*/}"
  printf 'State: %s%s, branch %s\n\n' "$STATE_NAME" "${REASONS:+ ($REASONS)}" "${S_branch:-none}"
  printf '## Needs you\n'; any=0
  while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
    [ "$st" = needs-user ] && [ "$ar" != true ] && { printf -- '- %s %s: %s\n' "$id" "$title" "$q"; any=1; }
  done <<< "$TASKS"; [ "$any" = 1 ] || printf 'none\n'
  printf '\n## Done and verified\n'; any=0
  while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
    [ "$ar" = true ] && [ "$st" = done ] || continue
    [ "${up:0:10}" = "$TODAY" ] || grep -q "^$TODAY[^$TAB]*$TAB$id$TAB" "$AP/integrated.tsv" 2>/dev/null || continue
    printf -- '- %s %s (%s)\n' "$id" "$title" "$(awk -F'\t' -v i="$id" '$2 == i { r = $3 } END { print (r == "" ? "none" : r) }' "$AP/integrated.tsv" 2>/dev/null)"; any=1
  done <<< "$TASKS"; [ "$any" = 1 ] || printf 'none\n'
  printf '\n## In review\n'; any=0
  while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
    [ "$st" = review ] && [ "$ar" != true ] && { printf -- '- %s %s\n' "$id" "$title"; any=1; }
  done <<< "$TASKS"; [ "$any" = 1 ] || printf 'none\n'
  printf '\n## Interrupted or blocked\n'; any=0
  while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
    case "$st" in interrupted|blocked) [ "$ar" != true ] || continue
      printf -- '- %s %s %s: %s\n' "$id" "$st" "$title" "$(tkr show "$id" --section "$( [ "$st" = blocked ] && echo report || echo handoff)" | grep '^### ' | tail -n 1)"; any=1 ;; esac
  done <<< "$TASKS"; [ "$any" = 1 ] || printf 'none\n'
  printf '\n## Budget\n'
  printf 'runs today %s of %s; turns today %s of %s; tokens today %s of %s; tokens this week %s of %s; runs this week %s of %s\n' \
    "$B_RUNSD" "$C_MAXRUNS" "$B_TURNSD" "$C_MAXTURNS" "$B_TOKD" "$( [ "$C_TOKD" = 0 ] && echo unlimited || echo "$C_TOKD")" \
    "$B_TOKW" "$( [ "$C_TOKW" = 0 ] && echo unlimited || echo "$C_TOKW")" "$B_RUNSW" "$( [ "$C_RUNSW" = 0 ] && echo unlimited || echo "$C_RUNSW")"
  printf 'runs with unknown token usage today: %s\n' "$B_UNKD"
  printf 'pauses: %s\n' "${S_pauses:-none}"
  printf '\n## Branch\n%s (base %s)\n' "${S_branch:-none}" "${S_base:-none}"
  [ -n "$S_branch" ] && [ -n "$S_base" ] && git -C "$PROJECT" log --oneline "$S_base..$S_branch" 2>/dev/null | head -n 50
  printf '\n## Manager notes\n'
  local lf; lf="$(ls "$AP/turns" 2>/dev/null | grep '\.final\.txt$' | sort | tail -n 1)"
  if [ -n "$lf" ]; then head -n 40 "$AP/turns/$lf"; printf '\n'; else printf 'none\n'; fi
}
digest() {
  local txt h
  txt="$(digest_text)"
  h="$(printf '%s' "$txt" | cksum)"; h="${h%% *}"
  if [ "$h" != "$S_digestHash" ] || [ ! -f "$AP/digest/$TODAY.md" ]; then
    ACTIONS=$((ACTIONS + 1))
    if [ "$DRY" = 1 ]; then would "digest $TODAY"; else mkdir -p "$AP/digest" 2>/dev/null; fwrite "$AP/digest/$TODAY.md" "$txt$NL"; fi
    S_digestHash="$h"
  fi
  if [ "$S_digestNotified" != "$TODAY" ] && [ "$LHOUR" -ge "$C_DIGESTH" ]; then
    S_digestNotified="$TODAY"
    notify done autopilot_digest
    ev autopilot_digest "\"date\":\"$TODAY\",\"path\":$(jstr "$AP/digest/$TODAY.md"),\"notified\":true"
  fi
}
# step 10: status.json
status_json() {
  local lp="" la=false pid ep k t u a first p next=null id st title role tool model br wt sk nf vd q ar up tr bl
  if [ -f "$AP/loop.pid" ]; then read -r pid ep < "$AP/loop.pid"; [[ $pid =~ ^[0-9]+$ ]] && { lp="$pid"; kill -0 "$pid" 2>/dev/null && la=true; }; fi
  [ "$la" = true ] && { iso_of $(( NOW + C_TICK )); next="\"$ISO\""; }
  printf '{"version":1,"project":%s,"enabled":%s,"state":"%s","reasons":[' "$(jstr "$PROJECT")" "$( [ "$C_ENABLED" = on ] && echo true || echo false)" "$STATE_NAME"
  first=1; local -a rr; IFS=, read -ra rr <<< "$REASONS"
  for p in ${rr[@]+"${rr[@]}"}; do [ "$first" = 1 ] || printf ','; first=0; jstr "$p"; done
  printf '],"loopPid":%s,"loopAlive":%s,"branch":%s,"base":%s,"worktree":%s,"lastTickAt":"%s","nextTickAt":%s,' \
    "${lp:-null}" "$la" "$(jstr "$S_branch")" "$(jstr "$S_base")" "$(jstr "$( [ -n "$S_branch" ] && printf '%s' "$APWT")")" "$NOW_ISO" "$next"
  local ls="" le=""; [ -n "$S_lastTurnStart" ] && { iso_of "$S_lastTurnStart"; ls="$ISO"; }; [ -n "$S_lastTurnEnd" ] && { iso_of "$S_lastTurnEnd"; le="$ISO"; }
  printf '"turn":{"active":%s,"lastStart":%s,"lastEnd":%s,"lastStatus":%s},' "$( [ "$ACTIVE_TURN" -gt 0 ] && echo true || echo false)" \
    "$( [ -n "$ls" ] && printf '"%s"' "$ls" || printf null)" "$( [ -n "$le" ] && printf '"%s"' "$le" || printf null)" "$( [ -n "$S_lastTurnStatus" ] && jstr "$S_lastTurnStatus" || printf null)"
  printf '"active":['; first=1
  while IFS="$SEP" read -r rid kind task role tool pid sa f; do
    [ "$kind" = task ] || continue
    local idle=0; mtime "${f%.json}.log"; [ -n "$MT" ] && idle=$(( (NOW - MT) / 60 )); [ "$idle" -lt 0 ] && idle=0
    [ "$first" = 1 ] || printf ','; first=0
    printf '{"task":%s,"role":%s,"tool":%s,"runId":%s,"startedAt":%s,"idleMinutes":%s}' "$(jstr "$task")" "$(jstr "$role")" "$(jstr "$tool")" "$(jstr "$rid")" "$( [ -n "$sa" ] && jstr "$sa" || printf null)" "$idle"
  done <<< "$ACTIVE"
  printf '],"queue":['; first=1
  for f in "$AP"/queue/*; do
    [ -f "$f" ] || continue
    qparse "${f##*/}"; iso_of "$Q_EPOCH"; [ "$first" = 1 ] || printf ','; first=0
    printf '{"task":%s,"role":%s,"queuedAt":"%s"}' "$(jstr "$Q_ID")" "$(jstr "$Q_ROLE")" "$ISO"
  done
  printf '],"pauses":['; first=1
  local -a pa; IFS=, read -ra pa <<< "$S_pauses"
  for p in ${pa[@]+"${pa[@]}"}; do
    IFS=: read -r k t u a <<< "$p"
    [ "$k" = quota ] && [ "${u:-0}" -le "$NOW" ] && continue
    [ "$first" = 1 ] || printf ','; first=0
    local uj=null; [ "${u:-0}" -gt 0 ] && { iso_of "$u"; uj="\"$ISO\""; }
    printf '{"kind":"%s","tool":%s,"until":%s}' "$k" "$(jstr "$t")" "$uj"
  done
  for p in $BUDGET_PAUSES; do
    [ "$first" = 1 ] || printf ','; first=0
    if [ "$p" = budget-day ]; then iso_of "$NEXT_DAY"; else iso_of "$NEXT_WEEK"; fi
    printf '{"kind":"budget","tool":"*","until":"%s"}' "$ISO"
  done
  printf '],"budget":{"day":{"runs":%s,"runsLimit":%s,"turns":%s,"turnsLimit":%s,"tokens":%s,"tokensLimit":%s,"unknownRuns":%s},' \
    "$B_RUNSD" "$C_MAXRUNS" "$B_TURNSD" "$C_MAXTURNS" "$B_TOKD" "$C_TOKD" "$B_UNKD"
  printf '"week":{"runs":%s,"runsLimit":%s,"tokens":%s,"tokensLimit":%s}},' "$B_RUNSW" "$C_RUNSW" "$B_TOKW" "$C_TOKW"
  printf '"needsUser":['; first=1
  while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
    [ "$st" = needs-user ] && [ "$ar" != true ] || continue
    local asked="" by=""
    asked="$(tkr show "$id" --section question | grep '^### .* asked (' | tail -n 1)"
    by="${asked#*asked (}"; by="${by%%,*}"; asked="${asked#\#\#\# }"; asked="${asked%% *}"
    [ "$first" = 1 ] || printf ','; first=0
    printf '{"task":%s,"title":%s,"question":%s,"askedAt":%s,"by":%s}' "$(jstr "$id")" "$(jstr "$title")" "$(jstr "$q")" "$( [ -n "$asked" ] && jstr "$asked" || printf null)" "$(jstr "$by")"
  done <<< "$TASKS"
  printf '],"digests":['; first=1
  for p in $(ls "$AP/digest" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' | sort -r | head -n 14); do
    [ "$first" = 1 ] || printf ','; first=0; printf '"%s"' "${p%.md}"
  done
  printf '],"integrated":['; first=1
  if [ -f "$AP/integrated.tsv" ]; then
    while IFS="$TAB" read -r at id res tip; do
      [ -n "$id" ] || continue; [ "$first" = 1 ] || printf ','; first=0
      printf '{"task":%s,"result":%s,"at":%s}' "$(jstr "$id")" "$(jstr "$res")" "$(jstr "$at")"
    done < <(tail -n 20 "$AP/integrated.tsv")
  fi
  printf ']}\n'
}

# compute pauses and state (step 6) -> STATE_NAME REASONS BUDGET_PAUSES PAUSED_TOOLS
compute_state() {
  local p k t u a old="$S_stateLine"; local -a arr
  REASONS=""; BUDGET_PAUSES=""; PAUSED_TOOLS=""
  budget_compute
  # expired quota pauses resume
  IFS=, read -ra arr <<< "$S_pauses"
  for p in ${arr[@]+"${arr[@]}"}; do
    IFS=: read -r k t u a <<< "$p"
    if [ "$k" = quota ] && [ "${u:-0}" -gt 0 ] && [ "$u" -le "$NOW" ]; then
      pause_set quota "$t" 0 "$a"
      ev autopilot_quota "\"tool\":$(jstr "$t"),\"until\":null,\"attempts\":${a:-0},\"action\":\"resume\""
    fi
  done
  IFS=, read -ra arr <<< "$S_pauses"
  for p in ${arr[@]+"${arr[@]}"}; do
    IFS=: read -r k t u a <<< "$p"
    case "$k" in
      quota) [ "${u:-0}" -gt "$NOW" ] && { add_reason "quota:$t"; PAUSED_TOOLS="$PAUSED_TOOLS${PAUSED_TOOLS:+, }$t until $(iso_of "$u"; printf '%s' "$ISO")"; } ;;
      auth) add_reason "auth:$t"; PAUSED_TOOLS="$PAUSED_TOOLS${PAUSED_TOOLS:+, }$t (login needed)" ;;
      manual) add_reason "$t" ;;
    esac
  done
  local loop=0
  case ",$REASONS," in *",manager-dirty,"*|*",integration,"*) loop=1 ;; esac
  if [ "$C_TOKD" -gt 0 ] && [ "$B_TOKD" -ge "$C_TOKD" ]; then BUDGET_PAUSES="budget-day"; fi
  if { [ "$C_TOKW" -gt 0 ] && [ "$B_TOKW" -ge "$C_TOKW" ]; } || { [ "$C_RUNSW" -gt 0 ] && [ "$B_RUNSW" -ge "$C_RUNSW" ]; }; then BUDGET_PAUSES="$BUDGET_PAUSES budget-week"; fi
  for p in $BUDGET_PAUSES; do add_reason "$p"; loop=1; done
  in_quiet && { add_reason quiet; loop=1; }
  if [ "$loop" = 1 ]; then STATE_NAME=paused
  elif [ $((ACTIVE_TASKS + ACTIVE_TURN)) -gt 0 ] || [ -n "$(ls "$AP/queue" 2>/dev/null)" ] || [ -n "$READY" ] \
       || printf '%s\n' "$TASKS" | awk -F"$SEP" '$13 != "true" && ($2 == "interrupted" || $2 == "review")' | grep -q .; then STATE_NAME=running
  else STATE_NAME=idle; fi
  # budget pause / resume events (on change)
  local nb=" $BUDGET_PAUSES "
  for p in budget-day budget-week; do
    case "$old" in *"$p"*) case "$nb" in *" $p "*) ;; *) ev autopilot_budget "\"scope\":\"${p#budget-}\",\"metric\":\"tokens\",\"used\":$( [ "$p" = budget-day ] && echo "$B_TOKD" || echo "$B_TOKW"),\"limit\":$( [ "$p" = budget-day ] && echo "$C_TOKD" || echo "$C_TOKW"),\"action\":\"resume\"" ;; esac ;;
      *) case "$nb" in *" $p "*) ev autopilot_budget "\"scope\":\"${p#budget-}\",\"metric\":\"tokens\",\"used\":$( [ "$p" = budget-day ] && echo "$B_TOKD" || echo "$B_TOKW"),\"limit\":$( [ "$p" = budget-day ] && echo "$C_TOKD" || echo "$C_TOKW"),\"action\":\"pause\"" ;; esac ;; esac
  done
}
state_event() { # emit autopilot_state when state or reasons changed
  local line="$STATE_NAME|$REASONS"
  [ "$line" = "$S_stateLine" ] && return 0
  S_stateLine="$line"
  local rj="" p first=1; local -a rr; IFS=, read -ra rr <<< "$REASONS"
  for p in ${rr[@]+"${rr[@]}"}; do rj="$rj$( [ "$first" = 1 ] || printf ',')$(jstr "$p")"; first=0; done
  ev autopilot_state "\"state\":\"$STATE_NAME\",\"reasons\":[$rj],\"branch\":$(jstr "$S_branch")"
}

tick() {
  QUEUE_DRY=""
  if [ "$DRY" = 0 ]; then lock_take 0 || return 0; fi
  [ "$DRY" = 0 ] && mkdir -p "$AP" 2>/dev/null
  state_load; cfg_load; roles_load; launched_load
  metas_load; active_load; tasks_load
  if killed || [ "$C_ENABLED" != on ]; then
    budget_compute
    if killed; then STATE_NAME=stopped; REASONS=""; [ -f "$GSTOP" ] && add_reason global-stop; else STATE_NAME=disabled; REASONS=""; fi
    BUDGET_PAUSES=""
    state_event
  else
    collect_finished
    [ "$ACTIONS" -gt 0 ] && { tasks_load; metas_load; active_load; }
    health_check
    strike_rule; [ "$ACTIONS" -gt 0 ] && tasks_load
    integrate
    compute_state
    state_event
    if [ "$STATE_NAME" != paused ]; then
      dispatch
      launch_queue; [ "$DRY" = 1 ] && launch_dry
      [ "$ACTIONS" -gt 0 ] && tasks_load
      manager_turn
    fi
    digest
  fi
  S_lastTickAt="$NOW_ISO"
  if [ "$DRY" = 0 ]; then
    fwrite "$AP/status.json" "$(status_json)$NL"
    state_save
    if [ "$ACTIONS" -gt 0 ]; then
      ev_quiet autopilot_tick "\"actions\":$ACTIONS,\"active\":$ACTIVE_TASKS,\"queued\":$(ls "$AP/queue" 2>/dev/null | grep -c .),\"state\":\"$STATE_NAME\""
    fi
  fi
  lock_release
  return 0
}

# =====================================================================================================================
# commands
# =====================================================================================================================
loop_alive() { LOOP_PID=""; [ -f "$AP/loop.pid" ] || return 1; read -r LOOP_PID _ < "$AP/loop.pid"; [[ $LOOP_PID =~ ^[0-9]+$ ]] && kill -0 "$LOOP_PID" 2>/dev/null; }

cmd_start() {
  local fail=0 j br cur tw mw
  [ -f "$GSTOP" ] && die 3 "global kill switch $GSTOP is present; remove it by hand to allow the autopilot"
  cfg_load; roles_load
  [ "$C_ENABLED" = on ] || { printf 'autopilot.sh: autopilot.enabled is off for this project (settings.sh set autopilot.enabled=on --project)\n' >&2; fail=1; }
  if ! git -C "$PROJECT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then printf 'autopilot.sh: %s is not a git repository with a commit\n' "$PROJECT" >&2; fail=1; fi
  for r in manager worker verifier; do rtool "$r"; [ -n "$RT" ] || { printf 'autopilot.sh: roles.%s is not mapped (settings.sh set roles.%s.tool=<cli>)\n' "$r" "$r" >&2; fail=1; }; done
  rtool worker; tw="$RT/${RM:-default}"; rtool verifier
  [ -n "$RT" ] && [ "$tw" = "$RT/${RM:-default}" ] && printf 'autopilot.sh: warning: the verifier uses the same tool and model as the worker (%s); run.sh will refuse verifier runs of that worker\n' "$tw" >&2
  [ "$C_NOTIFY" = on ] || printf 'autopilot.sh: warning: notifications are off: you will not hear about needs-user\n' >&2
  [ "$fail" = 0 ] || exit 2
  mkdir -p "$AP" 2>/dev/null || die 2 "cannot create $AP"
  loop_alive && die 4 "a live autopilot loop exists (pid $LOOP_PID)"
  lock_take 5 || die 4 "autopilot lock busy"
  rm -f "$AP/STOP"
  state_load
  cur="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$OPT_NEW" = 1 ] || [ -z "$S_branch" ]; then
    if [ "$OPT_NEW" = 1 ]; then
      # a new dated branch: -2, -3 ... when the name is taken
      br="autopilot/$TODAYC"; local n=2
      while git -C "$PROJECT" rev-parse --verify --quiet "refs/heads/$br" >/dev/null 2>&1; do br="autopilot/$TODAYC-$n"; n=$((n + 1)); done
    else
      br="${C_BRANCH:-autopilot/$TODAYC}"   # an existing branch of that name is reused (never reset)
    fi
    [ "$br" = "$cur" ] && { lock_release; die 2 "autopilot.branch $br is the current branch of $PROJECT; choose another one"; }
    case "$br" in main|master) lock_release; die 2 "the autopilot branch may not be $br" ;; esac
    if [ "$OPT_NEW" = 1 ] && [ -d "$APWT" ]; then
      [ -n "$(git -C "$APWT" status --porcelain 2>/dev/null)" ] && { lock_release; die 2 "the autopilot worktree $APWT has uncommitted changes"; }
      git -C "$PROJECT" worktree remove "$APWT" >/dev/null 2>&1 || { lock_release; die 2 "could not remove the old autopilot worktree $APWT"; }
    fi
    mkdir -p "${APWT%/*}" 2>/dev/null
    git -C "$PROJECT" worktree prune >/dev/null 2>&1
    if git -C "$PROJECT" rev-parse --verify --quiet "refs/heads/$br" >/dev/null 2>&1; then
      [ -d "$APWT" ] || git -C "$PROJECT" worktree add -q "$APWT" "$br" >/dev/null 2>&1 || { lock_release; die 2 "git worktree add $APWT $br failed"; }
    else
      git -C "$PROJECT" worktree add -q -b "$br" "$APWT" HEAD >/dev/null 2>&1 || { lock_release; die 2 "git worktree add -b $br failed"; }
    fi
    S_branch="$br"; S_base="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null)"; S_worktree="$APWT"; S_startedAt="$NOW_ISO"
    S_lastTurnFp=""
  else
    [ "$S_branch" = "$cur" ] && { lock_release; die 2 "autopilot branch $S_branch is the current branch of $PROJECT"; }
    if [ ! -d "$APWT" ]; then
      git -C "$PROJECT" worktree prune >/dev/null 2>&1
      git -C "$PROJECT" worktree add -q "$APWT" "$S_branch" >/dev/null 2>&1 || { lock_release; die 2 "git worktree add $APWT $S_branch failed"; }
    fi
  fi
  S_stateLine="starting"
  state_save
  lock_release
  set -m
  nohup bash "$SELF" --project "$PROJECT" _loop >> "$AP/loop.log" 2>&1 < /dev/null &
  local pid=$!
  reg_add "$pid" autopilot.sh loop ap-loop
  set +m
  printf '%s %s\n' "$pid" "$NOW" > "$AP/loop.pid"
  ev_quiet autopilot_state "\"state\":\"running\",\"reasons\":[],\"branch\":$(jstr "$S_branch")"
  printf 'autopilot started: pid %s, branch %s\n' "$pid" "$S_branch"
}
cmd_stop() {
  local rid kind task role tool pid sa f
  mkdir -p "$AP" 2>/dev/null
  printf '%s stop\n' "$NOW_ISO" > "$AP/STOP"
  reg_kill ap-loop   # registry only: alive + start time matches (never by name)
  if [ "$OPT_NOW" = 1 ]; then reg_kill ap-run; fi
  state_load
  ev_quiet autopilot_state "\"state\":\"stopped\",\"reasons\":[],\"branch\":$(jstr "$S_branch")"
  printf 'autopilot stopped%s\n' "$( [ "$OPT_NOW" = 1 ] && printf ' (active runs cancelled)')"
}
cmd_status() {
  DRY=1   # read-only refresh
  state_load; cfg_load; roles_load; launched_load; metas_load; active_load; tasks_load
  if killed; then STATE_NAME=stopped; REASONS=""; budget_compute; BUDGET_PAUSES=""
  elif [ "$C_ENABLED" != on ]; then STATE_NAME=disabled; REASONS=""; budget_compute; BUDGET_PAUSES=""
  else compute_state >/dev/null; fi
  local js; js="$(status_json)"
  if [ "$OPT_JSON" = 1 ]; then printf '%s\n' "$js"
  else
    printf 'autopilot: %s%s\n' "$STATE_NAME" "${REASONS:+ ($REASONS)}"
    printf 'branch: %s\n' "${S_branch:-none}"
    loop_alive && printf 'loop: pid %s, next tick in about %s s\n' "$LOOP_PID" "$C_TICK" || printf 'loop: not running\n'
    local rl; rl="$(reg_list)"
    if [ -n "$rl" ]; then printf 'processes (registry, alive): pid name task owner\n'; while IFS= read -r line; do printf '  %s\n' "$line"; done <<< "$rl"; else printf 'processes: none\n'; fi
    printf 'active: %s run(s)%s\n' "$ACTIVE_TASKS" "$( [ "$ACTIVE_TURN" -gt 0 ] && printf ', manager turn')"
    printf 'queue: %s\n' "$(ls "$AP/queue" 2>/dev/null | grep -c .)"
    printf 'budget today: runs %s/%s, turns %s/%s, tokens %s/%s\n' "$B_RUNSD" "$C_MAXRUNS" "$B_TURNSD" "$C_MAXTURNS" "$B_TOKD" "$( [ "$C_TOKD" = 0 ] && echo unlimited || echo "$C_TOKD")"
    local id st title role tool model br wt sk nf vd q ar up tr bl n=0
    while IFS="$SEP" read -r id st title role tool model br wt sk nf vd q ar up tr bl; do
      [ "$st" = needs-user ] && [ "$ar" != true ] && { printf 'needs you: %s %s: %s\n' "$id" "$title" "$q"; n=$((n + 1)); }
    done <<< "$TASKS"
    [ "$n" = 0 ] && printf 'needs you: none\n'
  fi
  [ "$C_ENABLED" = on ] || exit 2
  exit 0
}
cmd_launch() {
  local role="${POS[1]:-}" id="${POS[2]:-}"
  [ ${#POS[@]} -eq 3 ] || die 2 "usage: autopilot.sh launch <role> <task-id>"
  lock_take 5 || { printf 'refused: lock busy\n'; exit 4; }
  cfg_load; roles_load; launched_load; metas_load; active_load; tasks_load
  local reason=""
  if killed; then reason=stopped
  elif ! validate_launch "$role" "$id"; then reason="$VREASON"
  elif queued "$id"; then reason="already queued"
  elif is_active "$id"; then reason="already active"; fi
  if [ -n "$reason" ]; then
    ev_quiet autopilot_queue "\"task\":$(jstr "$id"),\"role\":$(jstr "$role"),\"result\":\"refused\",\"reason\":$(jstr "$reason")"
    lock_release; printf 'refused: %s\n' "$reason"; exit 2
  fi
  local seq=0 f
  mkdir -p "$AP/queue" 2>/dev/null
  while :; do printf -v f '%s/queue/%s-%04d-%s-%s' "$AP" "$NOW" "$seq" "$id" "$role"; [ -e "$f" ] || break; seq=$((seq + 1)); done
  : > "$f"
  ev_quiet autopilot_queue "\"task\":$(jstr "$id"),\"role\":$(jstr "$role"),\"result\":\"queued\",\"reason\":\"\""
  lock_release
  printf 'queued\n'
}
cmd_resume() {
  lock_take 5 || die 4 "autopilot lock busy"
  state_load
  local p k t u a out=""; local -a arr
  IFS=, read -ra arr <<< "$S_pauses"
  for p in ${arr[@]+"${arr[@]}"}; do
    IFS=: read -r k t u a <<< "$p"
    case "$k" in
      auth) [ -z "$OPT_TOOL" ] || [ "$OPT_TOOL" = "$t" ] && continue ;;
      manual) [ -z "$OPT_TOOL" ] && continue ;;
    esac
    out="$out${out:+,}$p"
  done
  S_pauses="$out"; state_save; lock_release
  printf 'resumed%s\n' "${OPT_TOOL:+ ($OPT_TOOL)}"
}
cmd_loop() {
  local i
  trap 'rm -f "$AP/loop.pid"; exit 0' TERM INT HUP
  while ! killed; do
    NOW="$(date +%s)"
    bash "$SELF" --project "$PROJECT" tick >/dev/null 2>&1
    cfg_load
    i=0; while [ "$i" -lt $(( (C_TICK + 4) / 5 )) ]; do killed && break; sleep 5 & wait $!; i=$((i + 1)); done
  done
  rm -f "$AP/loop.pid"
}

case "$CMD" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  tick) [ ${#POS[@]} -eq 1 ] || die 2 "$USAGE"; tick; exit 0 ;;
  dry-run) tick; exit 0 ;;
  launch) cmd_launch ;;
  resume) cmd_resume ;;
  _loop) cmd_loop ;;
  *) die 2 "$USAGE" ;;
esac
exit 0
