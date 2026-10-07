# SubDeck plugin

SubDeck turns a Claude Code session into a manager of parallel sub-agents. It adds an orchestrator rulebook, seven agents, three slash commands, task files, a few local hooks, and a deterministic guard. All status output comes from bash and awk scripts; the model is never called to produce it.

## Commands

- `/subdeck:desk [stop|status]` starts, locates or stops SubDeck Desk and prints its URL.
- `/subdeck:status [--all]` prints a table of running and recently finished sub-agents.
- `/subdeck:settings` shows or changes model policy, notifications, push and guard rules, context size and the optional status line (`help` lists every key, `set key=value`, `reset`, `--project`).

These three are the whole command surface. The manager's rulebook (model policy, task template, git rules, pre-push checklist, push only after explicit user approval) loads on its own when a session delegates, and `/subdeck:orchestrator` opens it by hand. Launching agents and pushing go through the manager.

## Agents

`worker-sonnet`, `worker-opus`, `researcher` (read-only: Read, Grep, Glob), `verifier`, and `worker-current`, `researcher-current`, `verifier-current`, which inherit the session model.

## Hooks

| Event | Script | What it does |
|---|---|---|
| SessionStart | inline `echo` | Adds one line of context telling Claude to load the orchestrator skill when delegating. Writes nothing. |
| SubagentStart, SubagentStop, StopFailure | `log-event.sh` | Appends one JSON line per event to `events.jsonl` in the project's state folder (fallback: `events.d/`), and `hook-errors.log` on errors. It then calls `tasks.sh hook <event>`, which updates the task file (see Tasks); `SUBDECK_TASKS=0` skips that. |
| Notification (permission prompt, elicitation, agent needs input) | `log-event.sh` | Same event file, so Desk and `/subdeck:status` can show an agent as waiting. |
| SubagentStop, Notification, Stop | `notify.sh` | Local desktop notification (OS native, silent). **Off by default**; when on, it defaults to the waiting and done events (agent and idle are opt-in). Shows only the project folder name and a fixed reason. Logs attempts (time, event, method, exit code, no content) to `notify.log` in the state folder. |
| PreToolUse (Bash, PowerShell, Write, Edit, MultiEdit) | `guard.sh` | Allows, asks or denies per the rules below. Writes nothing. |

No hook or script makes network calls or model calls. Nothing is written into your project: per-project state (events, notification log, status-line cache, project settings) lives in `~/.subdeck/projects/<name>-<hash>/`. Older versions wrote `<project>/.subdeck/`; that folder is still read but never written or deleted. Settings live in `~/.subdeck/config.json` (user) and the project's `config.json` in the state folder (project, wins). `SUBDECK_HOME` moves `~/.subdeck`.

## Tasks

`scripts/tasks.sh` keeps one Markdown file per delegated job, by default in `<state folder>/tasks/` (`tasks.dir` in the config moves it; archive of done tasks in `archive/`). Commands: `new`, `set`, `append`, `list`, `ready`, `show`, `link`, `verify`, `grant`, `pack`, `writable`, `done`. The manager puts `Task: <id>` in the agent's prompt; the hooks find it and set the status (`open`, `in-progress`, `blocked`, `interrupted`, `review`, `done`). The hook checks the report shape (`Stop:` and `Tested:` for workers, `Stop:` for researchers, `Verdict:` for verifiers); a missing line logs `report_missing` and notifies (off by default; agents with no task are "not tracked"). A usage-limit failure writes a handoff note (uncommitted files, diff stat) into the task. `done` needs `Verdict: Approved` in the task's Verification section. New features: `auto: true` tasks are created by the hook when an agent starts without `Task:`; `pack` builds context packs for waves; `link` sets the agent after launch; `verify --covers` verifies multiple tasks together; `grant` adds a path extension; `writable` lists effective paths. `scripts/verify-checks.sh` gives the verifier deterministic checks. Settings keys: `tasks.dir`, `report-check`, `tasks.autoBind`.

After installing or updating the plugin run `/reload-plugins` (or restart the tool); until then new agent types may be reported missing.

## Guard

The guard is a guard rail, not a sandbox. Default rules: `git-add-all` (deny), `force-push` (deny, in every mode), `rm-rf-danger` (deny), `push` (`branches`), `history-rewrite` (ask), `secret-files` (ask), `protected-paths` (ask, only for globs you configure), `protected-resources` (ask, only for ports, hosts and process names you configure with `protect-ports`, `protect-hosts`, `protect-procs`; it sees obvious command text only, not variables, scripts, config files or a plain `kill <pid>`), `commit-pathspec` (warn, directory names in commit args), `commit-scope` (warn, files outside a task's writable paths), `attribution` (off), `control-chars` (fail, bytes 0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F in committed lines).

Push modes (`/subdeck:settings set push=ask|branches|off`): `branches` (default) lets pushes to feature branches through and asks for protected branches (default `main`, `master`, `release/*`, change with `protect-branches=...`), tags, `--all` / `--mirror`, and merge/rebase/reset while on a protected branch; `ask` asks for every push; `off` allows pushes. Turn any rule off with `/subdeck:settings set <rule id>=off`, everything with `guard=off`, or set `SUBDECK_GUARD=0`. Any internal error means "allow".

## Desk

Desk is an optional local, read-only web dashboard. It binds to `127.0.0.1` only and reads local agent session files. It needs Node.js 22.13 or newer (Node 20 can start it, but the SQLite-based tool adapters need 22.13+). It shows sessions from Claude Code and, with some data formats not yet verified on every platform, Codex, Copilot, Gemini CLI, Cline/Roo, Cursor and OpenCode. Desk lives in the repository's `desk/` folder, outside this plugin folder. `/subdeck:desk` looks for it in this order: `$SUBDECK_DESK_DIR`, the repo checkout next to the plugin, the marketplace clone (`<claude config dir>/plugins/marketplaces/subdeck/desk`), the folder of a local-directory marketplace, then `~/.subdeck/offline/SubDeck/desk`. If none is found, clone the repository and set `SUBDECK_DESK_DIR` to its `desk/` folder. Runtime state: `~/.subdeck/desk.json` and `~/.subdeck/desk.log`.

## Other tools

The same rulebook, skills and agents are generated for Copilot, Codex, Cursor, Antigravity, Gemini CLI and OpenCode (`skills-portable/`, `.github/`, `opencode/`). They get fewer hooks than Claude Code; see the user guide for what works per tool.

## Privacy

No telemetry, analytics or crash reporting. Everything stays on your machine.

## Requirements

bash and awk (Git Bash on Windows). Desk additionally needs Node.js.

## Links

- Repository: https://github.com/emiirhandemirci/SubDeck
- User guide: https://github.com/emiirhandemirci/SubDeck/blob/main/docs/USER_GUIDE.md
- Security policy: https://github.com/emiirhandemirci/SubDeck/blob/main/.github/SECURITY.md
- Issues: https://github.com/emiirhandemirci/SubDeck/issues
