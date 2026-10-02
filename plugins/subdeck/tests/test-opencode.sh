#!/usr/bin/env bash
# Usage: bash plugins/subdeck/tests/test-opencode.sh   (temp HOME and project only; JS tests need node, else skipped)
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUG="$HERE/../opencode/subdeck.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

[ -f "$PLUG" ] && ok "plugin file present" || bad "plugin file present"
for c in status settings desk; do [ -f "$HERE/../opencode/commands/subdeck-$c.md" ] && ok "command subdeck-$c" || bad "command subdeck-$c"; done
[ -f "$HERE/../opencode/AGENTS.md" ] && ok "AGENTS.md pointer" || bad "AGENTS.md pointer"
grep -q "git add" "$PLUG" 2>/dev/null && bad "plugin has no git logic" || ok "plugin has no git logic"
[ "$(grep -c '^export ' "$PLUG")" = 1 ] && ok "exactly one export" || bad "exactly one export"

if ! command -v node >/dev/null 2>&1; then echo "skip JS behaviour tests (node not installed)"; echo "passed=$PASS failed=$FAIL"; [ $FAIL -eq 0 ]; exit; fi

H="$(mktemp -d)"; P="$(mktemp -d)"; P="$(cd "$P" && { pwd -W 2>/dev/null || pwd; })"; PLUGW="$(cd "$HERE/../opencode" && { pwd -W 2>/dev/null || pwd; })/subdeck.js"
# per-project state root outside the project; Windows form so node and any bash agree, never the real home
SD="$(mktemp -d)"; SD="$(cd "$SD" && { pwd -W 2>/dev/null || pwd; })"; export SUBDECK_STATE_DIR="$SD"; unset SUBDECK_HOME
cat > "$P/t.mjs" <<JS
import { SubDeckPlugin } from "file:///$PLUGW"
const h = await SubDeckPlugin({ directory: process.argv[2] })
const res = []
async function before(tool, args) { try { await h["tool.execute.before"]({ tool, sessionID: "s", callID: "c" }, { args }); return "allow" } catch (e) { return "deny:" + e.message } }
res.push(["bash-rm", await before("bash", { command: "rm -rf /" })])
res.push(["bash-add-all", await before("bash", { command: "git add -A" })])
res.push(["bash-push", await before("bash", { command: "git push origin main" })])
res.push(["bash-ls", await before("bash", { command: "ls" })])
res.push(["write-env", await before("write", { filePath: process.argv[2] + "/.env", content: "x" })])
res.push(["write-ok", await before("write", { filePath: process.argv[2] + "/a.txt", content: "x" })])
res.push(["read-tool", await before("read", { filePath: "/etc/passwd" })])
await h.event({ event: { type: "session.created", properties: { info: { id: "child1", parentID: "root", agent: "worker" } } } })
await h.event({ event: { type: "session.idle", properties: { sessionID: "child1" } } })
await h.event({ event: { type: "session.idle", properties: { sessionID: "root" } } })
await h.event({ event: { type: "permission.asked", properties: { sessionID: "root" } } })
for (const [k, v] of res) console.log(k + "=" + v)
JS
OUT="$(HOME="$H" SUBDECK_NOTIFY_DRYRUN=1 node "$P/t.mjs" "$P" 2>&1)"
chk() { printf '%s\n' "$OUT" | grep -Eq -- "$2" && ok "$1" || { bad "$1"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }; }
chk "rm -rf / denied"          '^bash-rm=deny:SubDeck guard \(rm-rf-danger\)'
chk "git add -A denied"        '^bash-add-all=deny:SubDeck guard \(git-add-all\)'
chk "push becomes ask-first"   '^bash-push=deny:Ask the user for approval first'
chk "ls allowed"               '^bash-ls=allow$'
chk "write .env asks first"    '^write-env=deny:Ask the user'
chk "write normal file allowed" '^write-ok=allow$'
chk "unguarded tool allowed"   '^read-tool=allow$'
EV="$(. "$HERE/../scripts/lib-paths.sh"; sd_state_dir "$P"; printf '%s' "$SD_STATE")/events.jsonl"   # state dir outside the project
[ ! -e "$P/.subdeck" ] && ok "nothing written into the project" || bad "project .subdeck written"
[ -f "$EV" ] && grep -q '"event":"SubagentStart".*"agent_id":"child1"' "$EV" && ok "SubagentStart logged" || bad "SubagentStart logged"
[ -f "$EV" ] && grep -q '"event":"SubagentStop".*"agent_id":"child1"' "$EV" && ok "SubagentStop logged" || bad "SubagentStop logged"
[ "$(grep -c . "$EV" 2>/dev/null)" = 2 ] && ok "root session idle not logged as sub-agent" || bad "event count"
SUBDECK_PLUGIN_ROOT=/nonexistent HOME="$H" node "$P/t.mjs" "$P" >/dev/null 2>&1 && ok "runs without crashing" || bad "runs without crashing"
rm -rf "$H" "$P" "$SD"
echo "passed=$PASS failed=$FAIL"; [ $FAIL -eq 0 ]
