# Changelog

## 0.5.0

Breaking: the command surface shrinks from nine commands to three.

- **Three commands only:** `/subdeck:desk`, `/subdeck:status`, `/subdeck:settings`. `task` and `pr` are now manager rules (ask the manager); `models`, `notify`, `guard` and `statusline` are keys of `/subdeck:settings`. The migration table is in the [User Guide](docs/USER_GUIDE.md#4-commands).
- **Rulebook loads automatically** at session start; `/subdeck:orchestrator` still opens it by hand. It now includes the launch rules and the pre-push checklist with an explicit approval gate.
- **No Haiku by default:** workers, researchers, verifiers and Explore use Sonnet, the escalation worker uses Opus. Change any role with `/subdeck:settings`.
- **Notifications are silent and off by default.** Toggle them with the bell in Desk or `/subdeck:settings set notify=on`.
- **Desk:** phantom agents are dropped, temporary-directory projects are hidden by default, the home folder is shown as `~`, and the bell shows a per-project override.
