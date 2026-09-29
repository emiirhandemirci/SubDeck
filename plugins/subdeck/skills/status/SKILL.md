---
name: status
description: Show the live SubDeck agent table (running and recently finished subagents, with current activity). Deterministic script output, no analysis.
argument-hint: "[--all]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply: no insight boxes, sidebars, or extra commentary; the output is a checklist/table.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" $ARGUMENTS "${CLAUDE_PROJECT_DIR}" || true
```
