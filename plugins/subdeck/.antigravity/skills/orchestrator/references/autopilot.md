# Autopilot (opt-in)

Open this file only when `autopilot.enabled` is on for the project.

Autopilot (`autopilot.sh`, off by default, enabled per project with `autopilot.enabled=on`) works the task queue unattended on its own branch: it launches workers and verifiers within the configured limits, integrates verified work into the autopilot branch and writes a daily digest. A headless manager turn reads the rules in `scripts/autopilot-prompt.md` and acts only through `tasks.sh` and `autopilot.sh launch`.

When autopilot is enabled in a project, cooperate with it:

- Give every task a `Done when` line; without one autopilot will not start it.
- Do not launch the same task yourself while autopilot has it queued or running; check `autopilot.sh status` first.
- Tasks that need the user get a `tasks.sh ask`; autopilot never answers them.
- Starting or stopping autopilot, merging its branch and every push still need the user's explicit yes.
