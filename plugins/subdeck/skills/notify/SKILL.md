---
name: notify
description: Show or change SubDeck desktop notifications and sound (on, off, test, sound on|off, events waiting,done,agent, --project). Deterministic script output, no analysis.
argument-hint: "[on | off | test | sound on|off | events waiting,done,agent] [--project]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply: no insight boxes, sidebars, or extra commentary; the output is a checklist/table.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" $ARGUMENTS "${CLAUDE_PROJECT_DIR}" || true
```
