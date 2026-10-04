# Changelog

## 0.5.3

- **Desk:** transcript content is read incrementally with a bounded cache. Desk tolerates Claude Code Agent Teams, nested agents, `StopFailure` events and the `effort` field.
- **Guard:** neutral deny/ask messages; PowerShell recursive deletes and backtick escapes are caught; options of wrappers such as `sudo` and `env` are skipped when finding the real command.
- **Settings:** `models.sh` looks up values only inside the `modelPolicy` object.
- **Hooks:** `.subdeck/.gitignore` is written automatically so the folder stays out of `git status`.
- **macOS:** bash 3.2 fixes in the event logger and the status table; Desk starts when launched through a symlinked path; portable generator and plugin tests work on macOS.
- **`/subdeck:desk`:** starts on Node 20+ and warns below 22.13.
- **Docs:** README is positioned alongside Agent View and has an FAQ; new plugin README; manifest directory metadata.
- **Project:** GitHub issue templates, SECURITY, CONTRIBUTING, and CI on Linux, macOS and Windows.

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
