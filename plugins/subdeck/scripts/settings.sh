#!/usr/bin/env bash
# SubDeck settings: one short table, a machine interface (json/set) and routing to the existing scripts.
#
#   bash <plugin>/scripts/settings.sh [show]                          short grouped table (essentials)
#   bash <plugin>/scripts/settings.sh help                            the 3 commands, every key with options
#   bash <plugin>/scripts/settings.sh json [--project [<dir>]]        every setting as one JSON object (Desk reads this)
#   bash <plugin>/scripts/settings.sh set k=v [k=v ...] [--project [<dir>]]   validate all, then write (all or nothing)
#   bash <plugin>/scripts/settings.sh reset [--project]               reset models, guard, notifications, context
# A trailing existing directory argument is the project dir (default $CLAUDE_PROJECT_DIR, else cwd).
# Keys: mode|worker|escalation|researcher|verifier|explore -> models.sh
#       notify=on|off, notify.events=waiting,done,agent,idle -> notify.sh
#       guard=on|off, <guard rule id>=deny|ask|off          -> guard.sh
#       push=ask|branches|off, protect-branches=<list>      -> guard.sh cli push|branches
#       protect=<list> (replaces), unprotect=<list>         -> guard.sh protect|unprotect (guard.protectedPaths)
#       context=<tokens>, 0 = auto                          -> config key context.window (written here)
#       statusline=on|off                                   -> not written here (the skill edits settings.json)
# Exit codes: show/help/reset always 0. json 0 (2 on a bad argument). set: 0 on success, 2 + one-line
# error on stderr for any invalid key/value (nothing is written if any pair is invalid).
# No jq/node.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_KEYS="mode worker escalation researcher verifier explore"
STATIC_RULES="git-add-all force-push history-rewrite rm-rf-danger secret-files attribution protected-paths"
EVENT_KINDS="waiting done agent idle"
US=$'\037'

CMD=""; SCOPE=""; PROJECT=""; PAIRS=(); BAD=()
for a in "$@"; do
  a="${a%$'\r'}"
  case "$a" in
    "") ;;
    --project) SCOPE="--project" ;;
    --*) BAD+=("$a") ;;
    show|set|reset|json|help) if [ -z "$CMD" ]; then CMD="$a"; else BAD+=("$a"); fi ;;
    *=*) PAIRS+=("$a") ;;
    *) if [ -d "$a" ]; then PROJECT="$a"; else BAD+=("$a"); fi ;;
  esac
done
[ -n "$CMD" ] || CMD=show
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# json in user scope must not see a project overlay: point the sub-scripts at an empty project and state dir
TMPD=""
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT
if [ "$CMD" = json ] && [ -z "$SCOPE" ]; then
  TMPD="$(mktemp -d)"; mkdir -p "$TMPD/p"; PROJECT="$TMPD/p"; export SUBDECK_STATE_DIR="$TMPD/state"
fi

M() { bash "$DIR/models.sh" "$@" "$PROJECT"; }
N() { bash "$DIR/notify.sh" "$@" "$PROJECT"; }
G() { bash "$DIR/guard.sh" cli "$@" "$PROJECT"; }

UFILE="${HOME}/.subdeck/config.json"
LFILE="$PROJECT/.subdeck/config.json"   # legacy project config (read only)
PFILE="$LFILE"; . "$DIR/lib-paths.sh" 2>/dev/null && { sd_state_dir "$PROJECT"; PFILE="$SD_STATE/config.json"; }
[ "$LFILE" = "$PFILE" ] && LFILE=""
if [ "$SCOPE" = "--project" ]; then TARGET="$PFILE"; else TARGET="$UFILE"; fi

