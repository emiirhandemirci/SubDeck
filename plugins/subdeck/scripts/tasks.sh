#!/usr/bin/env bash
# SubDeck task files: one markdown file per delegated job, kept in the task dir (default <state>/tasks).
# Bash 3.2+, bash + awk + sed + cksum (+ git for the handoff note). No jq/node.
#
# Usage: tasks.sh [--project <dir>] <command> ...
#   new "<title>" [--owner T] [--writable a,b] [--blocked-by t-x,t-y] [--task <text>|--task-file <f>] [--done-when <text>]   -> id
#   set <id> key=value ...     keys: title owner agent session transcript blocked-by writable status (not done)
#   append <id> <task|done-when|report|verification|handoff>      text on stdin, added as a "### <time> note" block
#   done <id> [--force]        needs a line "Verdict: Approved" under ## Verification; moves the file to archive/
#   list [--status s] [--all] [--json]    TSV: id status owner agent updated title
#   ready [--json]             open tasks whose blocked-by ids all exist and are done
#   show <id>                  the file verbatim (live or archive)
#   dir                        the resolved task dir (not created)
#   hook <SubagentStart|SubagentStop|StopFailure>   payload on stdin; called by log-event.sh; always exits 0
# Exit codes (CLI): 0 ok, 1 id not found, 2 usage / invalid value, 3 done refused, 4 lock busy.
# Task dir: env SUBDECK_TASKS_DIR, else config tasks.dir (project config wins over ~/.subdeck/config.json),
#   else <state>/tasks (lib-paths.sh). Relative values are relative to the project. Task file grammar: see docs.
# Env: SUBDECK_TASKS=0 disables the hook side (log-event.sh does not call it).

LC_COLLATE=C
HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
. "$HERE/lib-paths.sh" 2>/dev/null || { echo "tasks.sh: lib-paths.sh missing" >&2; exit 2; }

STATUSES="open in-progress blocked interrupted review done"
ID_RE='^t-[0-9a-f]{4,12}$'
US=$'\037'
TAB=$'\t'
NL=$'\n'
BS='\'; BB='\\'; SL='/'; DQ='"'

