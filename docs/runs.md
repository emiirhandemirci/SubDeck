# Mapped roles: run a role on another model or CLI

Since 0.8 a role can be mapped to another command-line tool. The manager then delegates that role's tasks with `run.sh` (a headless, one-shot run of that CLI) instead of launching an in-session sub-agent. Everything is opt-in: with no `roles` setting, SubDeck behaves exactly as in 0.7.

- Tools: `claude`, `codex`, `gemini`, `agy` (experimental), `opencode`, `copilot`, `custom` (your own command).
- Roles: `manager`, `worker`, `worker-heavy`, `researcher`, `verifier`, plus any name of your own (`^[a-z][a-z0-9-]{0,23}$`, for example `ui-worker`). The class decides the rules: a name starting with `verifier` is a verifier, one starting with `researcher` or `research` is a researcher, everything else is a worker. `manager` is informational only: you start that CLI yourself.
- Unmapped roles stay in-session sub-agents.

## Privacy: where your code goes

A mapped role sends the **code it reads, the task text and your protected-resource lists** to the provider of that role's tool, under that provider's terms. This is the point of the feature, and it is also the risk: map only roles and providers you are willing to share the project with. SubDeck itself sends nothing anywhere; Desk and the scripts stay local. The manager tells you once per session which providers will receive code before the first mapped run.

## Quick start

```
/subdeck:settings set roles.worker.tool=codex roles.worker.model=gpt-5-codex
/subdeck:settings set roles.verifier.tool=claude roles.verifier.model=opus
/subdeck:settings show
```

Add `--project` to keep the mapping to the current project. Check the effective mapping at any time:

```
bash plugins/subdeck/scripts/run.sh roles
```

The manager runs this once at session start. For a mapped role it creates the task file as usual, then starts `run.sh <role> <task-id>` in the background, reads `run.sh tail <task-id>` and the task's Report when it ends, and verifies the result like any other report. Desk lists these runs under "SubDeck runs" with a live log view.

### Settings keys

| Key | Meaning | Default |
|---|---|---|
| `roles.<role>.tool` | `claude codex gemini agy opencode copilot custom`; an empty value removes the whole role mapping | unset (in-session) |
| `roles.<role>.model` | passed to the CLI as is (for example `gpt-5-codex`, `sonnet`, `provider/model` for OpenCode); empty = the tool's own default | empty |
| `roles.<role>.args` | extra flags, whitespace-separated, at most 300 characters, no quotes or backslashes; write `{sp}` for a literal space inside one token | empty |
| `roles.<role>.cmd` | only with tool `custom`: the command line, must contain `{prompt_file}` | empty |
| `roles.<role>.timeout` | seconds, 60 to 86400 | 1800 |

A project's `roles.<role>` replaces the user's `roles.<role>` as a whole; the fields are never mixed across scopes. Set the tool first, then the other keys. Claude child runs get a fresh session identity (`CLAUDECODE` and `CLAUDE_CODE_SESSION_ID` are stripped from the environment). Flags that auto-approve everything or widen access are refused by **one global deny list** (`_.deny_args` in `plugins/subdeck/scripts/run-profiles.txt`, read by both `run.sh` and `settings.sh`; it is not per tool): any token containing `dangerously`, `bypassPermissions`, `yolo` or `danger-full-access`; the exact tokens `-y`, `--auto`, `--allow-all`, `--allow-all-paths`, `--allow-all-urls`, `--no-sandbox`, `--approve-for-me`, `--add-dir`, `--include-directories`, `--settings` and `--permission-mode=auto`; any `=value` form of a denied flag (for example `--add-dir=/x`); and short-flag clusters that contain a denied letter (for example `-sy`). Matching is case-insensitive. The file is the source of truth if it differs from this list.

More examples:

```
# a second worker for UI tasks on OpenCode, with a model from your provider
/subdeck:settings set roles.ui-worker.tool=opencode roles.ui-worker.model=provider/model
# research on Gemini with an API key
/subdeck:settings set roles.researcher.tool=gemini roles.researcher.model=gemini-2.5-pro
# any other CLI: the prompt file path replaces {prompt_file}
/subdeck:settings set roles.worker-heavy.tool=custom "roles.worker-heavy.cmd=mytool --in {prompt_file}"
# longer limit for one role
/subdeck:settings set roles.worker.timeout=3600
```

## Setup and login per CLI

SubDeck does not install or log in to any CLI for you. Install the tool, log in once in a normal terminal, and check that a one-line prompt works before mapping a role. `run.sh` reports a missing binary as exit 127 and a failed login as exit 6 and shows the hint below.

