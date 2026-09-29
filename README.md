# SubDeck

A private Claude Code plugin marketplace for running a manager session with sub-agents: worker/researcher/verifier agents, an orchestrator skill, and an IDE-independent live `/status` view built on hooks.

**Status: design phase.** Nothing is implemented yet; see `docs/design.md`.

## Getting started

1. Open this folder in Cursor (or any terminal) and start a Claude Code session here.
2. The session reads `CLAUDE.md`, then `docs/design.md`.
3. Bootstrap agents live in `.claude/agents/`; the plugin itself will be built under `plugins/subdeck/`.
