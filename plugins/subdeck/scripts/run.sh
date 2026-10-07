#!/usr/bin/env bash
# SubDeck headless runs: hand one task to the CLI mapped to a role (roles.<role> in the SubDeck config), in the
# foreground, and record the result. The manager starts this script in the background. Bash 3.2+, bash + awk + sed + git.
#
# Usage:
#   run.sh [--project <dir>] <role> <task-id> [--worktree|--no-worktree] [--dry-run] [--timeout S]
#   run.sh [--project <dir>] roles [--json]            effective role mapping (TSV: role class tool model timeout source)
#   run.sh [--project <dir>] tail <task-id> [--lines N] latest run of a task: meta header, then the .log and .out tails
#   run.sh [--project <dir>] cleanup <task-id> [--force] remove the task worktree (the branch subdeck/<id> is kept)
# --project defaults to $CLAUDE_PROJECT_DIR, else the current directory.
#
# Safety: workers run in a git worktree <state>/worktrees/<id> on branch subdeck/<id> by default; the CLI gets the
# restrictive flags of scripts/run-profiles.txt (the only place for CLI flags), a push blocker in its git config env, and
# its stdin from the prompt file or /dev/null. The prompt never passes through a shell (one argv element or a file).
# After every run the changed paths are checked against the task's writable list (violation: task blocked, exit 5;
# nothing is reverted). run.sh never commits, merges, pushes, rebases or deletes branches.
# Exit codes: 0 ok, 1 failed, 2 usage/config/unmapped/unknown or archived task/deny-listed args/manager role,
#   3 verifier would be the same model as the producer, 4 busy (a run of this task is active), 5 writable violation,
#   6 auth, 7 quota, 124 timeout, 127 CLI not on PATH, 130 cancelled.
# Files: <state>/runs/<id>/<ts>.{log,out,prompt.md,final.txt,last.txt,json} (ts = YYYYMMDDTHHMMSSZ, UTC).
# Env (tests): SUBDECK_ROLES_DIR = rulebook dir (default scripts/roles).

LC_COLLATE=C
HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
HERE="$(cd "$HERE" 2>/dev/null && pwd)"
. "$HERE/lib-paths.sh" 2>/dev/null || { echo "run.sh: lib-paths.sh missing" >&2; exit 2; }
TASKS_SH="$HERE/tasks.sh"
LOG_EVENT="$HERE/log-event.sh"
SETTINGS_SH="$HERE/settings.sh"
PROFILES="$HERE/run-profiles.txt"
ROLES_DIR="${SUBDECK_ROLES_DIR:-$HERE/roles}"

US=$'\037'; NL=$'\n'; TAB=$'\t'
FIXED_ROLES="manager worker worker-heavy researcher verifier"
TOOLS="claude codex gemini agy opencode copilot custom"
ROLE_RE='^[a-z][a-z0-9-]{0,23}$'
ID_RE='^t-[0-9a-f]{4,12}$'
MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$'
DEFAULT_TIMEOUT=1800

die() { printf 'run.sh: %s\n' "$2" >&2; exit "$1"; }
warn() { printf 'run.sh: warning: %s\n' "$1" >&2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_s() { printf -v "$1" '%(%s)T' -1 2>/dev/null || printf -v "$1" '%s' "$(date +%s)"; }
jesc() { # STR -> JE (JSON string body; other control characters dropped)
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$TAB/\\t}"; s="${s//$NL/\\n}"; s="${s//$'\r'/}"
  case "$s" in *[[:cntrl:]]*) s="$(printf '%s' "$s" | tr -d '\000-\037')" ;; esac
  JE="$s"
}
jstr() { jesc "$1"; printf '"%s"' "$JE"; }
jnum() { if [ -n "$1" ]; then printf '%s' "$1"; else printf 'null'; fi; }

# ---------- arguments ----------
PROJECT=""; POS=(); WT_MODE=""; DRY=0; TIMEOUT_OVR=""; JSON=0; LINES=""; FORCE=0; BADOPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die 2 "--project needs a directory"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --worktree) WT_MODE=yes; shift ;;
    --no-worktree) WT_MODE=no; shift ;;
    --dry-run) DRY=1; shift ;;
    --timeout) [ $# -ge 2 ] || die 2 "--timeout needs seconds"; TIMEOUT_OVR="$2"; shift 2 ;;
    --timeout=*) TIMEOUT_OVR="${1#--timeout=}"; shift ;;
    --json) JSON=1; shift ;;
    --lines) [ $# -ge 2 ] || die 2 "--lines needs a number"; LINES="$2"; shift 2 ;;
    --lines=*) LINES="${1#--lines=}"; shift ;;
    --force) FORCE=1; shift ;;
    --*) BADOPT="$1"; shift ;;
    *) POS[${#POS[@]}]="$1"; shift ;;
  esac
done
USAGE='usage: run.sh [--project <dir>] <role> <task-id> [--worktree|--no-worktree] [--dry-run] [--timeout S] | roles [--json] | tail <task-id> [--lines N] | cleanup <task-id> [--force]'
[ -n "$BADOPT" ] && die 2 "unknown option $BADOPT ($USAGE)"
[ ${#POS[@]} -gt 0 ] || die 2 "$USAGE"

[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-}"
[ -n "$PROJECT" ] || PROJECT="$(pwd)"
[ -d "$PROJECT" ] || die 2 "project directory not found: $PROJECT"
PROJECT="$(cd "$PROJECT" && pwd)"
sd_state_dir "$PROJECT"
STATE="$SD_STATE"; LEGACY="$SD_LEGACY"
sd_platform; PLAT="$SD_PLAT"

# ---------- config: roles ----------
# one awk pass per config file -> lines <scope>US<role>US<field>US<value> (field "" = the role object exists)
CFG_AWK='
function emit(r, f, v) { printf "%s\037%s\037%s\037%s\n", SC, r, f, v }
function u8(c) {
  if (c < 128) return sprintf("%c", c)
  if (c < 2048) return sprintf("%c%c", 192 + int(c / 64), 128 + c % 64)
  return sprintf("%c%c%c", 224 + int(c / 4096), 128 + int(c / 64) % 64, 128 + c % 64)
}
BEGIN { RS = "\001"; hx = "0123456789abcdef" }
{
  t = $0; n = length(t); i = 1; d = 0
  while (i <= n) {
    c = substr(t, i, 1)
    if (c == "{" || c == "[") {
      d++; ty[d] = (c == "{") ? "o" : "a"; ek[d] = (c == "{"); key[d] = ""
      if (c == "{" && d == 3 && ty[1] == "o" && ty[2] == "o" && key[1] == "roles") emit(key[2], "", "")
      i++
    } else if (c == "}" || c == "]") { d--; i++ }
    else if (c == ",") { if (d > 0 && ty[d] == "o") ek[d] = 1; i++ }
    else if (c == ":") { i++ }
    else if (c == "\"") {
      i++; s = ""
      while (i <= n) {
        c = substr(t, i, 1)
        if (c == "\\") {
          e = substr(t, i + 1, 1); i += 2
          if (e == "u") {
            code = 0
            for (k = 0; k < 4; k++) code = code * 16 + index(hx, tolower(substr(t, i + k, 1))) - 1
            i += 4
            s = s ((code < 32) ? "\002" : u8(code))
          } else if (e == "n" || e == "t" || e == "r" || e == "b" || e == "f") s = s "\002"
          else s = s e
        } else if (c == "\"") { i++; break }
        else { s = s c; i++ }
      }
      if (d > 0 && ty[d] == "o" && ek[d]) { key[d] = s; ek[d] = 0 }
      else if (d == 3 && ty[3] == "o" && key[1] == "roles" && ty[2] == "o") emit(key[2], key[3], s)
    } else if (c ~ /[-0-9a-zA-Z.+]/) {
      lit = ""
      while (i <= n) { c = substr(t, i, 1); if (c ~ /[-0-9a-zA-Z.+]/) { lit = lit c; i++ } else break }
      if (d == 3 && ty[3] == "o" && key[1] == "roles" && ty[2] == "o") emit(key[2], key[3], (lit == "null") ? "" : lit)
    } else i++
  }
}'
CFG_ROWS=""
load_config() {
  local f sc
  for sc in p l u; do
    case "$sc" in p) f="$STATE/config.json" ;; l) f="$LEGACY/config.json" ;; u) f="${HOME}/.subdeck/config.json" ;; esac
    [ -f "$f" ] || continue
    CFG_ROWS="$CFG_ROWS$(LC_ALL=C awk -v SC="$sc" "$CFG_AWK" "$f" 2>/dev/null)$NL"
  done
}
# resolve_role ROLE -> R_SCOPE (p|l|u|"") R_SOURCE R_TOOL R_MODEL R_ARGS R_CMD R_TIMEOUT (raw)
resolve_role() {
  local r="$1" sc line s rr f v
  R_SCOPE=""; R_TOOL=""; R_MODEL=""; R_ARGS=""; R_CMD=""; R_TIMEOUT=""; R_SOURCE=default
  for sc in p l u; do
    while IFS="$US" read -r s rr f v; do
      [ "$s" = "$sc" ] && [ "$rr" = "$r" ] || continue
      R_SCOPE="$sc"
      case "$f" in tool) R_TOOL="$v" ;; model) R_MODEL="$v" ;; args) R_ARGS="$v" ;; cmd) R_CMD="$v" ;; timeout) R_TIMEOUT="$v" ;; esac
    done <<< "$CFG_ROWS"
    [ -n "$R_SCOPE" ] && break
  done
  case "$R_SCOPE" in p|l) R_SOURCE=project ;; u) R_SOURCE=user ;; esac
}
role_class() { # ROLE -> CLASS
  case "$1" in
    manager) CLASS=manager ;;
    verifier*) CLASS=verifier ;;
    research*) CLASS=researcher ;;
    *) CLASS=worker ;;
  esac
}
all_roles() { # -> ROLE_LIST (fixed first, then free roles from any config, sorted)
  local extra s r f v
  extra="$(while IFS="$US" read -r s r f v; do
    [ -n "$r" ] || continue
    [[ $r =~ $ROLE_RE ]] || continue
    case " $FIXED_ROLES " in *" $r "*) continue ;; esac
    printf '%s\n' "$r"
  done <<< "$CFG_ROWS" | sort -u)"
  ROLE_LIST="$FIXED_ROLES $(printf '%s' "$extra" | tr '\n' ' ')"
}

