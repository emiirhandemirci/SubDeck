---
name: models
description: Show, set or reset the SubDeck model policy (which model each sub-agent role uses: worker, escalation, researcher, verifier, explore). Deterministic script output, no analysis.
argument-hint: "[show | set key=value ... [--project] | reset [--project]]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/models.sh" *)
---

Print the block below verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply: no insight boxes, sidebars, or extra commentary; the output is a checklist/table.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/models.sh" $ARGUMENTS "${CLAUDE_PROJECT_DIR}" || true
```
