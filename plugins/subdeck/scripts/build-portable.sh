#!/usr/bin/env bash
# Derive the tool-neutral variants (Codex, Copilot) from the Claude Code source files.
# Usage: build-portable.sh [--out DIR]      (default DIR: the plugin directory, i.e. regenerate in place)
# Sources of truth (never edited here): skills/*/SKILL.md, agents/*.md, hooks/copilot-hooks.json,
#   .claude-plugin/plugin.json. Generated (committed; tests/test-portable.sh fails when they drift):
#   skills-portable/<name>/SKILL.md   skills without Claude's "!" command injection and ${CLAUDE_PLUGIN_ROOT}:
#                                     the script path is resolved from the skill's own directory (../../scripts)
#   skills-portable/orchestrator/pr-facts.sh   copy
#   .github/agents/<name>.agent.md    Copilot custom agents (Claude model/effort/memory keys dropped)
#   .github/plugin/plugin.json        Copilot plugin manifest (found before .claude-plugin/plugin.json)
#   hooks/copilot-plugin-hooks.json   Copilot-format hooks using the PLUGIN_ROOT variable Copilot exports
# bash + sed + awk only.
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$SRC"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) shift; OUT="${1:-}" ;;
    *) echo "Usage: build-portable.sh [--out DIR]" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$OUT" ] || { echo "--out needs a directory" >&2; exit 2; }
mkdir -p "$OUT" || exit 1
OUT="$(cd "$OUT" && pwd)"

MARK="managed by SubDeck install script"

fm()   { awk -v k="$2" '/^---\r?$/{c++; next} c==1 { sub(/\r$/,""); i=index($0,":"); if (i>0 && substr($0,1,i-1)==k) { v=substr($0,i+1); sub(/^[ \t]+/,"",v); print v; exit } }' "$1"; }
body() { awk 'c>=2{sub(/\r$/,""); print} /^---\r?$/{c++}' "$1"; }
qesc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

SKILLDIR='<skill dir>'   # prose placeholder the model resolves: the directory holding the loaded SKILL.md

# ---------- portable skills ----------
rm -rf "$OUT/skills-portable"
for name in desk status settings; do
  src="$SRC/skills/$name/SKILL.md"
  script="$(sed -n 's#.*scripts/\([a-z]*\)\.sh.*#\1#p' "$src" | head -n 1)"
  d="$OUT/skills-portable/$name"; mkdir -p "$d"
  {
    echo "---"
    echo "name: $name"
    echo "description: \"$(qesc "$(fm "$src" description)")\""
    echo "---"
    echo
    echo "Run the command below with the shell tool and print its output verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands."
    echo "Replace \`$SKILLDIR\` with the absolute path of the directory that contains this SKILL.md, and put the user's arguments (if any) at the end; run it from the project directory."
    echo
    echo '```bash'
    echo "bash \"$SKILLDIR/../../scripts/$script.sh\" [arguments] || true"
    echo '```'
    if [ "$name" = settings ]; then
      echo
      echo "The status line (\`statusline=on|off\`) is a Claude Code feature: in this tool those keys have no effect; say so if the user asks for them."
    fi
  } > "$d/SKILL.md"
done

d="$OUT/skills-portable/orchestrator"; mkdir -p "$d"
{
  awk -v note="> Portable copy for Codex and Copilot, generated from the Claude Code skill. Launch sub-agents with this tool's own sub-agent mechanism by the plain names below (worker-sonnet, researcher, verifier ...; installed by \`install.sh --tool <tool>\` when the plugin does not bundle them). Model aliases and the \`model\` parameter in the policy below are Claude Code settings: in other tools let each agent use its configured model. \`<skill dir>\` is the directory that contains this SKILL.md." '
    { print } /^---\r?$/ { c++; if (c == 2) { print ""; print note } }' "$SRC/skills/orchestrator/SKILL.md" \
  | sed -e 's#"\${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/pr-facts\.sh"#"<skill dir>/pr-facts.sh"#g' \
        -e 's#"\${CLAUDE_PLUGIN_ROOT}/scripts/#"<skill dir>/../../scripts/#g' \
        -e 's#`/subdeck:\([a-z]*\)`#the `\1` skill#g' \
        -e 's#/subdeck:\([a-z]*\)#the \1 skill#g' \
        -e 's#subdeck:worker#worker#g' -e 's#subdeck:researcher#researcher#g' -e 's#subdeck:verifier#verifier#g' \
        -e 's#subdeck:<agent>#<agent>#g'
} > "$d/SKILL.md"
cp "$SRC/skills/orchestrator/pr-facts.sh" "$d/pr-facts.sh"

# ---------- Copilot agents ----------
rm -rf "$OUT/.github/agents"; mkdir -p "$OUT/.github/agents"
for f in "$SRC"/agents/*.md; do
  n="$(basename "$f" .md)"
  tools="$(fm "$f" tools)"
  {
    echo "---"
    echo "name: $n"
    echo "description: \"$(qesc "$(fm "$f" description)")\""
    if [ -n "$tools" ] && ! printf '%s' "$tools" | grep -qE 'Bash|Write|Edit'; then echo 'tools: ["read", "search"]'; fi
    echo "---"
    echo "<!-- $MARK -->"
    body "$f"
  } > "$OUT/.github/agents/$n.agent.md"
done

# ---------- Copilot plugin manifest and hooks ----------
VER="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/.claude-plugin/plugin.json" | head -n 1)"
mkdir -p "$OUT/.github/plugin" "$OUT/hooks"
cat > "$OUT/.github/plugin/plugin.json" <<EOF
{
  "name": "subdeck",
  "version": "$VER",
  "description": "Manager plus sub-agents toolkit: orchestrator rulebook, live agent status, SubDeck Desk dashboard, settings, and guard hooks.",
  "author": { "name": "Emirhan Demirci" },
  "license": "MIT",
  "skills": "skills-portable",
  "agents": ".github/agents",
  "hooks": "hooks/copilot-plugin-hooks.json"
}
EOF
# template placeholder __ROOT__: bash -> $PLUGIN_ROOT/..., powershell -> $env:PLUGIN_ROOT/...
sed -e '/"bash"/s#__ROOT__#$PLUGIN_ROOT#g' -e '/"powershell"/s#__ROOT__#$env:PLUGIN_ROOT#g' "$SRC/hooks/copilot-hooks.json" > "$OUT/hooks/copilot-plugin-hooks.json"
echo "portable files written to $OUT"
exit 0
