#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-cursor-antigravity.sh
# Cursor plugin, Antigravity plugin and Gemini CLI extension: sync with the generator, manifests, installer.
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PL/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
chk() { [ "$2" = 0 ] && ok "$1" || bad "$1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
CR="$(printf '\r')"

bash "$PL/scripts/build-portable.sh" --out "$T/gen" > "$T/out" 2>&1; chk "generator runs into a temp dir" $?
G="$T/gen/repo-root"
for p in .cursor-plugin gemini-extension.json GEMINI.md; do
  if diff -r "$G/$p" "$ROOT/$p" > "$T/d" 2>&1; then ok "committed $p equals generated"; else bad "$p drifted (run scripts/build-portable.sh): $(head -2 "$T/d" | tr '\n' ' ')"; fi
done
if diff -r "$T/gen/.antigravity" "$PL/.antigravity" > "$T/d" 2>&1; then ok "committed .antigravity equals generated"; else bad ".antigravity drifted: $(head -2 "$T/d" | tr '\n' ' ')"; fi
if grep -rq "$CR" "$ROOT/.cursor-plugin" "$PL/.antigravity" "$ROOT/gemini-extension.json" "$ROOT/GEMINI.md"; then bad "CRLF in generated files"; else ok "generated files LF"; fi

CV="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PL/.claude-plugin/plugin.json" | head -1)"
if command -v node >/dev/null 2>&1; then
  jt() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((function(j){return '"$2"'})(j)?0:1)' "$1" 2>/dev/null; }
  jt "$ROOT/.cursor-plugin/plugin.json" "j.name==='subdeck' && j.version==='$CV' && j.skills==='./plugins/subdeck/skills-portable/' && j.agents==='./.cursor-plugin/agents/' && j.rules==='./.cursor-plugin/rules/'"; chk "cursor plugin.json: name, version $CV, component paths" $?
  jt "$PL/.antigravity/plugin.json" "/^[a-zA-Z0-9_-]+\$/.test(j.name) && j.name==='subdeck' && j['\$schema']==='https://antigravity.google/schemas/v1/plugin.json' && !!j.description"; chk "antigravity plugin.json: name pattern, schema, description" $?
  jt "$ROOT/gemini-extension.json" "j.name==='subdeck' && j.version==='$CV' && j.contextFileName==='GEMINI.md' && /^[a-z0-9-]+\$/.test(j.name)"; chk "gemini-extension.json: name, version $CV, contextFileName" $?
fi
if grep -q '^@\./plugins/subdeck/skills-portable/orchestrator/SKILL.md$' "$ROOT/GEMINI.md" && [ -f "$PL/skills-portable/orchestrator/SKILL.md" ]; then ok "GEMINI.md imports the orchestrator skill (path exists)"; else bad "GEMINI.md import"; fi
if head -5 "$ROOT/.cursor-plugin/rules/subdeck.mdc" | grep -qx 'alwaysApply: true'; then ok "cursor rule is alwaysApply"; else bad "cursor rule"; fi