# ---------- args ----------
PROJECT=""
ARGV=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) shift; PROJECT="${1:-}"; [ $# -gt 0 ] && shift ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    *) ARGV[${#ARGV[@]}]="${1%$'\r'}"; shift ;;
  esac
done
CMD="${ARGV[0]:-}"
[ -n "$CMD" ] && ARGV=("${ARGV[@]:1}")
# payload (hook mode) is read first so cwd can name the project
PAYLOAD=""; COMPACT=""
if [ "$CMD" = hook ]; then
  HOOK_EXIT=0
  PAYLOAD="$(cat 2>/dev/null)"
  COMPACT="$(printf '%s' "$PAYLOAD" | tr -d '\r\n')"
fi
if [ -z "$PROJECT" ]; then
  PROJECT="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$PROJECT" ] && [ -n "$COMPACT" ] && [[ $COMPACT =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then PROJECT="${BASH_REMATCH[1]}"; fi
  [ -n "$PROJECT" ] && [ -d "$PROJECT" ] || PROJECT="$(pwd)"
fi
PROJECT="${PROJECT%/}"; [ -n "$PROJECT" ] || PROJECT="/"
sd_state_dir "$PROJECT"
STATE="$SD_STATE"

die() { # code message
  printf 'tasks.sh: %s\n' "$2" >&2
  exit "$1"
}
log_err() { [ -n "$SD_KEY" ] || return 0; mkdir -p "$STATE" 2>/dev/null; printf '%s tasks.sh: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/hook-errors.log" 2>/dev/null; return 0; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_s() { printf -v "$1" '%(%s)T' -1 2>/dev/null || printf -v "$1" '%s' "$(date +%s)"; }
trim() { # STR -> TRIMMED
  TRIMMED="$1"
  TRIMMED="${TRIMMED#"${TRIMMED%%[![:space:]]*}"}"
  TRIMMED="${TRIMMED%"${TRIMMED##*[![:space:]]}"}"
}

# ---------- config and dir ----------
# cfg_tasks_member FILE -> CFG_TASKS (raw {...} of the "tasks" member, or empty)
cfg_tasks_member() {
  CFG_TASKS=""
  [ -f "$1" ] || return 0
  local c
  c="$(<"$1")" 2>/dev/null; c="${c//$'\r'/}"; c="${c//$'\n'/}"
  if [[ $c =~ \"tasks\"[[:space:]]*:[[:space:]]*\{[^\}]*\} ]]; then CFG_TASKS="${BASH_REMATCH[0]}"; fi
}
# cfg_files -> CFG_LIST (most specific first): state config, legacy project config, user config
cfg_files() {
  CFG_LIST=("$STATE/config.json" "$SD_LEGACY/config.json" "${HOME}/.subdeck/config.json")
}
resolve_dir() {
  local d="" f
  if [ -n "${SUBDECK_TASKS_DIR:-}" ]; then d="$SUBDECK_TASKS_DIR"
  else
    cfg_files
    for f in "${CFG_LIST[@]}"; do
      cfg_tasks_member "$f"
      if [[ $CFG_TASKS =~ \"dir\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
        d="${BASH_REMATCH[1]}"; d=${d//"$BB"/$SL}; d=${d//"$BS"/$SL}
        [ -n "$d" ] && break
      fi
    done
  fi
  d=${d//"$BB"/$SL}; d=${d//"$BS"/$SL}
  if [ -z "$d" ]; then d="$STATE/tasks"
  else
    case "$d" in
      /*|[A-Za-z]:*) ;;
      *) d="$PROJECT/$d" ;;
    esac
    case "$d" in /*|[A-Za-z]:*) ;; *) d="$(pwd)/$d" ;; esac
  fi
  while [ "${#d}" -gt 1 ] && [ "${d%/}" != "$d" ]; do d="${d%/}"; done
  DIR="$d"
}
report_check_on() { # 0 when tasks.reportCheck is not false
  local f
  cfg_files
  for f in "${CFG_LIST[@]}"; do
    cfg_tasks_member "$f"
    if [[ $CFG_TASKS =~ \"reportCheck\"[[:space:]]*:[[:space:]]*(true|false) ]]; then
      [ "${BASH_REMATCH[1]}" = true ]; return
    fi
  done
  return 0
}

# ---------- lock ----------
HAVE_LOCK=0
lock_release() { [ "$HAVE_LOCK" = 1 ] && rm -rf "$DIR/.lock" 2>/dev/null; HAVE_LOCK=0; }
trap 'lock_release' EXIT
HOOK_EXIT=130
trap 'lock_release; exit "$HOOK_EXIT"' INT TERM HUP
lock_acquire() { # 0 ok, 1 busy after 5 s
  local start now owner ts missing=0
  mkdir -p "$DIR" 2>/dev/null || return 1
  now_s start
  while :; do
    if mkdir "$DIR/.lock" 2>/dev/null; then
      HAVE_LOCK=1
      now_s now
      printf '%s %s\n' "$$" "$now" > "$DIR/.lock/owner.tmp" 2>/dev/null && mv -f "$DIR/.lock/owner.tmp" "$DIR/.lock/owner" 2>/dev/null
      return 0
    fi
    now_s now
    ts=""; owner=""
    if { read -r owner < "$DIR/.lock/owner"; } 2>/dev/null && [[ $owner =~ ^[0-9]+\ ([0-9]{9,})$ ]]; then ts="${BASH_REMATCH[1]}"; fi
    if [ -n "$ts" ]; then
      missing=0
      if [ $((now - ts)) -gt 10 ]; then mv "$DIR/.lock" "$DIR/.lock.stale.$$" 2>/dev/null && rm -rf "$DIR/.lock.stale.$$" 2>/dev/null; continue; fi
    else
      missing=$((missing + 1))
      if [ "$missing" -gt 40 ]; then mv "$DIR/.lock" "$DIR/.lock.stale.$$" 2>/dev/null && rm -rf "$DIR/.lock.stale.$$" 2>/dev/null; missing=0; continue; fi
    fi
    [ $((now - start)) -ge 5 ] && return 1
    sleep 0.05
  done
}

# ---------- task files ----------
is_id() { [[ $1 =~ $ID_RE ]]; }
status_ok() { case " $STATUSES " in *" $1 "*) return 0 ;; esac; return 1; }
# normalise a list value ("[a, b]" or "a, b") -> comma-joined items in LIST_OUT
parse_list() {
  local v="$1" item out="" arr
  trim "$v"; v="$TRIMMED"
  v="${v#\[}"; v="${v%\]}"
  IFS=, read -ra arr <<< "$v"
  for item in "${arr[@]}"; do
    trim "$item"
    if [ -n "$TRIMMED" ]; then out="$out${out:+,}$TRIMMED"; fi
  done
  LIST_OUT="$out"
}
join_list() { # comma list -> "a, b" in JOINED
  JOINED="${1//,/, }"
}
# find_file ID -> FOUND (path) and FOUND_ARCH (0/1); returns 1 when absent
find_file() {
  FOUND=""; FOUND_ARCH=0
  is_id "$1" || return 1
  if [ -f "$DIR/$1.md" ]; then FOUND="$DIR/$1.md"; return 0; fi
  if [ -f "$DIR/archive/$1.md" ]; then FOUND="$DIR/archive/$1.md"; FOUND_ARCH=1; return 0; fi
  return 1
}
# load_task FILE: T_* variables, T_EXTRA, T_BODY, T_INVALID. Returns 1 when the file has no frontmatter.
load_task() {
  local line state=0 key val
  T_id=""; T_title=""; T_status=""; T_owner=""; T_agent=""; T_session=""; T_transcript=""
  T_blocked_by=""; T_writable=""; T_created=""; T_updated=""; T_EXTRA=""; T_BODY=""; T_INVALID=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "$state" = 0 ]; then
      [ "$line" = "---" ] || return 1
      state=1; continue
    elif [ "$state" = 1 ]; then
      if [ "$line" = "---" ]; then state=2; continue; fi
      if [[ $line =~ ^([a-z][a-z-]*):(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"; trim "${BASH_REMATCH[2]}"; val="$TRIMMED"
        case "$key" in
          blocked-by) parse_list "$val"; T_blocked_by="$LIST_OUT" ;;
          writable) parse_list "$val"; T_writable="$LIST_OUT" ;;
          id|title|status|owner|agent|session|transcript|created|updated) printf -v "T_$key" '%s' "$val" ;;
          *) T_EXTRA="$T_EXTRA$key: $val$NL" ;;
        esac
      fi
    else
      T_BODY="$T_BODY$line$NL"
    fi
  done < "$1"
  [ "$state" = 2 ] || return 1
  if [ -z "$T_status" ]; then T_status=open
  elif ! status_ok "$T_status"; then T_status=open; T_INVALID=1; fi
  return 0
}
# write_task DEST: writes T_* to DEST (temp + mv), sets updated unless T_KEEP_UPDATED=1
write_task() {
  local dest="$1" tmp d b
  d="${dest%/*}"; b="${dest##*/}"
  tmp="$d/.$b.tmp.$$"
  [ "${T_KEEP_UPDATED:-0}" = 1 ] || now_iso_to T_updated
  {
    printf -- '---\n'
    printf 'id: %s\n' "$T_id"
    printf 'title: %s\n' "$T_title"
    printf 'status: %s\n' "$T_status"
    printf 'owner: %s\n' "$T_owner"
    printf 'agent: %s\n' "$T_agent"
    printf 'session: %s\n' "$T_session"
    printf 'transcript: %s\n' "$T_transcript"
    join_list "$T_blocked_by"; printf 'blocked-by: [%s]\n' "$JOINED"
    join_list "$T_writable"; printf 'writable: [%s]\n' "$JOINED"
    printf 'created: %s\n' "$T_created"
    printf 'updated: %s\n' "$T_updated"
    if [ -n "$T_EXTRA" ]; then printf '%s' "$T_EXTRA"; fi
    printf -- '---\n'
    if [ -n "$T_BODY" ]; then printf '%s' "$T_BODY"; fi
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}
now_iso_to() { printf -v "$1" '%s' "$(now_iso)"; }
# clean_text: stdin -> stdout without CR, lines starting "## " indented
clean_text() { sed -e 's/\r$//' -e 's/^## /    ## /'; }
# append_block SECTION_HEADING BLOCK: adds BLOCK at the end of the section in T_BODY
append_block() {
  local out
  out="$(printf '%s' "$T_BODY" | BLOCK="$2" awk -v head="$1" '
    function emit(   n, a, i) { n = split(ENVIRON["BLOCK"], a, "\n"); for (i = 1; i <= n; i++) print a[i] }
    /^## / {
      if (insec) { emit(); print ""; insec = 0; done = 1; blanks = 0 }
      if ($0 == head && !done) insec = 1
      print; next
    }
    insec { if ($0 == "") { blanks++; next } for (i = 0; i < blanks; i++) print ""; blanks = 0; print; next }
    { print }
    END { if (insec) { emit(); done = 1 } if (!done) { if (NR > 0) print ""; print head; emit() } }')"
  T_BODY="$out$NL"
}
# get_section BODY HEADING -> stdout
get_section() {
  printf '%s' "$1" | awk -v head="$2" '
    /^## / { insec = ($0 == head); next }
    insec { print }'
}
section_heading() { # name -> HEADING
  case "$1" in
    task) HEADING="## Task" ;; done-when) HEADING="## Done when" ;; report) HEADING="## Report" ;;
    verification) HEADING="## Verification" ;; handoff) HEADING="## Handoff" ;; *) return 1 ;;
  esac
}
sanitize_title() { # STR -> TITLE_OUT
  local t="${1//$'\r'/ }"; t="${t//$'\n'/ }"; t="${t//$TAB/ }"
  trim "$t"; TITLE_OUT="${TRIMMED:0:200}"
  trim "$TITLE_OUT"; TITLE_OUT="$TRIMMED"
}
has_nl() { case "$1" in *$'\n'*|*$'\r'*) return 0 ;; esac; return 1; }
valid_list() { # comma list: items without [ ] ; returns 1 when bad
  case "$1" in *\[*|*\]*) return 1 ;; esac
  return 0
}
valid_ids() { # comma list of task ids
  local i arr
  IFS=, read -ra arr <<< "$1"
  for i in "${arr[@]}"; do trim "$i"; [ -z "$TRIMMED" ] && continue; is_id "$TRIMMED" || return 1; done
  return 0
}

# ---------- events and notify ----------
jesc() { # STR -> JESC
  local s="$1"
  s=${s//"$BS"/"$BS$BS"}; s=${s//"$DQ"/"$BS$DQ"}; s=${s//"$TAB"/"${BS}t"}; s=${s//"$NL"/"${BS}n"}; s=${s//$'\r'/}
  JESC="$s"
}
safe_tok() { printf '%s' "${1//[^A-Za-z0-9._:\/-]/}"; }
emit_event() { # kind json
  printf '%s' "$2" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$HERE/log-event.sh" "$1" >/dev/null 2>&1
  return 0
}
emit_status_event() { # task from to by agent session
  emit_event task_status "$(printf '{"agent_id":"%s","session_id":"%s","task":"%s","from":"%s","to":"%s","by":"%s"}' "$(safe_tok "$5")" "$(safe_tok "$6")" "$1" "$2" "$3" "$4")"
}
fire_notify() { # notification_type agent_type session
  local cwd="${PROJECT//\\//}"; jesc "$cwd"; cwd="$JESC"
  printf '{"session_id":"%s","cwd":"%s","agent_type":"%s","notification_type":"%s"}' "$(safe_tok "$3")" "$cwd" "$(safe_tok "$2")" "$1" \
    | CLAUDE_PROJECT_DIR="$PROJECT" bash "$HERE/notify.sh" hook waiting >/dev/null 2>&1
  return 0
}

# ---------- listing ----------
# collect ALL(0/1) -> ROWS (one line per task, US separated, sorted by updated desc)
collect() {
  local all="$1" f b rows="" arch d
  for d in "$DIR" "$DIR/archive"; do
    arch=0; [ "$d" = "$DIR/archive" ] && arch=1
    [ "$arch" = 1 ] && [ "$all" != 1 ] && continue
    [ -d "$d" ] || continue
    for f in "$d"/t-*.md; do
      [ -f "$f" ] || continue
      b="${f##*/}"; b="${b%.md}"
      is_id "$b" || continue
      load_task "$f" || continue
      local title="${T_title//$TAB/ }"
      rows="$rows$T_updated$US$b$US$T_status$US$T_owner$US$T_agent$US$T_session$US$T_transcript$US$T_blocked_by$US$T_writable$US$T_created$US$arch$US$T_INVALID$US$f$US$title$NL"
    done
  done
  if [ -n "$rows" ]; then ROWS="$(printf '%s' "$rows" | sort -t "$US" -k1,1r -k2,2)"; else ROWS=""; fi
}
json_list() { # comma list -> JL ["a","b"]
  local i out="" arr
  IFS=, read -ra arr <<< "$1"
  for i in "${arr[@]}"; do [ -n "$i" ] || continue; jesc "$i"; out="$out${out:+,}\"$JESC\""; done
  JL="[$out]"
}
print_rows() { # json(0/1), reads ROWS
  local upd id st ow ag se tr bl wr cr arch inv file title first=1 s
  if [ "$1" = 1 ]; then
    jesc "$DIR"; printf '{"version":1,"dir":"%s","tasks":[' "$JESC"
  fi
  [ -n "$ROWS" ] || { [ "$1" = 1 ] && printf ']}\n'; return 0; }
  while IFS="$US" read -r upd id st ow ag se tr bl wr cr arch inv file title; do
    if [ "$1" = 1 ]; then
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{'
      jesc "$id"; printf '"id":"%s",' "$JESC"
      jesc "$title"; printf '"title":"%s",' "$JESC"
      jesc "$st"; printf '"status":"%s",' "$JESC"
      jesc "$ow"; printf '"owner":"%s",' "$JESC"
      jesc "$ag"; printf '"agent":"%s",' "$JESC"
      jesc "$se"; printf '"session":"%s",' "$JESC"
      jesc "$tr"; printf '"transcript":"%s",' "$JESC"
      json_list "$bl"; printf '"blockedBy":%s,' "$JL"
      json_list "$wr"; printf '"writable":%s,' "$JL"
      jesc "$cr"; printf '"created":"%s",' "$JESC"
      jesc "$upd"; printf '"updated":"%s",' "$JESC"
      if [ "$arch" = 1 ]; then s=true; else s=false; fi; printf '"archived":%s,' "$s"
      if [ "$inv" = 1 ]; then s=true; else s=false; fi; printf '"invalid":%s,' "$s"
      jesc "$file"; printf '"file":"%s"}' "$JESC"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$st" "$ow" "$ag" "$upd" "$title"
    fi
  done <<< "$ROWS"
  [ "$1" = 1 ] && printf ']}\n'
  return 0
}

# ---------- CLI commands ----------
need_lock() {
  lock_acquire || die 4 "task lock busy ($DIR/.lock); try again"
}
cmd_new() {
  local title="" owner="" writable="" blocked="" task="" done_when="" have_task=0 a
  while [ ${#ARGV[@]} -gt 0 ]; do
    a="${ARGV[0]}"
    case "$a" in
      --owner|--writable|--blocked-by|--task|--task-file|--done-when)
        [ ${#ARGV[@]} -ge 2 ] || die 2 "$a needs a value"
        case "$a" in
          --owner) owner="${ARGV[1]}" ;;
          --writable) writable="${ARGV[1]}" ;;
          --blocked-by) blocked="${ARGV[1]}" ;;
          --task) task="${ARGV[1]}"; have_task=1 ;;
          --task-file) [ -f "${ARGV[1]}" ] || die 2 "task file not found: ${ARGV[1]}"; task="$(<"${ARGV[1]}")"; have_task=1 ;;
          --done-when) done_when="${ARGV[1]}" ;;
        esac
        ARGV=("${ARGV[@]:2}") ;;
      --*) die 2 "unknown option $a" ;;
      *) [ -z "$title" ] || die 2 "unexpected argument '$a'"; title="$a"; ARGV=("${ARGV[@]:1}") ;;
    esac
  done
  sanitize_title "$title"; title="$TITLE_OUT"
  [ -n "$title" ] || die 2 'usage: new "<title>" [--owner T] [--writable a,b] [--blocked-by t-x,t-y] [--task <text>|--task-file <f>] [--done-when <text>]'
  has_nl "$owner" && die 2 "owner must be one line"
  parse_list "$writable"; writable="$LIST_OUT"; valid_list "$writable" || die 2 "writable items may not contain [ or ]"
  has_nl "$writable" && die 2 "writable must be one line"
  parse_list "$blocked"; blocked="$LIST_OUT"; valid_ids "$blocked" || die 2 "blocked-by needs task ids (t-<hex>)"
  need_lock
  local h len cand tries=0
  gen_h() { h="$(printf '%s|%s|%s|%s' "$(date +%s)" "$$" "$RANDOM" "$title" | cksum)"; h="${h%% *}"; printf -v h '%08x' "$h"; }
  gen_h; len=4
  while :; do
    cand="t-${h:0:$len}"
    if [ ! -e "$DIR/$cand.md" ] && [ ! -e "$DIR/archive/$cand.md" ]; then break; fi
    if [ "$len" -lt 6 ]; then len=$((len + 1)); else gen_h; len=4; fi
    tries=$((tries + 1)); [ "$tries" -gt 2000 ] && { lock_release; die 2 "could not generate a free id"; }
  done
  T_id="$cand"; T_title="$title"; T_status=open; T_owner="$owner"; T_agent=""; T_session=""; T_transcript=""
  T_blocked_by="$blocked"; T_writable="$writable"; now_iso_to T_created; T_updated="$T_created"; T_EXTRA=""
  T_BODY="## Task$NL"
  if [ "$have_task" = 1 ]; then T_BODY="$T_BODY$(printf '%s' "$task" | clean_text)$NL"; fi
  T_BODY="$T_BODY${NL}## Done when$NL"
  if [ -n "$done_when" ]; then T_BODY="$T_BODY$(printf '%s' "$done_when" | clean_text)$NL"; fi
  T_BODY="$T_BODY${NL}## Report$NL${NL}## Verification$NL${NL}## Handoff$NL"
  T_KEEP_UPDATED=1
  write_task "$DIR/$T_id.md" || { lock_release; die 2 "could not write $DIR/$T_id.md"; }
  lock_release
  printf '%s\n' "$T_id"
}
cmd_set() {
  local id="${ARGV[0]:-}" pair k v i
  [ -n "$id" ] || die 2 "usage: set <id> key=value ..."
  ARGV=("${ARGV[@]:1}")
  [ ${#ARGV[@]} -gt 0 ] || die 2 "usage: set <id> key=value ..."
  local S_title="" S_owner="" S_agent="" S_session="" S_transcript="" S_blocked_by="" S_writable="" S_status=""
  local HAS=" "
  for pair in "${ARGV[@]}"; do
    case "$pair" in *=*) ;; *) die 2 "expected key=value, got '$pair'" ;; esac
    k="${pair%%=*}"; v="${pair#*=}"
    case "$k" in
      title) sanitize_title "$v"; v="$TITLE_OUT"; [ -n "$v" ] || die 2 "title may not be empty"; S_title="$v" ;;
      owner|agent|session|transcript)
        has_nl "$v" && die 2 "$k must be one line"
        trim "$v"; printf -v "S_$k" '%s' "$TRIMMED" ;;
      blocked-by) parse_list "$v"; valid_ids "$LIST_OUT" || die 2 "blocked-by needs task ids (t-<hex>)"; has_nl "$v" && die 2 "blocked-by must be one line"; S_blocked_by="$LIST_OUT" ;;
      writable) has_nl "$v" && die 2 "writable must be one line"; parse_list "$v"; valid_list "$LIST_OUT" || die 2 "writable items may not contain [ or ]"; S_writable="$LIST_OUT" ;;
      status)
        trim "$v"; v="$TRIMMED"
        [ "$v" = done ] && die 2 "status done is set with 'tasks.sh done'"
        status_ok "$v" || die 2 "invalid status '$v' (open in-progress blocked interrupted review)"
        S_status="$v" ;;
      *) die 2 "cannot set '$k' (keys: title owner agent session transcript blocked-by writable status)" ;;
    esac
    HAS="$HAS$k "
  done
  find_file "$id" || die 1 "task not found: $id"
  [ "$FOUND_ARCH" = 0 ] || die 1 "task $id is archived"
  need_lock
  find_file "$id" || { lock_release; die 1 "task not found: $id"; }
  load_task "$FOUND" || { lock_release; die 2 "task file unreadable: $FOUND"; }
  local old="$T_status"
  case "$HAS" in *" title "*) T_title="$S_title" ;; esac
  case "$HAS" in *" owner "*) T_owner="$S_owner" ;; esac
  case "$HAS" in *" agent "*) T_agent="$S_agent" ;; esac
  case "$HAS" in *" session "*) T_session="$S_session" ;; esac
  case "$HAS" in *" transcript "*) T_transcript="$S_transcript" ;; esac
  case "$HAS" in *" blocked-by "*) T_blocked_by="$S_blocked_by" ;; esac
  case "$HAS" in *" writable "*) T_writable="$S_writable" ;; esac
  case "$HAS" in *" status "*) T_status="$S_status" ;; esac
  T_id="$id"
  write_task "$FOUND" || { lock_release; die 2 "could not write $FOUND"; }
  local ag="$T_agent" se="$T_session" nw="$T_status"
  lock_release
  [ "$old" != "$nw" ] && emit_status_event "$id" "$old" "$nw" cli "$ag" "$se"
  return 0
}
cmd_append() {
  local id="${ARGV[0]:-}" sec="${ARGV[1]:-}" text blk
  [ -n "$id" ] && [ -n "$sec" ] || die 2 "usage: append <id> <task|done-when|report|verification|handoff>  (text on stdin)"
  section_heading "$sec" || die 2 "unknown section '$sec' (task done-when report verification handoff)"
  find_file "$id" || die 1 "task not found: $id"
  text="$(clean_text)"
  need_lock
  find_file "$id" || { lock_release; die 1 "task not found: $id"; }
  load_task "$FOUND" || { lock_release; die 2 "task file unreadable: $FOUND"; }
  T_id="$id"
  blk="### $(now_iso) note$NL$text"
  append_block "$HEADING" "$blk"
  write_task "$FOUND" || { lock_release; die 2 "could not write $FOUND"; }
  lock_release
}
cmd_done() {
  local id="" force=0 a
  for a in "${ARGV[@]}"; do
    case "$a" in --force) force=1 ;; -*) die 2 "unknown option $a" ;; *) [ -z "$id" ] && id="$a" || die 2 "unexpected argument '$a'" ;; esac
  done
  [ -n "$id" ] || die 2 "usage: done <id> [--force]"
  find_file "$id" || die 1 "task not found: $id"
  need_lock
  find_file "$id" || { lock_release; die 1 "task not found: $id"; }
  if [ "$FOUND_ARCH" = 1 ]; then lock_release; return 0; fi
  load_task "$FOUND" || { lock_release; die 2 "task file unreadable: $FOUND"; }
  if [ "$force" = 0 ]; then
    if ! get_section "$T_BODY" "## Verification" | grep -Eq '^[[:space:]]*Verdict:[[:space:]]*Approved'; then
      lock_release; die 3 "refused: ## Verification of $id has no 'Verdict: Approved' line (use --force to override)"
    fi
  fi
  local old="$T_status" ag="$T_agent" se="$T_session"
  T_id="$id"; T_status=done
  mkdir -p "$DIR/archive" 2>/dev/null
  write_task "$FOUND" || { lock_release; die 2 "could not write $FOUND"; }
  mv -f "$FOUND" "$DIR/archive/$id.md" 2>/dev/null || { lock_release; die 2 "could not archive $id"; }
  lock_release
  [ "$old" != done ] && emit_status_event "$id" "$old" done cli "$ag" "$se"
  return 0
}
cmd_list() {
  local st="" all=0 json=0 a
  while [ ${#ARGV[@]} -gt 0 ]; do
    a="${ARGV[0]}"
    case "$a" in
      --status) [ ${#ARGV[@]} -ge 2 ] || die 2 "--status needs a value"; st="${ARGV[1]}"; ARGV=("${ARGV[@]:1}") ;;
      --all) all=1 ;;
      --json) json=1 ;;
      *) die 2 "unknown argument '$a'" ;;
    esac
    ARGV=("${ARGV[@]:1}")
  done
  [ -z "$st" ] || status_ok "$st" || die 2 "invalid status '$st'"
  collect "$all"
  if [ -n "$st" ] && [ -n "$ROWS" ]; then
    ROWS="$(printf '%s\n' "$ROWS" | awk -F"$US" -v s="$st" '$3 == s')"
  fi
  print_rows "$json"
}
cmd_ready() {
  local json=0 a
  for a in "${ARGV[@]}"; do case "$a" in --json) json=1 ;; *) die 2 "unknown argument '$a'" ;; esac; done
  collect 1
  if [ -n "$ROWS" ]; then
    # open tasks whose every blocker exists and is done (archived counts); rows stay in sorted order
    ROWS="$(printf '%s\n' "$ROWS" | awk -F"$US" '
      { line[NR] = $0; id[NR] = $2; st[NR] = $3; bl[NR] = $8; if ($3 == "done" || $11 == 1) isdone[$2] = 1 }
      END {
        for (i = 1; i <= NR; i++) {
          if (st[i] != "open") continue
          n = split(bl[i], b, ","); ok = 1
          for (k = 1; k <= n; k++) if (b[k] != "" && !(b[k] in isdone)) ok = 0
          if (ok) print line[i]
        }
      }')"
  fi
  print_rows "$json"
}
cmd_show() {
  local id="${ARGV[0]:-}"
  [ -n "$id" ] || die 2 "usage: show <id>"
  find_file "$id" || die 1 "task not found: $id"
  cat "$FOUND"
}

