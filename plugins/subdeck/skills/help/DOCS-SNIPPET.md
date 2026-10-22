# Proposed doc lines (for the manager to merge; not applied)

## README.md / docs/USER_GUIDE.md, commands list
- `/subdeck:version`: installed plugin version and commit, latest on GitHub main, one verdict line (up to date / N.N.N available / same version but newer commit on main). The marketplace is the repo itself, so an update always brings the current main commit even when the version string is unchanged.
- `/subdeck:update`: runs `claude plugin marketplace update subdeck` and `claude plugin update subdeck@subdeck` (only SubDeck), prints version and commit before and after; then run `/reload-plugins` or restart.
- `/subdeck:doctor`: health check, one line per item (ok/warn/fail/info) with a fix hint: plugin installed and enabled, hooks, the 7 agent files, Node vs the Desk minimum, state folder writable, Desk running, model policy warnings, version. Always exits 0; ends with "N ok, N warn, N fail".
- `/subdeck:help`: the command list, the most used settings keys and the User Guide link.

## CHANGELOG.md (Unreleased)
- Added: `/subdeck:version`, `/subdeck:update`, `/subdeck:doctor`, `/subdeck:help` (Claude Code). Not yet in the portable skills for other tools.

## Notes
- hooks.json SessionStart text still says "User commands: /subdeck:desk, /subdeck:status, /subdeck:settings."; add the four new ones when that file is next edited.
- scripts/build-portable.sh hard-codes the skill list (desk status settings); the new commands need adding there before skills-portable can carry them.
