#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-multi-tool.sh
# Codex / Copilot packaging: manifests, hook files, payload normalisation, install.sh --tool.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PL="$ROOT/plugins/subdeck"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SUBDECK_STATE_DIR="$T/state"; unset SUBDECK_HOME   # hook scripts write per-project state here, never the real home

# ---------- JSON files: parse + required keys (node, as Desk requires it anyway) ----------
if command -v node >/dev/null 2>&1; then
  jt() { # file, js expression over j that must be truthy
    node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((function(j){return '"$2"'})(j)?0:1)' "$1" 2>/dev/null
  }
  CP="$ROOT/.codex-plugin/plugin.json"
  jt "$CP" 'j.name==="subdeck" && j.version && j.description && j.skills && j.hooks && j.interface && j.interface.displayName'; chk "codex plugin.json parses with required keys" $?
  CV="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$PL/.claude-plugin/plugin.json")"
  jt "$CP" "j.version===\"$CV\""; chk "codex plugin.json version equals the Claude plugin version ($CV)" $?
  [ -d "$PL/skills-portable" ] && [ -f "$PL/hooks/codex-hooks.json" ]; chk "codex plugin.json paths exist" $?
  jt "$CP" 'j.skills==="./plugins/subdeck/skills-portable/" && j.hooks==="./plugins/subdeck/hooks/codex-hooks.json"'; chk "codex plugin.json paths are root-relative" $?
  MP="$ROOT/.agents/plugins/marketplace.json"
  jt "$MP" 'j.name==="subdeck" && Array.isArray(j.plugins) && j.plugins.length===1'; chk "codex marketplace.json parses, name subdeck" $?
  jt "$MP" 'j.plugins[0].name==="subdeck" && j.plugins[0].source.source==="local" && /^\.\//.test(j.plugins[0].source.path) && j.plugins[0].policy.installation==="AVAILABLE" && j.plugins[0].policy.authentication && j.plugins[0].category'; chk "codex marketplace plugin entry has required keys" $?
  [ -f "$ROOT/.codex-plugin/plugin.json" ]; chk "marketplace source path ./ holds .codex-plugin/plugin.json" $?

  CH="$PL/hooks/codex-hooks.json"
  jt "$CH" '["SessionStart","SubagentStart","SubagentStop","PermissionRequest","Stop","PreToolUse"].every(e=>Array.isArray(j.hooks[e]))'; chk "codex-hooks.json has all events" $?
  jt "$CH" 'Object.values(j.hooks).every(g=>g.every(m=>m.hooks.every(h=>h.type==="command"&&h.command&&h.commandWindows&&h.timeout>0)))'; chk "codex hooks: command + commandWindows + timeout everywhere" $?
  jt "$CH" '/Bash\|apply_patch/.test(j.hooks.PreToolUse[0].matcher) && j.hooks.PreToolUse[0].hooks[0].command.includes("SUBDECK_TOOL=codex") && j.hooks.PreToolUse[0].hooks[0].command.includes("guard")'; chk "codex PreToolUse guard matcher covers Bash and apply_patch" $?
  jt "$CH" 'JSON.stringify(j).includes("PLUGIN_ROOT") && !JSON.stringify(j).includes("CLAUDE_PLUGIN_ROOT")'; chk "codex hooks use PLUGIN_ROOT only" $?
  for f in codex-session-start copilot-session-start; do
    jt "$PL/hooks/$f.json" 'j.hookSpecificOutput.hookEventName==="SessionStart" && /orchestrator/.test(j.hookSpecificOutput.additionalContext)'; chk "$f.json valid, points at the orchestrator" $?
  done
  jt "$PL/hooks/copilot-session-start.json" 'j.additionalContext===j.hookSpecificOutput.additionalContext'; chk "copilot session-start carries top-level additionalContext" $?
  CO="$PL/hooks/copilot-hooks.json"
  jt "$CO" 'j.version===1 && ["SessionStart","SubagentStart","SubagentStop","Stop","PreToolUse","permissionRequest"].every(e=>Array.isArray(j.hooks[e]))'; chk "copilot-hooks.json version 1 with all events" $?
  jt "$CO" 'Object.values(j.hooks).every(a=>a.every(h=>h.type==="command"&&h.bash&&h.powershell&&h.timeoutSec>0&&h.bash.includes("__ROOT__")&&h.powershell.includes("__ROOT__")))'; chk "copilot hooks: bash + powershell + __ROOT__ everywhere" $?
  jt "$CO" 'j.hooks.PreToolUse[0].env.SUBDECK_TOOL==="copilot" && /Bash/.test(j.hooks.PreToolUse[0].matcher)'; chk "copilot guard sets SUBDECK_TOOL=copilot" $?
  jt "$PL/hooks/hooks.json" 'JSON.stringify(j).includes("CLAUDE_PLUGIN_ROOT") && !JSON.stringify(j).includes("SUBDECK_TOOL")'; chk "Claude hooks.json untouched by tool variants" $?
