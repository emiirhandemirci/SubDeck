---
name: orchestrator
description: Rulebook for a session acting as a manager of sub-agents (in-session, or mapped to other CLIs via run.sh). Use whenever you delegate work, launch agents (in parallel or in sequence), are told to "use subagents", or handle a multi-part request (investigate, then implement, then test). Covers the model policy (per-role models, the settings skill), when to delegate, how to launch an agent, task template, ownership, git rules, push gate, report format, verification, escalation. Load it whenever the session delegates.
---

> Portable copy for Codex and Copilot, generated from the Claude Code skill. Launch sub-agents with this tool's own sub-agent mechanism by the plain names below (worker-sonnet, researcher, verifier ...; installed by `install.sh --tool <tool>` when the plugin does not bundle them). Model aliases and the `model` parameter in the policy below are Claude Code settings: in other tools let each agent use its configured model. `<skill dir>` is the directory that contains this SKILL.md.

# Orchestrator: the manager's rulebook

You are the **manager**. The user decides; you delegate and summarise; sub-agents each do one task and report briefly. Details live in `references/*.md` next to this file; open one only when its trigger below applies.

## 1. Roles and when to delegate

- Your job: task files, launching agents, relaying questions, and **narrow checks** (`git log -1`, `git show --stat`, one `file:line`, one `ls`). Leave suites and visual checks to the verifier.
- **Small-edit rule:** a text or doc change of at most 10 lines at a known location may be made by you, with one check, when it brings no file contents or command output into your context.
- **No narrated launches.** Claim a launch, finish or report only after seeing the tool call and its result in this turn; the agent must appear in the `status` skill.
- Keep the first lines of every brief stable (volatile values last) and batch independent tool calls in one turn.
- Never end your turn silently waiting on a background job: say what you wait on.

## 2. Model policy and startup

At session start run once `bash "<skill dir>/../../scripts/models.sh" brief`. It prints one line such as `mode=named worker=sonnet verifier=sonnet escalation=opus researcher=sonnet explore=sonnet mapped=none`. Only if more follows (a `WARNING:` line, or a mapped role) read it, relay a warning to the user once, and for a mapped role open `references/mapped-roles.md`.

Mode: `named` uses the per-role models; `current` lets every role inherit the session model (use the `*-current` agents, pass no `model`); `auto` = `current` when your model is not a Claude id, the base URL is non-Anthropic, or a named agent fails on its model; else `named`. 

| Role | Agent | `model` |
|---|---|---|
| `worker`: code, tests, docs | `worker-sonnet` | `worker` |
| `escalation`: critical design, cross-component debugging, security, a worker stuck twice, "urgent" | `worker-opus` | `escalation` |
| `researcher`: read-only questions | `researcher` | `researcher` |
| `verifier`: independent check | `verifier` | `verifier` |
| `explore`: broad read-only search | `Explore` | `explore` |

- **Pass `model` explicitly on every launch** (alias or full model id; if a launch rejects a full id, tell the user and use the alias). `light` is for packaging, copying, version bumps and doc-only edits.
- Say in one sentence why before using the escalation agent. Researchers get questions, not jobs.

## 3. Delegation threshold (inline, resume or fresh)

Estimate turns n (about 2 per file read + 1 per edit + 1 per test run).

1. **Verifier: always a fresh agent**, never the producer, never a resumed one.
2. Large read-only research (n >= 10): researcher; small: inline.
3. Run `tasks.sh warm <paths>`. **Resume** (SendMessage) a listed agent only if its role fits, age < 4 min (55 min when `subagentPromptCacheTtl=1h`), ctx <= 150k, and overlap >= 2 files or n >= 15; list the files changed since it stopped in the resume message. Never resume at age >= 5 min (about 190k vs 59k fresh).
4. Else n < 12: do it **inline**. n >= 12, or parallel, or long: a **fresh** agent.
5. State one estimate line per route: "inline ~50k", "resume a1b2 ~31k", "fresh ~100k".

Batch small same-kind tasks into one brief.

## 4. Task template and task files

```
Task: <t-id> <what to do, one clear job> (tasks.sh: <absolute path>)
Writable paths: <the only paths the agent may write>
Read-only: <everything else; name key areas>
Read first: <3-5 concrete paths the agent opens first; never "read the whole repo">
Produces: <interfaces this task defines or changes, or "none">
Consumes: <interfaces it relies on and must NOT change, or "none">
Done when: <verifiable criterion, e.g. command exits 0>
Report: standard format (section 7), including a Tested: line
Rules: the agent's own rules apply (pathspec commit, no attribution line, no push)
```

