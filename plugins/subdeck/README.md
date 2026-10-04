# SubDeck plugin

SubDeck turns a Claude Code session into a manager of parallel sub-agents. It adds an orchestrator rulebook, seven agents, four slash commands, a few local hooks, and a deterministic guard. All status output comes from bash and awk scripts; the model is never called to produce it.

## Commands

- `/subdeck:desk [stop|status]` starts, locates or stops SubDeck Desk and prints its URL.
- `/subdeck:status [--all]` prints a table of running and recently finished sub-agents.
- `/subdeck:settings` shows or changes model policy, notifications, guard rules and the optional status line.
- `/subdeck:orchestrator` is the manager's rulebook (model policy, task template, git rules, pre-push checklist, push only after explicit user approval).

## Agents

`worker-sonnet`, `worker-opus`, `researcher` (read-only: Read, Grep, Glob), `verifier`, and `worker-current`, `researcher-current`, `verifier-current`, which inherit the session model.

## Hooks

| Event | Script | What it does |
|---|---|---|
| SessionStart | inline `echo` | Adds one line of context telling Claude to load the orchestrator skill when delegating. Writes nothing. |
| SubagentStart, SubagentStop | `log-event.sh` | Appends one JSON line per event to `<project>/.subdeck/events.jsonl` (fallback: `.subdeck/events.d/`). Also creates `.subdeck/.gitignore` containing `*`, and `.subdeck/hook-errors.log` on errors. |
| Notification (permission prompt, elicitation, agent needs input) | `log-event.sh` | Same event file, so Desk and `/subdeck:status` can show an agent as waiting. |
| SubagentStop, Notification, Stop | `notify.sh` | Local desktop notification (OS native, silent). **Off by default.** Shows only the project folder name and a fixed reason. Logs attempts (time, event, method, exit code, no content) to `.subdeck/notify.log`. |
| PreToolUse (Bash, PowerShell, Write, Edit, MultiEdit) | `guard.sh` | Allows, asks or denies per the rules below. Writes nothing. |

No hook or script makes network calls or model calls. Settings live in `~/.subdeck/config.json` (user) and `<project>/.subdeck/config.json` (project, wins).

## Guard

The guard is a guard rail, not a sandbox. Default rules: `git-add-all` (deny), `force-push` (deny), `rm-rf-danger` (deny), `push` (ask), `history-rewrite` (ask), `secret-files` (ask), `protected-paths` (ask, only for globs you configure), `attribution` (off). Turn rules off with `/subdeck:settings set push=off` (or any rule id), everything with `guard=off`, or set `SUBDECK_GUARD=0`. Any internal error means "allow".

## Desk

Desk is an optional local, read-only web dashboard. It binds to `127.0.0.1` only and reads local agent session files. It needs Node.js 20+ (22.13+ for the SQLite-based tool adapters). Desk lives in the repository's `desk/` folder, outside this plugin folder. `/subdeck:desk` looks for it in this order: `$SUBDECK_DESK_DIR`, the repo checkout next to the plugin, the marketplace clone (`<claude config dir>/plugins/marketplaces/subdeck/desk`), the folder of a local-directory marketplace, then `~/.subdeck/offline/SubDeck/desk`. If none is found, clone the repository and set `SUBDECK_DESK_DIR` to its `desk/` folder. Runtime state: `~/.subdeck/desk.json` and `~/.subdeck/desk.log`.

## Privacy

No telemetry, analytics or crash reporting. Everything stays on your machine.

## Requirements

bash and awk (Git Bash on Windows). Desk additionally needs Node.js.

## Links

- Repository: https://github.com/emiirhandemirci/SubDeck
- User guide: https://github.com/emiirhandemirci/SubDeck/blob/main/docs/USER_GUIDE.md
- Security policy: https://github.com/emiirhandemirci/SubDeck/blob/main/.github/SECURITY.md
- Issues: https://github.com/emiirhandemirci/SubDeck/issues
