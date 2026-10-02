# Changelog

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
