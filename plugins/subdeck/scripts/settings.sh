#!/usr/bin/env bash
# SubDeck settings: one short table, a machine interface (json/set) and routing to the existing scripts.
#
#   bash <plugin>/scripts/settings.sh [show]                          short grouped table (essentials)
#   bash <plugin>/scripts/settings.sh help                            the 3 commands, every key with options
#   bash <plugin>/scripts/settings.sh json [--project [<dir>]]        every setting as one JSON object (Desk reads this)
#   bash <plugin>/scripts/settings.sh set k=v [k=v ...] [--project [<dir>]]   validate all, then write (all or nothing)
#   bash <plugin>/scripts/settings.sh reset [--project]               reset models, guard, notifications, context, tasks, roles
# A trailing existing directory argument is the project dir (default $CLAUDE_PROJECT_DIR, else cwd).
# Keys: mode|worker|escalation|researcher|verifier|explore -> models.sh
#       notify=on|off, notify.events=waiting,done,agent,idle -> notify.sh
#       guard=on|off, <guard rule id>=deny|ask|off          -> guard.sh
#       push=ask|branches|off, protect-branches=<list>      -> guard.sh cli push|branches
#       protect=<list> (replaces), unprotect=<list>         -> guard.sh protect|unprotect (guard.protectedPaths)
#       context=<tokens>, 0 = auto                          -> config key context.window (written here)
#       protected-resources=deny|ask|off                    -> guard.sh (guard.rules.protected-resources)
#       protect-ports|protect-hosts|protect-procs=<list>    -> guard.sh cli ports|hosts|procs (replaces; empty clears)
#       tasks.dir=<path>, empty = the state dir             -> config key tasks.dir (written here; \ stored as /)
#       report-check=on|off                                 -> config key tasks.reportCheck (written here)
#       roles.<role>.tool|model|args|cmd|timeout=<v>        -> config member "roles" (written here; per role the whole object of one scope wins)
#       statusline=on|off                                   -> not written here (the skill edits settings.json)
# Exit codes: show/help/reset always 0. json 0 (2 on a bad argument). set: 0 on success, 2 + one-line
# error on stderr for any invalid key/value (nothing is written if any pair is invalid).
# No jq/node.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_KEYS="mode worker escalation researcher verifier explore"
STATIC_RULES="git-add-all force-push history-rewrite rm-rf-danger secret-files attribution protected-paths protected-resources"
EVENT_KINDS="waiting done agent idle"
ROLE_TOOLS="claude codex gemini agy opencode copilot custom"
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
ctx_members() { # file [name] -> raw top-level members except <name> (default "context"); 1 when not a JSON object
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | tr '\n' ' ' | obj_members "^\"${2:-context}\"[ \t]*:" except
}
member_value() { # file name -> raw JSON value of the top-level member <name> (empty when absent or not an object file)
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | tr '\n' ' ' | obj_members "^\"$2\"[ \t]*:" value
}
obj_members() { # stdin: JSON object text; $1 regex on a member, $2 except (print the other members) | value (value of the match)
  awk -v ex="$1" -v op="$2" '
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
      if (cur != "") {
        if (op == "value") { if (cur ~ ex && !done) { sub(/^"([^"\\]|\\.)*"[ \t]*:[ \t]*/, "", cur); print cur; done = 1 } }
        else if (cur !~ ex) print cur
      }
      cur = ""
    }'
}
member_write() { # file name json|remove -> writes one top-level member, keeping every other member verbatim
  local f="$1" k="$2" v="$3" others line body=""
  if ! others="$(ctx_members "$f" "$k")"; then echo "error: $f is not a valid JSON object; left untouched"; return 1; fi
  if [ "$v" = remove ]; then
    [ -f "$f" ] || return 0
    if [ -z "$others" ]; then rm -f "$f" 2>/dev/null; return 0; fi
  fi
  mkdir -p "$(dirname "$f")" 2>/dev/null
  while IFS= read -r line; do [ -n "$line" ] && body="$body$line,"; done <<< "$others"
  [ "$v" = remove ] || body="$body\"$k\":$v,"
  if printf '{%s}\n' "${body%,}" > "$f" 2>/dev/null; then return 0; fi
  echo "error: could not write $f"; return 1
}
ctx_write() { # file value|remove -> writes the context member
  if [ "$2" = remove ]; then member_write "$1" context remove; else member_write "$1" context "{\"window\":$2}"; fi
}
# tasks_write file dirop dir rcop rc: op keep|set|remove for tasks.dir and tasks.reportCheck; other members of
# "tasks" are kept verbatim; an empty "tasks" object is dropped
tasks_write() {
  local f="$1" raw inner="" body="" line d r
  raw="$(member_value "$f" tasks)"
  case "$raw" in "{"*) inner="$(printf '%s' "$raw" | obj_members '^"(dir|reportCheck)"[ \t]*:' except)" || inner="" ;; esac
  d="$(printf '%s' "$raw" | obj_members '^"dir"[ \t]*:' value 2>/dev/null)"
  r="$(printf '%s' "$raw" | obj_members '^"reportCheck"[ \t]*:' value 2>/dev/null)"
  case "$2" in set) d="\"$3\"" ;; remove) d="" ;; esac
  case "$4" in set) r="$5" ;; remove) r="" ;; esac
  while IFS= read -r line; do [ -n "$line" ] && body="$body$line,"; done <<< "$inner"
  [ -n "$d" ] && body="$body\"dir\":$d,"
  [ -n "$r" ] && body="$body\"reportCheck\":$r,"
  if [ -z "$body" ]; then member_write "$f" tasks remove; else member_write "$f" tasks "{${body%,}}"; fi
}

