# Changelog

## Unreleased

- **Task files:** new keys `auto` (hook-created tasks), `pack` (wave context pack), `grants` (writable-path extensions), `covers` (batch verification IDs). `tasks.sh verify --covers` checks a whole wave together; `done` requires the latest verdict = Approved.
- **New tasks.sh commands:** `link` (set agent + session), `verify` (write verdict + fingerprint + covers), `grant` (add path extension with reason), `pack` (write context pack from contract/decisions/file map/tasks), `writable` (list effective paths), `show --section` (read task sections).
- **Task list output:** terse default format; `--tsv` for scripts.
- **Auto-bind:** tasks without an explicit manager launch are auto-created by the hook (status in-progress, `auto: true`). "Not tracked" agents have no task.
- **Guard warnings:** new `commit-pathspec` (directory in commit args) and `commit-scope` (file outside writable paths) rules (default `warn`).
- **Light model:** new `light` setting in model policy for packaging, copying, version bumps, doc-only edits (default haiku); pass it explicitly as Agent model.
- **Metering:** `tasks_cli` events log every CLI call's byte count; `ready` watches quota resets in the last 60 minutes and warns before launch.
- **Quota events:** `quota_recent` logged by hooks and `run.sh` with reset time parsed from `reset <HH:MM>[am|pm]` or ISO timestamps; `ready` warns in stderr.
- **Report length:** logs `report_too_long` (lines > 9) but does not truncate or change task status; re-instruct the agent, not re-read.
- **Desk:** tasks board shows wave grouping (smallest pack name or covers relation), task auto/grants/covers/verdict info, agent not-tracked and long-report badges, tokens per task and wave, context packs in project info, quota banner with last 24h CLI call counts, `reportMissing` only for tracked agents.
- **Rulebook:** 12 concrete items for verifiers, agents and skills (verify-checks per wave, batch small work, context packs, guard warnings, light model, `light` key docs, control-char checks, metering, quota warning, report-length retraining).

## 0.8.0 - 2026-10-07

- **Any model, any role (opt-in):** map a role to another CLI with `roles.<role>.tool|model|args|cmd|timeout` (`claude`, `codex`, `gemini`, `agy` experimental, `opencode`, `copilot`, `custom`). New `scripts/run.sh` runs a role headlessly from its task file, in a git worktree on branch `subdeck/<task>` for workers, with a timeout, a writable-path check afterwards and a push blocker. Exit codes classify auth, quota, timeout and violations; `run.sh roles|tail|cleanup` inspect and clean up. Flags per CLI live in `scripts/run-profiles.txt`. Unmapped roles stay in-session sub-agents; without a `roles` setting nothing changes.
- **Verifier on another model:** a mapped verifier on the same `tool/model` as the task's producer is refused.
- **Results only after your yes:** `run.sh` never commits, merges or pushes; the manager integrates `subdeck/<task>` only after your explicit approval.
- **Rulebook:** new orchestrator section "Mapped roles (opt-in)"; sub-agents know they may be in a headless run (end with `Stop: waiting` and the question). Portable per-class rulebooks are generated into `scripts/roles/`.
- **Desk:** SubDeck runs appear as a source with a live log view, role/tool/model badges and a roles table in Settings.
- **Desk fixes:** no horizontal overflow and wrapped titles at 390 px width, the tab label reads "Tasks (N) !M", a hint when temporary projects are hidden, clearer settings placeholders. The Beads bridge now reads the real `bd` 1.3.0 `list --json` output (a plain array or `{issues,meta}`), shows blocking dependencies only, and runs `bd` with `BEADS_DOLT_AUTO_START=0`.
- **Docs:** new [docs/runs.md](docs/runs.md) (setup and login per CLI, privacy, honest guard coverage per tool, smoke checklist), README privacy note. Gemini CLI consumer tiers ended in June 2026: use an API key or Vertex, or `agy`.

## 0.7.0 - 2026-10-07

- **Tasks:** the manager keeps a task file per delegated job (`tasks.sh`: new, set, append, done, list, ready, show). Files live in the project's state folder by default; `tasks.dir` moves them. Hooks set the status from the agent's start, stop and failure events; `done` needs an approved verifier verdict. Desk gets a Tasks tab.
- **Report watchdog:** a worker, researcher or verifier that stops without the required `Stop:` / `Tested:` / `Verdict:` line is logged as `report_missing`, notified and shown in Desk as "stopped without report". Agents may no longer end a turn waiting on a background job. Setting `report-check`.
- **Interrupted handoff:** a usage-limit failure marks the task `interrupted` and writes the uncommitted files and a diff stat into its Handoff section (new `StopFailure` hook); nothing is committed or reverted for you.
- **"Tested how?":** worker reports need a `Tested:` line; verifier evidence is typed `read`, `executed` or `live`, and behaviour claims need executed or live evidence. New `scripts/verify-checks.sh` (empty or shrinking tests, claimed commands missing from the transcript).
- **Protected resources:** new guard rule `protected-resources` (default ask) with `protect-ports`, `protect-hosts`, `protect-procs`; plus a lock-file and leave-as-found rule in the rulebook. A guard rail on obvious command text only.
- **Missing agent types:** install output, README and the session hint now say to run `/reload-plugins` (or restart) after install or update; the manager tells you once if a `subdeck:` agent type is missing.
- **Desk, Beads bridge (opt-in):** with `SUBDECK_BEADS=1`, Desk also shows `bd list --json` items of projects that have a `.beads/` folder on the Tasks board, read-only. `bd` (or `SUBDECK_BD`) is resolved from PATH only, never from the project.
- **Desk:** a slow first scan is no longer shown as "no sessions" (sessions appear as they are found, with scan progress), and the first Claude Code scan is faster; Desk now subscribes to changes before the first scan.
- **Cursor:** sessions are found when `composerHeaders` is missing (falls back to `cursorDiskKV` and per-workspace storage); an unknown layout shows a note instead of an error.

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