| Tool | Version checked | Login (one of) | Notes |
|---|---|---|---|
| `claude` | 2.1.292 | `claude` login, or `ANTHROPIC_API_KEY` | Runs `claude -p` with `--permission-mode acceptEdits --permission-prompts none`, shell allowed except `git push`. |
| `codex` | 0.160.1 | `codex login`, or `CODEX_API_KEY` | Runs `codex exec` in the `workspace-write` sandbox; the run cannot ask questions, commands outside the sandbox just fail. |
| `gemini` | 0.63.0 | `GEMINI_API_KEY`, or Vertex AI (`GOOGLE_GENAI_USE_VERTEXAI`) | See the consumer-tier note below. Edits are auto-approved, shell commands that need confirmation are denied in headless mode. |
| `agy` | not verified | Google login | **Experimental**, see below. |
| `opencode` | 1.18.35 | `opencode providers` (login) or the provider's API key variable | Model is `provider/model` (`opencode models` lists them). Restrictions below. |
| `copilot` | 1.0.92 | `copilot login`, or `COPILOT_GITHUB_TOKEN` / `GH_TOKEN` | Runs with `--allow-all-tools` (required in non-interactive mode) minus a deny list for `git push`. |
| `custom` | - | whatever your command needs | You are responsible for its safety; SubDeck adds only the worktree, the writable check and the push blocker. |

### Codex (GPT models)

Install the Codex CLI, run `codex login` (or export `CODEX_API_KEY`), then map the role. The model name is whatever your account offers. `run.sh` starts `codex exec -C <dir> -s workspace-write --json -o <file> -`, reads the final message from the `-o` file and the prompt from stdin. SubDeck never passes `--full-auto`, `--yolo` or a bypass flag.

### Gemini CLI

Map a role to `gemini` only if you authenticate with an **API key or Vertex AI**. Google ended Gemini CLI access for the consumer tiers (free, AI Pro, Ultra) in June 2026 and points those users to **Antigravity**; enterprise Code Assist accounts keep access. If you used Gemini CLI with a consumer login, use `agy` (below) or an API key instead. Whether API-key and Vertex use keeps working after the consumer change is not verified by SubDeck. Auth failure shows as exit code 41 and is reported as exit 6.

### Antigravity (`agy`), experimental

The `agy` profile is built from secondary sources only; no flag has been verified against a real install. Every run prints `warning: agy profile is experimental (flags unverified)` and is marked experimental in the run record and in Desk. Treat the first runs as a test: look at `run.sh tail`, and report or fix the profile (`plugins/subdeck/scripts/run-profiles.txt`) when a flag differs. Output format, exit codes and the transcript location are unknown, so a failed run may be classified as plain `failed`. If you cannot make it work, map the role to `custom` with your own command line.

### OpenCode

OpenCode allows shell and file edits by default and automatically rejects anything it would ask about when running headless. SubDeck therefore passes an `OPENCODE_PERMISSION` setting that allows shell and edits but denies `git push` and access outside the working directory. This is a text-pattern deny list: it does not make OpenCode a sandbox. Use `roles.<r>.args` and your own OpenCode agent configuration for anything stricter. The model must be written `provider/model`.

### Copilot CLI

Needs `copilot login` or a token in `COPILOT_GITHUB_TOKEN` or `GH_TOKEN` (in that order of precedence). Non-interactive mode requires `--allow-all-tools`, so SubDeck allows all tools and adds deny rules for `git push`. File access stays inside the working directory unless you widen it yourself. Do not set `COPILOT_ALLOW_ALL=true` in the environment of a run: it also trusts the directory's hooks and plugins.

### Claude

Uses your normal Claude Code login. This is the only tool where SubDeck's own guard hooks run inside the headless run. Use it for a role that should use a different Claude model than the session (for example a verifier on another model).

## What a run does

1. `run.sh` reads the task file and builds one prompt: the role's rulebook, the headless rules, the writable paths, your protected resources and the task text.
2. A worker gets its own git worktree at `<state>/worktrees/<task>` on branch `subdeck/<task>`, created from the project's current HEAD (uncommitted changes in your main tree are not copied; `run.sh` warns when some lie in the writable paths). Researchers and verifiers are read-only and use that worktree if it exists, otherwise the project directory.
3. The CLI runs in the foreground of `run.sh` (the manager starts `run.sh` in the background), with stdin redirected, the timeout enforced and a push blocker in place: every push URL is rewritten to an unknown scheme (`pushInsteadOf`) and a SubDeck pre-push hook is set through `core.hooksPath` for the run. That disables the repository's own git hooks inside the worker run only. A remote's `pushurl` is rewritten to an unusable scheme as well, so `--no-verify` does not help there. The exception is a `pushurl` that is a prefix of a fetch URL: only the pre-push hook guards it, and `--no-verify` bypasses it. `run.sh` warns when a remote has a separate `pushurl`. This is a guard rail, not a sandbox: a worker that edits its own environment or uses `--no-verify` can get around it. For Claude runs the in-session guard still blocks `git push` as well.
4. After the run, `run.sh` compares what changed against the writable paths. Any other path is a violation: the task is marked `blocked`, the paths are listed in the task's Report and `run.sh` exits 5. Nothing is reverted. Changes to the shared `.git` hooks, config, `info/exclude` or `info/attributes` are flagged (`git-dir`), and so are symlinks that resolve outside the worktree (`symlink-escape`). Gitignored files are only listed as warnings.
5. Task status follows the same rules as for in-session agents: `review` on a report, `blocked` on a violation or missing report, `interrupted` plus a Handoff block on a quota, auth or timeout failure.

