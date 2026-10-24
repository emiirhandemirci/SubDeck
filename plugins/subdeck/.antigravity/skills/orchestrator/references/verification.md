# Verification details

Open this file when you verify a non-trivial result (tiers and levels are in the core rulebook).

- Open the task file's `## Report` and `## Handoff` when you check an agent; they hold the final reply and any early notes.
- Verifier prompts carry `Task: <id>` too. The verifier first runs the scripted checks (`scripts/verify-checks.sh --base <commit> --report <file>`: test files not empty, test count not dropped, claimed commands really run, `Tested:` line present), then judges. Its evidence is typed `read`, `executed` or `live`; a runtime or behaviour claim backed only by `read` is `unsupported` and comes to you as `Escalate`. After an `Approved` verdict with a current fingerprint, run `tasks.sh done <id>`.
- Mapped runs (section 4b): read `run.sh tail <id>` and `## Report`; the verifier is a different model than the producer.
  The verifier gets the report, allowed write paths and base commit and returns a verdict `Approved | Needs fixes | Escalate`; its per-claim JSON goes to its Detail file, the reply is the verdict and the failed or uncertain claims only.
- **Verification levels (a task field, `tasks.sh new --verify`).** Pick the level when you create the task:
  - **L0**: your own narrow check only, no verifier (the small tier: one file, docs, version, packaging). `tasks.sh done` accepts an L0 task without a verdict.
  - **L1** (default): a verifier on the changed paths and their tests only (the medium tier).
  - **L2**: full verifier plus a live run, only for security, data loss or cross-component work. Raising a task to L2 needs a one-line reason (`--verify-reason`, or `verify-reason=` with `tasks.sh set`); the tool refuses L2 without it.
  - **A fix round is never higher than the previous level**: after an L2 `Needs fixes` the fix round is L1. `tasks.sh verify-level <id>` prints the level the next verification runs at.
- **Delta re-verify.** The verifier's reply ends with a machine-readable `Verified paths:` line and the fingerprint. Record it: `tasks.sh verify ... --fingerprint <fp> --level <Lx> --paths <the line>`. A re-verify brief is then built with `tasks.sh verify-delta <id>` (also appended to `tasks.sh resume-prompt <id>`): previous verdict, the paths that changed since the verified HEAD (`git diff --name-only <old HEAD>`) and the unchanged paths, which the verifier carries as "previously verified" without re-checking.
- **Artifact reuse.** A worker that builds something expensive reports `Artifact: <path> sha256:<hex>` in its task file; the verifier tests that artifact after matching the hash and rebuilds only at L2, as a sample.
- **Acceptance is yours, not the worker's.** A worker's "done" is a claim. Before accepting, the acceptance check must be shown able to fail (negative control: run it on a known-bad or deliberately broken copy and see it fail, then see it pass on the real work). A check that cannot fail is not evidence. The verifier also runs static checks (syntax check of every touched shell/JS file, JSON parse) that catch a shipped-file break the worker's own tests missed.
- **Report freshness.** A verifier report carries `Fingerprint: HEAD=<hash> state=<cksum>` (state = `{ git rev-parse HEAD; git status --porcelain; git diff; } | cksum`). Before relying on any verifier report, take the same fingerprint (one narrow check). If HEAD or state changed, the report is stale: re-verify only the claims on paths that changed since (`git diff --name-only <old HEAD>`), not everything. Parallel agents make this routine, not rare.
- **Protected files.** A worker must not edit tests, validators or acceptance scripts to make a failing check pass unless the task says so. If a diff touches the check itself, the verifier flags it (`review`) and the negative control is rerun against the original check.
- `Needs fixes`: send the findings back to the same agent. `Escalate`: relay to the user.
- If a commit contains an attribution line, have the owning agent fix its own unpushed commit.
