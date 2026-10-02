#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-portable.sh
# The committed portable files (skills-portable, .github agents + manifest, copilot-plugin-hooks) must equal
# what scripts/build-portable.sh generates from the Claude Code sources.
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PL/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

bash "$PL/scripts/build-portable.sh" --out "$T/gen" > "$T/out" 2>&1 && ok "generator runs into a temp dir" || bad "generator failed: $(cat "$T/out")"
for p in skills-portable .github/agents .github/plugin hooks/copilot-plugin-hooks.json; do
  if diff -r "$T/gen/$p" "$PL/$p" > "$T/diff" 2>&1; then ok "committed $p equals generated"; else bad "committed $p drifted from the generator (run scripts/build-portable.sh): $(head -3 "$T/diff" | tr '\n' ' ')"; fi
done
bash "$PL/scripts/build-portable.sh" --out "$T/gen" > /dev/null 2>&1
diff -r "$T/gen" "$T/gen" > /dev/null && ok "generator is repeatable into the same dir" || bad "not repeatable"
if grep -rq $'\r' "$PL/skills-portable" "$PL/.github" "$PL/hooks/copilot-plugin-hooks.json" "$PL/scripts/build-portable.sh"; then bad "CRLF in generated files"; else ok "generated files LF"; fi

# content of the portable skills
for s in desk status settings orchestrator; do
  f="$PL/skills-portable/$s/SKILL.md"
  [ -f "$f" ] && head -1 "$f" | grep -qx -- '---' && grep -qx "name: $s" "$f" && grep -q '^description: ' "$f" && ok "$s: portable skill has name + description" || bad "$s: frontmatter"
  grep -q 'CLAUDE_PLUGIN_ROOT\|CLAUDE_PROJECT_DIR\|^```!\|allowed-tools\|disable-model-invocation\|\$ARGUMENTS' "$f" && bad "$s: Claude-specific syntax left" || ok "$s: no Claude-specific syntax"
  grep -q 'subdeck:' "$f" && bad "$s: namespaced Claude names left" || ok "$s: no subdeck: names"
done
for s in desk status settings; do
  sc="$(sed -n 's#.*<skill dir>/\.\./\.\./scripts/\([a-z]*\)\.sh.*#\1#p' "$PL/skills-portable/$s/SKILL.md" | head -1)"
  [ -n "$sc" ] && [ -f "$PL/skills-portable/$s/../../scripts/$sc.sh" ] && ok "$s: script path resolves from the skill dir" || bad "$s: script path ($sc)"
done
grep -o '<skill dir>/\.\./\.\./scripts/[a-z]*\.sh' "$PL/skills-portable/orchestrator/SKILL.md" | sort -u | while read -r p; do
  [ -f "$PL/skills-portable/orchestrator/${p#<skill dir>/}" ] || echo "MISSING $p"
done > "$T/miss"; [ ! -s "$T/miss" ] && ok "orchestrator: script paths resolve" || bad "orchestrator: $(cat "$T/miss")"
cmp -s "$PL/skills/orchestrator/pr-facts.sh" "$PL/skills-portable/orchestrator/pr-facts.sh" && grep -q '<skill dir>/pr-facts.sh' "$PL/skills-portable/orchestrator/SKILL.md" && ok "orchestrator: pr-facts.sh copied and referenced" || bad "orchestrator: pr-facts"
# Claude sources must stay Claude-shaped
grep -q 'CLAUDE_PLUGIN_ROOT' "$PL/skills/desk/SKILL.md" && grep -q '^model: sonnet' "$PL/agents/worker-sonnet.md" && ok "Claude sources unchanged in shape" || bad "Claude sources changed"

# Copilot manifest, agents, hooks
if command -v node >/dev/null 2>&1; then
  jt() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((function(j){return '"$2"'})(j)?0:1)' "$1" 2>/dev/null; }
  CV="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$PL/.claude-plugin/plugin.json")"
  M="$PL/.github/plugin/plugin.json"
  jt "$M" "j.name===\"subdeck\" && j.version===\"$CV\" && j.skills===\"skills-portable\" && j.agents===\".github/agents\" && j.hooks===\"hooks/copilot-plugin-hooks.json\""; [ $? = 0 ] && ok "copilot plugin.json: keys, paths, version $CV" || bad "copilot plugin.json"
  [ -d "$PL/skills-portable" ] && [ -d "$PL/.github/agents" ] && [ -f "$PL/hooks/copilot-plugin-hooks.json" ] && ok "copilot manifest paths exist" || bad "copilot manifest paths"
  H="$PL/hooks/copilot-plugin-hooks.json"
  jt "$H" 'j.version===1 && Object.values(j.hooks).every(a=>a.every(h=>h.type==="command"&&h.bash&&h.powershell&&h.timeoutSec>0))'; [ $? = 0 ] && ok "copilot-plugin-hooks.json parses, bash + powershell everywhere" || bad "copilot-plugin-hooks.json"
  jt "$H" '!JSON.stringify(j).includes("__ROOT__") && !JSON.stringify(j).includes("CLAUDE_PLUGIN_ROOT") && Object.values(j.hooks).every(a=>a.every(h=>/\$PLUGIN_ROOT/.test(h.bash)&&/\$env:PLUGIN_ROOT/.test(h.powershell)))'; [ $? = 0 ] && ok "copilot plugin hooks use PLUGIN_ROOT (bash + powershell)" || bad "copilot plugin hooks root variable"
  jt "$PL/hooks/hooks.json" 'JSON.stringify(j).includes("CLAUDE_PLUGIN_ROOT")'; [ $? = 0 ] && ok "Claude hooks.json untouched" || bad "Claude hooks.json"
fi
n=0; for f in "$PL"/agents/*.md; do b="$(basename "$f" .md)"; g="$PL/.github/agents/$b.agent.md"; [ -f "$g" ] && grep -qx "name: $b" "$g" && ! grep -q '^model:\|^effort:\|^memory:' "$g" && n=$((n+1)); done
[ "$n" = 7 ] && ok "7 Copilot agents, Claude-only keys dropped" || bad "copilot agents: $n"
grep -qx 'tools: \["read", "search"\]' "$PL/.github/agents/researcher.agent.md" && ! grep -q '^tools:' "$PL/.github/agents/worker-sonnet.agent.md" && ok "copilot: researcher read-only, worker unrestricted" || bad "copilot tools"
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
