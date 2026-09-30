# SubDeck Desk

A local, read-only web dashboard that shows what your AI coding agents are doing: projects, sessions, sub-agents, state, and token usage. It reads the session data that Claude Code, Cursor, Codex, Copilot, Gemini CLI, Cline/Roo and OpenCode already write on your machine. No dependencies, no build step.

## Run

```
node desk/server.mjs [--port N] [--days N] [--open] [--no-content]
```

- Needs Node 20 or newer; Cursor, Codex and OpenCode (SQLite) need Node 22.13+ (built-in `node:sqlite`).
- Binds `127.0.0.1` only. Default port 4917, falling back to 4918-4936; `--port N` is exact (exit 1 if busy); `--port 0` picks any free port.
- `--days N` sets the retention window (1-365, default 14). `--open` opens the browser. `--no-content` disables the agent content endpoint.
- A second start prints the URL of the running instance. Runtime file: `~/.subdeck/desk.json` (`pid`, `port`, `startedAt`, `version`).
- Inside Claude Code: `/subdeck:desk` (or `/subdeck:desk stop|status`), backed by `plugins/subdeck/scripts/desk.sh`.

## Data sources

| Tool | Location | Notes |
|---|---|---|
| Claude Code | `~/.claude/projects/` transcripts, plus `.subdeck/` hook events | Sub-agents are read from `subagents/`. The model column shows the real id from the last assistant record. |
| Cursor | `state.vscdb` under the Cursor user directory | Opened read-only; retried when Cursor holds a lock. |
| Codex (experimental) | `$CODEX_HOME` (default `~/.codex`): `state_N.sqlite` index and `sessions/` rollout files | Needs Node 22.13+. Rollout event names and sub-agent status values are unverified. |
| Copilot (experimental) | CLI: `$COPILOT_HOME/session-state` (default `~/.copilot`); VS Code Chat: `chatSessions` under the VS Code user directory | A live `inuse` lock file marks running CLI sessions (state source `lock`). VS Code Chat gives title, times and request count only. |
| Gemini CLI (experimental) | `$GEMINI_CLI_HOME/.gemini/tmp/<project>/chats/` (default `~/.gemini`) | Sub-agent parent links are inferred. |
| Cline/Roo (experimental) | `globalStorage` of the Cline and Roo extensions in VS Code family editors | Title is the first task text. Roo child tasks link to their parent. |
| OpenCode (experimental) | `$XDG_DATA_HOME/opencode` (default `~/.local/share/opencode`): `opencode.db`, older `storage/` | Needs Node 22.13+ for the database. |

Tools that are not installed are hidden in the UI header (listed under a collapsed "not detected" hint). Experimental adapters carry an `experimental` flag in `/api/sources` and an "experimental" tag in the UI.

Tool colours: Claude orange, Cursor blue, Codex teal, Copilot violet, Gemini pink, Cline/Roo yellow, OpenCode green.

Environment overrides: `SUBDECK_CLAUDE_PROJECTS_DIR`, `SUBDECK_CURSOR_USER_DIR`, `SUBDECK_GEMINI_DIR`, `SUBDECK_DISABLE` (comma-separated tool names, e.g. `codex,gemini`), plus the tools' own variables `CODEX_HOME`, `GEMINI_CLI_HOME`, `COPILOT_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `APPDATA`.

## Privacy

Lists, snapshots and live updates carry only titles (up to 120 characters), a short last-activity summary (up to 80 characters, never taken from prompts) and metadata. Opening an agent fetches its prompt, tool calls (name and target) and final report on demand from the local transcript (`GET /api/sessions/:id/content`, `no-store`, never logged or cached). Tool output, thinking text and secret fields are never served. `--no-content` turns the endpoint off. Requests with a foreign `Host` header are rejected (403).

## States

`running` (activity within 2 minutes, or a hook Start without Stop), `idle` (within 30 minutes), `finished` (older, or an explicit completion), `failed` (explicit failure or API error), `stale` (hook Start without Stop and file untouched for 5 minutes), `unknown`. `waiting` means the session or agent is blocked on you (permission prompt, question, plan approval); it is counted per project (`waitingCount`) and per source (`counts.waiting`), waiting projects sort first, and the header badge sums them. The state source is shown per session (`hook`, `field`, `lock` (Copilot CLI lock file), `mtime`, or `none`). Codex and OpenCode treat an open turn as running only while the session was updated within the 5-minute stale window.

## Context usage

Each session and agent row shows a thin context bar: the last known context tokens divided by the model's context window. Claude models use 200k; 1M is assumed only when the model id carries a  marker or the observed context already exceeds 200k (transcripts normally record the plain API id, so a 1M session below 200k is shown against 200k). Other tools' models have no known window, so only the token count is shown. Colours: under 60% neutral, 60 to 85% amber, above 85% red; the percentage is always printed and the bar is a  with a text equivalent. Projects show the summed tokens of their sessions and agents ( in : reported total, else latest context, per session). These are token counts, not cost. Sessions from tools without usage data show nothing.

## Tests

```
node --test "desk/test/*.test.mjs"
bash plugins/subdeck/tests/test-desk-launcher.sh
```

Design: see this README. Design notes, decision records 0015 to 0019 and the smoke check on real data live in `internal/` (private, maintainers only).
