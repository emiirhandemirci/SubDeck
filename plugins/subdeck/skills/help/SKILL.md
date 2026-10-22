---
name: help
description: List the SubDeck commands, the most used settings keys and where the User Guide is. Deterministic script output, no analysis.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/help.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/help.sh" || true
```
