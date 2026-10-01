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

Or run `./install.sh` (macOS, Linux, Git Bash) / `.\install.ps1` (Windows PowerShell) from a clone; the script installs, or updates if SubDeck is already installed. Inside a Claude Code terminal session you can use `/plugin marketplace add emiirhandemirci/SubDeck` and `/plugin install subdeck@subdeck`. The VS Code extension has no `/plugin`, so use the terminal CLI; the plugin is then active in the extension too. Restart Claude Code afterwards.

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
| `/subdeck:models` | Shows the model policy (which model each sub-agent role runs on, and where each value comes from), or changes it with `set` / `reset`. `--project` writes to this project only. | `/subdeck:models set worker=haiku verifier=opus` |
| `/subdeck:notify` | Shows or changes desktop notifications (`on`, `off`, `test`, `sound on|off`, `events ...`). | `/subdeck:notify test` |
| `/subdeck:guard` | Shows or changes the guard rules (`set`, `on`, `off`, `reset`). | `/subdeck:guard set push=off` |
| `/subdeck:statusline` | Optional status line with live agent counts in the Claude Code status bar. `remove` explains how to undo it. | `/subdeck:statusline` |
| `/subdeck:desk` | Starts Desk (or prints its URL if it is already running). | `/subdeck:desk` |
| `/subdeck:desk stop` | Stops Desk. `status` prints the URL or says it is not running. | `/subdeck:desk stop` |

## 5. SubDeck Desk

**Start.** Run `/subdeck:desk`, or from a SubDeck checkout:

```
node desk/server.mjs --open
```

Desk serves on `http://127.0.0.1:4917` by default (it falls back to 4918-4936 if that port is busy).

**Open it in VS Code.** Command Palette, then "Simple Browser: Show", then paste `http://127.0.0.1:4917` (or the URL that `/subdeck:desk` printed).

**Supported tools.** Claude Code and Cursor are supported. Codex, Copilot (CLI and VS Code Chat), Gemini CLI, Cline/Roo and OpenCode support is newer; some of their data formats are not yet verified on every platform. Hover a tool badge in the header for details. Tools that are not installed are hidden behind a collapsed "not detected" hint. Each tool has its own badge colour.

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

**Context usage.** Each session and agent row has a thin bar: the last known context tokens divided by the model's window. Claude models are measured against their real window: Opus 4.7 and later, Sonnet 5 and later and Fable/Mythos against 1M, older models (Haiku, Sonnet 4.5 and earlier, Opus 4.5 and earlier) against 200k; a `[1m]` marker or a context above 200k also means 1M. When Desk cannot know the window (Opus or Sonnet 4.6 without a visible marker, bare aliases, unrecognised ids) and for other tools, it shows just the token count. The bar is neutral below 60%, amber from 60 to 85%, red above 85%, and the percentage is always printed. Each project shows the total tokens of its sessions and agents in the retention window. These are tokens, not cost, and the totals are approximate (per-session context can overlap across turns). Tools that report no usage show nothing.

**Paths.** Desk never shows your home directory: paths in the project list, tooltips and the session "Data" row start with `~`, and a home directory inside free text (session titles, summaries, last activity, tool-call targets, prompts, final reports) is shown as `~` too. "Copy path" still copies the full real path.

**Stop.** `/subdeck:desk stop`.

Example view (agent detail with Prompt, Tool calls and Final report expanded; synthetic data):

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="assets/desk-agent-detail-light.png">
    <img src="assets/desk-agent-detail-dark.png" alt="Desk agent detail with prompt, tool calls and final report" width="700">
  </picture>
</p>

## 6. Choosing models

SubDeck picks the model of each sub-agent role from a small policy. Defaults: workers, researchers and verifiers on Sonnet, the escalation worker on Opus, Explore on Haiku. Your own (manager) model is separate: switch it with `/model`.

Show the effective policy, with the source of each value (default, user or project) and what each alias resolves to:

```
/subdeck:models
```

Change it:

```
/subdeck:models set worker=haiku verifier=opus
/subdeck:models set worker=claude-sonnet-5-5 --project
/subdeck:models set mode=current
/subdeck:models reset [--project]
```

