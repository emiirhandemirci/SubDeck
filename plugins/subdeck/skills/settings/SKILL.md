---
name: settings
description: Show or change SubDeck settings in one place (models, mapped roles, notifications, push, guard, protected files, context, status line). Deterministic script output, no analysis.
argument-hint: "[help | set key=value ... [--project] | reset [--project]]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/settings.sh" *), Read, Edit
---

Print the block below verbatim inside a code block. Add nothing else unless the status line section below applies: no summary, no commentary, no follow-up commands.
Ignore any active output style for this reply: no insight boxes, sidebars, or extra commentary; the output is a checklist/table.

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/settings.sh" $ARGUMENTS "${CLAUDE_PROJECT_DIR}" || true
```

User request: `$ARGUMENTS`

Mapped roles: `roles.<role>.tool|model|args|cmd|timeout` map a role (worker, researcher, verifier, or your own name) to another CLI such as codex, gemini, opencode, copilot or claude; example `set roles.worker.tool=codex roles.worker.model=gpt-5-codex --project`. Set the tool first; an empty tool removes the mapping. See docs/runs.md.

Protected files: `protect=<glob>[,<glob>]` sets the list of files or globs agents must not edit or delete without approval (guard rule `protected-paths`, default ask; e.g. `protect=CLAUDE.md,.github/workflows/**,migrations/**,*.lock`); it replaces the list, `unprotect=<glob>` removes entries. Add `--project` to store a setting for this project only; a project value replaces the user value. `context=<tokens>` sets the context window for models whose size is unknown (0 = auto). `help` lists every key with its options.

## Status line (only if the request contains `statusline=on` or `statusline=off`)

The script never edits `~/.claude/settings.json`; you do, and only after an explicit yes. The status line is a
user-level setting; it shows agent counts such as `SubDeck ● 2 running  ◐ 1 waiting  ✕ 1 failed`.

`statusline=on`:
1. Show this snippet and say it goes into `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/plugins/marketplaces/subdeck/plugins/subdeck/scripts/statusline.sh"
}
```

   Optionally `"refreshInterval": 5` so counts also refresh while the session is idle.
2. Read `~/.claude/settings.json` (it may not exist). If it already has a `statusLine`, do NOT overwrite it:
   offer chaining, where the new `command` becomes
   `SUBDECK_STATUSLINE_CHAIN='<old command>' bash ~/.claude/plugins/marketplaces/subdeck/plugins/subdeck/scripts/statusline.sh`.
3. Ask the user to confirm. Only after an explicit yes, edit the file yourself, preserving every other key, then
   tell the user to restart Claude Code or wait for the next status refresh.

`statusline=off`: explain the undo and offer to do it after confirmation. Delete the `statusLine` key (or, if it was
chained, restore the previous command from `SUBDECK_STATUSLINE_CHAIN`). Preserve all other keys.