# ---------- hook mode ----------
# sfield KEY -> V (first string value of KEY in the payload; empty when absent)
sfield() {
  V=""
  local re='"'"$1"'"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ $COMPACT =~ $re ]]; then V="${BASH_REMATCH[1]}"; fi
}
# jstring KEY -> stdout, JSON-decoded string value of the first match
jstring() {
  printf '%s' "$COMPACT" | awk -v key="$1" '
    BEGIN { RS = "\001"; hx = "0123456789abcdef" }
    {
      s = $0; pat = "\"" key "\"[ \t]*:[ \t]*\""
      if (!match(s, pat)) exit
      i = RSTART + RLENGTH; out = ""; n = length(s)
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\"") break
        if (c == "\\") {
          i++; d = substr(s, i, 1)
          if (d == "n") out = out "\n"
          else if (d == "t") out = out "\t"
          else if (d == "r") { }
          else if (d == "u") {
            code = 0
            for (k = 1; k <= 4; k++) code = code * 16 + index(hx, tolower(substr(s, i + k, 1))) - 1
            i += 4
            if (code > 0 && code < 128) out = out sprintf("%c", code); else out = out "?"
          } else out = out d
        } else out = out c
        i++
      }
      printf "%s", out
    }'
}
# agent class: worker researcher verifier other
agent_class() {
  local t="${1#subdeck:}"
  case "$t" in
    worker-*) CLASS=worker ;;
    researcher*) CLASS=researcher ;;
    verifier*) CLASS=verifier ;;
    *) CLASS=other ;;
  esac
}
# shape_check CLASS TEXT -> MISSING (space separated names), STOPW (last Stop word, lower case), VERDICT
shape_check() {
  local class="$1" line have_stop=0 have_tested=0 have_verdict=0
  local re_stop='^[[:space:]]*Stop:[[:space:]]*([A-Za-z][A-Za-z-]*)'
  local re_tested='^[[:space:]]*Tested:[[:space:]]*(ran|not run)([^A-Za-z]|$)'
  local re_verdict='^[[:space:]]*Verdict:[[:space:]]*(Approved|Needs fixes|Escalate)'
  STOPW=""; VERDICT=""; MISSING=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ $line =~ $re_stop ]]; then have_stop=1; STOPW="${BASH_REMATCH[1]}"; fi
    if [[ $line =~ $re_tested ]]; then have_tested=1; fi
    if [[ $line =~ $re_verdict ]]; then have_verdict=1; VERDICT="${BASH_REMATCH[1]}"; fi
  done <<< "$2"
  sd_lower "$STOPW"; STOPW="$SD_LOWER"
  case "$class" in
    verifier) [ "$have_verdict" = 1 ] || MISSING="Verdict" ;;
    researcher) [ "$have_stop" = 1 ] || MISSING="Stop" ;;
    *) [ "$have_stop" = 1 ] || MISSING="Stop"; [ "$have_tested" = 1 ] || MISSING="$MISSING${MISSING:+ }Tested" ;;
  esac
}
missing_json() { # "Stop Tested" -> ["Stop","Tested"]
  local m out=""
  for m in $1; do out="$out${out:+,}\"$m\""; done
  MJ="[$out]"
}
# find the task id: sets TID ("" when none)
TASK_RE='Task:[[:space:]]*(t-[0-9a-f]{4,12})'
find_task_id() { # event
  TID=""; TR_PATH=""
  local tp="" aid="$AGENT_ID" line f
  if [[ $COMPACT =~ $TASK_RE ]]; then TID="${BASH_REMATCH[1]}"; fi
  sfield agent_transcript_path; tp="$V"
  if [ -z "$tp" ]; then
    sfield transcript_path
    if [ -n "$V" ] && [ -n "$aid" ]; then tp="${V%.jsonl}/subagents/agent-$aid.jsonl"; fi
  fi
  TR_PATH="$tp"
  if [ -z "$TID" ] && [ -n "$tp" ] && [ -f "$tp" ]; then
    line="$(head -c 262144 "$tp" 2>/dev/null | grep -m1 -E '"type"[[:space:]]*:[[:space:]]*"user"')"
    if [[ $line =~ $TASK_RE ]]; then TID="${BASH_REMATCH[1]}"; fi
  fi
  if [ -z "$TID" ] && [ "$1" != SubagentStart ] && [ -n "$aid" ] && [ -d "$DIR" ]; then
    while IFS= read -r f; do
      f="${f##*/}"; f="${f%.md}"
      if is_id "$f"; then TID="$f"; break; fi
    done < <(grep -l -E "^agent:[[:space:]]*$aid[[:space:]]*\$" "$DIR"/t-*.md 2>/dev/null)
  fi
  [ -n "$TID" ] && [ ! -f "$DIR/$TID.md" ] && [ ! -f "$DIR/archive/$TID.md" ] && TID=""
  return 0
}