lower() { if declare -F sd_lower >/dev/null; then sd_lower "$1"; LOW="$SD_LOWER"; else LOW="$(printf %s "$1" | tr A-Z a-z)"; fi; }

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
    protected-resources) MG=guard; MT=enum; MO="deny ask off"; MD="commands that use a protected port, host or process (lists below)" ;;
    protect)      MG=protect; MT=list; MD="files or globs agents must not edit or delete without approval (set protect= replaces the list)" ;;
    protect-ports) MG=resources; MT=list; MD="live local ports (1-65535) agents must not use without approval, e.g. 8080,9000" ;;
    protect-hosts) MG=resources; MT=list; MD="hosts agents must not contact without approval, e.g. staging.example" ;;
    protect-procs) MG=resources; MT=list; MD="process names agents must not stop or look up without approval, e.g. redis" ;;
    tasks.dir)    MG=tasks; MT=string; MD="task file directory, relative to the project or absolute; empty = the state dir" ;;
    report-check) MG=tasks; MT=bool; MO="on off"; MD="flag sub-agents that stop without a report (Stop:/Tested: lines)" ;;
    context)      MG=context; MT=int; MD="context window in tokens for models whose size is unknown; 0 = auto" ;;
    statusline)   MG=statusline; MT=bool; MO="on off"; MD="agent counts in the Claude Code status line (read-only here; the skill edits settings.json)" ;;
    roles.*.tool)    MG=roles; MT=enum; MO="$ROLE_TOOLS"; MD="CLI that runs this role instead of an in-session sub-agent; empty removes the role mapping at this scope" ;;
    roles.*.model)   MG=roles; MT=string; MD="model passed to the CLI as is; empty = the tool's own default" ;;
    roles.*.args)    MG=roles; MT=string; MD="extra CLI flags, split on spaces ({sp} = a literal space); auto-approve flags are refused" ;;
    roles.*.cmd)     MG=roles; MT=string; MD="command for tool custom; must contain {prompt_file}" ;;
    roles.*.timeout) MG=roles; MT=int; MD="seconds before the run is stopped, 60-86400 (default 1800)" ;;
    *)            MG=guard; MT=enum; MO="deny ask off"; MD="guard rule" ;;
  esac
}

