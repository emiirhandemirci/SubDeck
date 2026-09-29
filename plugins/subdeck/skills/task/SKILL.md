---
name: task
description: Launch a SubDeck agent directly (worker-sonnet, worker-opus, researcher, verifier) with a task text or task file, without writing the delegation by hand.
argument-hint: "<agent> <task text or path to task file>"
disable-model-invocation: true
---

Launch a SubDeck agent for the user. Arguments: `$ARGUMENTS`

1. **Parse.** The first word may be an agent: `worker-sonnet` (default when absent), `worker-opus`, `researcher`, `verifier`. The rest is the task text, or a path to an existing task file.
2. **Complete the task.** It needs: task text, writable paths, done criterion. (`researcher` and `verifier` need no writable paths; say "none, read-only".) If writable paths or the done criterion are missing, ask the user once, compactly, in a single message. Do not guess them.
3. **Task file.** If the task text is longer than about 15 lines, write it first to `docs/tasks/NNNN-<slug>.md` (next free number, zero-padded to match existing files), or to the project's configured task directory if one is defined. Include: task, writable paths, read-only areas, done criterion, report format. Then point the agent at that file instead of pasting the text.
4. **Launch.** Use the Agent tool with `subagent_type: "subdeck:<agent>"`, the `model` set explicitly (`opus` for worker-opus, `sonnet` for the others), running in the background. The prompt is the task text, or "Your task is fully described in <file>; read it first, then execute it."
5. **Reply** with exactly one line: agent, task file (or "inline"), and how to watch it: `/subdeck:status`.

## Launching outside the manager window (headless)

In v0.1 the in-session launch above is the supported path. For a separate terminal, the CLI has an `--agent` flag (see `claude --help`), so this should work:

```
claude -p --agent subdeck:<agent> "<task text, or: read docs/tasks/NNNN-slug.md and execute it>"
```

The plugin-namespaced `subdeck:<agent>` form for `--agent` is not verified; if it is rejected, try the bare agent name.