# ---------- raw config readers (no jq) ----------
rd_str() { # file key -> string value or empty
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}
rd_arr() { # file key -> comma-joined items of a top-level-unique string array; empty if absent
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | tr '\n' ' ' | awk -v k="\"$2\"" '
    { t = t $0 }
    END {
      p = index(t, k); if (!p) exit
      n = length(t); i = p + length(k)
      while (i <= n && substr(t, i, 1) != "[") i++
      i++; ins = 0; esc = 0; cur = ""; out = ""
      for (; i <= n; i++) {
        c = substr(t, i, 1)
        if (ins) {
          if (esc) { cur = cur c; esc = 0 }
          else if (c == "\\") esc = 1
          else if (c == "\"") { ins = 0; out = out (out == "" ? "" : ",") cur; cur = "" }
          else cur = cur c
        } else if (c == "\"") ins = 1
        else if (c == "]") break
      }
      print out
    }'
}
rd_ctx() { # file -> integer window or empty
  [ -f "$1" ] || return 0
  tr -d '\r\n' < "$1" | grep -o '"context"[[:space:]]*:[[:space:]]*{[^}]*}' | head -1 | grep -o '"window"[[:space:]]*:[[:space:]]*[0-9]\+' | head -1 | grep -o '[0-9]\+$'
}
# eff KIND KEY -> EV (value) and ES (source): project file, legacy project file, user file
eff() {
  EV=""; ES=""
  local f s
  for s in project legacy user; do
    case "$s" in project) f="$PFILE" ;; legacy) f="$LFILE" ;; user) f="$UFILE" ;; esac
    [ -n "$f" ] || continue
    case "$1" in str) EV="$(rd_str "$f" "$2")" ;; arr) EV="$(rd_arr "$f" "$2")" ;; ctx) EV="$(rd_ctx "$f")" ;; esac
    if [ -n "$EV" ]; then case "$s" in user) ES=user ;; *) ES=project ;; esac; return 0; fi
  done
  ES=default
}

