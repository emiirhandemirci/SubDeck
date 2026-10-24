# Rulebook items (what every agent must know)

The agents, verifier and skills must understand these constraints:

1. **One verifier per wave.** Launch one verifier for all tasks of a wave, record its verdict once with `tasks.sh verify --covers <ids> --verdict <v> --by <agent>`, then finish with `tasks.sh done <ids>`. Fix rounds verify only the delta + affected suites; full suites and negative controls only in the first pass.
2. **Batch small work.** Docs, IDE warnings, small fixes into one task when paths do not collide. Use the `light` model for packaging, copying, version bumps, doc-only edits (pass it as Agent model); code and verification always use worker/verifier models.
3. **Reuse with context.** Follow-up messages to an agent resume its context unless it is full or the topic changed. Do not spawn a fresh agent for follow-ups.
4. **Researcher reads-only.** Researchers do pure research/planning without follow-up code; for anything else the worker reads. Pass researchers questions, not jobs.
5. **Commit explicit paths.** Every agent commits only its own paths: `git add <new files>` then `git commit -- <paths>`. Never `git add -A` or `git add .` (shared tree).
6. **Ignore stale reports.** Do not act on notifications from agents marked accepted or carrying a stale fingerprint. Ignore IDE new-diagnostics for files in running tasks' writable paths until the task ends.
7. **Check quota.** Run `tasks.sh ready` before launching and heed its quota warning; do not launch if quota will be hit in the next 60 minutes.
8. **One pack per wave.** Build a context pack per wave and point launch prompts at it instead of re-describing context (`pack <wave> --from <file>`; reference it in the prompt).
9. **Small grant.** When a worker needs a small extra path, use `grant <id> <path> --reason <text>` instead of a blocked round trip. `link` agents started without `Task:`. Auto tasks need no verify.
10. **Reply format.** Final reply max 9 lines (workers: plus `Tested:` and `Not verified:`; verifiers: plus `Verdict:` and `Not verified:`). A `report_too_long` event means re-instruct the agent, not re-read its reply.
11. **Context packs.** Agents read the context pack named in the prompt first (if present), before the task description.
12. **Writable scope.** When an agent needs a path outside writable, it ends with `Stop: blocked` naming the path; the manager grants it.
13. **Findings ledger.** Record a finding you cite with `ledger.sh add <file>:<line> "<finding>"` and run `ledger.sh check` before trusting an old one; stale entries are marked, not silently reused.
14. **Heavy cap.** At most `SUBDECK_MAX_HEAVY` (default 2, 0 = off) worker/verifier agents run at once; researchers are not counted. When the guard refuses a launch, wait for one to finish instead of retrying.