# ---------- collect every setting into REC (US-separated records) ----------
# One awk pass over the config files (user < legacy project < project); no sub-script is run for reads.
REC=""
rec() { meta "$1"; REC="$REC$1$US$2$US$3$US$MG$US$MT$US$MO$US$MD"$'\n'; }
COLLECT_AWK='
function jp(d,   i, p) { p = ""; for (i = 1; i <= d; i++) if (ty[i] == "o") p = p (p == "" ? "" : "/") kk[i]; return p }
function val(role, d, s,   p) {
  if (ty[d] == "a") { p = ap[d]; L[role, p] = (cnt[d]++ ? L[role, p] "," : "") s }
  else S[role, jp(d)] = s
}
function parse(role, t,   n, i, c, d, s, lit, p) {
  n = length(t); i = 1; d = 0
  while (i <= n) {
    c = substr(t, i, 1)
    if (c == "{") { d++; ty[d] = "o"; ek[d] = 1; kk[d] = ""; i++ }
    else if (c == "[") {
      if (d > 0 && ty[d] == "o") { p = jp(d); d++; ty[d] = "a"; ap[d] = p; cnt[d] = 0; HL[role, p] = 1; L[role, p] = "" }
      else { d++; ty[d] = "a"; ap[d] = "-"; cnt[d] = 0 }
      i++
    }
    else if (c == "}" || c == "]") { d--; i++ }
    else if (c == ",") { if (d > 0 && ty[d] == "o") ek[d] = 1; i++ }
    else if (c == "\"") {
      i++; s = ""
      while (i <= n) { c = substr(t, i, 1); if (c == "\\") { s = s substr(t, i + 1, 1); i += 2 } else if (c == "\"") { i++; break } else { s = s c; i++ } }
      if (d > 0 && ty[d] == "o" && ek[d]) { kk[d] = s; ek[d] = 0 } else if (d > 0) val(role, d, s)
    }
    else if (c ~ /[-0-9a-zA-Z]/) {
      lit = ""
      while (i <= n) { c = substr(t, i, 1); if (c ~ /[-0-9a-zA-Z.+]/) { lit = lit c; i++ } else break }
      if (d > 0) val(role, d, lit)
    }
    else i++
  }
}
function flush() { if (cur != "") parse(role_of(cur), buf); buf = ""; cur = "" }
function role_of(f) { return (f == PF) ? "p" : (f == LF) ? "l" : "u" }
function sv(path, ok,   i, r) {
  EV = ""; ES = "default"
  for (i = 1; i <= 3; i++) { r = substr("plu", i, 1)
    if (((r, path) in S) && (ok == "" || (" " ok " ") ~ (" " S[r, path] " "))) { EV = S[r, path]; ES = (r == "u") ? "user" : "project"; return 1 } }
  return 0
}
function lv(path,   i, r) {
  EV = ""; ES = "default"
  for (i = 1; i <= 3; i++) { r = substr("plu", i, 1)
    if ((r, path) in HL) { EV = L[r, path]; ES = (r == "u") ? "user" : "project"; return 1 } }
  return 0
}
function out(k, v, s) { printf "%s\037%s\037%s\n", k, v, s }
FNR == 1 { flush(); cur = FILENAME }
{ buf = buf " " $0 }
END {
  flush()
  n = split("mode worker escalation researcher verifier explore", MK, " ")
  split("auto sonnet opus sonnet sonnet sonnet", MD, " ")
  for (i = 1; i <= n; i++) {
    if (MK[i] == "mode") sv("modelPolicy/mode", "auto named current")
    else if (sv("modelPolicy/" MK[i]) && EV !~ /^[A-Za-z0-9][A-Za-z0-9._:\/@-]*$/) { EV = ""; ES = "default" }
    if (ES == "default") EV = MD[i]
    out(MK[i], EV, ES)
  }
  if (sv("notify/enabled", "true false")) out("notify", (EV == "true") ? "on" : "off", ES); else out("notify", "off", "default")
  if (lv("notify/events")) out("notify.events", EV, ES); else out("notify.events", "waiting,done", "default")
  if (sv("guard/rules/push", "ask branches off")) out("push", EV, ES); else out("push", "branches", "default")
  if (lv("guard/protectBranches")) out("protect-branches", EV, ES); else out("protect-branches", "main,master,release/*", "default")
  if (sv("guard/enabled", "true false")) out("guard", (EV == "true") ? "on" : "off", ES); else out("guard", "on", "default")
  n = split("git-add-all force-push history-rewrite rm-rf-danger secret-files attribution protected-paths protected-resources", RK, " ")
  split("deny deny ask deny ask off ask ask", RD, " ")
  for (i = 1; i <= n; i++) { if (sv("guard/rules/" RK[i], "deny ask off")) out(RK[i], EV, ES); else out(RK[i], RD[i], "default") }
  if (lv("guard/protectedPaths")) out("protect", EV, ES); else out("protect", "", "default")
  if (lv("guard/protectPorts")) out("protect-ports", EV, ES); else out("protect-ports", "", "default")
  if (lv("guard/protectHosts")) out("protect-hosts", EV, ES); else out("protect-hosts", "", "default")
  if (lv("guard/protectProcs")) out("protect-procs", EV, ES); else out("protect-procs", "", "default")
  if (sv("context/window") && EV ~ /^[0-9]+$/) out("context", EV + 0, ES); else out("context", 0, "default")
  if (sv("tasks/dir")) out("tasks.dir", EV, ES); else out("tasks.dir", "", "default")
  if (sv("tasks/reportCheck", "true false")) out("report-check", (EV == "true") ? "on" : "off", ES); else out("report-check", "on", "default")
  roles_out()
}
# roles: per role the whole object of the first scope (project, legacy project, user) that has it
function roles_out(   key, a, r, nr, i, j, t, sc, f, fv, src, v, order) {
  split("manager worker worker-heavy researcher verifier", FX, " ")
  for (i = 1; i <= 5; i++) { RL[FX[i]] = 1; order[i] = FX[i] }
  nr = 5; nf = 0
  for (key in S) {
    split(key, a, SUBSEP)
    if (split(a[2], pp, "/") >= 3 && pp[1] == "roles" && pp[2] ~ /^[a-z][a-z0-9-]*$/ && length(pp[2]) <= 24) {
      RP[a[1], pp[2]] = 1
      if (!(pp[2] in RL)) { RL[pp[2]] = 1; FR[++nf] = pp[2] }
    }
  }
  for (i = 2; i <= nf; i++) { t = FR[i]; for (j = i - 1; j >= 1 && FR[j] > t; j--) FR[j + 1] = FR[j]; FR[j + 1] = t }
  for (i = 1; i <= nf; i++) order[5 + i] = FR[i]
  for (i = 1; i <= 5 + nf; i++) {
    r = order[i]; sc = ""; src = "default"
    for (j = 1; j <= 3; j++) { t = substr("plu", j, 1); if ((t, r) in RP) { sc = t; src = (t == "u") ? "user" : "project"; break } }
    for (j = 1; j <= 5; j++) {
      f = (j == 1) ? "tool" : (j == 2) ? "model" : (j == 3) ? "args" : (j == 4) ? "cmd" : "timeout"
      v = (sc != "" && ((sc, "roles/" r "/" f) in S)) ? S[sc, "roles/" r "/" f] : ""
      if (f == "tool" && v !~ /^(claude|codex|gemini|agy|opencode|copilot|custom)$/) v = ""
      if (f == "model" && v != "" && (v !~ /^[A-Za-z0-9][A-Za-z0-9._:\/@+-]*$/ || length(v) > 128)) v = ""
      if (f == "timeout") { if (v ~ /^[0-9]+$/ && v + 0 >= 60 && v + 0 <= 86400) v = v + 0; else v = 1800 }
      out("roles." r "." f, v, src)
    }
  }
}'
collect() {
  local k v s files=() out sl="" c
  [ -n "$SCOPE" ] || [ "$CMD" != json ] && { [ -n "$LFILE" ] && [ -f "$LFILE" ] && files+=("$LFILE"); [ -f "$PFILE" ] && files+=("$PFILE"); }
  [ -f "$UFILE" ] && files=("$UFILE" ${files[@]+"${files[@]}"})
  [ ${#files[@]} -gt 0 ] || files=(/dev/null)
  out="$(awk -v PF="$PFILE" -v LF="$LFILE" "$COLLECT_AWK" "${files[@]}" 2>/dev/null)"
  while IFS="$US" read -r k v s; do [ -n "$k" ] && rec "$k" "$v" "$s"; done <<< "$out"
  if [ -f "${HOME}/.claude/settings.json" ]; then read -r -d '' c < "${HOME}/.claude/settings.json"; [[ "$c" == *statusline.sh* ]] && sl=on; fi
  if [ "$sl" = on ]; then rec statusline on user; else rec statusline off default; fi
}

jesc() { JE="${1//\/\\}"; JE="${JE//\"/\\\"}"; }
jarr() { # items as arguments -> JA
  local i; JA=""
  for i in "$@"; do jesc "$i"; JA="$JA${JA:+,}\"$JE\""; done
  JA="[$JA]"
}
jcsv() { local a; if [ -z "$1" ]; then JA='[]'; else IFS=',' read -ra a <<< "$1"; jarr "${a[@]}"; fi; }

json() {
  local first=1 k v s g t o d vj oj scope proj
  if [ -n "$SCOPE" ]; then scope=project; jesc "$PROJECT"; proj="\"$JE\""; else scope=user; proj=null; fi
  collect
  printf '{"version":1,"scope":"%s","project":%s,"settings":[' "$scope" "$proj"
  while IFS="$US" read -r k v s g t o d; do
    [ -n "$k" ] || continue
    case "$t" in
      list) jcsv "$v"; vj="$JA" ;;
      int) vj="${v:-0}" ;;
      *) jesc "$v"; vj="\"$JE\"" ;;
    esac
    # shellcheck disable=SC2086
    jarr $o; oj="$JA"
    jesc "$d"
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"key":"%s","value":%s,"source":"%s","group":"%s","type":"%s","options":%s,"description":"%s"}' \
      "$k" "$vj" "$s" "$g" "$t" "$oj" "$JE"
  done <<< "$REC"
  printf ']}\n'
}