ctx_members() { # file -> raw top-level members except "context"; return 1 when not a JSON object
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | tr '\n' ' ' | awk '
    { t = t $0 }
    END {
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") exit 0
      n = length(t)
      if (substr(t,1,1) != "{" || substr(t,n,1) != "}") exit 1
      depth = 0; ins = 0; esc = 0; cur = ""
      for (i = 1; i <= n; i++) {
        c = substr(t, i, 1)
        if (ins) { cur = cur c; if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") ins = 0; continue }
        if (c == "\"") { ins = 1; cur = cur c; continue }
        if (c == "{" || c == "[") { depth++; if (depth == 1) continue }
        else if (c == "}" || c == "]") {
          depth--
          if (depth < 0) exit 1
          if (depth == 0) { if (i != n) exit 1; emit(); continue }
        }
        else if (c == "," && depth == 1) { emit(); continue }
        cur = cur c
      }
      if (ins || depth != 0) exit 1
    }
    function emit() {
      gsub(/^[ \t]+|[ \t]+$/, "", cur)
      if (cur != "" && cur !~ /^"context"[ \t]*:/) print cur
      cur = ""
    }'
}
ctx_write() { # file value|remove -> writes the context member, keeping every other member verbatim
  local f="$1" v="$2" others line body=""
  if ! others="$(ctx_members "$f")"; then echo "error: $f is not a valid JSON object; left untouched"; return 1; fi
  if [ "$v" = remove ]; then
    [ -f "$f" ] || return 0
    if [ -z "$others" ]; then rm -f "$f" 2>/dev/null; return 0; fi
  fi
  mkdir -p "$(dirname "$f")" 2>/dev/null
  while IFS= read -r line; do [ -n "$line" ] && body="$body$line,"; done <<< "$others"
  [ "$v" = remove ] || body="$body\"context\":{\"window\":$v},"
  if printf '{%s}\n' "${body%,}" > "$f" 2>/dev/null; then return 0; fi
  echo "error: could not write $f"; return 1
}

statusline_state() {
  if [ -f "${HOME}/.claude/settings.json" ] && tr -d '\r' < "${HOME}/.claude/settings.json" | grep -q 'statusline\.sh'; then echo installed; else echo "not installed"; fi
}

guard_rules() { # every rule id the guard knows (falls back to the static list)
  local r
  r="$(G show 2>/dev/null | awk '$2 ~ /^[a-z]+$/ && $3 ~ /^(default|user|project)$/ { print $1 }')"
  [ -n "$r" ] || r="$STATIC_RULES push"
  printf '%s\n' "$r"
}

# ---------- key metadata ----------
# meta KEY -> MG (group) MT (type) MO (space-separated options) MD (one-line meaning)
meta() {
  MO=""
  case "$1" in
    mode)         MG=models; MT=enum; MO="auto named current"; MD="how sub-agent models are chosen: auto = the policy below, named = explicit, current = the session model" ;;
    worker)       MG=models; MT=enum; MO="sonnet opus haiku fable inherit"; MD="model for general sub-agents (or a full model id)" ;;
    escalation)   MG=models; MT=enum; MO="sonnet opus haiku fable inherit"; MD="model for critical architecture or security work (or a full model id)" ;;
    researcher)   MG=models; MT=enum; MO="sonnet opus haiku fable inherit"; MD="model for read-only research agents (or a full model id)" ;;
    verifier)     MG=models; MT=enum; MO="sonnet opus haiku fable inherit"; MD="model for the independent verifier (or a full model id)" ;;
    explore)      MG=models; MT=enum; MO="sonnet opus haiku fable inherit"; MD="model for code-exploration agents (or a full model id)" ;;
    notify)       MG=notify; MT=bool; MO="on off"; MD="desktop notification when you are needed" ;;
    notify.events) MG=notify; MT=list; MO="$EVENT_KINDS"; MD="which events notify: waiting (needs input), done (manager finished), agent (a sub-agent finished), idle (session idle)" ;;
    push)         MG=push; MT=enum; MO="ask branches off"; MD="git push: ask = always ask, branches = ask only for protected branches and tags, off = no check" ;;
    protect-branches) MG=push; MT=list; MD="branch globs treated as protected when push=branches (default main,master,release/*)" ;;
    guard)        MG=guard; MT=bool; MO="on off"; MD="master switch for all guard rules" ;;
    git-add-all)  MG=guard; MT=enum; MO="deny ask off"; MD="blocks git add -A / git add ." ;;
    force-push)   MG=guard; MT=enum; MO="deny ask off"; MD="blocks force pushes" ;;
    history-rewrite) MG=guard; MT=enum; MO="deny ask off"; MD="merge, rebase, reset that rewrite history" ;;
    rm-rf-danger) MG=guard; MT=enum; MO="deny ask off"; MD="recursive deletes of important paths" ;;
    secret-files) MG=guard; MT=enum; MO="deny ask off"; MD="reading or writing secret files such as .env" ;;
    attribution)  MG=guard; MT=enum; MO="deny ask off"; MD="AI attribution lines in commits and PRs" ;;
    protected-paths) MG=guard; MT=enum; MO="deny ask off"; MD="edits to the files listed under protect" ;;
    protect)      MG=protect; MT=list; MD="files or globs agents must not edit or delete without approval (set protect= replaces the list)" ;;
    context)      MG=context; MT=int; MD="context window in tokens for models whose size is unknown; 0 = auto" ;;
    statusline)   MG=statusline; MT=bool; MO="on off"; MD="agent counts in the Claude Code status line (read-only here; the skill edits settings.json)" ;;
    *)            MG=guard; MT=enum; MO="deny ask off"; MD="guard rule" ;;
  esac
}

