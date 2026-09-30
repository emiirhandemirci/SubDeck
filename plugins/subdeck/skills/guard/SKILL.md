---
name: guard
description: Show or change the SubDeck guard rules (deterministic PreToolUse checks for git add -A, force push, push, history rewrite, dangerous rm -rf, secret files, attribution). Deterministic script output, no analysis.
argument-hint: "[show | set rule=deny|ask|off ... [--project] | on [--project] | off [--project] | reset [--project]]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply: no insight boxes, sidebars, or extra commentary; the output is a checklist/table.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh" cli $ARGUMENTS "${CLAUDE_PROJECT_DIR}" || true
```
