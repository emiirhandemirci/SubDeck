# SubDeck User Guide

## 1. What SubDeck is

SubDeck is a manager + sub-agents toolkit for Claude Code: rules, agents and skills that let one session delegate work to worker, researcher and verifier agents. `/subdeck:status` shows the live agent table in the terminal. SubDeck Desk is a local web dashboard that shows the agents of Claude Code, Cursor and several other tools, like the Claude Code "Agent map" but outside the IDE.

## 2. Requirements

- Claude Code.
- Git Bash on Windows (the plugin scripts are bash).
- Node.js 22.13 or newer for Desk (Cursor support needs the built-in `node:sqlite`).

## 3. Install

**Permanent install from GitHub** (recommended), in a terminal:

```
claude plugin marketplace add emiirhandemirci/SubDeck && claude plugin install subdeck@subdeck
```

Or run `./install.sh` (macOS, Linux, Git Bash) / `.\install.ps1` (Windows PowerShell) from a clone; the script installs, or updates if SubDeck is already installed. Inside a Claude Code terminal session you can use `/plugin marketplace add emiirhandemirci/SubDeck` and `/plugin install subdeck@subdeck`. The VS Code extension has no `/plugin`, so use the terminal CLI; the plugin is then active in the extension too. The repo is private, so you need GitHub access. Restart Claude Code afterwards.

**Update:**

```
claude plugin marketplace update subdeck && claude plugin update subdeck@subdeck
```

**Uninstall:** `claude plugin uninstall subdeck@subdeck` (or `./install.sh --uninstall` / `.\install.ps1 -Uninstall`).

Desk is found automatically in the marketplace clone under `~/.claude/plugins/marketplaces/subdeck/`.

**For plugin development** (local checkout, nothing installed):

```
claude --plugin-dir <path-to-SubDeck>/plugins/subdeck
```

or `claude plugin marketplace add <path-to-SubDeck>` followed by `claude plugin install subdeck@subdeck`.

Add `.subdeck/` to your project's `.gitignore`; the hooks write agent events there.

## 4. Commands

| Command | What it does | Example |
|---|---|---|
| `/subdeck:orchestrator` | Loads the manager rulebook: delegate, do not do the work yourself. | `/subdeck:orchestrator` |
| `/subdeck:task` | Launches an agent (`worker-sonnet`, `worker-opus`, `researcher`, `verifier`, or the `*-current` variants) with a task text or task file. | `/subdeck:task researcher find where login errors are handled` |
| `/subdeck:status` | Prints the live table of running and recently finished sub-agents, including the real model id (MODEL column; on narrow terminals ACTIVITY is dropped first, then MODEL). `--all` shows more. | `/subdeck:status --all` |
| `/subdeck:pr` | Pre-push checklist and approval gate. It never pushes by itself. | `/subdeck:pr release notes` |
| `/subdeck:desk` | Starts Desk (or prints its URL if it is already running). | `/subdeck:desk` |
| `/subdeck:desk stop` | Stops Desk. `status` prints the URL or says it is not running. | `/subdeck:desk stop` |

## 5. SubDeck Desk

**Start.** Run `/subdeck:desk`, or from a SubDeck checkout:

```
node desk/server.mjs --open
```

Desk serves on `http://127.0.0.1:4917` by default (it falls back to 4918-4936 if that port is busy).

**Open it in VS Code.** Command Palette, then "Simple Browser: Show", then paste `http://127.0.0.1:4917` (or the URL that `/subdeck:desk` printed).

**Supported tools.** Claude Code and Cursor are supported. Codex, Copilot (CLI and VS Code Chat), Gemini CLI, Cline/Roo and OpenCode are **experimental**: they are marked "experimental" in the header, and some of their data formats are not verified on every platform. Tools that are not installed are hidden behind a collapsed "not detected" hint. Each tool has its own badge colour.

| Tool | "Running" means |
|---|---|
| Claude Code | A hook saw an agent start with no stop, or the transcript changed in the last 2 minutes. |
| Cursor | The composer is generating, or its data changed in the last 2 minutes. |
| Codex | A turn is open in the rollout file and it was updated in the last 5 minutes. |
| Copilot | CLI: an open turn while the session's lock file belongs to a live process. VS Code Chat: recent file activity. |
| Gemini CLI | The session file changed in the last 2 minutes. |
| Cline/Roo | The task is not completed and its data changed in the last 2 minutes. |
| OpenCode | An assistant message is still open and the session was updated in the last 5 minutes. |

**Three panes.**

- **Projects** (left): projects with recent sessions; filter by name, or tick "Only active".
- **Agent map** (middle): sessions and their sub-agents as a tree.
- **Detail** (right): the selected session or agent.

**State colours.**