show() {
  local k v s g t o d cur="" rn m
  collect
  echo "SubDeck settings"
  while IFS="$US" read -r k v s g t o d; do
    [ -n "$k" ] || continue
    if [ "$g" != "$cur" ]; then
      cur="$g"
      case "$g" in models) echo "Models" ;; notify) echo "Notifications" ;; push) echo "Push" ;; guard) echo "Guard" ;;
        protect) echo "Protected files" ;; resources) echo "Protected resources" ;; context) echo "Context" ;;
        tasks) echo "Tasks" ;; roles) echo "Roles" ;; statusline) echo "Status line" ;; esac
    fi
    if [ "$g" = roles ]; then
      case "$k" in
        *.tool)
          rn="${k#roles.}"; rn="${rn%.tool}"
          if [ -z "$v" ]; then printf '  %-19s %s\n' "$rn" "(in-session)"
          else
            m="$(printf '%s\n' "$REC" | awk -F "$US" -v k="roles.$rn.model" '$1 == k { print $2; exit }')"
            printf '  %-19s %s  %s\n' "$rn" "$v${m:+ $m}" "${s/default/}"
          fi ;;
      esac
      continue
    fi
    case "$k" in protect|protect-*) [ -n "$v" ] || v="(none)" ;; context) [ "$v" = 0 ] && v="0 (auto)" ;; tasks.dir) [ -n "$v" ] || v="(state dir)" ;; esac
    [ "$s" = default ] && s=""
    printf '  %-19s %-20s %s\n' "$k" "$v" "$s"
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
  /subdeck:settings reset [--project]    back to defaults (models, guard, notifications, context, tasks, roles)
  (also: json prints every setting as JSON, for tools such as the Desk)