- Roles: `worker`, `escalation`, `researcher`, `verifier`, `explore`. `mode` is `auto` (default), `named` or `current`.
- Values: `sonnet`, `opus`, `haiku`, `fable`, `inherit` (use the session's model), or a full model id such as `claude-sonnet-5-5`. Other ids are accepted as free text for non-Claude backends.
- Files: `~/.subdeck/config.json` (all projects) and `<project>/.subdeck/config.json` (this project, wins). Both are local; do not commit them.
- Aliases follow the latest model, so `sonnet` upgrades automatically. A full id pins a version. To remap an alias, set `ANTHROPIC_DEFAULT_SONNET_MODEL` (and `_OPUS_`, `_HAIKU_`) in your Claude Code settings `env`.
- The real model id used by an agent shows in Desk and `/subdeck:status`.
- Invalid keys or values are rejected and nothing is written. If `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` is set (or an organization `availableModels` list applies), Claude Code overrides the policy and `/subdeck:models` prints a warning.

## 7. Using a non-Claude model (e.g. GLM)

Normally the plugin agents pin `model: sonnet` or `model: opus`. If you run Claude Code against another backend (for example GLM through an Anthropic-compatible `ANTHROPIC_BASE_URL`), those aliases may not resolve. SubDeck therefore has a **model mode**:

- `named`: the existing agents with pinned models (`worker-sonnet`, `worker-opus`, `researcher`, `verifier`).
- `current`: the inherit agents `worker-current`, `researcher-current`, `verifier-current`. They have `model: inherit`, so they run on whatever model the session uses. There is no cheap/expensive split and no opus escalation in this mode.
- `auto` (default): the manager picks `current` when its own model id is not a Claude model, when `ANTHROPIC_BASE_URL` points to a non-Anthropic host, or when a named agent fails to start because its model is unavailable; otherwise `named`. It states the chosen mode once per session.

To force a mode, put `Model mode: auto|named|current` in your project's `CLAUDE.local.md` (the template has the line). You can also launch an inherit agent directly: `/subdeck:task worker-current <task>`.

Optional: instead of using the `*-current` agents, you can remap the aliases so `sonnet` and `opus` resolve to your backend's models, with `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` (each takes a full model name), or set `CLAUDE_CODE_SUBAGENT_MODEL` for sub-agents without a model of their own. Sources: [model configuration](https://code.claude.com/docs/en/model-config) (environment variables) and [sub-agents](https://code.claude.com/docs/en/sub-agents) (`model` accepts an alias, a full model ID, or `inherit`, "use the same model as the main conversation"; resolution order).

Note: the agent prompts were tuned on Claude. Behaviour on other models is untested.

## 8. Notifications

SubDeck shows a local desktop notification (plus a system sound) when Claude needs your input (permission prompts, questions, idle) and when the manager finishes its turn. Sub-agent completion is available but off by default. Nothing leaves your machine; the notification shows only the project folder name and a short reason, never prompt content.

```
/subdeck:notify                       # show settings
/subdeck:notify on | off | test
/subdeck:notify sound on|off
/subdeck:notify events waiting,done,agent
```

Add `--project` to write the project config instead of the user config (project wins). Set the environment variable `SUBDECK_NOTIFY=0` to silence everything. Config: `{"notify":{"enabled":true,"sound":true,"events":["waiting","done"]}}` in `~/.subdeck/config.json` or `<project>/.subdeck/config.json`. Windows uses a toast (balloon fallback), macOS `osascript`, Linux `notify-send` if installed. On Windows, Focus Assist / Do Not Disturb can hide toasts; if `test` shows nothing, check those settings.

## 9. Guard rules

SubDeck ships a deterministic PreToolUse hook. It makes no model call and adds about 0.1 s per tool call. It checks Bash, PowerShell, Write, Edit and MultiEdit calls against these rules:

| Rule | Default | Blocks |
|---|---|---|
| `git-add-all` | deny | `git add -A/--all/-u/.`, `git commit -a` |
| `force-push` | deny | `git push --force`, `-f`, `--force-with-lease`, `+refspec` |
| `push` | ask | any other `git push` |
| `history-rewrite` | ask | `git reset --hard`, `rebase`, `filter-branch/filter-repo`, `clean -f` |
| `rm-rf-danger` | deny | recursive delete of `/`, a drive root, `~`/`$HOME`, the project root or their parents |
| `secret-files` | ask | Write/Edit of `.env*` (not `.env.example`), `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `credentials*.json` |
| `attribution` | off | `git commit` messages containing `Co-Authored-By` or "Generated with" |

- `/subdeck:guard` shows the effective rules.
- `/subdeck:guard set push=off attribution=deny [--project]`, `on`, `off` and `reset [--project]` change them. They write the `guard` key of `~/.subdeck/config.json` or `<project>/.subdeck/config.json`; the project file wins.
- `SUBDECK_GUARD=0` disables the guard for a session.
- In auto mode, "ask" acts as "deny": an auto-mode agent can never push with the default rules.
- Rule ids that SubDeck does not recognise (for example from a newer version) are kept when `set`, `on` or `off` rewrite your config, and `show` lists them as "unknown (ignored)". They have no effect; `set <unknown-id>=...` is rejected. `reset` removes the whole `guard` key.
- It is a guard rail, not a sandbox. Aliases, scripts and other interpreters can get around it.

## 10. Status line

`/subdeck:statusline` adds an optional line to the Claude Code status bar with the agent counts of the current project, for example `SubDeck ● 2 running  ◐ 1 waiting  ✕ 1 failed`. Groups with a zero count are hidden; an idle project shows just `SubDeck`. The counts use the same waiting and stale rules as `/subdeck:status`.

- **Install.** The command edits `statusLine` in `~/.claude/settings.json` only after you confirm, and keeps all other keys.
- **Chaining.** If you already have a status line, it offers to chain: your old command keeps running and its first line is appended after ` | ` (`SUBDECK_STATUSLINE_CHAIN`).
- **Environment.** `SUBDECK_ASCII=1` uses ASCII symbols, `NO_COLOR` turns colours off, `SUBDECK_STATUSLINE_TTL` sets how many seconds the counts are cached (default 3, `0` turns the cache off).
- **Remove.** `/subdeck:statusline remove` explains how to undo it: delete the `statusLine` key, or restore the chained command.
- **States.** The terminal table (`/subdeck:status`) and the status line show running, waiting, stale and done. Desk also distinguishes failed and idle, because it reads more tools.

## 11. Privacy

- Local only: Desk binds `127.0.0.1` and rejects requests with a foreign `Host` header.
- Prompt, tool calls and final report are read from your local transcript only when you open an agent. They are never stored, cached or logged; tool output and thinking text are never served.
- Start with `--no-content` to turn content reading off completely.

## 12. Troubleshooting

**Desk says it is already running.** Only one instance runs at a time. Open the printed URL, or run `/subdeck:desk stop` and start again.

**`claude` not found.** Add the folder that contains the Claude Code executable to your `PATH`, then open a new terminal.

**A tool is missing in the header.** Tools that Desk cannot find are listed under "not detected". Codex, Copilot, Gemini, Cline/Roo and OpenCode read their standard data folders; if yours live elsewhere see the environment overrides in [desk/README.md](../desk/README.md). OpenCode and Codex also need Node 22.13 or newer.

**Cursor shows nothing.** Check that Node is 22.13 or newer (`node --version`) and that Cursor has been used on this machine, so its data directory exists.

**An agent looks idle but is finished.** Update to the latest SubDeck and restart Desk (`/subdeck:desk stop`, then `/subdeck:desk`). Older versions guessed completion from file activity only.

**States look wrong for projects without the plugin.** In projects where the plugin is installed, hooks record exact start and stop events. Without it, Desk falls back to session files and file activity, so states are estimates and can lag by a few minutes.

## 13. Where to learn more

- [desk/README.md](../desk/README.md) for Desk internals, data sources and environment overrides.
