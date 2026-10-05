# Changelog

## 0.6.1

- **Guard hardening:** recursive deletes through PowerShell and cmd, backtick escapes and wrapper commands that take option arguments are now caught; deny/ask messages are neutral and short.
- **Desk:** nested agents and Agent Teams are shown, a `StopFailure` is a failed agent with its reason, and the effort level is displayed.
- **macOS portability:** epoch and field-separator fixes, portable `sed`, and a safer main-script check in the shell scripts; lookups are scoped to `modelPolicy`.
- **Repository:** GitHub community files, CI, a plugin README and directory metadata; internal references removed from public files.

## 0.6.0

- **Desk Settings tab and theme:** edit every `/subdeck:settings` key in the browser (selects, switches, list chips, scope All projects / This project, confirmation before turning a guard off). New System / Light / Dark switch and visual polish.
- **Desk layout:** the page fills the window, each pane scrolls independently with thin themed scrollbars, and scroll positions survive re-renders.
- **Failure reasons:** a failed Claude Code agent shows why (API error, quota, timeout, permission, tests failed, tool error, stuck).
- **Agent commits:** commits an agent made show in Changed files ("via commit") with an on-demand read-only `git show --stat`.
- **Resumed agents:** a sub-agent resumed after a Stop is shown as running again in Desk and `/subdeck:status`.
- **State outside the repository:** events, notification log, status-line cache and project settings live in `~/.subdeck/projects/<name>-<hash>/`; nothing is written into your project, so no `.gitignore` entry is needed. A legacy `<project>/.subdeck/` is still read, never written. `SUBDECK_STATE_DIR` moves the root.
- **Settings:** a short grouped table, `/subdeck:settings help`, a `json` output for tools, validated `set` (any invalid key or value changes nothing, exit 2), `protect=` replaces the list, new `context=<tokens>` key.
- **Push guard (breaking default):** `push` now has the modes `ask|branches|off`; the default `branches` asks only for protected branches (`protect-branches`, default `main,master,release/*`), tags, `--all`/`--mirror` and merge/rebase/reset on a protected branch. Force push is always denied. The old default asked for every push.
- **Notifications:** defaults are `waiting,done`; `agent` and `idle` are opt-in; repeated notifications for one session within 10 seconds collapse into one; sub-agent stops without a type or transcript are ignored.
- **No nested managers:** all plugin agents disable the Agent tool and carry a "you are not the manager" rule. The rulebook gains contract-first coupling rules, Produces/Consumes and integration verification.
- **More tools:** install support for Cursor, Antigravity, Gemini CLI and OpenCode (generated manifests, `install.sh --tool cursor|antigravity|opencode`, a dependency-free OpenCode plugin).

## 0.5.2

- **Protected paths:** `/subdeck:settings set protect=CLAUDE.md,.github/workflows/**,*.lock` adds a guard rule (`protected-paths`, default ask) for Write/Edit/MultiEdit/apply_patch and obvious shell writes and deletes. A project list replaces the user list. Still a guard rail, not a sandbox.
- **Desk waiting list:** the "N waiting" badge opens a list of every session blocked on you, with what it waits for and how long (`GET /api/waiting`).
- **Desk changed files:** per-agent "Changed files" with red/green diffs, "also changed by" badges and a conflict strip when agents of one session touch the same file (Claude Code; shell edits are not listed).
- **`SUBDECK_HOME`:** one data root for Desk; with it set, Desk ignores `APPDATA`, `LOCALAPPDATA` and `XDG_*`. Useful for tests and sandboxes.
- **Offline installer:** `make-offline-bundle.sh` builds a zip with `install-offline.ps1` / `install-offline.sh`; Desk finds a locally installed marketplace.
- **Rulebook and agents:** verifiers must show that an acceptance check can fail and run static checks on touched files and report a fingerprint; workers end reports with a `Stop:` reason; approval of one thing is not approval of another.
- **Fixes:** quoting in the multi-tool settings helpers, a stray blank line in this changelog.
- **Docs:** new README "Limits" section, an animated "how it works" overview, updated promo video.

## 0.5.1

Copilot and Codex support. Built from the official docs; both still need a live test.

- **GitHub Copilot CLI:** installs as a plugin (`copilot plugin marketplace add emiirhandemirci/SubDeck`) with skills, agents and hooks.
- **Codex:** installs as a plugin; Codex plugins cannot bundle agents, so `./install.sh --tool codex` adds them.
- **Portable skills and agents** are generated from one source (`plugins/subdeck/scripts/build-portable.sh`), so Claude Code, Copilot and Codex stay in sync.
- **Installers:** `install.sh` / `install.ps1` take `--tool copilot|codex` (`-Tool` in PowerShell) and `--hooks`; `--uninstall` removes only what the installer wrote.
- **Still needs a live test:** Copilot picking up the plugin's agents and firing its hooks, and the Codex plugin install, on a real machine.

## 0.5.0

Breaking: the command surface shrinks from nine commands to three.

- **Three commands only:** `/subdeck:desk`, `/subdeck:status`, `/subdeck:settings`. `task` and `pr` are now manager rules (ask the manager); `models`, `notify`, `guard` and `statusline` are keys of `/subdeck:settings`. The migration table is in the [User Guide](docs/USER_GUIDE.md#4-commands).
- **Rulebook loads automatically** at session start; `/subdeck:orchestrator` still opens it by hand. It now includes the launch rules and the pre-push checklist with an explicit approval gate.
- **No Haiku by default:** workers, researchers, verifiers and Explore use Sonnet, the escalation worker uses Opus. Change any role with `/subdeck:settings`.
- **Notifications are silent and off by default.** Toggle them with the bell in Desk or `/subdeck:settings set notify=on`.
- **Desk:** phantom agents are dropped, temporary-directory projects are hidden by default, the home folder is shown as `~`, and the bell shows a per-project override.