Values come from built-in defaults, then your user config, then the project config (the last one wins).
A set with any invalid key or value changes nothing and exits with code 2.

Keys
EOF
  collect
  while IFS="$US" read -r k v s g t o d; do
    [ -n "$k" ] || continue
    [ "$g" = roles ] && continue
    case "$t" in
      int) r="a number (tokens)" ;;
      string) r="a path (empty = default)" ;;
      list) if [ -n "$o" ]; then r="comma list of: ${o// /, }"; else r="comma list"; fi ;;
      *) r="${o// /|}" ;;
    esac
    printf '  %-19s %s\n' "$k" "$r"
    printf '  %-19s %s\n' "" "$d"
  done <<< "$REC"
  printf '  %-19s %s\n' "roles.<role>.tool" "${ROLE_TOOLS// /|} (empty = in-session, removes the role)"
  printf '  %-19s %s\n' "roles.<role>.model" "model id passed to the CLI (empty = the tool's default)"
  printf '  %-19s %s\n' "roles.<role>.args" "extra CLI flags (max 300 chars, {sp} = space; auto-approve flags refused)"
  printf '  %-19s %s\n' "roles.<role>.cmd" "command for tool custom, must contain {prompt_file}"
  printf '  %-19s %s\n' "roles.<role>.timeout" "seconds, 60-86400 (default 1800)"
  printf '  %-19s %s\n' "" "roles: manager worker worker-heavy researcher verifier, or your own name (a-z, 0-9, -)"
  cat <<'EOF'

