#!/usr/bin/env bash
# SubDeck model policy: show / set / reset the per-role model policy.
#
#   bash <plugin>/scripts/models.sh [show]                         effective policy + source of each value
#   bash <plugin>/scripts/models.sh set key=value ... [--project]  write user (default) or project config
#   bash <plugin>/scripts/models.sh reset [--project]              remove the modelPolicy of that config file
# A trailing existing directory argument is the project dir (default $CLAUDE_PROJECT_DIR, else cwd).
# Precedence: built-in defaults < ~/.subdeck/config.json < project config. The project config lives outside the
# project in ~/.subdeck/projects/<key>/config.json (lib-paths.sh); a legacy <project>/.subdeck/config.json is
# still read (below the new file) but never written.
# Keys: mode (auto|named|current), worker, escalation, researcher, verifier, explore
# Values: sonnet|opus|haiku|fable|inherit, a full model id (claude-...), or another backend's model id.
# `set`/`reset` only replace/remove the modelPolicy member; other top-level members are re-emitted verbatim.
# A file that is not a JSON object is left untouched (message, exit 0).
# `show` warns when a setting would defeat the policy (CLAUDE_CODE_SUBAGENT_MODEL_FORCE, availableModels).
# No jq/node. Always exits 0 (a failing injected command would abort the skill).

KEYS="mode worker escalation researcher verifier explore"
default_of() {
  case "$1" in
    mode) echo auto ;; worker) echo sonnet ;; escalation) echo opus ;;
    researcher) echo sonnet ;; verifier) echo sonnet ;; explore) echo sonnet ;;
  esac
}

CMD=""; SCOPE=user; PROJECT=""; PAIRS=(); BADARGS=()
for a in "$@"; do
  a="${a%$'\r'}"
  case "$a" in
    "") ;;
    --project) SCOPE=project ;;
    --*) BADARGS+=("$a") ;;
    show|set|reset) if [ -z "$CMD" ]; then CMD="$a"; else BADARGS+=("$a"); fi ;;
    *=*) PAIRS+=("$a") ;;
    *) if [ -d "$a" ]; then PROJECT="$a"; else BADARGS+=("$a"); fi ;;
  esac
done
[ -n "$CMD" ] || CMD=show
[ -n "$PROJECT" ] || PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
UFILE="${HOME}/.subdeck/config.json"
HERE="${BASH_SOURCE[0]%[/\\]*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE="."
LFILE="$PROJECT/.subdeck/config.json"   # legacy project config: still read (new file wins), never written
PFILE="$LFILE"; . "$HERE/lib-paths.sh" 2>/dev/null && { sd_state_dir "$PROJECT"; PFILE="$SD_STATE/config.json"; }
[ "$LFILE" = "$PFILE" ] && LFILE=""
if [ "$SCOPE" = project ]; then TARGET="$PFILE"; else TARGET="$UFILE"; fi

getval() { # file key -> value or empty
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}
valid_key() { case " $KEYS " in *" $1 "*) return 0 ;; esac; return 1; }
valid_val() { # key value
  if [ "$1" = mode ]; then case "$2" in auto|named|current) return 0 ;; esac; return 1; fi
  case "$2" in sonnet|opus|haiku|fable|inherit) return 0 ;; esac
  printf '%s' "$2" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,127}$'
}
resolve() { # alias -> resolved id text
  local up var val f
  case "$1" in
    sonnet|opus|haiku|fable) ;;
    inherit) echo "session model (whatever /model is set to)"; return ;;
    *) echo "pinned id"; return ;;
  esac
  up="$(printf '%s' "$1" | tr 'a-z' 'A-Z')"; var="ANTHROPIC_DEFAULT_${up}_MODEL"
  val="${!var}"
  if [ -n "$val" ]; then echo "$val (env $var)"; return; fi
  for f in "$PROJECT/.claude/settings.local.json" "$PROJECT/.claude/settings.json" "$HOME/.claude/settings.json"; do
    val="$(getval "$f" "$var")"
    if [ -n "$val" ]; then echo "$val (settings $var)"; return; fi
  done
  echo "latest $1 (alias; real id shown by /subdeck:status)"
}

# members FILE: print each top-level member of a JSON object on its own line (raw text), except modelPolicy.
# Returns 1 when the file is not a well-formed JSON object; an absent or blank file has no members (returns 0).
members() {
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
      if (cur != "" && cur !~ /^"modelPolicy"[ \t]*:/) print cur
      cur = ""
    }'
}

