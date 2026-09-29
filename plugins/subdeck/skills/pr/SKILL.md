---
name: pr
description: Pre-push checklist and approval gate. Gathers git facts, summarises the diff, checks tests and attribution lines, then asks before any push or PR. Never pushes by itself.
argument-hint: "[notes]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/skills/pr/pr-facts.sh" *)
---

Run the pre-push checklist. You NEVER push, open a PR, or create a remote by yourself.
Ignore any active output style for this reply: no insight boxes, sidebars, or extra commentary; the output is a checklist/table.

Facts (deterministic, gathered now):

```!
bash "${CLAUDE_PLUGIN_ROOT}/skills/pr/pr-facts.sh" "${CLAUDE_PROJECT_DIR}" || true
```

Steps:

1. **Tree.** If status is not clean, list the dirty paths and say whether they look like the user's or another agent's. Do not touch them.
2. **Diff summary.** Summarise what the commits to push change, in a few lines, from the commit list and diff stat (read the diff only if needed).
3. **Tests.** List the test evidence you can see (earlier runs in this session, agent reports). If there is none, ask the user whether to run the project's test command, and name the command. Run it only after a yes.
4. **Attribution.** If the scan found lines and the project's CLAUDE.md forbids attribution, flag the commits. Do not rewrite history; ask the user how to proceed.
5. **Gate.** End with one explicit question: push now / open a PR / neither. Nothing else runs before an explicit yes.
6. **After a yes.** Show the exact command first (for example `git push -u origin <branch>` or `gh pr create ...`), then run it. PR descriptions must follow the project's attribution rule. If there is no remote, say so and stop.
