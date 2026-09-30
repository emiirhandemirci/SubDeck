# SubDeck Desk

A local, read-only web dashboard that shows what your AI coding agents are doing: projects, sessions, sub-agents, state, and token usage. It reads the session data that Claude Code and Cursor already write on your machine. No dependencies, no build step.

## Run

```
node desk/server.mjs [--port N] [--days N] [--open]
```

- Needs Node 20 or newer; Cursor support needs Node 22.13+ (built-in `node:sqlite`).
- Binds `127.0.0.1` only. Default port 4917, falling back to 4918-4936; `--port N` is exact (exit 1 if busy); `--port 0` picks any free port.
- `--days N` sets the retention window (1-365, default 14). `--open` opens the browser.
- A second start prints the URL of the running instance. Runtime file: `~/.subdeck/desk.json` (`pid`, `port`, `startedAt`, `version`).
- Inside Claude Code: `/subdeck:desk` (or `/subdeck:desk stop|status`), backed by `plugins/subdeck/scripts/desk.sh`.

## Data sources

| Tool | Location | Notes |
|---|---|---|
| Claude Code | `~/.claude/projects/` transcripts, plus `.subdeck/` hook events | Sub-agents are read from `subagents/`. |
| Cursor | `state.vscdb` under the Cursor user directory | Opened read-only; retried when Cursor holds a lock. |

Environment overrides: `SUBDECK_CLAUDE_PROJECTS_DIR`, `SUBDECK_CURSOR_USER_DIR`, `SUBDECK_DISABLE` (comma-separated tool names).

## Privacy

Only titles (up to 120 characters) and a short last-activity summary (up to 80 characters, never taken from prompts) are served. Message bodies, prompts, tool output, and secret fields are never read into the model, logged, or served. Requests with a foreign `Host` header are rejected (403).

## States

`running` (activity within 2 minutes, or a hook Start without Stop), `idle` (within 30 minutes), `finished` (older), `stale` (hook Start without Stop and file untouched for 5 minutes), `error`. The state source is shown per session (`field`, `hook`, or `mtime`).

## Tests

```
node --test "desk/test/*.test.mjs"
bash plugins/subdeck/tests/test-desk-launcher.sh
```

Design: `docs/superpowers/specs/2026-09-29-subdeck-desk-design.md`. Decisions: `docs/decisions/0015` to `0019`. Smoke check on real data: `docs/research/desk-smoke.md`.
