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
| Codex | `$CODEX_HOME` (default `~/.codex`): `state_N.sqlite` index and `sessions/` rollout files | Needs Node 22.13+. Rollout event names and sub-agent status values are unverified. |
| Copilot | CLI: `$COPILOT_HOME/session-state` (default `~/.copilot`); VS Code Chat: `chatSessions` under the VS Code user directory | A live `inuse` lock file marks running CLI sessions (state source `lock`). VS Code Chat gives title, times and request count only. |
| Gemini CLI | `$GEMINI_CLI_HOME/.gemini/tmp/<project>/chats/` (default `~/.gemini`) | Sub-agent parent links are inferred. |
| Cline/Roo | `globalStorage` of the Cline and Roo extensions in VS Code family editors | Title is the first task text. Roo child tasks link to their parent. |
| OpenCode | `$XDG_DATA_HOME/opencode` (default `~/.local/share/opencode`): `opencode.db`, older `storage/` | Needs Node 22.13+ for the database. |

Tools that are not installed are hidden in the UI header (listed under a collapsed "not detected" hint). Newer adapters (Codex, Copilot, Gemini CLI, Cline/Roo, OpenCode) carry an `experimental` flag in `/api/sources`; the UI shows no label for it, only a tooltip on the header badge ("data format not yet verified on every platform").

Tool colours: Claude orange, Cursor blue, Codex teal, Copilot violet, Gemini pink, Cline/Roo yellow, OpenCode green.

Home override: `SUBDECK_HOME` sets the single data root (default: `USERPROFILE` on Windows, `HOME` elsewhere, then the OS home). Desk reads `~/.claude`, `~/.subdeck` and every other per-user path below it, and with `SUBDECK_HOME` set it ignores the ambient `APPDATA`, `LOCALAPPDATA` and `XDG_*` variables so nothing outside it is touched. Use it for tests and sandboxes.

Environment overrides: `SUBDECK_CLAUDE_PROJECTS_DIR`, `SUBDECK_CURSOR_USER_DIR`, `SUBDECK_GEMINI_DIR`, `SUBDECK_DISABLE` (comma-separated tool names, e.g. `codex,gemini`), plus the tools' own variables `CODEX_HOME`, `GEMINI_CLI_HOME`, `COPILOT_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `APPDATA`.

## Privacy

Lists, snapshots and live updates carry only titles (up to 120 characters), a short last-activity summary (up to 80 characters, never taken from prompts) and metadata. Opening an agent fetches its prompt, tool calls (name and target) and final report on demand from the local transcript (`GET /api/sessions/:id/content`, `no-store`, never logged or cached). Tool output, thinking text and secret fields are never served. `--no-content` turns the endpoint off. Requests with a foreign `Host` header are rejected (403).

## States

`running` (activity within 2 minutes, or a hook Start without Stop), `idle` (within 30 minutes), `finished` (older, or an explicit completion), `failed` (explicit failure or API error), `stale` (hook Start without Stop and file untouched for 5 minutes), `unknown`. `waiting` means the session or agent is blocked on you (permission prompt, question, plan approval); it is counted per project (`waitingCount`) and per source (`counts.waiting`), waiting projects sort first, and the header badge sums them. The state source is shown per session (`hook`, `field`, `lock` (Copilot CLI lock file), `mtime`, or `none`). Codex and OpenCode treat an open turn as running only while the session was updated within the 5-minute stale window.

The header "N waiting" badge is a button: it opens a compact list of every waiting session and agent across all projects and tools (tool, project, title, what it waits for, how long). Selecting an entry jumps to that project and agent; Esc closes the list. The list is served by `GET /api/waiting` (titles and metadata only, never prompt content).

Changed files (Claude Code): the agent detail has a collapsed "Changed files" section built from the agent's Write, Edit, MultiEdit and NotebookEdit tool calls (failed calls are dropped). Click a file for a red/green diff of the old and new text of each edit (no line numbers; a Write shows its full new content). Files touched by two or more agents of the same session are badged "also changed by <agent>" and listed in a strip at the top of the detail. Edits made through shell commands are not listed. Served on demand by `GET /api/sessions/:id/changes` and `GET /api/sessions/:id/changes/file?path=` (`no-store`, never logged or cached, long text cut with a "truncated" marker, secret-looking files such as .env and keys are listed but their contents withheld); `--no-content` turns both off. The waiting list shows the exact reason (permission, question, plan approval) when the data says which.

## Context usage

Each session and agent row shows a thin context bar: the last known context tokens divided by the model's context window. The window comes from the model id: 1M for a `[1m]` marker, Fable/Mythos, Sonnet 5 and later, Opus 4.7 and later, or an observed context above 200k; 200k for Haiku and for Sonnet/Opus 4.5 and earlier. When the window is unknown (Opus or Sonnet 4.6, whose `[1m]` suffix is stripped from transcripts, bare aliases such as `opus`, unrecognised Claude ids) and for other tools' models, only the token count is shown, with no percentage. Colours: under 60% neutral, 60 to 85% amber, above 85% red; the percentage is always printed and the bar is a `role=meter` with a text equivalent. Projects show the summed tokens of their sessions and agents (`tokenTotal` in `/api/projects`: reported total, else latest context, per session). These are token counts, not cost. Sessions from tools without usage data show nothing.

## Tests

```
node --test "desk/test/*.test.mjs"
bash plugins/subdeck/tests/test-desk-launcher.sh
```

Design: see this README.
