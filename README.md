# SubDeck

SubDeck is a private Claude Code plugin marketplace for running a manager session with sub-agents.
The manager delegates to worker, researcher and verifier agents and reads short reports; you get a live, IDE-independent view of what every agent is doing.
Everything is deterministic (hooks, bash, awk); the model is never called just to produce status.

## Components (`plugins/subdeck`)

- Agents: `worker-sonnet` (default), `worker-opus` (critical work only), `researcher` (read-only), `verifier` (independent checks, no commits).
- Skills: `/subdeck:orchestrator` (manager rulebook), `/subdeck:task` (launch an agent directly), `/subdeck:status` (live agent table), `/subdeck:pr` (pre-push checklist and approval gate, never pushes by itself).
- Hooks: `SubagentStart` / `SubagentStop` write events to `<project>/.subdeck/` (git-ignore it).
- Scripts: event logger, `status.sh` (bash + awk renderer), `run-hook.cmd` (Windows/POSIX launcher).
- Templates: `CLAUDE.local.md.template`, `decision.md.template`.

## Install

Local marketplace (persistent). Inside a Claude Code session:

```
/plugin marketplace add <path-to>/SubDeck
/plugin install subdeck@subdeck
/reload-plugins
```

Same from a terminal: `claude plugin marketplace add <path-to>/SubDeck` then `claude plugin install subdeck@subdeck`.

Session only, nothing installed:

```
claude --plugin-dir <path-to>/SubDeck/plugins/subdeck
```

Check the manifests with `claude plugin validate .` (repo root) and `claude plugin validate ./plugins/subdeck`. Command forms are documented in `docs/research/plugin-manifest.md`.

## Quick start

1. In your project, copy `plugins/subdeck/templates/CLAUDE.local.md.template` to `CLAUDE.local.md` (private, git-ignored) and fill in the `{{PLACEHOLDERS}}`.
2. Start Claude Code in the project and run `/subdeck:orchestrator` (or just make a request; the skill loads on its own).
3. Launch an agent without the manager window: `/subdeck:task`.
4. Watch agents: `/subdeck:status` (add `--all` for finished agents), or from any terminal:
   `bash <path-to>/SubDeck/plugins/subdeck/scripts/status.sh --all <project>`
5. Before pushing: `/subdeck:pr` (it asks first; nothing is pushed without an explicit yes).

## Requirements

- Bash and awk on the path (Git Bash on Windows). No jq, node or python at runtime.
- Claude Code with plugin support; git.

## Status

v0.1 is implemented: agents, hooks, status renderer, four skills, templates, decision log. It was run end to end (parallel worker + researcher, then verifier, plus `/subdeck:status` and `/subdeck:pr`); see `docs/demo/v0.1-demo.md`. Remaining items and roadmap (v0.2 "SubDeck Desk" web app) are in `docs/design.md`. Decisions are in `docs/decisions/`.
