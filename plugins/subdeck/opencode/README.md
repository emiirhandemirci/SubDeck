# SubDeck for OpenCode

`subdeck.js` is a dependency-free OpenCode plugin. It runs the shared SubDeck bash scripts:
guard (`tool.execute.before`, deny by throwing), event log (sub-agent sessions) and desktop notifications
(`session.idle`, `permission.asked`). `commands/` holds `/subdeck-status`, `/subdeck-settings`, `/subdeck-desk`.
`AGENTS.md` is a pointer to the orchestrator rulebook. Needs bash (Git Bash on Windows). Not published to npm.
Task files (`scripts/tasks.sh`) work from the rulebook; the automatic status updates, report watchdog and interrupted handoff depend on sub-agent hooks and are not wired for OpenCode (the guard's `protected-resources` rule does apply). Restart OpenCode after installing.
