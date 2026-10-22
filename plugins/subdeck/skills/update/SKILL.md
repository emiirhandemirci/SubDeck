---
name: update
description: Update the SubDeck plugin from its marketplace (only subdeck@subdeck) and show the version before and after. Deterministic script output, no analysis.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/update.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/update.sh" || true
```
