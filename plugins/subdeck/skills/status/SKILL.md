---
name: status
description: Show the live SubDeck agent table (running and recently finished subagents, with current activity). Deterministic script output, no analysis.
argument-hint: "[--all] [project_dir]"
disable-model-invocation: true
allowed-tools: Bash(bash *status.sh*)
---

Run exactly this command with the Bash tool:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" $ARGUMENTS
```

Then print the command output verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands. If the command fails, print its error output verbatim.
