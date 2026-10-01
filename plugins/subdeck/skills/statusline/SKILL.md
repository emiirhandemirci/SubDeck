---
name: statusline
description: Install, show or remove the optional SubDeck status line (agent counts for the current project in the Claude Code status bar).
argument-hint: "[install | remove]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh" *), Read, Edit
---

SubDeck can show a status line such as `SubDeck ● 2 running  ◐ 1 waiting  ✕ 1 failed` (zero groups are
omitted; just `SubDeck` when nothing is active). It is optional and never installed automatically.
`SUBDECK_ASCII=1` switches to ASCII symbols, `NO_COLOR` turns colours off.

Current preview (this project, no model analysis):

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/statusline.sh" < /dev/null || true
```

User request: `$ARGUMENTS`

If the request is empty or `install`:
1. Show this snippet for `~/.claude/settings.json` and explain that it is a user-level setting:

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/plugins/marketplaces/subdeck/plugins/subdeck/scripts/statusline.sh"
}
```

   The path is stable across plugin updates. Optionally add `"refreshInterval": 5` so the counts also refresh
   while the main session is idle.
2. Read `~/.claude/settings.json` (it may not exist yet). If it already has a `statusLine`, do NOT overwrite
   it silently: offer chaining. Chaining keeps the old status line and appends its first line after ` | `: the
   new `command` becomes `SUBDECK_STATUSLINE_CHAIN='<old command>' bash ~/.claude/plugins/marketplaces/subdeck/plugins/subdeck/scripts/statusline.sh`.
3. Ask the user to confirm. Only after an explicit yes, edit `~/.claude/settings.json` yourself, preserving every
   other key, then tell the user to restart Claude Code or wait for the next status refresh.

If the request is `remove`: explain how to undo and offer to do it after confirmation. Delete the `statusLine`
key from `~/.claude/settings.json` (or, if it was chained, restore the previous command from
`SUBDECK_STATUSLINE_CHAIN`). Preserve all other keys.