else
  echo "skip JSON structure tests (no node)"
fi

# ---------- guard payload normalisation ----------
G="$PL/scripts/guard.sh"
mkdir -p "$T/ghome" "$T/proj"
CLAUDE_OUT="$(printf '%s' '{"tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":"/x/.env"}}' | HOME="$T/ghome" bash "$G")"
case "$CLAUDE_OUT" in '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"SubDeck guard (secret-files)'*) ok "claude: secret write still the unchanged Claude shape";; *) bad "claude shape changed: $CLAUDE_OUT";; esac
PATCH='{"tool_name":"apply_patch","cwd":"/tmp","tool_input":{"command":"*** Begin Patch\n*** Add File: app/.env\n+K=1\n*** End Patch"}}'
OUT="$(printf '%s' "$PATCH" | SUBDECK_TOOL=codex HOME="$T/ghome" bash "$G")"
case "$OUT" in *'"permissionDecision":"deny"'*'Ask the user'*) ok "codex: apply_patch on .env is denied (ask becomes deny)";; *) bad "codex apply_patch: $OUT";; esac
OUT="$(printf '%s' '{"tool_name":"apply_patch","cwd":"/tmp","tool_input":{"command":"*** Begin Patch\n*** Update File: src/main.c\n@@\n-a\n+b\n*** End Patch"}}' | SUBDECK_TOOL=codex HOME="$T/ghome" bash "$G")"
[ -z "$OUT" ] && ok "codex: apply_patch on a normal file is allowed" || bad "codex normal patch: $OUT"
OUT="$(printf '%s' '{"tool_name":"apply_patch","cwd":"/tmp","tool_input":{"command":"*** Begin Patch\n*** Update File: a.c\n*** Move to: keys/id_rsa\n*** End Patch"}}' | SUBDECK_TOOL=codex HOME="$T/ghome" bash "$G")"
case "$OUT" in *secret-files*) ok "codex: Move to a secret path is caught";; *) bad "codex move: $OUT";; esac
OUT="$(printf '%s' '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git add -A"}}' | SUBDECK_TOOL=codex HOME="$T/ghome" bash "$G")"
case "$OUT" in '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"'*) ok "codex: deny keeps the Claude shape";; *) bad "codex deny: $OUT";; esac
OUT="$(printf '%s' '{"tool_name":"bash","cwd":"/tmp","tool_input":{"command":"git add -A"}}' | SUBDECK_TOOL=copilot HOME="$T/ghome" bash "$G")"
case "$OUT" in '{"permissionDecision":"deny","permissionDecisionReason":"'*'"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"'*) ok "copilot: lowercase bash tool, flat deny plus Claude member";; *) bad "copilot deny: $OUT";; esac
OUT="$(printf '%s' '{"tool_name":"create","cwd":"/tmp","tool_input":{"path":"/x/credentials.json"}}' | SUBDECK_TOOL=copilot HOME="$T/ghome" bash "$G")"
case "$OUT" in *'"permissionDecision":"ask"'*secret-files*) ok "copilot: create + tool_input.path is checked";; *) bad "copilot create: $OUT";; esac
OUT="$(printf '%s' '{"tool_name":"bash","cwd":"/tmp","tool_input":{"command":"ls -la"}}' | SUBDECK_TOOL=copilot HOME="$T/ghome" bash "$G")"
[ -z "$OUT" ] && ok "copilot: harmless command allowed (no output)" || bad "copilot allow: $OUT"

