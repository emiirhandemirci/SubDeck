---
name: doctor
description: Check the SubDeck installation (plugin, hooks, agents, Node, state folder, Desk, model policy, version) with a fix hint per item. Deterministic script output, no analysis.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" || true
```