| State | Colour | Meaning |
|---|---|---|
| 🟢 running | green | Activity in the last 2 minutes, or a hook saw a start with no stop. |
| 🟠 waiting | orange | Blocked on you: a permission prompt, a question or a plan approval. Waiting sessions sort first, and the header shows how many are waiting in total. |
| 🟡 idle | amber | Last activity within 30 minutes. |
| ⚪ finished | grey | Older, or the agent explicitly completed. |
| 🔴 failed | red | Explicit failure or an API error. |
| ⚪❔ stale | grey with `?` | A start was seen but no stop, and the file has been untouched for 5 minutes. State is uncertain. |

Each agent also shows where its state came from. "Estimated from file activity" means there was no hook or explicit status, so Desk guessed from how recently the session file changed. "From lock file" (Copilot CLI) means the session's lock file is held by a live process.

**Agent content.** Click an agent to open it. The detail pane has three sections: **Prompt** (what it was asked), **Tool calls** (tool name and target), and **Final report** (its last message).

**Flags.**

| Flag | Meaning |
|---|---|
| `--port N` | Use exactly this port (exit 1 if busy). `0` picks any free port. |
| `--days N` | Retention window in days, 1-365 (default 14). |
| `--no-content` | Disable the prompt / tool calls / final report endpoint. |
| `--open` | Open the browser after starting. |

**Stop.** `/subdeck:desk stop`.

Example view (agent detail with Prompt, Tool calls and Final report expanded; synthetic data):

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="assets/desk-agent-detail-light.png">
    <img src="assets/desk-agent-detail-dark.png" alt="Desk agent detail with prompt, tool calls and final report" width="700">
  </picture>
</p>

## 6. Using a non-Claude model (e.g. GLM)

Normally the plugin agents pin `model: sonnet` or `model: opus`. If you run Claude Code against another backend (for example GLM through an Anthropic-compatible `ANTHROPIC_BASE_URL`), those aliases may not resolve. SubDeck therefore has a **model mode**:

- `named`: the existing agents with pinned models (`worker-sonnet`, `worker-opus`, `researcher`, `verifier`).
- `current`: the inherit agents `worker-current`, `researcher-current`, `verifier-current`. They have `model: inherit`, so they run on whatever model the session uses. There is no cheap/expensive split and no opus escalation in this mode.
- `auto` (default): the manager picks `current` when its own model id is not a Claude model, when `ANTHROPIC_BASE_URL` points to a non-Anthropic host, or when a named agent fails to start because its model is unavailable; otherwise `named`. It states the chosen mode once per session.

To force a mode, put `Model mode: auto|named|current` in your project's `CLAUDE.local.md` (the template has the line). You can also launch an inherit agent directly: `/subdeck:task worker-current <task>`.

Optional: instead of using the `*-current` agents, you can remap the aliases so `sonnet` and `opus` resolve to your backend's models, with `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` (each takes a full model name), or set `CLAUDE_CODE_SUBAGENT_MODEL` for sub-agents without a model of their own. Sources: [model configuration](https://code.claude.com/docs/en/model-config) (environment variables) and [sub-agents](https://code.claude.com/docs/en/sub-agents) (`model` accepts an alias, a full model ID, or `inherit`, "use the same model as the main conversation"; resolution order).

Note: the agent prompts were tuned on Claude. Behaviour on other models is untested.

## 7. Privacy

- Local only: Desk binds `127.0.0.1` and rejects requests with a foreign `Host` header.
- Prompt, tool calls and final report are read from your local transcript only when you open an agent. They are never stored, cached or logged; tool output and thinking text are never served.
- Start with `--no-content` to turn content reading off completely.

## 8. Troubleshooting

**Desk says it is already running.** Only one instance runs at a time. Open the printed URL, or run `/subdeck:desk stop` and start again.

**`claude` not found.** Add the folder that contains the Claude Code executable to your `PATH`, then open a new terminal.

**A tool is missing in the header.** Tools that Desk cannot find are listed under "not detected". Codex, Copilot, Gemini, Cline/Roo and OpenCode read their standard data folders; if yours live elsewhere see the environment overrides in [desk/README.md](../desk/README.md). OpenCode and Codex also need Node 22.13 or newer.

**Cursor shows nothing.** Check that Node is 22.13 or newer (`node --version`) and that Cursor has been used on this machine, so its data directory exists.

**An agent looks idle but is finished.** Update to the latest SubDeck and restart Desk (`/subdeck:desk stop`, then `/subdeck:desk`). Older versions guessed completion from file activity only.

**States look wrong for projects without the plugin.** In projects where the plugin is installed, hooks record exact start and stop events. Without it, Desk falls back to session files and file activity, so states are estimates and can lag by a few minutes.

## 9. Where to learn more

- [desk/README.md](../desk/README.md) for Desk internals, data sources and environment overrides.
