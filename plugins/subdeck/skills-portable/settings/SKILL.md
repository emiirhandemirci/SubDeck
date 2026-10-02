---
name: settings
description: "Show or change all SubDeck settings in one place (model policy, notifications, guard rules, status line). Deterministic script output, no analysis."
---

Run the command below with the shell tool and print its output verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Replace `<skill dir>` with the absolute path of the directory that contains this SKILL.md, and put the user's arguments (if any) at the end; run it from the project directory.

```bash
bash "<skill dir>/../../scripts/settings.sh" [arguments] || true
```

The status line (`statusline=on|off`) is a Claude Code feature: in this tool those keys have no effect; say so if the user asks for them.
