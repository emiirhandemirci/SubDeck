---
name: desk
description: Start, locate or stop SubDeck Desk, the local read-only dashboard of AI coding agent sessions. Prints the URL.
argument-hint: "[stop|status]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/desk.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/desk.sh" $ARGUMENTS || true
```
