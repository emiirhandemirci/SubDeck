# SubDeck rulebook (OpenCode)

When you delegate work to sub-agents or run a multi-part request, follow the SubDeck orchestrator rulebook:
`~/.subdeck/plugin/skills/orchestrator/SKILL.md` (read it first). Git rules there: pathspec commits only, no
attribution lines, never push without explicit user approval.
For each delegated job create a task file (`bash ~/.subdeck/plugin/scripts/tasks.sh new "<title>"`), put `Task: <id>` in the agent prompt, and have workers end with `Tested:` and `Stop:` lines. OpenCode has no sub-agent stop hook here, so the task file is not updated automatically: read the agent's reply and update it with `tasks.sh set` / `append`.
Mapped roles (opt-in): if the user mapped a role to another CLI, `bash ~/.subdeck/plugin/scripts/run.sh roles` lists it and `run.sh <role> <task-id>` runs it headlessly in a worktree on branch `subdeck/<task-id>`; read `run.sh tail <task-id>` and the task Report afterwards, use a verifier on a different model, and merge the branch only after the user's explicit yes. See the orchestrator rulebook, section 4b.