# write_file FILE OTHERS [key=value ...]: OTHERS = newline-separated raw members kept verbatim.
write_file() {
  local f="$1" others="$2" line out="" body="" kv
  shift 2
  mkdir -p "$(dirname "$f")" 2>/dev/null
  while IFS= read -r line; do if [ -n "$line" ]; then body="$body$line,"; fi; done <<< "$others"
  if [ $# -gt 0 ]; then
    for kv in "$@"; do out="$out,\"${kv%%=*}\":\"${kv#*=}\""; done
    body="$body\"modelPolicy\":{${out#,}},"
  fi
  if printf '{%s}\n' "${body%,}" > "$f" 2>/dev/null; then return 0; fi
  echo "error: could not write $f"; return 1
}

setting_env() { # NAME -> value from process env, else from Claude settings files
  local var="$1" val f
  val="${!var}"; if [ -n "$val" ]; then echo "$val"; return; fi
  for f in "$PROJECT/.claude/settings.local.json" "$PROJECT/.claude/settings.json" "$HOME/.claude/settings.json"; do
    val="$(getval "$f" "$var")"; if [ -n "$val" ]; then echo "$val"; return; fi
  done
}
warn_overrides() {
  local v f
  v="$(setting_env CLAUDE_CODE_SUBAGENT_MODEL_FORCE)"
  case "$v" in
    ""|0|false) ;;
    *) echo "WARNING: CLAUDE_CODE_SUBAGENT_MODEL_FORCE is on: Claude Code ignores this policy and runs every subagent on one model (CLAUDE_CODE_SUBAGENT_MODEL, else the session model). Unset it to use /subdeck:settings." ;;
  esac
  for f in "$PROJECT/.claude/settings.local.json" "$PROJECT/.claude/settings.json" "$HOME/.claude/settings.json"; do
    if [ -f "$f" ] && grep -q '"availableModels"' "$f"; then
      echo "WARNING: availableModels in $f may block a policy model; Claude Code then substitutes another model."; break
    fi
  done
}

show() {
  local k v src val ids=""
  echo "SubDeck model policy (defaults < user < project)"
  printf '%-11s %-24s %s\n' KEY VALUE SOURCE
  for k in $KEYS; do
    v="$(default_of "$k")"; src="default"
    val="$(getval "$UFILE" "$k")"; if [ -n "$val" ]; then v="$val"; src="user"; fi
    if [ -n "$LFILE" ]; then val="$(getval "$LFILE" "$k")"; if [ -n "$val" ]; then v="$val"; src="project"; fi; fi
    val="$(getval "$PFILE" "$k")"; if [ -n "$val" ]; then v="$val"; src="project"; fi
    printf '%-11s %-24s %s\n' "$k" "$v" "$src"
    if [ "$k" != mode ]; then ids="$ids$k|$v"$'\n'; fi
  done
  echo
  echo "Resolved models:"
  printf '%s' "$ids" | while IFS='|' read -r k v; do
    [ -n "$k" ] && printf '  %-11s %s -> %s\n' "$k" "$v" "$(resolve "$v")"
  done
  echo
  echo "user file:    $UFILE$([ -f "$UFILE" ] || echo ' (absent)')"
  echo "project file: $PFILE$([ -f "$PFILE" ] || echo ' (absent)')"
  [ -n "$LFILE" ] && [ -f "$LFILE" ] && echo "legacy file:  $LFILE (still read; the project file wins; remove it by hand when no longer needed)"
  warn_overrides
  echo "Manager model: chosen in Claude Code with /model (not part of this policy)."
  echo "Usage: /subdeck:settings set worker=sonnet verifier=opus (low-level: models.sh set worker=haiku verifier=opus [--project] | reset [--project])"
}

for b in "${BADARGS[@]}"; do echo "warning: ignored argument '$b'"; done

case "$CMD" in
  show) show ;;
  reset)
    if [ ! -f "$TARGET" ]; then echo "reset: nothing to remove ($TARGET absent)"
    elif ! OTHERS="$(members "$TARGET")"; then echo "error: $TARGET is not a valid JSON object; left untouched (fix or delete it by hand)."
    elif [ -z "$OTHERS" ]; then
      if rm -f "$TARGET" 2>/dev/null; then echo "reset: removed $TARGET"; else echo "error: could not remove $TARGET"; fi
    else
      if write_file "$TARGET" "$OTHERS"; then echo "reset: removed modelPolicy from $TARGET (other settings kept)"; fi
    fi
    echo; show ;;
  set)
    if [ ${#PAIRS[@]} -eq 0 ]; then echo "error: set needs key=value pairs, e.g. set worker=haiku"; echo "valid keys: $KEYS"; exit 0; fi
    ERR=0; NEW=()
    for kv in "${PAIRS[@]}"; do
      k="${kv%%=*}"; v="${kv#*=}"
      if ! valid_key "$k"; then echo "error: unknown key '$k' (valid: $KEYS)"; ERR=1
      elif ! valid_val "$k" "$v"; then
        if [ "$k" = mode ]; then echo "error: invalid value '$v' for mode (valid: auto, named, current)"
        else echo "error: invalid value '$v' for $k (valid: sonnet, opus, haiku, fable, inherit, or a model id such as claude-sonnet-5-5)"; fi
        ERR=1
      else NEW+=("$k=$v"); fi
    done
    if [ $ERR -ne 0 ]; then echo "nothing written."; exit 0; fi
    if ! OTHERS="$(members "$TARGET")"; then
      echo "error: $TARGET is not a valid JSON object; left untouched (fix or delete it by hand)."; exit 0
    fi
    MERGED=()
    for k in $KEYS; do
      val="$(getval "$TARGET" "$k")"
      for kv in "${NEW[@]}"; do if [ "${kv%%=*}" = "$k" ]; then val="${kv#*=}"; fi; done
      if [ -n "$val" ]; then MERGED+=("$k=$val"); fi
    done
    if write_file "$TARGET" "$OTHERS" "${MERGED[@]}"; then echo "wrote $TARGET"; fi
    echo; show ;;
esac
exit 0
