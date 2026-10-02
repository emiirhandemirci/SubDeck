// SubDeck plugin for OpenCode (dependency-free, plain JS: OpenCode loads .js/.ts plugins with Bun).
// Bridges OpenCode plugin hooks to the same bash scripts the other tools use:
//   tool.execute.before  -> scripts/guard.sh      (deny by throwing; "ask" is turned into a deny that tells the
//                                                  model to ask the user first, like the Codex mapping)
//   session.created/idle -> scripts/log-event.sh  (sub-agent = session with a parentID) and scripts/notify.sh
//   permission.asked     -> scripts/notify.sh hook waiting
// Plugin root (where scripts/ lives): $SUBDECK_PLUGIN_ROOT, else the parent of this file's directory
// (in-repo layout), else ~/.subdeck/plugin. Every failure is swallowed except an intentional guard deny.
// Only ONE export on purpose: OpenCode calls every export of a plugin file as a plugin.
import { spawn } from "node:child_process"
import { existsSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { homedir } from "node:os"

function pluginRoot() {
  const env = process.env.SUBDECK_PLUGIN_ROOT
  const cands = []
  if (env) cands.push(env)
  try { cands.push(resolve(dirname(fileURLToPath(import.meta.url)), "..")) } catch {}
  cands.push(join(homedir(), ".subdeck", "plugin"))
  for (const c of cands) if (existsSync(join(c, "scripts", "guard.sh"))) return c
  return ""
}

function bashPath() {
  if (process.platform === "win32") {
    for (const p of ["C:\Program Files\Git\bin\bash.exe", "C:\Program Files (x86)\Git\bin\bash.exe"])
      if (existsSync(p)) return p
  }
  return "bash"
}

// Run scripts/<name>.sh with args, payload on stdin; resolves { code, out }; never rejects.
function runScript(root, dir, name, args, payload) {
  return new Promise((done) => {
    let out = "", settled = false
    const fin = (code) => { if (!settled) { settled = true; clearTimeout(timer); done({ code, out }) } }
    let child
    try {
      child = spawn(bashPath(), [join(root, "scripts", name + ".sh"), ...args], {
        cwd: dir,
        env: { ...process.env, SUBDECK_TOOL: "opencode", CLAUDE_PROJECT_DIR: dir },
        stdio: ["pipe", "pipe", "ignore"],
        windowsHide: true,
      })
    } catch { return done({ code: -1, out: "" }) }
    const timer = setTimeout(() => { try { child.kill() } catch {} fin(-1) }, 10000)
    child.stdout.on("data", (d) => { out += d })
    child.on("error", () => fin(-1))
    child.on("close", (c) => fin(c))
    try { child.stdin.on("error", () => {}); child.stdin.end(JSON.stringify(payload)) } catch {}
  })
}

// OpenCode tool + args -> the Claude-shaped tool_name/tool_input guard.sh understands, or null (not guarded).
function normalise(tool, args) {
  const a = args || {}
  const fp = a.filePath || a.file_path || a.path || ""
  switch (String(tool).toLowerCase()) {
    case "bash": return { tool_name: "Bash", tool_input: { command: a.command || "" } }
    case "edit": return { tool_name: "Edit", tool_input: { file_path: fp } }
    case "multiedit": return { tool_name: "MultiEdit", tool_input: { file_path: fp } }
    case "write": return { tool_name: "Write", tool_input: { file_path: fp } }
    case "patch": case "apply_patch":
      return { tool_name: "apply_patch", tool_input: { command: a.patchText || a.input || a.command || "" } }
    default: return null
  }
}

function decisionOf(out) {
  const m = /"permissionDecision"\s*:\s*"(deny|ask)"/.exec(out || "")
  if (!m) return null
  const r = /"permissionDecisionReason"\s*:\s*"((?:[^"\\]|\\.)*)"/.exec(out)
  let reason = r ? r[1] : "blocked by SubDeck guard"
  try { reason = JSON.parse('"' + reason + '"') } catch {}
  return { decision: m[1], reason }
}

export const SubDeckPlugin = async (ctx = {}) => {
  const dir = ctx.directory || ctx.worktree || process.cwd()
  const root = pluginRoot()
  const children = new Set() // ids of sub-agent sessions (sessions with a parent)
  const run = (name, args, payload) => (root ? runScript(root, dir, name, args, payload) : Promise.resolve({ code: -1, out: "" }))
  const base = (ev, extra) => ({ hook_event_name: ev, cwd: dir, ...extra })

  return {
    "tool.execute.before": async (input, output) => {
      if (!root) return
      const n = normalise(input && input.tool, output && output.args)
      if (!n) return
      const r = await run("guard", [], base("PreToolUse", { session_id: (input && input.sessionID) || "", ...n }))
      const d = decisionOf(r.out)
      if (!d) return
      throw new Error(d.decision === "ask"
        ? "Ask the user for approval first; retry only if they approve. " + d.reason
        : d.reason)
    },

    event: async ({ event }) => {
      try {
        const type = event && event.type
        const p = (event && event.properties) || {}
        if (type === "session.created") {
          const info = p.info || {}
          if (info.parentID) {
            children.add(info.id)
            await run("log-event", ["SubagentStart"], base("SubagentStart", {
              session_id: info.parentID, agent_id: info.id || "", agent_type: info.agent || "subagent" }))
          }
        } else if (type === "session.idle") {
          const sid = p.sessionID || ""
          if (children.has(sid)) {
            children.delete(sid)
            await run("log-event", ["SubagentStop"], base("SubagentStop", { session_id: sid, agent_id: sid, agent_type: "subagent" }))
            await run("notify", ["hook", "agent"], base("SubagentStop", { session_id: sid }))
          } else {
            await run("notify", ["hook", "done"], base("Stop", { session_id: sid }))
          }
        } else if (type === "permission.asked" || type === "permission.updated") {
          await run("notify", ["hook", "waiting"], base("Notification", { session_id: p.sessionID || "", notification_type: "permission_prompt" }))
        }
      } catch {}
    },
  }
}