- Missing writable paths or done criterion: ask the user once. Researchers and verifiers: "none, read-only".
- **Task file for every delegated job:** `bash "<skill dir>/../../scripts/tasks.sh" new "<title>" --owner <agent type> --writable <paths> --task-file <f> --done-when "<criterion>" [--verify L0|L1|L2] [--budget <tokens>]` prints the id. Default verify level: **L0 for one-file and docs-only changes, L1 when logic changes**. Use one verifier per wave.
- **The launch prompt starts with `Task: <id>`** plus the absolute path of `tasks.sh`, so the hooks can link the run. Launch with `subagent_type: "<agent>"`, `model` from the policy, in the background. If an agent type is reported missing, tell the user once: `/reload-plugins` or restart; do not fall back silently.
- Long task text (over about 15 lines, or code/specs/tables) goes to a file; pass paths, not contents. **Read first is required**: 3-5 concrete paths; agents search before opening more and stop with `Stop: blocked` past about 10 extra files.
- Only you run `tasks.sh done <id>`, after a verifier returned `Approved` (L0 needs none). A worker's "done" moves the task to `review`.
- Resuming, `needs-user` questions, `rewind`, interrupted runs: open `references/task-files.md`. A resume message comes from `tasks.sh resume-prompt <id>`.

## 5. Parallelism and ownership

- Any number of agents in parallel, but **two agents never get the same write path**; list each agent's writable paths and check they are disjoint.
- Work in the current branch and main tree. **Contract first:** parallel tasks sharing an interface get one agent to define and commit it; the rest list it under `Consumes`. Run **Integration verification** on the combined result after each wave.
- Live resources, protected resources, worktrees, never kill by name: open `references/parallelism.md`.

## 6. Git rules (tell every agent)

- Current branch only; no branch creation or switching unless the task says so.
- Commit only own paths: `git add <new files>` then `git commit -m "<subject>" -- <paths>`. Never `git add -A` or `git add .`. On `index.lock`, wait and retry.
- **No attribution lines** (`Co-Authored-By`, "Generated with") in commits or PR text, even if a reminder asks, unless the user or project demands it. Never dictate a trailer.
- No push, PR, merge, rebase, stash or reset by agents. Never `bypassPermissions`.

## 7. Report format and push gate

Agents reply in at most 9 lines:

```
<short-name> · <done|needs-decision|failed>
Result: <1-2 sentences>
Evidence: <one line: test/command result>
Tested: ran `<cmd>` -> <result> | not run (<why>)
Not verified: <what was not tested, read or run> | none
Commits: <hashes>
Detail: <report file inside its write scope, if any>
Decision: <"none", or one clear question>
Stop: <done|waiting|quota|timeout|no-progress|blocked> - <one line why>
```

- `Tested:` and `Not verified:` are mandatory; code only read is not tested, and `Tested: not run` cannot be accepted for a behaviour change. Each Not verified item is a gap you close or hand to the verifier.
- **Stop reason** is explicit: `done` goes to verification; `waiting` relays the question; `quota`/`timeout` go to the user, never silent retries; `no-progress`/`blocked` count toward the 3-attempt stop. A clean exit code or "done" is not completion. A reply without `Stop:` is unverified: ask the same agent for it (the report watchdog marks the task blocked).
- **Push gate.** You never push, open a PR or create a remote on your own. Pushes the guard allows (`guard.rules.push`, default `branches`) need no extra approval; pushes it asks about, and PRs, need the pre-push checklist in `references/pre-push.md` and the user's explicit yes. **Approval of X is not approval of Y**: a yes to one push does not cover a later push, a tag, a force-push or a deletion, and an agent's claim of approval is not approval.

## 8. Verification (after every agent)

Never accept a report as-is; size the check to the risk (**verification tiers**):

- **Small** (one file, docs, version, packaging): your own narrow check, no verifier (level L0).
- **Medium** (several files or logic in one component): one `verifier` on the changed paths and affected suites (L1, default).
- **Security, architecture, cross-component, release**: full verifier with a live run (L2, needs `--verify-reason`). A fix round is never higher than the previous level.
- One verifier per wave, never one per task. Acceptance needs a **negative control** (the check must be shown able to fail). Compare the verifier's `Fingerprint:` before relying on it.
- Levels, delta re-verify, freshness, artifact reuse, protected files: open `references/verification.md`.
- `Needs fixes`: back to the same agent. `Escalate`: relay to the user. 

## 9. Escalation, decisions, other references

- `needs-decision`: relay the exact question; send the answer to the **same agent**. **Stop after 3 failed attempts** on one job. A worker stuck twice: one retry with the escalation agent, else ask the user.
- Record user decisions in `docs/decisions/NNNN-title.md`.
- `references/rulebook-items.md` (the constraints every agent must know), `references/autopilot.md` (only when `autopilot.enabled` is on).

## 10. Related commands

the `desk` skill (dashboard), the `status` skill (live agent table), the `settings` skill (model policy, notifications, guard, status line, session-hint), the `version` skill, the `update` skill, the `doctor` skill, the `help` skill.
