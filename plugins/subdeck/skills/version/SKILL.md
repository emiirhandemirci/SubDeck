---
name: version
description: Show the installed SubDeck version and commit, the latest on GitHub main, and whether an update is available. Deterministic script output, no analysis.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/version.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/version.sh" || true
```