Examples
  /subdeck:settings set worker=opus escalation=opus
  /subdeck:settings set notify=on notify.events=waiting,done
  /subdeck:settings set push=branches protect-branches=main,release/*
  /subdeck:settings set protect=CLAUDE.md,migrations/** --project
  /subdeck:settings set unprotect=migrations/**
  /subdeck:settings set context=200000
  /subdeck:settings set attribution=deny git-add-all=ask
  /subdeck:settings set protect-ports=8080,9000 protect-procs=redis --project
  /subdeck:settings set tasks.dir=docs/tasks report-check=off --project
  /subdeck:settings set roles.worker.tool=codex roles.worker.model=gpt-5-codex --project
  /subdeck:settings reset --project
EOF
}

die() { echo "error: $1" >&2; exit 2; }

ROLE_FIXED=" manager worker worker-heavy researcher verifier "
role_name_ok() { case "$ROLE_FIXED" in *" $1 "*) return 0 ;; esac; [[ $1 =~ ^[a-z][a-z0-9-]{0,23}$ ]]; }
# Deny list for roles.<r>.args: the _.deny_args line of run-profiles.txt (the list run.sh enforces at run time);
# the fallback below is the same list for an install without that file. Same matching rule as run.sh deny_check:
# lower-case token, token with {sp} as "=", and "<previous token>=<token>", each against every bash pattern.
DENY_FALLBACK='*dangerously* *bypasspermissions* *yolo* *danger-full-access* -y --auto --allow-all --allow-all-paths --allow-all-urls --no-sandbox --permission-mode=auto --approve-for-me --add-dir --add-dir=* --include-directories --include-directories=*'
DENY_PATS=()
deny_load() {
  local line list=""
  if [ -f "$DIR/run-profiles.txt" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in _.deny_args=*) list="${line#_.deny_args=}" ;; esac
    done < "$DIR/run-profiles.txt"
  fi
  [ -n "$list" ] || list="$DENY_FALLBACK"
  read -ra DENY_PATS <<< "$list"
}
deny_token() { # token [previous token] -> 0 when it is on the deny list
  local t c2 c3="" p
  [ ${#DENY_PATS[@]} -gt 0 ] || deny_load
  lower "$1"; t="$LOW"; c2="${t//\{sp\}/=}"
  if [ -n "${2:-}" ]; then lower "$2"; c3="${LOW//\{sp\}/=}=$t"; fi
  for p in "${DENY_PATS[@]}"; do
    lower "$p"
    # shellcheck disable=SC2053
    if [[ $t == $LOW ]] || [[ $c2 == $LOW ]] || { [ -n "$c3" ] && [[ $c3 == $LOW ]]; }; then return 0; fi
  done
  return 1
}
jstr_esc() { JS="${1//\\/\\\\}"; JS="${JS//\"/\\\"}"; }
role_raw() { # file role -> raw JSON object of roles.<role> in that file (empty when absent)
  local r; r="$(member_value "$1" roles)"
  case "$r" in "{"*) printf '%s' "$r" | obj_members "^\"$2\"[ \t]*:" value ;; esac
}
rfield() { printf '%s' "$1" | obj_members "^\"$2\"[ \t]*:" value 2>/dev/null; }   # object field -> raw value
runq() { RQ="${1#\"}"; RQ="${RQ%\"}"; }
# roles_write file: apply the role objects computed in RJ_<id> (object text or "-" = remove) to the "roles" member
roles_write() {
  local f="$1" raw members m n rid body="" seen=" " line
  raw="$(member_value "$f" roles)"
  case "$raw" in "{"*) members="$(printf '%s' "$raw" | obj_members '^$' except)" ;; *) members="" ;; esac
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    n="$(printf '%s' "$m" | sed 's/^"\([^"]*\)".*/\1/')"; rid="${n//-/_}"
    case "$ROLELIST" in *" $n "*)
      seen="$seen$n "; eval "line=\${RJ_$rid}"
      [ "$line" = "-" ] || body="$body\"$n\":$line," ;;
    *) body="$body$m," ;; esac
  done <<< "$members"
  for n in $ROLELIST; do
    case "$seen" in *" $n "*) continue ;; esac
    rid="${n//-/_}"; eval "line=\${RJ_$rid}"
    [ "$line" = "-" ] || body="$body\"$n\":$line,"
  done
  if [ -z "$body" ]; then member_write "$f" roles remove; else member_write "$f" roles "{${body%,}}"; fi
}

for b in "${BAD[@]}"; do
  case "$CMD" in set|json) die "unknown argument '$b' (run: settings.sh help)" ;; *) echo "warning: ignored argument '$b'" ;; esac
done

