# Sessions — dotfiles

One dated section per working session, newest first: what changed, what is unverified, what is
open and where. Rule: workspace `CLAUDE.md` § Session workflow, step 6 (D68). This file is public:
no private repo names, findings or personal data. Those go in the private repo's logs.

## 2026-11-13 — Pre-push security sweep rule, session log rule (D68)

**Changed** (branch `claude-md-reach`):
- `claude/dev-CLAUDE.md` (copied to `~/dev/CLAUDE.md`): new hard rule, run the GitHub security sweep
  before any push or going public. Session workflow step 6 now writes the closing summary to
  `docs/SESSIONS.md`.
- `docs/policy/security-and-privacy.md` §10: the pre-push requirement. `docs/policy/repo-standards.md`
  § Enforcement: two rows, both marked instruction only.
- `docs/design-decisions.md` D68, `CHANGELOG.md`, `TODO.md` (two follow-ups to mechanise the rules),
  this file. `~/.codex/AGENTS.md` rebuilt with `codex-agents-sync`.

**Ran:** a full `security-audit.sh --history`: 8 FAIL, none new, 17 WARN. Also a settings sweep dry
run, which needed no changes. The details name private repos, so they are in the workspace log
`~/dev/SESSIONS.md` and the report in `~/dev/audit-reports/`.

**Unverified:** D68 is `PARTIAL`. `./test.sh docs` has one failure, from another branch's
uncommitted `templates-CLAUDE.md` edit.

**Open:** `TODO.md` § Tooling, the two D68 items.