# ---------- collect every setting into REC (US-separated records) ----------
REC=""
rec() { meta "$1"; REC="$REC$1$US$2$US$3$US$MG$US$MT$US$MO$US$MD"$'\n'; }
row_of() { # text key -> "value source" from a `key value source` table
  printf '%s\n' "$1" | awk -v k="$2" '$1 == k && $3 ~ /^(default|user|project)$/ { print $2 " " $3; exit }'
}
collect() {
  local mo no go k r v s sl rules en ev pp pb
  mo="$(M show 2>/dev/null)"; no="$(N show 2>/dev/null)"; go="$(G show 2>/dev/null)"
  for k in $MODEL_KEYS; do
    r="$(row_of "$mo" "$k")"; v="${r%% *}"; s="${r#* }"
    [ -n "$r" ] || { v=""; s=default; }
    rec "$k" "$v" "$s"
  done
  en="$(printf '%s\n' "$no" | awk '$1 == "enabled" && NF >= 3 { print ($2 == "true") ? "on" : "off", $3; exit }')"
  [ -n "$en" ] || en="off default"
  rec notify "${en%% *}" "${en#* }"
  ev="$(printf '%s\n' "$no" | awk '$1 == "events" && NF >= 3 { print $2, $3; exit }')"
  [ -n "$ev" ] || ev="waiting,done default"
  rec notify.events "${ev%% *}" "${ev#* }"
  r="$(row_of "$go" push)"
  if [ -n "$r" ]; then rec push "${r%% *}" "${r#* }"
  else eff str push; if [ -n "$EV" ]; then rec push "$EV" "$ES"; else rec push branches default; fi; fi
  eff arr protectBranches
  if [ -n "$EV" ]; then rec protect-branches "$EV" "$ES"; else rec protect-branches "main,master,release/*" default; fi
  v="$(printf '%s\n' "$go" | awk '/^enabled:/ { print ($2 == "yes") ? "on" : "off"; exit }')"
  s="$(printf '%s\n' "$go" | awk '/^enabled:/ { s = $3; gsub(/[()]/, "", s); print s; exit }')"
  case "$s" in default|user|project) ;; *) s=default ;; esac
  rec guard "${v:-on}" "$s"
  rules="$(guard_rules)"
  for k in $rules; do
    [ "$k" = push ] && continue
    r="$(row_of "$go" "$k")"; [ -n "$r" ] || continue
    rec "$k" "${r%% *}" "${r#* }"
  done
  pp="$(printf '%s\n' "$go" | awk '/^protectedPaths/ {
      s = "default"; if ($0 ~ /^protectedPaths \(user\)/) s = "user"; else if ($0 ~ /^protectedPaths \(project\)/) s = "project"
      v = $0; sub(/^protectedPaths[^:]*: /, "", v); if (v == "(none)") v = ""; print s "|" v; exit }')"
  rec protect "${pp#*|}" "${pp%%|*}"
  eff ctx window
  rec context "${EV:-0}" "$ES"
  sl="$(statusline_state)"
  if [ "$sl" = installed ]; then rec statusline on user; else rec statusline off default; fi
}

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
jarr() { # items as arguments
  local out="" i
  for i in "$@"; do out="$out${out:+,}\"$(jesc "$i")\""; done
  printf '[%s]' "$out"
}
jcsv() { local a; [ -n "$1" ] || { printf '[]'; return; }; IFS=',' read -ra a <<< "$1"; jarr "${a[@]}"; }

json() {
  local first=1 k v s g t o d vj oj scope proj
  if [ -n "$SCOPE" ]; then scope=project; proj="\"$(jesc "$PROJECT")\""; else scope=user; proj=null; fi
  collect
  printf '{"version":1,"scope":"%s","project":%s,"settings":[' "$scope" "$proj"
  while IFS="$US" read -r k v s g t o d; do
    [ -n "$k" ] || continue
    case "$t" in
      list) vj="$(jcsv "$v")" ;;
      int) vj="${v:-0}" ;;
      *) vj="\"$(jesc "$v")\"" ;;
    esac
    # shellcheck disable=SC2086
    oj="$(jarr $o)"
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"key":"%s","value":%s,"source":"%s","group":"%s","type":"%s","options":%s,"description":"%s"}' \
      "$k" "$vj" "$s" "$g" "$t" "$oj" "$(jesc "$d")"
  done <<< "$REC"
  printf ']}\n'
}

show() {
  local k v s g t o d cur=""
  collect
  echo "SubDeck settings"
  while IFS="$US" read -r k v s g t o d; do
    [ -n "$k" ] || continue
    if [ "$g" != "$cur" ]; then
      cur="$g"
      case "$g" in models) echo "Models" ;; notify) echo "Notifications" ;; push) echo "Push" ;; guard) echo "Guard" ;;
        protect) echo "Protected files" ;; context) echo "Context" ;; statusline) echo "Status line" ;; esac
    fi
    case "$k" in protect) [ -n "$v" ] || v="(none)" ;; context) [ "$v" = 0 ] && v="0 (auto)" ;; esac
    [ "$s" = default ] && s=""
    printf '  %-17s %-20s %s\n' "$k" "$v" "$s"
  done <<< "$REC"
  echo
  echo "More: /subdeck:settings help"
}