# agents: 7 each, frontmatter, Claude-only keys dropped, read-only mapping
nc=0; na=0
for f in "$PL"/agents/*.md; do b="$(basename "$f" .md)"
  c="$ROOT/.cursor-plugin/agents/$b.md"; a="$PL/.antigravity/agents/$b.md"
  if [ -f "$c" ] && grep -qx "name: $b" "$c" && grep -qx 'model: inherit' "$c" && ! grep -Eq '^(effort|memory|tools):' "$c"; then nc=$((nc+1)); fi
  if [ -f "$a" ] && grep -qx "name: $b" "$a" && grep -qx 'subagent: true' "$a" && ! grep -Eq '^(effort|memory):' "$a"; then na=$((na+1)); fi
done
[ "$nc" = 7 ] && ok "7 cursor agents (name, model inherit, no Claude-only keys)" || bad "cursor agents: $nc"
[ "$na" = 7 ] && ok "7 antigravity agents (name, subagent: true)" || bad "antigravity agents: $na"
if grep -qx 'readonly: true' "$ROOT/.cursor-plugin/agents/researcher.md" && ! grep -q '^readonly:' "$ROOT/.cursor-plugin/agents/worker-sonnet.md"; then ok "cursor: researcher readonly, worker not"; else bad "cursor readonly"; fi
if grep -qx '  - view_file' "$PL/.antigravity/agents/researcher.md" && ! grep -q '^tools:' "$PL/.antigravity/agents/worker-sonnet.md"; then ok "antigravity: researcher tool-limited, worker not"; else bad "antigravity tools"; fi
if diff -r "$PL/skills-portable" "$PL/.antigravity/skills" > /dev/null; then ok "antigravity skills = portable skills"; else bad "antigravity skills differ"; fi

# installer (sh)
IS="$ROOT/install.sh"
CH="$T/cursor"; AH="$T/agy"
CURSOR_HOME="$CH" bash "$IS" --tool cursor > "$T/out" 2>&1; chk "install --tool cursor exits 0" $?
D="$CH/plugins/local/subdeck"
if [ -f "$D/.cursor-plugin/plugin.json" ] && [ -f "$D/plugins/subdeck/skills-portable/desk/SKILL.md" ] && [ -f "$D/plugins/subdeck/scripts/desk.sh" ] && [ -f "$D/.subdeck-managed" ]; then ok "cursor install: manifest, skills, scripts, marker"; else bad "cursor install layout"; fi
if [ -f "$D/plugins/subdeck/skills-portable/desk/../../scripts/desk.sh" ]; then ok "cursor install: skill script path resolves"; else bad "cursor script path"; fi
CURSOR_HOME="$CH" bash "$IS" --tool cursor > /dev/null 2>&1; chk "cursor install is idempotent" $?
CURSOR_HOME="$CH" bash "$IS" --tool cursor --uninstall > /dev/null 2>&1; if [ ! -e "$D" ]; then ok "cursor uninstall removes it"; else bad "cursor uninstall"; fi
mkdir -p "$D"; echo keep > "$D/foreign.txt"
CURSOR_HOME="$CH" bash "$IS" --tool cursor > "$T/out" 2>&1; if grep -q 'not managed' "$T/out" && [ -f "$D/foreign.txt" ]; then ok "cursor: foreign directory never overwritten"; else bad "cursor foreign"; fi
CURSOR_HOME="$CH" bash "$IS" --tool cursor --uninstall > /dev/null 2>&1; if [ -f "$D/foreign.txt" ]; then ok "cursor uninstall leaves foreign directory"; else bad "cursor uninstall foreign"; fi
SUBDECK_ANTIGRAVITY_DIR="$AH" PATH="/usr/bin:/bin" bash "$IS" --tool antigravity > "$T/out" 2>&1; chk "install --tool antigravity exits 0" $?
if [ -f "$AH/plugin.json" ] && [ -d "$AH/skills/status" ] && [ -f "$AH/scripts/status.sh" ] && [ -f "$AH/agents/worker-sonnet.md" ] && [ -f "$AH/rules/subdeck.md" ] && [ -f "$AH/.subdeck-managed" ]; then ok "antigravity install: plugin.json, skills, scripts, agents, rules"; else bad "antigravity layout"; fi
if grep -q 'agy plugin install' "$T/out"; then ok "antigravity prints the agy install line when agy is missing"; else bad "agy line"; fi
if [ -f "$AH/skills/status/../../scripts/status.sh" ]; then ok "antigravity: skill script path resolves"; else bad "antigravity script path"; fi
SUBDECK_ANTIGRAVITY_DIR="$AH" bash "$IS" --tool antigravity --uninstall > /dev/null 2>&1; if [ ! -e "$AH" ]; then ok "antigravity uninstall removes the staging dir"; else bad "antigravity uninstall"; fi
bash "$IS" --tool nope > /dev/null 2>&1; [ $? = 2 ] && ok "unknown tool exits 2" || bad "unknown tool"
if grep -q "'cursor', 'antigravity', 'opencode'" "$ROOT/install.ps1"; then ok "install.ps1 knows cursor and antigravity"; else bad "install.ps1 tools"; fi

# OpenCode installer (sh)
OH="$T/oc"; OP="$T/ocp"
OPENCODE_CONFIG_HOME="$OH" SUBDECK_PLUGIN_COPY="$OP" bash "$IS" --tool opencode > "$T/out" 2>&1; chk "install --tool opencode exits 0" $?
if [ -f "$OH/plugins/subdeck.js" ] && [ -f "$OH/commands/subdeck-status.md" ] && [ -f "$OH/commands/subdeck-settings.md" ] && [ -f "$OH/commands/subdeck-desk.md" ] && [ -f "$OP/scripts/status.sh" ] && [ -f "$OP/skills/orchestrator/SKILL.md" ] && [ -f "$OP/.subdeck-managed" ]; then ok "opencode install: plugin, 3 commands, plugin copy, marker"; else bad "opencode layout"; fi
if grep -q '"instructions"' "$T/out" && [ ! -e "$OH/opencode.json" ]; then ok "opencode: prints the instructions line, never writes opencode.json"; else bad "opencode instructions"; fi
OPENCODE_CONFIG_HOME="$OH" SUBDECK_PLUGIN_COPY="$OP" bash "$IS" --tool opencode > /dev/null 2>&1; chk "opencode install is idempotent" $?
OPENCODE_CONFIG_HOME="$OH" SUBDECK_PLUGIN_COPY="$OP" bash "$IS" --tool opencode --uninstall > /dev/null 2>&1
if [ ! -e "$OH/plugins/subdeck.js" ] && [ ! -e "$OH/commands/subdeck-status.md" ] && [ ! -e "$OP" ]; then ok "opencode uninstall removes ours"; else bad "opencode uninstall"; fi
mkdir -p "$OH/commands"; echo keep > "$OH/commands/subdeck-status.md"
OPENCODE_CONFIG_HOME="$OH" SUBDECK_PLUGIN_COPY="$OP" bash "$IS" --tool opencode > "$T/out" 2>&1
if grep -q 'did not write' "$T/out" && [ "$(cat "$OH/commands/subdeck-status.md")" = keep ] && [ ! -e "$OP" ]; then ok "opencode: foreign command never overwritten"; else bad "opencode foreign"; fi

# installer (ps1), only where PowerShell exists
if command -v powershell >/dev/null 2>&1; then
  PP="$(cygpath -w "$ROOT/install.ps1" 2>/dev/null || echo "$ROOT/install.ps1")"
  CURSOR_HOME="$T/pcursor" powershell -NoProfile -ExecutionPolicy Bypass -File "$PP" -Tool cursor > "$T/out" 2>&1
  if [ -f "$T/pcursor/plugins/local/subdeck/.cursor-plugin/plugin.json" ] && [ -f "$T/pcursor/plugins/local/subdeck/plugins/subdeck/scripts/desk.sh" ]; then ok "install.ps1 -Tool cursor layout"; else bad "ps1 cursor: $(tail -2 "$T/out")"; fi
  if diff -r "$ROOT/.cursor-plugin" "$T/pcursor/plugins/local/subdeck/.cursor-plugin" > /dev/null; then ok "ps1 and committed cursor files agree"; else bad "ps1 cursor content"; fi
  CURSOR_HOME="$T/pcursor" powershell -NoProfile -ExecutionPolicy Bypass -File "$PP" -Tool cursor -Uninstall > /dev/null 2>&1; if [ ! -e "$T/pcursor/plugins/local/subdeck" ]; then ok "install.ps1 cursor -Uninstall"; else bad "ps1 cursor uninstall"; fi
  SUBDECK_ANTIGRAVITY_DIR="$T/pagy" powershell -NoProfile -ExecutionPolicy Bypass -File "$PP" -Tool antigravity > "$T/out" 2>&1
  if [ -f "$T/pagy/plugin.json" ] && [ -f "$T/pagy/scripts/status.sh" ] && [ -d "$T/pagy/skills/desk" ]; then ok "install.ps1 -Tool antigravity layout"; else bad "ps1 antigravity: $(tail -2 "$T/out")"; fi
  SUBDECK_ANTIGRAVITY_DIR="$T/pagy" powershell -NoProfile -ExecutionPolicy Bypass -File "$PP" -Tool antigravity -Uninstall > /dev/null 2>&1; if [ ! -e "$T/pagy" ]; then ok "install.ps1 antigravity -Uninstall"; else bad "ps1 antigravity uninstall"; fi
  OPENCODE_CONFIG_HOME="$T/poc" SUBDECK_PLUGIN_COPY="$T/pocp" powershell -NoProfile -ExecutionPolicy Bypass -File "$PP" -Tool opencode > "$T/out" 2>&1
  if [ -f "$T/poc/plugins/subdeck.js" ] && [ -f "$T/poc/commands/subdeck-desk.md" ] && [ -f "$T/pocp/scripts/status.sh" ] && [ -f "$T/pocp/.subdeck-managed" ]; then ok "install.ps1 -Tool opencode layout"; else bad "ps1 opencode: $(tail -2 "$T/out")"; fi
  OPENCODE_CONFIG_HOME="$T/poc" SUBDECK_PLUGIN_COPY="$T/pocp" powershell -NoProfile -ExecutionPolicy Bypass -File "$PP" -Tool opencode -Uninstall > /dev/null 2>&1; if [ ! -e "$T/poc/plugins/subdeck.js" ] && [ ! -e "$T/pocp" ]; then ok "install.ps1 opencode -Uninstall"; else bad "ps1 opencode uninstall"; fi
else echo "skip install.ps1 tests (no powershell)"; fi
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