QUEUE=""      # events to emit after the lock is released: kind<US>json lines
NOTIFY_Q=""   # notification types to fire after unlock
queue_event() { QUEUE="$QUEUE$1$US$2$NL"; }
flush_queue() {
  local line k j
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    k="${line%%$US*}"; j="${line#*$US}"
    emit_event "$k" "$j"
  done <<< "$QUEUE"
  QUEUE=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fire_notify "$line" "$AGENT_TYPE" "$SESSION_ID"
  done <<< "$NOTIFY_Q"
  NOTIFY_Q=""
}
queue_status() { # task from to
  queue_event task_status "$(printf '{"agent_id":"%s","session_id":"%s","task":"%s","from":"%s","to":"%s","by":"hook"}' "$(safe_tok "$AGENT_ID")" "$(safe_tok "$SESSION_ID")" "$1" "$2" "$3")"
}
queue_missing() { # task-or-empty missing-list
  report_check_on || return 0
  missing_json "$2"
  local t="null"; [ -n "$1" ] && t="\"$1\""
  queue_event report_missing "$(printf '{"agent_id":"%s","agent_type":"%s","session_id":"%s","transcript_path":"%s","task":%s,"missing":%s}' "$(safe_tok "$AGENT_ID")" "$(safe_tok "$AGENT_TYPE")" "$(safe_tok "$SESSION_ID")" "$(safe_tok "$TR_PATH")" "$t" "$MJ")"
  NOTIFY_Q="${NOTIFY_Q}report_missing$NL"
}
git_part() { # prints indented lines of a command's output, capped at 50
  head -n 50 | sed 's/^/    /'
}
# handoff_block ERRTYPE -> HB (text), HB_FILES (number)
handoff_block() {
  local err="$1" ws="" w pathspec="" st df n
  local -a args warr
  args=()
  IFS=, read -ra warr <<< "$T_writable"
  for w in "${warr[@]}"; do [ -n "$w" ] || continue; args[${#args[@]}]="$w"; ws="$ws $w"; done
  HB="### $(now_iso) interrupted ($err)${NL}agent: ${T_agent:-$AGENT_ID} (${AGENT_TYPE:-unknown})${NL}"
  if git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ ${#args[@]} -gt 0 ]; then
      st="$(git -C "$PROJECT" status --porcelain -- "${args[@]}" 2>/dev/null)"
      df="$(git -C "$PROJECT" diff --stat -- "${args[@]}" 2>/dev/null)"
      pathspec=" --$ws"
    else
      st="$(git -C "$PROJECT" status --porcelain 2>/dev/null)"
      df="$(git -C "$PROJECT" diff --stat 2>/dev/null)"
    fi
    n=0; [ -n "$st" ] && n="$(printf '%s\n' "$st" | wc -l | tr -d ' ')"
    HB_FILES="$n"
    HB="${HB}files: $n${NL}uncommitted (git status --porcelain${pathspec}):${NL}"
    [ -n "$st" ] && HB="$HB$(printf '%s\n' "$st" | git_part)$NL"
    HB="${HB}diff --stat:$NL"
    [ -n "$df" ] && HB="$HB$(printf '%s\n' "$df" | git_part)$NL"
  else
    HB_FILES=0
    HB="${HB}files: 0${NL}uncommitted: (not a git repository)$NL"
  fi
  HB="${HB}Resume: read this note, then resume the agent or revert the files above."
}
# apply start effects to the loaded task
apply_start() {
  local from="$T_status"
  T_status=in-progress
  [ -n "$AGENT_ID" ] && T_agent="$AGENT_ID"
  [ -n "$SESSION_ID" ] && T_session="$SESSION_ID"
  [ -n "$TR_PATH" ] && T_transcript="$TR_PATH"
  queue_status "$T_id" "$from" in-progress
}
append_reply() { # heading label text (cap 4000)
  local text="$3"
  text="${text:0:4000}"
  text="$(printf '%s' "$text" | clean_text)"
  [ -n "$text" ] || return 0
  append_block "$1" "### $(now_iso) $2$NL$text"
}
interrupt_task() { # errtype : T_* loaded, status in-progress
  local from="$T_status" files
  handoff_block "$1"; files="$HB_FILES"
  append_block "## Handoff" "$HB"
  T_status=interrupted
  queue_status "$T_id" "$from" interrupted
  queue_event task_interrupted "$(printf '{"agent_id":"%s","agent_type":"%s","session_id":"%s","task":"%s","error_type":"%s","files":%s}' "$(safe_tok "${T_agent:-$AGENT_ID}")" "$(safe_tok "$AGENT_TYPE")" "$(safe_tok "${T_session:-$SESSION_ID}")" "$T_id" "$1" "$files")"
  NOTIFY_Q="${NOTIFY_Q}task_interrupted$NL"
}
# with_task ID FUNC: lock, load, run FUNC (returns 0 = write), unlock
with_task() {
  local id="$1" fn="$2" rc
  [ -f "$DIR/$id.md" ] || return 0
  lock_acquire || { log_err "lock busy for $id ($HOOK_EVENT)"; return 0; }
  if [ -f "$DIR/$id.md" ] && load_task "$DIR/$id.md"; then
    T_id="$id"
    "$fn"; rc=$?
    if [ "$rc" = 0 ]; then write_task "$DIR/$id.md" || log_err "write failed for $id"; fi
  fi
  lock_release
  return 0
}
h_start() {
  [ "$CLASS" = verifier ] && return 1
  case "$T_status" in open|blocked|interrupted|review) apply_start; return 0 ;; esac
  return 1
}
h_stop() {
  local msg="$MSG" fallback=0 from="$T_status" st sw
  if [ "$CLASS" = verifier ]; then
    # a verifier never changes the status; its verdict goes under Verification
    if [ -z "$msg" ]; then msg="$(get_section "$T_BODY" "## Verification")"; fi
    shape_check verifier "$msg"
    if [ -n "$MISSING" ]; then queue_missing "$T_id" "$MISSING"; return 1; fi
    [ "$T_status" = review ] && [ -n "$MSG" ] || return 1
    append_reply "## Verification" "verifier reply ($AGENT_TYPE $AGENT_ID)" "$MSG"
    return 0
  fi
  [ "$T_status" = done ] && return 1
  if [ "$T_status" != in-progress ]; then
    # Start was missed (or this agent is a fresh run on the task): apply its effects first. A repeated Stop
    # of the agent that already finished this task changes nothing.
    if [ -n "$AGENT_ID" ] && [ "$T_agent" = "$AGENT_ID" ]; then return 1; fi
    apply_start
  fi
  if [ -z "$msg" ]; then msg="$(get_section "$T_BODY" "## Report")"; fallback=1; fi
  shape_check "$CLASS" "$msg"
  if [ -n "$MISSING" ]; then
    T_status=blocked
    [ "$fallback" = 0 ] && append_reply "## Report" "final reply ($AGENT_TYPE $AGENT_ID)" "$MSG"
    queue_status "$T_id" in-progress blocked
    queue_missing "$T_id" "$MISSING"
    return 0
  fi
  sw="$STOPW"
  [ "$fallback" = 0 ] && append_reply "## Report" "final reply ($AGENT_TYPE $AGENT_ID)" "$MSG"
  case "$sw" in
    done) st=review ;;
    quota) interrupt_task quota; return 0 ;;
    *) st=blocked ;;
  esac
  T_status="$st"
  queue_status "$T_id" in-progress "$st"
  return 0
}
h_fail() {
  [ "$T_status" = in-progress ] || return 1
  interrupt_task "$ERRTYPE"
  return 0
}
hook_main() {
  HOOK_EVENT="${ARGV[0]:-}"
  case "$HOOK_EVENT" in SubagentStart|SubagentStop|StopFailure) ;; *) return 0 ;; esac
  [ -n "$SD_KEY" ] || return 0
  resolve_dir
  sfield agent_id; AGENT_ID="${V//[^A-Za-z0-9._-]/}"
  sfield agent_type; AGENT_TYPE="$V"
  [ -n "$AGENT_TYPE" ] || { sfield agent_name; AGENT_TYPE="$V"; }
  AGENT_TYPE="${AGENT_TYPE//[^A-Za-z0-9._:-]/}"
  sfield session_id; SESSION_ID="${V//[^A-Za-z0-9._-]/}"
  agent_class "$AGENT_TYPE"
  MSG=""
  if [ "$HOOK_EVENT" = SubagentStop ]; then MSG="$(jstring last_assistant_message)"; fi
  case "$HOOK_EVENT" in
    SubagentStart)
      find_task_id SubagentStart
      [ -n "$TID" ] && with_task "$TID" h_start ;;
    SubagentStop)
      find_task_id SubagentStop
      if [ -n "$TID" ]; then
        with_task "$TID" h_stop
      elif [ "$CLASS" != other ] && [ -n "$AGENT_TYPE" ]; then
        shape_check "$CLASS" "$MSG"
        [ -n "$MISSING" ] && queue_missing "" "$MISSING"
      fi ;;
    StopFailure)
      [ "$CLASS" = verifier ] && return 0
      ERRTYPE=""
      sfield error_type; ERRTYPE="$V"
      [ -n "$ERRTYPE" ] || { sfield error; ERRTYPE="$V"; }
      sd_lower "$ERRTYPE"; ERRTYPE="${SD_LOWER//[^a-z_]/}"
      [ -n "$ERRTYPE" ] || ERRTYPE=unknown
      if [ -n "$AGENT_ID" ]; then
        find_task_id StopFailure
        [ -n "$TID" ] && with_task "$TID" h_fail
      elif [ -n "$SESSION_ID" ] && [ -d "$DIR" ]; then
        local f id
        while IFS= read -r f; do
          id="${f##*/}"; id="${id%.md}"
          if is_id "$id"; then with_task "$id" h_fail; fi
        done < <(grep -l -E "^session:[[:space:]]*$SESSION_ID[[:space:]]*\$" "$DIR"/t-*.md 2>/dev/null)
      fi ;;
  esac
  flush_queue
  return 0
}

# ---------- dispatch ----------
case "$CMD" in
  hook) hook_main >/dev/null 2>&1 || log_err "hook failed (${ARGV[0]:-})"; lock_release; exit 0 ;;
  "") die 2 "usage: tasks.sh [--project <dir>] <new|set|append|done|list|ready|show|dir|hook> ..." ;;
esac
resolve_dir
case "$CMD" in
  new) cmd_new ;;
  set) cmd_set ;;
  append) cmd_append ;;
  done) cmd_done ;;
  list) cmd_list ;;
  ready) cmd_ready ;;
  show) cmd_show ;;
  dir) printf '%s\n' "$DIR" ;;
  *) die 2 "unknown command '$CMD'" ;;
esac
exit 0