help() {
  local k v s g t o d r
  cat <<'EOF'
SubDeck settings: three commands

  /subdeck:settings                      show the current settings (short table)
  /subdeck:settings set key=value ...    change one or more settings; add --project to store them for this project only
  /subdeck:settings reset [--project]    back to defaults (models, guard, notifications, context)
  (also: json prints every setting as JSON, for tools such as the Desk)

Values come from built-in defaults, then your user config, then the project config (the last one wins).
A set with any invalid key or value changes nothing and exits with code 2.

Keys
EOF
  collect
  while IFS="$US" read -r k v s g t o d; do
    [ -n "$k" ] || continue
    case "$t" in
      int) r="a number (tokens)" ;;
      list) if [ -n "$o" ]; then r="comma list of: ${o// /, }"; else r="comma list"; fi ;;
      *) r="${o// /|}" ;;
    esac
    printf '  %-17s %s\n' "$k" "$r"
    printf '  %-17s %s\n' "" "$d"
  done <<< "$REC"
  cat <<'EOF'

Examples
  /subdeck:settings set worker=opus escalation=opus
  /subdeck:settings set notify=on notify.events=waiting,done
  /subdeck:settings set push=branches protect-branches=main,release/*
  /subdeck:settings set protect=CLAUDE.md,migrations/** --project
  /subdeck:settings set unprotect=migrations/**
  /subdeck:settings set context=200000
  /subdeck:settings set attribution=deny git-add-all=ask
  /subdeck:settings reset --project
EOF
}

die() { echo "error: $1" >&2; exit 2; }

for b in "${BAD[@]}"; do
  case "$CMD" in set|json) die "unknown argument '$b' (run: settings.sh help)" ;; *) echo "warning: ignored argument '$b'" ;; esac
done

case "$CMD" in
  show) show ;;
  help) help ;;
  json) json ;;
  set)
    [ ${#PAIRS[@]} -gt 0 ] || die "set needs key=value pairs, e.g. set notify=on worker=opus"
    RULES=" $(guard_rules | tr '\n' ' ')"
    MP=(); GP=(); NV=""; NE=""; GE=""; SL=""; PUSH=""; PB=""; PBSET=0; PRSET=0; PR=""; UP=""; CX=""
    for kv in "${PAIRS[@]}"; do
      k="${kv%%=*}"; v="${kv#*=}"; lv="$(printf '%s' "$v" | tr 'A-Z' 'a-z')"
      case "$k" in
        mode)
          case "$lv" in auto|named|current) MP+=("mode=$lv") ;; *) die "mode must be auto, named or current (got '$v')" ;; esac ;;
        worker|escalation|researcher|verifier|explore)
          printf '%s' "$v" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,127}$' || die "$k must be sonnet, opus, haiku, fable, inherit or a model id (got '$v')"
          MP+=("$k=$v") ;;
        notify)
          case "$lv" in on|true) NV=on ;; off|false) NV=off ;; *) die "notify must be on or off (got '$v')" ;; esac ;;
        notify.events)
          [ -n "$v" ] || die "notify.events needs a comma list of: ${EVENT_KINDS// /, }"
          IFS=',' read -ra EVS <<< "$lv"
          for e in "${EVS[@]}"; do case " $EVENT_KINDS " in *" $e "*) ;; *) die "notify.events: unknown event '$e' (valid: ${EVENT_KINDS// /, })" ;; esac; done
          NE="$lv" ;;
        guard)
          case "$lv" in on|true) GE=on ;; off|false) GE=off ;; *) die "guard must be on or off (got '$v')" ;; esac ;;
        push)
          case "$lv" in ask|branches|off) PUSH="$lv" ;; *) die "push must be ask, branches or off (got '$v')" ;; esac ;;
        protect-branches)
          [ -n "$v" ] || die "protect-branches needs a comma list of branch globs (e.g. main,release/*)"
          case "$v" in *\"*|*[[:cntrl:]]*) die "protect-branches: invalid characters in '$v'" ;; esac
          PB="$v"; PBSET=1 ;;
        protect)
          case "$v" in *\"*|*[[:cntrl:]]*) die "protect: invalid characters in '$v'" ;; esac
          PR="$v"; PRSET=1 ;;
        unprotect)
          [ -n "$v" ] || die "unprotect needs a glob (e.g. unprotect=migrations/**)"
          case "$v" in *\"*|*[[:cntrl:]]*) die "unprotect: invalid characters in '$v'" ;; esac
          UP="$UP${UP:+,}$v" ;;
        context)
          printf '%s' "$v" | grep -Eq '^[0-9]{1,9}$' || die "context must be a whole number of tokens, 0 = auto (got '$v')"
          CX=$((10#$v)) ;;
        statusline)
          case "$lv" in on|install) SL=on ;; off|remove) SL=off ;; *) die "statusline must be on or off (got '$v')" ;; esac ;;
        *)
          if [[ "$RULES" == *" $k "* ]]; then
            case "$lv" in deny|ask|off) GP+=("$k=$lv") ;; *) die "$k must be deny, ask or off (got '$v')" ;; esac
          else die "unknown key '$k' (run: settings.sh help)"; fi ;;
      esac
    done
    # a corrupt target file must not leave a half-applied set
    if [ -n "$CX" ] && ! ctx_members "$TARGET" >/dev/null; then die "$TARGET is not a valid JSON object; left untouched"; fi
    OUT=""; ERRLINE=""; SNAPF=""
    if [ -f "$TARGET" ]; then SNAPF="$(mktemp)"; cp "$TARGET" "$SNAPF"; fi   # restored if any routed write fails
    route() { # run a routed command, keep its first output line, remember the first error
      local l; l="$("$@" | head -1)"; [ -n "$l" ] && OUT="$OUT$l"$'\n'
      case "$l" in error*) [ -n "$ERRLINE" ] || ERRLINE="$l" ;; esac
    }
    [ ${#MP[@]} -gt 0 ] && route M set "${MP[@]}" $SCOPE
    [ -n "$NV" ] && route N "$NV" $SCOPE
    [ -n "$NE" ] && route N events "$NE" $SCOPE
    [ ${#GP[@]} -gt 0 ] && route G set "${GP[@]}" $SCOPE
    [ -n "$PUSH" ] && route G push "$PUSH" $SCOPE
    [ $PBSET -eq 1 ] && route G branches "$PB" $SCOPE
    if [ $PRSET -eq 1 ]; then
      OLD="$(rd_arr "$TARGET" protectedPaths)"
      [ -n "$OLD" ] && route G unprotect "$OLD" $SCOPE
      [ -n "$PR" ] && route G protect "$PR" $SCOPE
    fi
    [ -n "$UP" ] && route G unprotect "$UP" $SCOPE
    [ -n "$GE" ] && route G "$GE" $SCOPE
    if [ -n "$CX" ]; then
      if l="$(ctx_write "$TARGET" "$CX")"; then OUT="${OUT}wrote $TARGET"$'\n'; else ERRLINE="${l%%$'\n'*}"; fi
    fi
    if [ -n "$ERRLINE" ]; then
      if [ -n "$SNAPF" ]; then cp "$SNAPF" "$TARGET" 2>/dev/null; else rm -f "$TARGET" 2>/dev/null; fi
      rm -f "$SNAPF"; die "${ERRLINE#error: } (nothing written)"
    fi
    rm -f "$SNAPF"
    printf '%s' "$OUT"
    [ -n "$SL" ] && echo "statusline=$SL: not written by this script; it needs your confirmation (handled by the skill)."
    echo; show ;;
  reset)
    M reset $SCOPE | head -1
    G reset $SCOPE | head -1
    N off $SCOPE | head -1
    N events waiting,done $SCOPE | head -1
    ctx_write "$TARGET" remove >/dev/null
    echo; show ;;
esac
exit 0