# ---------- log-event: agent_name fallback ----------
mkdir -p "$T/proj"; ED="$(. "$PL/scripts/lib-paths.sh"; sd_state_dir "$T/proj"; printf '%s' "$SD_STATE")"   # state dir outside the project
printf '%s' "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"s1\",\"cwd\":\"$T/proj\",\"agent_id\":\"a1\",\"agent_name\":\"researcher\"}" | bash "$PL/scripts/log-event.sh" SubagentStart
grep -q '"agent_type":"researcher"' "$ED/events.jsonl" && ok "log-event: agent_name fills agent_type" || bad "log-event agent_name fallback"
rm -rf "$ED"
printf '%s' "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"s1\",\"cwd\":\"$T/proj\",\"agent_id\":\"a1\",\"agent_type\":\"worker\",\"agent_name\":\"other\"}" | bash "$PL/scripts/log-event.sh" SubagentStart
grep -q '"agent_type":"worker"' "$ED/events.jsonl" && ok "log-event: agent_type wins over agent_name" || bad "log-event agent_type precedence"

# ---------- install.sh --tool ----------
IS="$ROOT/install.sh"
CX="$T/codexhome"; PH="$T/copilothome"
CODEX_HOME="$CX" bash "$IS" --tool codex > "$T/out" 2>&1; chk "install --tool codex exits 0" $?
[ "$(ls "$CX/agents"/*.toml 2>/dev/null | wc -l | tr -d ' ')" = 7 ] && ok "codex: 7 agent TOML files" || bad "codex: agent file count"
T1="$CX/agents/worker-sonnet.toml"
grep -qx 'name = "worker-sonnet"' "$T1" && grep -q '^description = "' "$T1" && grep -q "^developer_instructions = '''" "$T1" && grep -q "managed by SubDeck" "$T1" && ok "codex TOML: name, description, developer_instructions, marker" || bad "codex TOML keys"
grep -q '^model = ' "$T1" && bad "codex TOML must not carry a Claude model alias" || ok "codex TOML: no model key (Codex default)"
grep -qx 'sandbox_mode = "read-only"' "$CX/agents/researcher.toml" && ok "codex: researcher is read-only" || bad "codex: researcher sandbox"
grep -q sandbox_mode "$T1" && bad "codex: worker must not be read-only" || ok "codex: worker has no sandbox override"
grep -qx 'model_reasoning_effort = "high"' "$CX/agents/worker-opus.toml" && ok "codex: worker-opus gets high reasoning effort" || bad "codex: worker-opus effort"
[ "$(grep -c "'''" "$T1")" = 2 ] && [ "$(wc -l < "$T1")" -gt 20 ] && ok "codex TOML: literal string closed once, body present" || bad "codex TOML quoting"
cp "$T1" "$T/before"; CODEX_HOME="$CX" bash "$IS" --tool codex > /dev/null 2>&1; cmp -s "$T/before" "$T1" && ok "codex install is idempotent" || bad "codex idempotent"
echo 'name = "mine"' > "$CX/agents/other.toml"; echo 'name = "worker-opus"' > "$CX/agents/worker-opus.toml"
CODEX_HOME="$CX" bash "$IS" --tool codex > "$T/out" 2>&1
grep -qx 'name = "worker-opus"' "$CX/agents/worker-opus.toml" && grep -q "skip .*worker-opus.toml" "$T/out" && ok "codex: foreign file of the same name is not overwritten" || bad "codex: foreign overwrite"
CODEX_HOME="$CX" bash "$IS" --tool codex --uninstall > /dev/null 2>&1; chk "codex uninstall exits 0" $?
[ "$(ls "$CX/agents" | sort | tr '\n' ' ')" = "other.toml worker-opus.toml " ] && ok "codex uninstall removes only SubDeck files" || bad "codex uninstall residue: $(ls "$CX/agents")"

COPILOT_HOME="$PH" bash "$IS" --tool copilot > "$T/out" 2>&1; chk "install --tool copilot exits 0" $?
[ "$(ls "$PH/agents"/*.agent.md 2>/dev/null | wc -l | tr -d ' ')" = 7 ] && ok "copilot: 7 .agent.md files" || bad "copilot: agent file count"
A1="$PH/agents/researcher.agent.md"
head -1 "$A1" | grep -qx -- '---' && grep -qx 'name: researcher' "$A1" && grep -q '^description: "' "$A1" && grep -qx 'tools: \["read", "search"\]' "$A1" && ok "copilot agent: frontmatter name, description, read-only tools" || bad "copilot agent frontmatter"
grep -q '^model:' "$PH/agents/worker-sonnet.agent.md" && bad "copilot agent must drop Claude model" || ok "copilot agent: no model key"
HF="$PH/hooks/subdeck.json"
[ ! -e "$HF" ] && ok "copilot: no user hooks file by default (the plugin ships the hooks)" || bad "copilot default hooks file"
cmp -s "$A1" "$PL/.github/agents/researcher.agent.md" && ok "copilot agent is the generated plugin copy" || bad "copilot agent differs from generated copy"
COPILOT_HOME="$PH" bash "$IS" --tool copilot --hooks > /dev/null 2>&1
[ -f "$HF" ] && ! grep -q __ROOT__ "$HF" && grep -q "plugins/subdeck/scripts/run-hook.cmd" "$HF" && ok "copilot --hooks writes the hooks file with the clone path" || bad "copilot hooks file"
if command -v node >/dev/null 2>&1; then node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$HF"; chk "copilot hooks file is valid JSON" $?; fi
grep -q 'managed by SubDeck' "$A1" && ok "copilot agent carries the marker" || bad "copilot marker"
COPILOT_HOME="$PH" bash "$IS" --tool copilot --uninstall > /dev/null 2>&1
[ -z "$(find "$PH" -type f 2>/dev/null)" ] && ok "copilot uninstall removes agents and hooks file" || bad "copilot uninstall residue"
bash "$IS" --tool nope > "$T/out" 2>&1; [ $? = 2 ] && ok "unknown tool exits 2" || bad "unknown tool rc"
bash "$IS" --bogus > "$T/out" 2>&1; [ $? = 2 ] && ok "unknown flag exits 2" || bad "unknown flag rc"

# ---------- installer string escaping: backslash and quote ----------
eval "$(grep '^qesc()' "$ROOT/install.sh")"
[ "$(qesc 'a\b"c')" = 'a\\b\"c' ] && ok "install.sh qesc doubles backslashes and escapes quotes" || bad "install.sh qesc: $(qesc 'a\b"c')"

# ---------- install.ps1 -Tool (only where PowerShell exists) ----------
PSX=""; command -v powershell >/dev/null 2>&1 && PSX=powershell
if [ -n "$PSX" ]; then
  ESCDEF="$(grep '^function Esc' "$ROOT/install.ps1" | tr -d '\r')"
  got="$($PSX -NoProfile -Command "$ESCDEF; Esc 'a\b\"c'" 2>/dev/null | tr -d '\r')"
  [ "$got" = 'a\\b\"c' ] && ok "install.ps1 Esc doubles backslashes and escapes quotes" || bad "install.ps1 Esc: $got"
  PSD="$T/pscodex"; PP="$(cygpath -w "$ROOT/install.ps1" 2>/dev/null || echo "$ROOT/install.ps1")"
  PSW="$(cygpath -w "$PSD" 2>/dev/null || echo "$PSD")"
  CODEX_HOME="$PSW" $PSX -NoProfile -ExecutionPolicy Bypass -File "$PP" -Tool codex > "$T/out" 2>&1
  [ "$(ls "$PSD/agents"/*.toml 2>/dev/null | wc -l | tr -d ' ')" = 7 ] && ok "install.ps1 -Tool codex writes 7 TOML files" || bad "install.ps1 codex: $(tail -2 "$T/out")"
  grep -qx 'name = "researcher"' "$PSD/agents/researcher.toml" && grep -qx 'sandbox_mode = "read-only"' "$PSD/agents/researcher.toml" && ok "install.ps1 codex TOML keys" || bad "install.ps1 codex keys"
  CODEX_HOME="$PSW" $PSX -NoProfile -ExecutionPolicy Bypass -File "$PP" -Tool codex -Uninstall > /dev/null 2>&1
  [ -z "$(find "$PSD" -type f 2>/dev/null)" ] && ok "install.ps1 -Tool codex -Uninstall removes them" || bad "install.ps1 uninstall residue"
else echo "skip install.ps1 -Tool tests (no powershell)"; fi

if grep -q $'\r' "${BASH_SOURCE[0]}" "$PL/hooks/codex-hooks.json" "$PL/hooks/copilot-hooks.json" "$ROOT/.codex-plugin/plugin.json" "$ROOT/.agents/plugins/marketplace.json"; then bad "CRLF in new files"; else ok "new files LF"; fi
echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