case "$CMD" in
  show) show ;;
  help) help ;;
  json) json ;;
  set)
    [ ${#PAIRS[@]} -gt 0 ] || die "set needs key=value pairs, e.g. set notify=on worker=opus"
    RULES=" $STATIC_RULES push "; RE_MODEL="^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,127}$"; RE_NUM="^[0-9]{1,9}$"
    MP=(); GP=(); NV=""; NE=""; GE=""; SL=""; PUSH=""; PB=""; PBSET=0; PRSET=0; PR=""; UP=""; CX=""
    TDOP=keep; TD=""; RCOP=keep; RC=""; RES=(); ROLELIST=" "
    for kv in "${PAIRS[@]}"; do
      k="${kv%%=*}"; v="${kv#*=}"; lower "$v"; lv="$LOW"
      case "$k" in
        mode)
          case "$lv" in auto|named|current) MP+=("mode=$lv") ;; *) die "mode must be auto, named or current (got '$v')" ;; esac ;;
        worker|escalation|researcher|verifier|explore)
          [[ $v =~ $RE_MODEL ]] || die "$k must be sonnet, opus, haiku, fable, inherit or a model id (got '$v')"
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
          [[ $v =~ $RE_NUM ]] || die "context must be a whole number of tokens, 0 = auto (got '$v')"
          CX=$((10#$v)) ;;
        tasks.dir)
          v="${v//\\//}"
          [ ${#v} -le 200 ] || die "tasks.dir: at most 200 characters"
          case "$v" in *\"*|*[[:cntrl:]]*) die "tasks.dir: no quotes or control characters (got '$v')" ;; esac
          case "/$v/" in */../*) die "tasks.dir: '..' segments are not allowed (got '$v')" ;; esac
          if [ -n "$v" ]; then TDOP=set; TD="$v"; else TDOP=remove; TD=""; fi ;;
        report-check)
          case "$lv" in on|true) RCOP=set; RC=true ;; off|false) RCOP=set; RC=false ;; *) die "report-check must be on or off (got '$v')" ;; esac ;;
        protect-ports|protect-hosts|protect-procs)
          IFS=',' read -ra ITS <<< "$v"; RL=""
          for it in ${ITS[@]+"${ITS[@]}"}; do
            it="${it#"${it%%[![:space:]]*}"}"; it="${it%"${it##*[![:space:]]}"}"
            [ -n "$it" ] || continue
            case "$k" in
              protect-ports) { [[ $it =~ ^[0-9]{1,5}$ ]] && [ $((10#$it)) -ge 1 ] && [ $((10#$it)) -le 65535 ]; } || die "protect-ports: '$it' is not a port (1-65535)" ;;
              protect-hosts) [[ $it =~ ^[A-Za-z0-9._:-]+$ ]] || die "protect-hosts: invalid host '$it' (letters, digits, . _ : -)" ;;
              protect-procs) [[ $it =~ ^[A-Za-z0-9._-]+$ ]] || die "protect-procs: invalid process name '$it' (letters, digits, . _ -)" ;;
            esac
            RL="$RL${RL:+,}$it"
          done
          RES+=("${k#protect-}$US$RL") ;;
        roles.*)
          rest="${k#roles.}"; rn="${rest%.*}"; fld="${rest##*.}"
          [ "$rest" != "$fld" ] || die "unknown key '$k' (run: settings.sh help)"
          case "$fld" in tool|model|args|cmd|timeout) ;; *) die "unknown key '$k' (run: settings.sh help)" ;; esac
          role_name_ok "$rn" || die "$k: invalid role name '$rn' (manager worker worker-heavy researcher verifier, or a-z 0-9 - up to 24 chars)"
          case "$v" in *[[:cntrl:]]*) die "$k: control characters are not allowed" ;; esac
          case "$fld" in
            tool) case "$lv" in ""|claude|codex|gemini|agy|opencode|copilot|custom) v="$lv" ;; *) die "$k must be one of ${ROLE_TOOLS// /, } (got '$v')" ;; esac ;;
            model) { [ -z "$v" ] || [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$ ]]; } || die "$k: invalid model id '$v' (letters, digits, . _ : / @ + -; max 128)" ;;
            args)
              [ ${#v} -le 300 ] || die "$k: at most 300 characters"
              case "$v" in *\"*|*\'*|*\\*) die "$k: quotes and backslashes are not allowed (use {sp} for a space inside a token)" ;; esac
              IFS=' ' read -ra ATOK <<< "$v"; nv=""; pit=""
              for it in ${ATOK[@]+"${ATOK[@]}"}; do
                deny_token "$it" "$pit" && die "$k: '$it' is not allowed (it disables the tool's approval or sandbox)"
                nv="$nv${nv:+ }$it"; pit="$it"
              done
              v="$nv" ;;
            cmd)
              [ ${#v} -le 500 ] || die "$k: at most 500 characters"
              [ -z "$v" ] || case "$v" in *"{prompt_file}"*) ;; *) die "$k must contain {prompt_file}" ;; esac ;;
            timeout)
              if [ -n "$v" ]; then { [[ $v =~ ^[0-9]{1,6}$ ]] && [ $((10#$v)) -ge 60 ] && [ $((10#$v)) -le 86400 ]; } || die "$k must be 60-86400 seconds (got '$v')"; v=$((10#$v)); fi ;;
          esac
          rid="${rn//-/_}"
          case "$ROLELIST" in *" $rn "*) ;; *) ROLELIST="$ROLELIST$rn " ;; esac
          printf -v "RF_${rid}_$fld" '%s' "$v"; printf -v "RS_${rid}_$fld" '%s' 1 ;;
        statusline)
          case "$lv" in on|install) SL=on ;; off|remove) SL=off ;; *) die "statusline must be on or off (got '$v')" ;; esac ;;
        *)
          if [[ "$RULES" == *" $k "* ]]; then
            case "$lv" in deny|ask|off) GP+=("$k=$lv") ;; *) die "$k must be deny, ask or off (got '$v')" ;; esac
          else die "unknown key '$k' (run: settings.sh help)"; fi ;;
      esac
    done
    # roles: resolve every touched role against the target scope before anything is written
    for rn in $ROLELIST; do
      rid="${rn//-/_}"
      for fld in tool model args cmd timeout; do eval "RSET_$fld=\${RS_${rid}_$fld:-}; RVAL_$fld=\${RF_${rid}_$fld:-}"; done
      if ! ctx_members "$TARGET" >/dev/null; then die "$TARGET is not a valid JSON object; left untouched"; fi
      obj="$(role_raw "$TARGET" "$rn")"
      if [ -n "$RSET_tool" ] && [ -z "$RVAL_tool" ]; then
        { [ -n "$RSET_model" ] || [ -n "$RSET_args" ] || [ -n "$RSET_cmd" ] || [ -n "$RSET_timeout" ]; } && die "roles.$rn: cannot set other keys while removing roles.$rn.tool"
        printf -v "RJ_$rid" '%s' "-"; continue
      fi
      etool=""; emodel=""; eargs=""; ecmd=""; etimeout=""; extra=""
      if [ -n "$obj" ]; then
        runq "$(rfield "$obj" tool)"; etool="$RQ"; runq "$(rfield "$obj" model)"; emodel="$RQ"; runq "$(rfield "$obj" args)"; eargs="$RQ"
        runq "$(rfield "$obj" cmd)"; ecmd="$RQ"; runq "$(rfield "$obj" timeout)"; etimeout="$RQ"
        extra="$(printf '%s' "$obj" | obj_members '^"(tool|model|args|cmd|timeout)"[ \t]*:' except 2>/dev/null | tr '\n' ',')"; extra="${extra%,}"
      fi
      ftool="$etool"; [ -z "$RSET_tool" ] || ftool="$RVAL_tool"
      [ -n "$ftool" ] || die "set roles.$rn.tool first"
      fmodel="$emodel"; [ -z "$RSET_model" ] || fmodel="$RVAL_model"
      fargs="$eargs"; [ -z "$RSET_args" ] || fargs="$RVAL_args"
      ftimeout="$etimeout"; [ -z "$RSET_timeout" ] || ftimeout="$RVAL_timeout"
      fcmd="$ecmd"; if [ -n "$RSET_cmd" ]; then jstr_esc "$RVAL_cmd"; fcmd="$JS"; fi
      if [ "$ftool" = custom ]; then
        [ -n "$fcmd" ] || die "roles.$rn.cmd is required with tool custom (it must contain {prompt_file})"
      else
        [ -z "$RSET_cmd" ] || [ -z "$RVAL_cmd" ] || die "roles.$rn.cmd only works with tool custom"
        fcmd=""
      fi
      body="\"tool\":\"$ftool\""
      [ -z "$fmodel" ] || body="$body,\"model\":\"$fmodel\""
      [ -z "$fargs" ] || body="$body,\"args\":\"$fargs\""
      [ -z "$fcmd" ] || body="$body,\"cmd\":\"$fcmd\""
      [ -z "$ftimeout" ] || body="$body,\"timeout\":$ftimeout"
      [ -z "$extra" ] || body="$body,$extra"
      printf -v "RJ_$rid" '%s' "{$body}"
    done
    # a corrupt target file must not leave a half-applied set
    if { [ -n "$CX" ] || [ $TDOP != keep ] || [ $RCOP != keep ]; } && ! ctx_members "$TARGET" >/dev/null; then die "$TARGET is not a valid JSON object; left untouched"; fi
    OUT=""; ERRLINE=""; SNAP=""; SNAPSET=0
    if [ -f "$TARGET" ]; then IFS= read -r -d "" SNAP < "$TARGET"; SNAPSET=1; fi   # restored if any routed write fails
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
    for r in ${RES[@]+"${RES[@]}"}; do route G "${r%%"$US"*}" "${r#*"$US"}" $SCOPE; done
    [ -n "$GE" ] && route G "$GE" $SCOPE
    if [ -n "$CX" ]; then
      if l="$(ctx_write "$TARGET" "$CX")"; then OUT="${OUT}wrote $TARGET"$'\n'; else ERRLINE="${l%%$'\n'*}"; fi
    fi
    if [ -z "$ERRLINE" ] && { [ $TDOP != keep ] || [ $RCOP != keep ]; }; then
      if l="$(tasks_write "$TARGET" $TDOP "$TD" $RCOP "$RC")"; then OUT="${OUT}wrote $TARGET"$'\n'; else ERRLINE="${l%%$'\n'*}"; fi
    fi
    if [ -z "$ERRLINE" ] && [ "$ROLELIST" != " " ]; then
      if l="$(roles_write "$TARGET")"; then OUT="${OUT}wrote $TARGET"$'\n'; else ERRLINE="${l%%$'\n'*}"; fi
    fi
    if [ -n "$ERRLINE" ]; then
      if [ $SNAPSET -eq 1 ]; then printf "%s" "$SNAP" > "$TARGET"; else rm -f "$TARGET" 2>/dev/null; fi
      die "${ERRLINE#error: } (nothing written)"
    fi
    printf '%s' "$OUT"
    [ -n "$SL" ] && echo "statusline=$SL: not written by this script; it needs your confirmation (handled by the skill)."
    echo; show ;;
  reset)
    M reset $SCOPE | head -1
    G reset $SCOPE | head -1
    N off $SCOPE | head -1
    N events waiting,done $SCOPE | head -1
    ctx_write "$TARGET" remove >/dev/null
    member_write "$TARGET" tasks remove >/dev/null
    member_write "$TARGET" roles remove >/dev/null
    echo; show ;;
esac
exit 0
