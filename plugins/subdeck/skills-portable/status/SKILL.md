---
name: status
description: "Show the live SubDeck agent table (running and recently finished subagents, with current activity). Deterministic script output, no analysis."
---

Run the command below with the shell tool and print its output verbatim inside a code block. Add nothing else: no summary, no commentary, no follow-up commands.
Replace `<skill dir>` with the absolute path of the directory that contains this SKILL.md, and put the user's arguments (if any) at the end; run it from the project directory.

```bash
bash "<skill dir>/../../scripts/status.sh" [arguments] || true
```