# ---------- profiles ----------
load_profiles() {
  local line re='^[[:space:]]*([a-z_]+)\.([a-z_]+)=(.*)$'
  [ -f "$PROFILES" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ $line =~ $re ]] || continue
    printf -v "PF_${BASH_REMATCH[1]}__${BASH_REMATCH[2]}" '%s' "${BASH_REMATCH[3]}"
    eval "PFSET_${BASH_REMATCH[1]}__${BASH_REMATCH[2]}=1"
  done < "$PROFILES"
  return 0
}
pget() { # tool field -> PV (tool value, else the "_" default, else "")
  local isset
  eval "isset=\${PFSET_${1}__${2}:-}"
  if [ -n "$isset" ]; then eval "PV=\${PF_${1}__${2}}"; return 0; fi
  eval "isset=\${PFSET____${2}:-}"
  if [ -n "$isset" ]; then eval "PV=\${PF____${2}}"; return 0; fi
  PV=""
}
sq() { # STR -> SQ (single-quoted for bash)
  SQ="'${1//\'/\'\\\'\'}'"
}
# subst TOKEN [quote] -> SUB: single left-to-right pass; inserted values are never scanned again
subst() {
  local t="$1" q="${2:-}" out="" name val
  while :; do
    case "$t" in *"{"*"}"*) ;; *) out="$out$t"; break ;; esac
    out="$out${t%%\{*}"; t="${t#*\{}"
    name="${t%%\}*}"
    val=""; local known=1
    case "$name" in
      model) val="$V_MODEL" ;; cwd) val="$V_CWD" ;; prompt) val="$V_PROMPT" ;; prompt_file) val="$V_PROMPT_FILE" ;;
      last_file) val="$V_LAST_FILE" ;; cmd) [ -z "$q" ] && val="$V_CMD" || known=0 ;;
      sp) [ -z "$q" ] && val=" " || known=0 ;; empty) [ -z "$q" ] && val="" || known=0 ;;
      *) known=0 ;;
    esac
    if [ "$known" = 1 ]; then
      if [ -n "$q" ]; then sq "$val"; val="$SQ"; fi
      out="$out$val"; t="${t#*\}}"
    else
      out="$out{"
    fi
  done
  SUB="$out"
}
# add_tokens LIST: split on whitespace, substitute each token, append to ARGV_OUT
add_tokens() {
  local tok
  local -a toks
  read -ra toks <<< "$1"
  for tok in ${toks[@]+"${toks[@]}"}; do subst "$tok"; ARGV_OUT[${#ARGV_OUT[@]}]="$SUB"; done
}
# split_user_args ARGS -> UARGS array ({sp} = literal space)
split_user_args() {
  local tok
  local -a toks
  UARGS=()
  read -ra toks <<< "$1"
  for tok in ${toks[@]+"${toks[@]}"}; do UARGS[${#UARGS[@]}]="${tok//\{sp\}/ }"; done
}
# deny_check ARGS -> 0 ok, 1 denied (DENIED = the token). settings.sh applies the same rule to the same list
# (_.deny_args). A token (lower-case) is denied when any of these matches a pattern: the token; the token with spaces
# ({sp}) as "="; "<previous token>=<token>"; the flag part before "=" (so --auto=true is --auto); and a single-dash
# cluster of short flags (-sy) containing a denied one-letter flag (-y).
deny_check() {
  local tok pat low lpat prev="" c2 c3 c4
  local -a pats
  pget _ deny_args
  read -ra pats <<< "$PV"
  split_user_args "$1"
  DENIED=""
  for tok in ${UARGS[@]+"${UARGS[@]}"}; do
    sd_lower "$tok"; low="$SD_LOWER"
    c2="${low// /=}"; c3="$prev=$low"; c4="${c2%%=*}"
    for pat in ${pats[@]+"${pats[@]}"}; do
      sd_lower "$pat"; lpat="$SD_LOWER"
      # shellcheck disable=SC2053
      if [[ $low == $lpat ]] || [[ $c2 == $lpat ]] || { [ -n "$prev" ] && [[ $c3 == $lpat ]]; } \
         || { [ "${c4:0:1}" = - ] && [[ $c4 == $lpat ]]; }; then DENIED="$tok"; return 1; fi
      if [[ $lpat =~ ^-[a-z0-9]$ ]] && [[ $c4 =~ ^-[a-z0-9]{2,}$ ]]; then
        case "${c4:1}" in *"${lpat:1}"*) DENIED="$tok"; return 1 ;; esac
      fi
    done
    prev="$low"
  done
  return 0
}
# validate_role -> 0, or sets VERR + VREASON and returns 1
validate_role() {
  VERR=""; VREASON=usage
  case " $TOOLS " in *" $R_TOOL "*) ;; *) VERR="roles.$ROLE.tool: unknown tool '$R_TOOL' (one of: $TOOLS)"; return 1 ;; esac
  if [ -n "$R_MODEL" ] && ! [[ $R_MODEL =~ $MODEL_RE ]]; then VERR="roles.$ROLE.model: invalid model '$R_MODEL'"; return 1; fi
  if [ -n "$R_ARGS" ]; then
    [ ${#R_ARGS} -le 300 ] || { VERR="roles.$ROLE.args: longer than 300 characters"; return 1; }
    case "$R_ARGS" in *\"*|*\'*|*\\*|*[[:cntrl:]]*) VERR="roles.$ROLE.args: no quotes, backslashes or control characters"; return 1 ;; esac
    case "$R_ARGS" in *$'\002'*) VERR="roles.$ROLE.args: control characters"; return 1 ;; esac
    if ! deny_check "$R_ARGS"; then VERR="roles.$ROLE.args: '$DENIED' is not allowed (it would approve beyond the SubDeck profile)"; VREASON=deny-args; return 1; fi
  fi
  if [ "$R_TOOL" = custom ]; then
    [ -n "$R_CMD" ] || { VERR="roles.$ROLE.cmd is required for tool custom"; return 1; }
    [ ${#R_CMD} -le 500 ] || { VERR="roles.$ROLE.cmd: longer than 500 characters"; return 1; }
    case "$R_CMD" in *[[:cntrl:]]*|*$'\002'*) VERR="roles.$ROLE.cmd: control characters"; return 1 ;; esac
    case "$R_CMD" in *"{prompt_file}"*) ;; *) VERR="roles.$ROLE.cmd must contain {prompt_file}"; return 1 ;; esac
  elif [ -n "$R_CMD" ]; then
    VERR="roles.$ROLE.cmd is only allowed with tool custom"; return 1
  fi
  if [ -n "$R_TIMEOUT" ]; then
    { [[ $R_TIMEOUT =~ ^[0-9]{1,6}$ ]] && [ "$((10#$R_TIMEOUT))" -ge 60 ] && [ "$((10#$R_TIMEOUT))" -le 86400 ]; } \
      || { VERR="roles.$ROLE.timeout: '$R_TIMEOUT' is not 60-86400 seconds"; return 1; }
  fi
  return 0
}

# ---------- events ----------
emit_event() { # kind json
  printf '%s' "$2" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$LOG_EVENT" "$1" >/dev/null 2>&1
  return 0
}
RUN_ID=""; AGENT_TYPE=""
refuse() { # exit-code reason detail
  if [ "$DRY" = 0 ]; then
    local aid="${RUN_ID:-run-${TASK:-none}-$(date -u +%Y%m%dT%H%M%SZ)}"
    emit_event run_refused "{\"agent_id\":$(jstr "$aid"),\"agent_type\":$(jstr "${AGENT_TYPE:-run}"),\"session_id\":$(jstr "$aid"),\"task\":$(jstr "${TASK:-}"),\"role\":$(jstr "${ROLE:-}"),\"tool\":$(jstr "${R_TOOL:-}"),\"reason\":$(jstr "$2"),\"detail\":$(jstr "$3")}"
  fi
  die "$1" "$3"
}

# ---------- task file ----------
task_dir() { TDIR="$(bash "$TASKS_SH" --project "$PROJECT" dir 2>/dev/null)"; }
# read_task FILE -> TK_title TK_status TK_writable (comma list) TK_tool TK_model TK_worktree
read_task() {
  local line state=0 key val re='^([a-z][a-z-]*):(.*)$'
  TK_title=""; TK_status=""; TK_writable=""; TK_tool=""; TK_model=""; TK_worktree=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "$state" = 0 ]; then [ "$line" = "---" ] || return 1; state=1; continue; fi
    [ "$line" = "---" ] && return 0
    if [[ $line =~ $re ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
      case "$key" in
        title) TK_title="$val" ;; status) TK_status="$val" ;; tool) TK_tool="$val" ;; model) TK_model="$val" ;;
        worktree) TK_worktree="$val" ;;
        writable) val="${val#\[}"; val="${val%\]}"; TK_writable="$val" ;;
      esac
    fi
  done < "$1"
  return 1
}
writable_items() { # TK_writable -> WITEMS array (trimmed, ./ and trailing / dropped)
  local it
  local -a arr
  WITEMS=()
  IFS=, read -ra arr <<< "$TK_writable"
  for it in ${arr[@]+"${arr[@]}"}; do
    it="${it#"${it%%[![:space:]]*}"}"; it="${it%"${it##*[![:space:]]}"}"
    while [ "${it#./}" != "$it" ]; do it="${it#./}"; done
    while [ "${#it}" -gt 1 ] && [ "${it%/}" != "$it" ]; do it="${it%/}"; done
    [ -n "$it" ] && WITEMS[${#WITEMS[@]}]="$it"
  done
}

# ---------- git helpers ----------
is_git() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
phys() { (cd "$1" 2>/dev/null && pwd -P); }
# changed_paths DIR BASE -> stdout, one path per line, relative to the repo top (no renames: both sides listed)
changed_paths() {
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  {
    git -C "$top" diff --no-renames --name-only -z "$2" -- 2>/dev/null
    git -C "$top" diff --no-renames --name-only -z -- 2>/dev/null
    git -C "$top" ls-files --others --exclude-standard -z 2>/dev/null
  } | tr '\0' '\n' | LC_ALL=C sort -u
}
path_allowed() { # path -> 0 when it matches a writable item (WITEMS, with PREFIX)
  local p="$1" it
  for it in ${WITEMS[@]+"${WITEMS[@]}"}; do
    it="$PREFIX$it"
    [ "$p" = "$it" ] && return 0
    case "$p" in "$it"/*) return 0 ;; esac
    case "$it" in
      *[*?]*)
        # shellcheck disable=SC2053
        [[ $p == $it ]] && return 0 ;;
    esac
  done
  return 1
}

# gitdir_snapshot -> stdout: "<cksum> <name>" for the common git dir's config and hooks/ (and config.worktree)
gitdir_snapshot() {
  local cd gd f
  cd="$(cd "$CWD" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)" || return 0
  gd="$(cd "$CWD" && cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd)"
  [ -n "$cd" ] || return 0
  for f in "$cd/config" "$gd/config.worktree"; do [ -f "$f" ] && printf '%s %s\n' "$(cksum < "$f" | tr ' ' :)" "${f#$cd/}"; done
  if [ -d "$cd/hooks" ] || [ -d "$cd/info" ]; then
    find "$cd/hooks" "$cd/info" \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      if [ -L "$f" ]; then printf 'link:%s %s\n' "$(readlink "$f")" "${f#$cd/}"
      else printf '%s %s\n' "$(cksum < "$f" | tr ' ' :)" "${f#$cd/}"; fi
    done
  fi
}
# link_escapes REL -> 0 when the symlink TOP/REL points outside TOP (lexically resolved); LINK_T = its target
link_escapes() {
  local l="$TOP/$1" t abs topp
  LINK_T="$(readlink "$l" 2>/dev/null)"
  t="$LINK_T"
  case "$t" in /*) abs="$t" ;; *) abs="${l%/*}/$t" ;; esac
  sd_norm_path "$abs" posix; abs="$SD_NORM"
  topp="$(phys "$TOP")"
  for t in "$TOP" "$topp"; do
    [ -n "$t" ] || continue
    [ "$abs" = "$t" ] && return 1
    case "$abs" in "$t"/*) return 1 ;; esac
  done
  # a target inside the physical top reached through a symlinked parent counts as inside
  return 0
}

# ---------- lock ----------
LOCK=""; HAVE_LOCK=0
lock_state() { # -> 0 free (or stale, removed when $1=take), 1 busy
  local owner pid
  [ -d "$LOCK" ] || return 0
  owner=""; { read -r owner < "$LOCK/owner"; } 2>/dev/null
  pid="${owner%% *}"
  if [[ $pid =~ ^[0-9]+$ ]]; then
    kill -0 "$pid" 2>/dev/null && return 1
  else
    # no owner yet: a run is starting, unless the lock is older than a minute
    [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 1
  fi
  [ "$1" = take ] && { mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -rf "$LOCK.stale.$$" 2>/dev/null; }
  return 0
}
lock_take() {
  local now
  mkdir -p "${LOCK%/*}" 2>/dev/null || return 1
  lock_state take || return 1
  mkdir "$LOCK" 2>/dev/null || return 1
  HAVE_LOCK=1
  now_s now
  printf '%s %s\n' "$$" "$now" > "$LOCK/owner.tmp" 2>/dev/null && mv -f "$LOCK/owner.tmp" "$LOCK/owner" 2>/dev/null
  return 0
}
lock_release() { [ "$HAVE_LOCK" = 1 ] && rm -rf "$LOCK" 2>/dev/null; HAVE_LOCK=0; }

# ---------- protected resources (settings.sh json) ----------
protected_text() {
  local j out
  j="$(bash "$SETTINGS_SH" json --project "$PROJECT" 2>/dev/null)"
  out="$(printf '%s' "$j" | LC_ALL=C awk '
    BEGIN { RS = "\001" }
    {
      t = $0; n = split("protect protect-ports protect-hosts protect-procs", K, " ")
      for (k = 1; k <= n; k++) {
        p = index(t, "{\"key\":\"" K[k] "\",\"value\":")
        if (!p) continue
        i = p + length("{\"key\":\"" K[k] "\",\"value\":")
        if (substr(t, i, 1) != "[") continue
        i++; items = ""; ins = 0; s = ""
        while (i <= length(t)) {
          c = substr(t, i, 1)
          if (ins) {
            if (c == "\\") { s = s substr(t, i + 1, 1); i += 2; continue }
            if (c == "\"") { ins = 0; items = items (items == "" ? "" : ", ") s; s = "" }
            else s = s c
          } else if (c == "\"") ins = 1
          else if (c == "]") break
          i++
        }
        if (items != "") print K[k] ": " items
      }
    }')"
  [ -n "$out" ] || out="none"
  PROTECTED="$out"
}

# ---------- commands: roles / tail / cleanup ----------
cmd_roles() {
  local r tool model to src mapped
  load_config; all_roles
  if [ "$JSON" = 1 ]; then
    printf '{"version":1,"roles":['
    local first=1
    for r in $ROLE_LIST; do
      resolve_role "$r"; role_class "$r"
      to="${R_TIMEOUT:-$DEFAULT_TIMEOUT}"; [[ $to =~ ^[0-9]+$ ]] || to=$DEFAULT_TIMEOUT
      mapped=false; [ -n "$R_TOOL" ] && mapped=true
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"role":%s,"class":%s,"tool":%s,"model":%s,"args":%s,"timeout":%s,"source":%s,"mapped":%s}' \
        "$(jstr "$r")" "$(jstr "$CLASS")" "$(jstr "$R_TOOL")" "$(jstr "$R_MODEL")" "$(jstr "$R_ARGS")" "$((10#$to))" "$(jstr "$R_SOURCE")" "$mapped"
    done
    printf ']}\n'
  else
    for r in $ROLE_LIST; do
      resolve_role "$r"; role_class "$r"
      tool="${R_TOOL:--}"; model="${R_MODEL:--}"
      to="${R_TIMEOUT:-$DEFAULT_TIMEOUT}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$CLASS" "$tool" "$model" "$to" "$R_SOURCE"
    done
  fi
}
meta_field() { # file key -> MF (string or literal value)
  local c re
  MF=""
  c="$(tr -d '\r\n' < "$1" 2>/dev/null)"
  re="\"$2\":\"([^\"]*)\""
  if [[ $c =~ $re ]]; then MF="${BASH_REMATCH[1]}"; return 0; fi
  re="\"$2\":([^,}]*)"
  if [[ $c =~ $re ]]; then MF="${BASH_REMATCH[1]}"; fi
}
cmd_tail() {
  local id="${POS[1]:-}" n="${LINES:-40}" d last f k
  [[ $id =~ $ID_RE ]] || die 2 "usage: run.sh tail <task-id> [--lines N]"
  [[ $n =~ ^[0-9]{1,6}$ ]] && [ "$n" -ge 1 ] || die 2 "--lines needs a number 1-2000"
  [ "$n" -gt 2000 ] && n=2000
  d="$STATE/runs/$id"
  last=""
  for f in "$d"/*.json; do [ -f "$f" ] && last="$f"; done
  [ -n "$last" ] || die 1 "no runs for $id"
  for k in status exit tool model branch; do meta_field "$last" "$k"; printf '%s: %s\n' "$k" "$MF"; done
  f="${last%.json}"
  printf -- '--- log (last %s lines): %s\n' "$n" "$f.log"
  [ -f "$f.log" ] && tail -n "$n" "$f.log"
  printf -- '--- out (last %s lines): %s\n' "$n" "$f.out"
  [ -f "$f.out" ] && tail -n "$n" "$f.out"
  return 0
}
cmd_cleanup() {
  local id="${POS[1]:-}" wt
  [[ $id =~ $ID_RE ]] || die 2 "usage: run.sh cleanup <task-id> [--force]"
  LOCK="$STATE/runs/$id/.lock"
  lock_state check || die 4 "a run of $id is active"
  wt="$STATE/worktrees/$id"
  [ -d "$wt" ] || die 1 "no worktree for $id ($wt)"
  if [ "$FORCE" = 1 ]; then
    git -C "$PROJECT" worktree remove --force "$wt" || die 1 "git worktree remove failed"
  else
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      die 1 "worktree $wt has uncommitted changes; commit them on subdeck/$id or use --force"
    fi
    git -C "$PROJECT" worktree remove "$wt" || die 1 "git worktree remove failed"
  fi
  printf 'removed %s (branch subdeck/%s kept)\n' "$wt" "$id"
}

case "${POS[0]}" in
  roles) [ ${#POS[@]} -eq 1 ] || die 2 "usage: run.sh roles [--json]"; cmd_roles; exit 0 ;;
  tail) cmd_tail; exit $? ;;
  cleanup) cmd_cleanup; exit $? ;;
esac

# ---------- run: resolve ----------
ROLE="${POS[0]}"; TASK="${POS[1]:-}"
[ ${#POS[@]} -eq 2 ] || refuse 2 usage "$USAGE"
[[ $ROLE =~ $ROLE_RE ]] || refuse 2 usage "invalid role name '$ROLE'"
[[ $TASK =~ $ID_RE ]] || refuse 2 usage "invalid task id '$TASK'"
role_class "$ROLE"; AGENT_TYPE="$CLASS-run"
[ "$CLASS" = manager ] && refuse 2 usage "the manager role is not runnable (start that CLI yourself)"
if [ -n "$TIMEOUT_OVR" ]; then
  [[ $TIMEOUT_OVR =~ ^[0-9]{1,6}$ ]] && [ "$((10#$TIMEOUT_OVR))" -ge 1 ] || refuse 2 usage "--timeout needs whole seconds >= 1"
fi
load_config
resolve_role "$ROLE"
[ -n "$R_TOOL" ] || refuse 2 not-mapped "role $ROLE is not mapped to a CLI (set roles.$ROLE.tool); unmapped roles run in-session"
load_profiles || refuse 2 usage "profile file missing: $PROFILES"
validate_role || refuse 2 "$VREASON" "$VERR"
TOOL="$R_TOOL"; MODEL="$R_MODEL"
pget "$TOOL" bin; BIN="$PV"
[ -n "$BIN" ] || refuse 2 usage "no profile for tool $TOOL in $PROFILES"
TIMEOUT="${R_TIMEOUT:-$DEFAULT_TIMEOUT}"; [ -n "$TIMEOUT_OVR" ] && TIMEOUT="$TIMEOUT_OVR"
TIMEOUT=$((10#$TIMEOUT))

task_dir
if [ -f "$TDIR/$TASK.md" ]; then TFILE="$TDIR/$TASK.md"
elif [ -f "$TDIR/archive/$TASK.md" ]; then refuse 2 not-found "task $TASK is archived (done)"
else refuse 2 not-found "task not found: $TASK ($TDIR)"; fi
read_task "$TFILE" || refuse 2 not-found "task file unreadable: $TFILE"
writable_items
RULEBOOK="$ROLES_DIR/$CLASS.md"
[ -f "$RULEBOOK" ] || refuse 2 not-found "rulebook missing: $RULEBOOK"

# verifier must be a different model than the producer (exact normalized tool/model)
MODEL_CHECK="n/a"
if [ "$CLASS" = verifier ]; then
  if [ -z "$TK_tool" ]; then
    MODEL_CHECK=unknown
    warn "task $TASK has no producer tool/model recorded; cannot check that the verifier is a different model"
  else
    sd_lower "$TOOL/${MODEL:-default}"; VKEY="$SD_LOWER"
    sd_lower "$TK_tool/${TK_model:-default}"; PKEY="$SD_LOWER"
    [ "$VKEY" = "$PKEY" ] && refuse 3 same-model "verifier $VKEY is the same model that produced $TASK; map roles.$ROLE to another model"
    MODEL_CHECK=ok
  fi
fi
command -v "$BIN" >/dev/null 2>&1 || refuse 127 not-found "$BIN not found on PATH (tool $TOOL); $(pget "$TOOL" auth_hint; printf 'install it, then: %s' "$PV")"

# working directory
GIT=0; is_git "$PROJECT" && GIT=1
WT_PATH="$STATE/worktrees/$TASK"; USE_WT=0; WT_ACTION=""
case "$CLASS" in
  worker) [ "$WT_MODE" = no ] || USE_WT=1 ;;
  *) [ "$WT_MODE" = yes ] && USE_WT=1 ;;
esac
if [ "$USE_WT" = 1 ] && [ "$GIT" = 0 ]; then
  refuse 2 no-git "$PROJECT is not a git repository: use --no-worktree (the writable check is then skipped)"
fi
PREFIX=""
[ "$GIT" = 1 ] && PREFIX="$(git -C "$PROJECT" rev-parse --show-prefix 2>/dev/null)"
BASE=""
if [ "$USE_WT" = 1 ]; then
  if [ -e "$WT_PATH" ]; then
    WP="$(phys "$WT_PATH")"
    if [ -n "$WP" ] && [ "$(phys "$(git -C "$WT_PATH" rev-parse --show-toplevel 2>/dev/null)")" = "$WP" ] \
       && [ "$(cd "$WT_PATH" && phys "$(git rev-parse --git-common-dir 2>/dev/null)")" = "$(cd "$PROJECT" && phys "$(git rev-parse --git-common-dir 2>/dev/null)")" ]; then
      WT_ACTION=reuse
    else
      refuse 2 usage "$WT_PATH exists but is not a registered worktree of $PROJECT; move it away"
    fi
  elif git -C "$PROJECT" rev-parse --verify --quiet "refs/heads/subdeck/$TASK" >/dev/null 2>&1; then
    WT_ACTION=branch
  else
    WT_ACTION=create
  fi
  CWD="$WT_PATH${PREFIX:+/${PREFIX%/}}"
  BRANCH="subdeck/$TASK"
elif [ "$CLASS" != worker ] && [ -z "$WT_MODE" ] && [ -n "$TK_worktree" ] && [ -d "$TK_worktree" ]; then
  CWD="$TK_worktree"
  BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)"
else
  CWD="$PROJECT"
  BRANCH=""; [ "$GIT" = 1 ] && BRANCH="$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
fi
WORKTREE=""; [ "$USE_WT" = 1 ] && WORKTREE="$WT_PATH"
[ "$CWD" != "$PROJECT" ] && [ "$USE_WT" = 0 ] && WORKTREE="$CWD"
# read-only classes have nothing writable
[ "$CLASS" = worker ] || WITEMS=()

# lock (checked here; taken only by a real run)
LOCK="$STATE/runs/$TASK/.lock"
lock_state check || refuse 4 busy "a run of $TASK is already active ($LOCK)"

# run files
RUNDIR="$STATE/runs/$TASK"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
if [ "$DRY" = 0 ]; then
  mkdir -p "$RUNDIR" 2>/dev/null || die 2 "cannot create $RUNDIR"
  lock_take || refuse 4 busy "a run of $TASK is already active ($LOCK)"
  trap 'lock_release' EXIT
  while [ -e "$RUNDIR/$TS.json" ]; do sleep 1; TS="$(date -u +%Y%m%dT%H%M%SZ)"; done
fi
RUN_ID="run-$TASK-$TS"
F="$RUNDIR/$TS"
LOGF="$F.log"; OUTF="$F.out"; PROMPTF="$F.prompt.md"; FINALF="$F.final.txt"; LASTF="$F.last.txt"; METAF="$F.json"

# ---------- prompt ----------
build_prompt() {
  local w
  printf 'Task: %s (tasks.sh: %s)\n' "$TASK" "$TASKS_SH"
  printf '# SubDeck run: %s (%s) via %s %s\n\n' "$ROLE" "$CLASS" "$TOOL" "${MODEL:-default}"
  printf '## Rules\n'
  tr -d '\r' < "$RULEBOOK"; printf '\n'
  printf '## Headless run\n'
  printf 'This run is non-interactive: nobody reads or answers questions until it ends. Do not ask; if you need a decision, end with `Stop: waiting` and put the question under Decision.\n'
  printf 'Work only in `%s`%s.\n' "$CWD" "${BRANCH:+ on branch \`$BRANCH\`}"
  if [ ${#WITEMS[@]} -gt 0 ]; then
    printf 'Commit only the writable paths below, there, with pathspec commits (`git commit -m "<message>" -- <paths>`); never `git add -A` or `git add .`; no attribution lines.\n'
  else
    printf 'Change no files and make no commits.\n'
  fi
  printf 'Never push, merge, rebase, reset or switch branches. Every changed path is checked after the run.\n\n'
  printf '## Writable paths\n'
  if [ ${#WITEMS[@]} -gt 0 ]; then for w in "${WITEMS[@]}"; do printf '%s\n' "$w"; done
  else printf 'none (read-only): any change is a violation\n'; fi
  printf '\n## Protected resources\n%s\n' "$PROTECTED"
  printf 'Leave every protected resource as you found it: do not use, stop, restart or reconfigure one without the user'"'"'s approval, and stop anything you started.\n\n'
  printf '## Task file\n'
  tr -d '\r' < "$TFILE"
  printf '\n## Final reply\n'
  case "$CLASS" in
    worker)
      printf 'End with exactly this block (at most 9 lines):\n'
      printf '%s\n' '<short-name> · <done|needs-decision|failed>' 'Result: <1-2 sentences>' 'Evidence: <one line: test/command result>' \
        'Tested: ran `<cmd>` -> <result> | not run (<why>)' 'Commits: <hashes>' 'Detail: <report file inside your write scope, if any>' \
        'Decision: <"none", or one clear question>' 'Stop: <done|waiting|quota|timeout|no-progress|blocked> - <one line why>' ;;
    researcher)
      printf 'Answer first, evidence after, then end with one line:\n'
      printf '%s\n' 'Stop: <done|waiting|quota|timeout|no-progress|blocked> - <one line why>' ;;
    verifier)
      printf 'End with the fingerprint line and exactly one verdict line:\n'
      printf '%s\n' 'Fingerprint: HEAD=<hash> state=<cksum>' 'Verdict: Approved | Needs fixes | Escalate' ;;
  esac
}
protected_text
PROMPT="$(build_prompt)"
PROMPT="$PROMPT$NL"

# ---------- argv and env ----------
pget "$TOOL" prompt; PMODE="$PV"
V_MODEL="$MODEL"; V_CWD="$CWD"; V_PROMPT="$PROMPT"; V_PROMPT_FILE="$PROMPTF"; V_LAST_FILE="$LASTF"
if [ "$PLAT" = win ] && command -v cygpath >/dev/null 2>&1; then
  V_CWD="$(cygpath -w "$CWD" 2>/dev/null || printf '%s' "$CWD")"
  V_PROMPT_FILE="$(cygpath -w "$PROMPTF" 2>/dev/null || printf '%s' "$PROMPTF")"
  V_LAST_FILE="$(cygpath -w "$LASTF" 2>/dev/null || printf '%s' "$LASTF")"
fi
V_CMD=""
if [ "$TOOL" = custom ]; then subst "$R_CMD" quote; V_CMD="$SUB"; fi
if [ "$PLAT" = win ] && [ "$PMODE" = arg ]; then
  PBYTES="$(printf '%s' "$PROMPT" | wc -c | tr -d ' ')"
  [ "$PBYTES" -gt 30000 ] && refuse 2 prompt-too-long "prompt is $PBYTES bytes; $TOOL takes it as one argument and Windows allows about 32 KB"
fi
ARGV_OUT=()
pget "$TOOL" argv
read -ra ATOKS <<< "$PV"
for tok in ${ATOKS[@]+"${ATOKS[@]}"}; do
  case "$tok" in
    "{model_args}") [ -n "$MODEL" ] && { pget "$TOOL" model; add_tokens "$PV"; } ;;
    "{cwd_args}") pget "$TOOL" cwd; add_tokens "$PV" ;;
    "{restrict_args}") pget "$TOOL" restrict; add_tokens "$PV" ;;
    "{user_args}") split_user_args "$R_ARGS"; for u in ${UARGS[@]+"${UARGS[@]}"}; do ARGV_OUT[${#ARGV_OUT[@]}]="$u"; done ;;
    *) subst "$tok"; ARGV_OUT[${#ARGV_OUT[@]}]="$SUB" ;;
  esac
done
# child env: fixed run vars, push blocker (appended to any git config already in the env), profile env
ENV_OUT=()
ENV_OUT[${#ENV_OUT[@]}]="SUBDECK_RUN=1"
ENV_OUT[${#ENV_OUT[@]}]="SUBDECK_TASK=$TASK"
ENV_OUT[${#ENV_OUT[@]}]="SUBDECK_ROLE=$ROLE"
ENV_OUT[${#ENV_OUT[@]}]="SUBDECK_PROJECT=$PROJECT"
ENV_OUT[${#ENV_OUT[@]}]="CLAUDE_PROJECT_DIR=$CWD"
ENV_OUT[${#ENV_OUT[@]}]="GIT_TERMINAL_PROMPT=0"
# Push blocker, three layers: every push URL rewritten to an unknown scheme (pushInsteadOf); explicit
# remote.<n>.pushurl values (pushInsteadOf ignores them) rewritten with insteadOf unless that would also break a fetch
# URL; and a SubDeck hooks dir whose pre-push refuses (core.hooksPath: the repo's own hooks do not run in the run).
HOOKS_DIR="$RUNDIR/hooks"; V_HOOKS="$HOOKS_DIR"
if [ "$PLAT" = win ] && command -v cygpath >/dev/null 2>&1; then V_HOOKS="$(cygpath -m "$HOOKS_DIR" 2>/dev/null || printf '%s' "$HOOKS_DIR")"; fi
GCN=0; [[ ${GIT_CONFIG_COUNT:-} =~ ^[0-9]{1,3}$ ]] && GCN=$((10#$GIT_CONFIG_COUNT))
GC_KEYS=("url.subdeck-no-push://.pushInsteadOf" "core.hooksPath"); GC_VALS=("" "$V_HOOKS")
PUSHURLS=""; PU_NOTE=""
if is_git "$PROJECT" || is_git "$CWD" 2>/dev/null; then
  GDIR="$PROJECT"; is_git "$GDIR" || GDIR="$CWD"
  PUSHURLS="$(git -C "$GDIR" config --get-regexp '^remote\..*\.pushurl$' 2>/dev/null)"
  FETCHURLS="$(git -C "$GDIR" config --get-regexp '^remote\..*\.url$' 2>/dev/null | sed 's/^[^ ]* //')"
  while IFS= read -r pl; do
    [ -n "$pl" ] || continue
    pu="${pl#* }"; pn="${pl%% *}"; pn="${pn#remote.}"; pn="${pn%.pushurl}"; clash=0
    while IFS= read -r fu; do [ -n "$fu" ] && case "$fu" in "$pu"*) clash=1 ;; esac; done <<< "$FETCHURLS"
    if [ "$clash" = 0 ]; then
      GC_KEYS[${#GC_KEYS[@]}]="url.subdeck-no-push://.insteadOf"; GC_VALS[${#GC_VALS[@]}]="$pu"
      PU_NOTE="$PU_NOTE${NL}warning: remote $pn has an explicit pushurl $pu: push blocked by url rewrite and the SubDeck pre-push hook"
    else
      PU_NOTE="$PU_NOTE${NL}warning: remote $pn has an explicit pushurl $pu that is also a fetch url prefix: guarded by the SubDeck pre-push hook only (git push --no-verify is not blocked)"
    fi
  done <<< "$PUSHURLS"
fi
ENV_OUT[${#ENV_OUT[@]}]="GIT_CONFIG_COUNT=$((GCN + ${#GC_KEYS[@]}))"
i=0
while [ $i -lt ${#GC_KEYS[@]} ]; do
  ENV_OUT[${#ENV_OUT[@]}]="GIT_CONFIG_KEY_$((GCN + i))=${GC_KEYS[i]}"
  ENV_OUT[${#ENV_OUT[@]}]="GIT_CONFIG_VALUE_$((GCN + i))=${GC_VALS[i]}"
  i=$((i + 1))
done
pget "$TOOL" env
if [ -n "$PV" ]; then
  read -ra ETOKS <<< "$PV"
  for tok in "${ETOKS[@]}"; do
    [[ $tok =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    subst "$tok"; ENV_OUT[${#ENV_OUT[@]}]="$SUB"
  done
fi
pget "$TOOL" status; EXPERIMENTAL=false; [ "$PV" = experimental ] && EXPERIMENTAL=true

if [ "$DRY" = 1 ]; then
  printf 'tool: %s\nmodel: %s\ncwd: %s\n' "$TOOL" "${MODEL:-(tool default)}" "$CWD"
  if [ "$USE_WT" = 1 ]; then printf 'worktree: %s (%s)\n' "$WT_PATH" "$WT_ACTION"
  elif [ -n "$WORKTREE" ]; then printf 'worktree: %s (task worktree)\n' "$WORKTREE"
  else printf 'worktree: none\n'; fi
  printf 'branch: %s\ntimeout: %s\n' "${BRANCH:-(none)}" "$TIMEOUT"
  printf 'argv:\n%s\n' "$BIN"
  for tok in ${ARGV_OUT[@]+"${ARGV_OUT[@]}"}; do
    if [ "$tok" = "$PROMPT" ]; then printf '<prompt>\n'; else printf '%s\n' "${tok//$NL/\\n}"; fi
  done
  printf 'env:\n'
  for tok in "${ENV_OUT[@]}"; do printf '%s\n' "$tok"; done
  printf 'prompt:\n%s' "$PROMPT"
  exit 0
fi

# ---------- launch ----------
logh() { printf '[subdeck] %s\n' "$1" >> "$LOGF"; }
STARTED="$(now_iso)"; START_S=$SECONDS
: > "$OUTF"; : > "$LOGF"
printf '%s' "$PROMPT" > "$PROMPTF"
if [ "$USE_WT" = 1 ]; then
  BASE="$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null)"
  mkdir -p "${WT_PATH%/*}" 2>/dev/null
  case "$WT_ACTION" in
    create) git -C "$PROJECT" worktree prune >/dev/null 2>&1
            git -C "$PROJECT" worktree add -q -b "subdeck/$TASK" "$WT_PATH" HEAD >> "$LOGF" 2>&1 || { lock_release; die 2 "git worktree add failed (see $LOGF)"; } ;;
    branch) git -C "$PROJECT" worktree prune >/dev/null 2>&1
            git -C "$PROJECT" worktree add -q "$WT_PATH" "subdeck/$TASK" >> "$LOGF" 2>&1 || { lock_release; die 2 "git worktree add failed (see $LOGF)"; }
            BASE="$(git -C "$PROJECT" merge-base HEAD "subdeck/$TASK" 2>/dev/null)" ;;
    reuse)  BASE="$(git -C "$PROJECT" merge-base HEAD "subdeck/$TASK" 2>/dev/null)" ;;
  esac
  if [ ${#WITEMS[@]} -gt 0 ] && [ -n "$(git -C "$PROJECT" status --porcelain -- "${WITEMS[@]}" 2>/dev/null)" ]; then
    warn "uncommitted changes in the main tree inside writable paths are not in the worktree $WT_PATH"
  fi
elif [ "$GIT" = 1 ] || is_git "$CWD"; then
  BASE="$(git -C "$CWD" rev-parse HEAD 2>/dev/null)"
fi
mkdir -p "$HOOKS_DIR" 2>/dev/null
printf '#!/bin/sh\necho "SubDeck: git push is disabled inside a SubDeck run; the manager integrates branch subdeck/%s after the user approves." >&2\nexit 1\n' "$TASK" > "$HOOKS_DIR/pre-push"
chmod +x "$HOOKS_DIR/pre-push" 2>/dev/null
while IFS= read -r pl; do [ -n "$pl" ] && logh "$pl"; done <<< "$PU_NOTE"
CHECK=skipped; is_git "$CWD" && CHECK=ok
RUNBASE=""; PRE=""; TOP=""; GSNAP=""; MARKF="$F.marker"
if [ "$CHECK" = ok ]; then
  RUNBASE="$(git -C "$CWD" rev-parse HEAD 2>/dev/null)"
  [ -n "$RUNBASE" ] || RUNBASE="$(git hash-object -t tree /dev/null)"
  PRE="$(changed_paths "$CWD" "$RUNBASE")"
  TOP="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
  GSNAP="$(gitdir_snapshot)"
  : > "$MARKF"
fi

write_meta() { # status cliExit exit endedAt(json) sessionId(json) violations(json) commits uncommitted
  local tmp="$METAF.tmp.$$"
  {
    printf '{"version":1,"task":%s,"title":%s,"role":%s,"class":%s,"tool":%s,"model":%s,"agent":%s,"runId":%s,' \
      "$(jstr "$TASK")" "$(jstr "$TK_title")" "$(jstr "$ROLE")" "$(jstr "$CLASS")" "$(jstr "$TOOL")" "$(jstr "$MODEL")" "$(jstr "$AGENT_TYPE")" "$(jstr "$RUN_ID")"
    printf '"project":%s,"cwd":%s,"worktree":%s,"branch":%s,"base":%s,"runbase":%s,"pid":%s,' \
      "$(jstr "$PROJECT")" "$(jstr "$CWD")" "$(jstr "$WORKTREE")" "$(jstr "$BRANCH")" "$(jstr "$BASE")" "$(jstr "$RUNBASE")" "$$"
    printf '"startedAt":%s,"endedAt":%s,"status":%s,"cliExit":%s,"exit":%s,"experimental":%s,"sessionId":%s,' \
      "$(jstr "$STARTED")" "$4" "$(jstr "$1")" "$(jnum "$2")" "$(jnum "$3")" "$EXPERIMENTAL" "$5"
    printf '"writableCheck":%s,"violations":%s,"commits":%s,"uncommitted":%s}\n' "$(jstr "$CHECK")" "$6" "${7:-0}" "${8:-0}"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$METAF" 2>/dev/null
}
logh "run $RUN_ID role=$ROLE class=$CLASS tool=$TOOL model=${MODEL:-default}"
logh "cwd=$CWD branch=${BRANCH:-none} base=${BASE:-none} timeout=$TIMEOUT"
logh "argv: $BIN $( for tok in ${ARGV_OUT[@]+"${ARGV_OUT[@]}"}; do if [ "$tok" = "$PROMPT" ]; then printf '<prompt> '; else printf '%s ' "${tok//$NL/\\n}"; fi; done)"
logh "prompt: $PROMPTF"
if [ "$EXPERIMENTAL" = true ]; then
  printf 'warning: %s profile is experimental (flags unverified)\n' "$TOOL" >&2
  printf 'warning: %s profile is experimental (flags unverified)\n' "$TOOL" >> "$LOGF"
fi
[ "$MODEL_CHECK" = unknown ] && logh "warning: producer of $TASK unknown; verifier model not checked"
CPID=""
write_meta running "" "" null null '[]' 0 0

# task status before the run (synthetic hook payloads keep the 0.7 rules in tasks.sh)
task_hook() { # event extra-json
  printf '{"hook_event_name":"%s","session_id":%s,"agent_id":%s,"agent_type":%s,"cwd":%s,"prompt":%s%s}' \
    "$1" "$(jstr "$RUN_ID")" "$(jstr "$RUN_ID")" "$(jstr "$AGENT_TYPE")" "$(jstr "$PROJECT")" "$(jstr "Task: $TASK")" "$2" \
    | SUBDECK_TASK_GIT="$CWD" bash "$TASKS_SH" --project "$PROJECT" hook "$1" >/dev/null 2>&1
}
task_set() { bash "$TASKS_SH" --project "$PROJECT" set "$TASK" "$@" >> "$LOGF" 2>&1 || logh "warning: tasks.sh set $* failed"; }
case "$CLASS" in
  worker|researcher)
    SETS=("role=$ROLE" "run=$LOGF")
    [ "$CLASS" = worker ] && SETS=("${SETS[@]}" "tool=$TOOL" "model=$MODEL")
    [ "$USE_WT" = 1 ] && SETS=("${SETS[@]}" "branch=$BRANCH" "worktree=$WT_PATH")
    task_set "${SETS[@]}"
    task_hook SubagentStart "" ;;
  verifier) task_set "run=$LOGF" ;;
esac
emit_event run_start "{\"agent_id\":$(jstr "$RUN_ID"),\"agent_type\":$(jstr "$AGENT_TYPE"),\"session_id\":$(jstr "$RUN_ID"),\"task\":$(jstr "$TASK"),\"role\":$(jstr "$ROLE"),\"class\":$(jstr "$CLASS"),\"tool\":$(jstr "$TOOL"),\"model\":$(jstr "$MODEL"),\"cwd\":$(jstr "$CWD"),\"worktree\":$(jstr "$WORKTREE"),\"branch\":$(jstr "$BRANCH"),\"base\":$(jstr "$BASE"),\"log\":$(jstr "$LOGF"),\"pid\":$$,\"timeout\":$TIMEOUT,\"experimental\":$EXPERIMENTAL,\"modelCheck\":$(jstr "$MODEL_CHECK")}"

STDIN_SRC=/dev/null; [ "$PMODE" = stdin ] && STDIN_SRC="$PROMPTF"
CANCELLED=0; TIMED_OUT=0
kill_tree() { # signal
  local wp
  if [ "$PLAT" = win ] && [ -r "/proc/$CPID/winpid" ] && command -v taskkill >/dev/null 2>&1; then
    read -r wp < "/proc/$CPID/winpid" 2>/dev/null
    [ -n "$wp" ] && taskkill //F //T //PID "$wp" >/dev/null 2>&1
  fi
  kill "-$1" -- "-$CPID" 2>/dev/null || kill "-$1" "$CPID" 2>/dev/null
}
stop_child() { # TERM, then KILL after 10 s
  local i=0
  kill_tree TERM
  while kill -0 "$CPID" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  kill -0 "$CPID" 2>/dev/null && kill_tree KILL
}
on_signal() { CANCELLED=1; [ -n "$CPID" ] && stop_child; }
trap 'on_signal' INT TERM HUP

set -m
(
  cd "$CWD" || exit 126
  # the caller's Claude Code session identity must not leak into the child (it would look like that session)
  unset CLAUDECODE CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SSE_PORT \
    CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_WORKER_EPOCH CLAUDE_AFTER_LAST_COMPACT \
    CLAUDE_CODE_SESSION_ATTENDED 2>/dev/null
  while IFS='=' read -r n _; do
    case "$n" in CLAUDE*_SESSION_ID) [[ $n =~ ^[A-Z0-9_]+$ ]] && unset "$n" ;; esac
  done < <(env 2>/dev/null)
  for e in "${ENV_OUT[@]}"; do export "$e"; done
  exec "$BIN" ${ARGV_OUT[@]+"${ARGV_OUT[@]}"} < "$STDIN_SRC" > "$OUTF" 2>> "$LOGF"
) &
CPID=$!
set +m
write_meta running "" "" null null '[]' 0 0

ELAPSED_START=$SECONDS; TICK=0
while kill -0 "$CPID" 2>/dev/null; do
  [ "$CANCELLED" = 1 ] && break
  if [ $((SECONDS - ELAPSED_START)) -ge "$TIMEOUT" ]; then
    TIMED_OUT=1; logh "timeout after ${TIMEOUT}s: stopping the CLI"; stop_child; break
  fi
  if [ $TICK -lt 25 ]; then sleep 0.2; TICK=$((TICK + 1)); else sleep 1; fi
done
wait "$CPID" 2>/dev/null; CLI_EXIT=$?
trap - INT TERM HUP

# ---------- results ----------
pget "$TOOL" out; OUTMODE="$PV"
FINAL=""
case "$OUTMODE" in
  json:*)
    FINAL="$(LC_ALL=C awk -v key="${OUTMODE#json:}" '
      function u8(c) {
        if (c < 128) return sprintf("%c", c)
        if (c < 2048) return sprintf("%c%c", 192 + int(c / 64), 128 + c % 64)
        if (c < 65536) return sprintf("%c%c%c", 224 + int(c / 4096), 128 + int(c / 64) % 64, 128 + c % 64)
        return sprintf("%c%c%c%c", 240 + int(c / 262144), 128 + int(c / 4096) % 64, 128 + int(c / 64) % 64, 128 + c % 64)
      }
      BEGIN { RS = "\001"; hx = "0123456789abcdef"; last = ""; found = 0 }
      {
        s = $0; pat = "\"" key "\"[ \t\r\n]*:[ \t\r\n]*\""
        while (match(s, pat)) {
          i = RSTART + RLENGTH; out = ""; n = length(s); hi = 0
          while (i <= n) {
            c = substr(s, i, 1)
            if (c == "\"") break
            if (c == "\\") {
              i++; d = substr(s, i, 1)
              if (d == "n") out = out "\n"; else if (d == "t") out = out "\t"
              else if (d == "r" || d == "b" || d == "f") { }
              else if (d == "u") {
                code = 0
                for (k = 1; k <= 4; k++) code = code * 16 + index(hx, tolower(substr(s, i + k, 1))) - 1
                i += 4
                if (code >= 55296 && code < 56320) hi = code
                else if (code >= 56320 && code < 57344 && hi) { out = out u8(65536 + (hi - 55296) * 1024 + (code - 56320)); hi = 0 }
                else if (code >= 32 || code == 10 || code == 9) out = out u8(code)
              } else out = out d
            } else out = out c
            i++
          }
          last = out; found = 1
          s = substr(s, i + 1)
        }
      }
      END { if (found) printf "%s", last }' "$OUTF" 2>/dev/null)" ;;
  file) [ -f "$LASTF" ] && FINAL="$(cat "$LASTF" 2>/dev/null)" ;;
  *) FINAL="$(tail -c 65536 "$OUTF" 2>/dev/null)" ;;
esac
FINAL="$(printf '%s' "$FINAL" | head -c 65536 | tr -d '\000-\010\013\014\016-\037')"
printf '%s' "$FINAL" > "$FINALF"
SESSION_ID=""
SRE='"(session_id|sessionId|sessionID|thread_id)"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._:-]{1,128})"'
SLINE="$(grep -m1 -Eo "$SRE" "$OUTF" 2>/dev/null)"
[[ $SLINE =~ $SRE ]] && SESSION_ID="${BASH_REMATCH[2]}"

# exit class (first match wins)
TAILTXT="$( { grep -v '^\[subdeck\] ' "$LOGF" 2>/dev/null | tail -n 100; tail -n 100 "$OUTF" 2>/dev/null; } )"
pget "$TOOL" auth_codes; AUTH_CODES="$PV"
pget "$TOOL" auth_re; AUTH_RE="$PV"
pget "$TOOL" quota_re; QUOTA_RE="$PV"
if [ "$CANCELLED" = 1 ]; then STATUS=cancelled; EXIT=130
elif [ "$TIMED_OUT" = 1 ]; then STATUS=timeout; EXIT=124
elif [ "$CLI_EXIT" = 0 ]; then STATUS=ok; EXIT=0
elif case " ${AUTH_CODES//,/ } " in *" $CLI_EXIT "*) true ;; *) false ;; esac \
     || { [ -n "$AUTH_RE" ] && printf '%s' "$TAILTXT" | grep -Eiq -- "$AUTH_RE"; }; then STATUS=auth; EXIT=6
elif [ -n "$QUOTA_RE" ] && printf '%s' "$TAILTXT" | grep -Eiq -- "$QUOTA_RE"; then STATUS=quota; EXIT=7
else STATUS=failed; EXIT=1; fi
case "$STATUS" in
  auth) pget "$TOOL" auth_hint; logh "auth: $PV"; printf 'run.sh: %s needs a login: %s\n' "$TOOL" "$PV" >&2 ;;
esac

# task status after the run
case "$STATUS" in
  ok) ERRT="" ;;
  failed) if [ -n "$FINAL" ]; then ERRT=""; else ERRT=cli_error; fi ;;
  quota) ERRT=rate_limit ;; auth) ERRT=auth ;; timeout) ERRT=timeout ;; cancelled) ERRT=cancelled ;;
esac
if [ -z "$ERRT" ]; then
  task_hook SubagentStop ",\"last_assistant_message\":$(jstr "$FINAL")"
else
  task_hook StopFailure ",\"error_type\":\"$ERRT\""
fi

# writable check (always, also on failure)
VIOL=""; VCOUNT=0; COMMITS=0; UNCOMMITTED=0; VW=""; VG=""; VS=""; IGN=""; IGNCOUNT=0
add_viol() { VCOUNT=$((VCOUNT + 1)); [ "$VCOUNT" -le 50 ] && VIOL="$VIOL$1$NL"; }
if [ "$CHECK" = ok ]; then
  POST="$(changed_paths "$CWD" "$RUNBASE")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -n "$PRE" ] && printf '%s\n' "$PRE" | grep -Fxq -- "$p"; then continue; fi
    path_allowed "$p" && continue
    VW="$VW$p$NL"; add_viol "$p"
  done <<< "$POST"
  # writes into the git dir (hooks, config) bypass the work-tree diff
  GSNAP2="$(gitdir_snapshot)"
  if [ "$GSNAP" != "$GSNAP2" ]; then
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      VG="${VG}git-dir:$g$NL"; add_viol "git-dir:$g"
    done < <({ printf '%s\n' "$GSNAP"; printf '%s\n' "$GSNAP2"; } | grep -v '^$' | LC_ALL=C sort | uniq -u | sed 's/^[^ ]* //' | LC_ALL=C sort -u)
  fi
  # symlinks made or changed in the run that point outside the work tree; ignored files written in the run (warning)
  if [ -f "$MARKF" ] && [ -n "$TOP" ]; then
    NEWF="$(find "$TOP" -path "$TOP/.git" -prune -o -newer "$MARKF" \( -type f -o -type l \) -print 2>/dev/null | head -n 5000 | awk -v t="$TOP/" 'index($0, t) == 1 { print substr($0, length(t) + 1) }')"
    while IFS= read -r p; do
      [ -n "$p" ] && [ -L "$TOP/$p" ] || continue
      if link_escapes "$p"; then VS="${VS}symlink-escape:$p -> $LINK_T$NL"; add_viol "symlink-escape:$p -> $LINK_T"; fi
    done <<< "$NEWF"
    if [ -n "$NEWF" ]; then
      IGN="$(printf '%s\n' "$NEWF" | git -C "$TOP" check-ignore --stdin 2>/dev/null)"
      [ -n "$IGN" ] && IGNCOUNT="$(printf '%s\n' "$IGN" | wc -l | tr -d ' ')"
    fi
  fi
  rm -f "$MARKF" 2>/dev/null
  COMMITS="$(git -C "$CWD" rev-list --count "$RUNBASE..HEAD" 2>/dev/null)"; [[ $COMMITS =~ ^[0-9]+$ ]] || COMMITS=0
  UNCOMMITTED="$(git -C "$CWD" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
fi
if [ "$IGNCOUNT" -gt 0 ]; then
  logh "warning: $IGNCOUNT gitignored file(s) written in this run (not checked against writable): $(printf '%s' "$IGN" | head -n 50 | tr '\n' ' ')"
  { printf '%s\n' "$IGN" | head -n 50; [ "$IGNCOUNT" -gt 50 ] && printf '(%s more)\n' "$((IGNCOUNT - 50))"; } \
    | bash "$TASKS_SH" --project "$PROJECT" append "$TASK" report --label "warning: gitignored files written ($ROLE $TOOL)" >> "$LOGF" 2>&1 \
    || logh "warning: could not append the ignored-files warning to $TASK"
fi
jlist() { # lines -> JSON array
  local out
  out="$(while IFS= read -r p; do [ -n "$p" ] && { jesc "$p"; printf '"%s"\n' "$JE"; }; done <<< "$1" | head -n 50 | paste -sd, -)"
  printf '[%s]' "$out"
}
violation_event() { # reason lines
  local n
  [ -n "$2" ] || return 0
  n="$(printf '%s' "$2" | grep -c .)"
  emit_event writable_violation "{\"agent_id\":$(jstr "$RUN_ID"),\"agent_type\":$(jstr "$AGENT_TYPE"),\"session_id\":$(jstr "$RUN_ID"),\"task\":$(jstr "$TASK"),\"role\":$(jstr "$ROLE"),\"tool\":$(jstr "$TOOL"),\"paths\":$(jlist "$2"),\"count\":$n,\"reason\":$(jstr "$1")}"
}
VJSON='[]'
if [ "$VCOUNT" -gt 0 ]; then
  CHECK=violation
  VJSON="$(jlist "$VIOL")"
  logh "writable violation ($VCOUNT): $(printf '%s' "$VIOL" | tr '\n' ' ')"
  violation_event writable "$VW"
  violation_event git-dir "$VG"
  violation_event symlink-escape "$VS"
  bash "$TASKS_SH" --project "$PROJECT" set "$TASK" status=blocked >> "$LOGF" 2>&1 || logh "warning: could not set $TASK blocked"
  { printf '%s' "$VIOL"; [ "$VCOUNT" -gt 50 ] && printf '(%s more)\n' "$((VCOUNT - 50))"; } \
    | bash "$TASKS_SH" --project "$PROJECT" append "$TASK" report --label "writable violation ($ROLE $TOOL)" >> "$LOGF" 2>&1 \
    || logh "warning: could not append the violation to $TASK"
  printf 'run.sh: writable violation: %s path(s) outside the writable list of %s; task blocked (nothing reverted)\n' "$VCOUNT" "$TASK" >&2
  if [ "$STATUS" = ok ]; then STATUS=violation; EXIT=5; fi
fi

# ---------- finish ----------
ENDED="$(now_iso)"
SJ=null; [ -n "$SESSION_ID" ] && SJ="$(jstr "$SESSION_ID")"
write_meta "$STATUS" "$CLI_EXIT" "$EXIT" "$(jstr "$ENDED")" "$SJ" "$VJSON" "$COMMITS" "$UNCOMMITTED"
{
  printf '[subdeck] --- stdout ---\n'
  head -c 1048576 "$OUTF" 2>/dev/null
  printf '\n[subdeck] end status=%s cliExit=%s exit=%s commits=%s uncommitted=%s writable=%s\n' "$STATUS" "$CLI_EXIT" "$EXIT" "$COMMITS" "$UNCOMMITTED" "$CHECK"
} >> "$LOGF"
DUR=$(( (SECONDS - START_S) * 1000 ))
emit_event run_end "{\"agent_id\":$(jstr "$RUN_ID"),\"agent_type\":$(jstr "$AGENT_TYPE"),\"session_id\":$(jstr "$RUN_ID"),\"task\":$(jstr "$TASK"),\"role\":$(jstr "$ROLE"),\"tool\":$(jstr "$TOOL"),\"model\":$(jstr "$MODEL"),\"status\":$(jstr "$STATUS"),\"cliExit\":$CLI_EXIT,\"exit\":$EXIT,\"durationMs\":$DUR,\"log\":$(jstr "$LOGF"),\"finalChars\":${#FINAL},\"commits\":$COMMITS,\"uncommitted\":$UNCOMMITTED,\"writableCheck\":$(jstr "$CHECK")}"
lock_release
printf 'run %s: %s (exit %s); log %s\n' "$RUN_ID" "$STATUS" "$EXIT" "$LOGF"
exit "$EXIT"
