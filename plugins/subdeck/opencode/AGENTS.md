# SubDeck rulebook (OpenCode)

When you delegate work to sub-agents or run a multi-part request, follow the SubDeck orchestrator rulebook:
`~/.subdeck/plugin/skills/orchestrator/SKILL.md` (read it first). Git rules there: pathspec commits only, no
attribution lines, never push without explicit user approval.
For each delegated job create a task file (`bash ~/.subdeck/plugin/scripts/tasks.sh new "<title>"`), put `Task: <id>` in the agent prompt, and have workers end with `Tested:` and `Stop:` lines. OpenCode has no sub-agent stop hook here, so the task file is not updated automatically: read the agent's reply and update it with `tasks.sh set` / `append`.