Files per run are in `<state>/runs/<task>/`: the log, the CLI output, the prompt, the final message and a small JSON record. `run.sh tail <task>` shows the latest.

### Getting the result back

`run.sh` never commits, merges, pushes or deletes branches. A worker commits on `subdeck/<task>` in its worktree. When the work is verified, the manager shows you `git log --oneline <base>..subdeck/<task>` and asks. Only after your explicit yes does it run `git merge --ff-only subdeck/<task>` (or cherry-picks the listed commits), and then `run.sh cleanup <task>`, which removes the worktree and keeps the branch. A yes to one merge does not cover a later merge or any push.

### The verifier must be a different model

A mapped verifier whose `tool/model` equals the one recorded on the task as its producer is refused (exit 3, no override). For in-session runs the manager records the producer with `tasks.sh set <id> tool=claude model=<model>` and picks a different verifier model itself. If the producer is unknown, the run goes ahead with a warning. The comparison is by exact `tool/model` text: two names for the same model count as different.

### Exit codes of `run.sh`

| Code | Meaning | What to do |
|---|---|---|
| 0 | CLI finished | still read the Report; exit 0 is not acceptance |
| 1 | CLI failed | read `run.sh tail` |
| 2 | refused before launch (setting, unmapped role, unknown task, denied args, not a git repo for a worker) | fix the setting or use `--no-worktree` |
| 3 | verifier is the same model as the producer | map the verifier to another model |
| 4 | a run for this task is active | wait |
| 5 | writable violation | review the listed paths; the task is blocked |
| 6 | not logged in | log in (table above) |
| 7 | quota or rate limit | wait; the task has a Handoff block |
| 124 | timeout | raise `roles.<r>.timeout` or split the task |
| 127 | CLI not found on PATH | install it |
| 130 | cancelled (run.sh was interrupted) | - |

Auth and quota are recognised from the CLI's exit code and the end of its output. Those patterns are not verified for every CLI; a quota failure may show up as exit 1 until the profile is adjusted.

## What the SubDeck guard does and does not cover

| Tool | SubDeck guard hooks | The tool's own restriction | Always applied by SubDeck |
|---|---|---|---|
| `claude` | Yes: hooks run in `claude -p` | `acceptEdits`, prompts denied, `git push` denied | worktree for workers, writable-path check after the run, push blocker (`pushInsteadOf` plus a pre-push hook) |
| `codex`, `copilot` | Only if you installed SubDeck's hooks for that tool; whether they fire in a headless run is not verified | Codex: `workspace-write` sandbox. Copilot: deny list for `git push`, paths in the working directory | same |
| `gemini`, `opencode`, `agy` | None | Gemini: auto-approve edits only. OpenCode: `OPENCODE_PERMISSION` deny list. agy: accept-edits mode (not verified) | same |
| `custom` | None | None | same |

In plain words: outside Claude, nothing stops the tool from writing where it can write while it runs; SubDeck notices afterwards (writable-path check, task blocked) and the worktree keeps the damage away from your branch. The checks look at files in the git working tree and at obvious push commands; they are not a sandbox, do not see network traffic or files outside the repository, and a shell command can still reach other directories the tool is allowed to touch. The protected-resource lists are only text in the prompt for non-Claude tools. The writable check cannot detect writes through absolute paths outside the worktree in general. For anything you cannot afford to lose, or for untrusted work, run the CLI in a container or VM, or in a user account without access to it.

## Live smoke checklist (once per CLI)

Run these in a throwaway git repository before trusting a mapping.

1. `<tool> --version` works, and a one-line prompt in a normal terminal gets an answer (login is valid).
2. `bash plugins/subdeck/scripts/run.sh roles` shows the role with the tool and model you set.
3. Create a small task with one writable file and run `run.sh <role> <task> --dry-run`: check the argv and the prompt.
4. Run it for real. The task goes to `review`, `run.sh tail <task>` shows a final message with `Stop:` and `Tested:` lines, and the file was changed on `subdeck/<task>`.
5. Ask for a change outside the writable paths: the run ends with exit 5 and a blocked task.
6. Log out (or unset the key): exit 6 with the login hint. For a quota failure, note the exit code and message and adjust `run-profiles.txt` if it is not recognised.
7. Run `run.sh cleanup <task>` and confirm the worktree is gone and the branch remains.

## Limits

- Roles run one task per run; there is no streaming of questions back to you. A run that needs an answer ends with `Stop: waiting` and the question.
- Flags live in one file, `plugins/subdeck/scripts/run-profiles.txt`; CLIs change their flags between versions, so the checked versions above matter.
- On Windows the prompt of tools that take it as an argument (`opencode`, `copilot`, `agy`) is limited to 30000 bytes.
- Cursor's CLI is supported only through `custom`.
