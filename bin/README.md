# `bin/` — executables on `PATH`

This directory is on `PATH`, set in `shell/.zshrc`:

```zsh
export PATH="$HOME/dev/dotfiles/bin:$PATH"
```

Everything here is executable and self-contained; nothing needs `source`-ing from
a shell rc file. Files are run **in place** out of the repo — there is no second
copy in `~` to keep in sync, so an edit here takes effect immediately. That is the
opposite of most of this repo, where the live file in `~` is what the system reads
and the repo holds a copy (see [docs/system-overview.md](../docs/system-overview.md)).

| Script | What it is |
|---|---|
| [`llm`](../docs/llm.md) | Run a prompt against a local model. Never the cloud. |
| `weekly-disk-cleanup.sh` | Reclaims disk from caches that regenerate (npm, pip, pip-tools, uv, Homebrew, pnpm, Xcode, Squirrel and Sparkle app-updater leftovers) and Trash older than 7 days. Runs weekly via launchd, which points at this path; `--dry-run` shows what it would do; every real run is logged and mailed (`--no-mail` to skip). See [docs/maintenance.md](../docs/maintenance.md). |
| `mail-report` | Sends stdin as a plain-text email over Gmail SMTP, credentials from one Keychain item — the sender behind the maintenance jobs' mails. `mail-report --test` to check the setup. Python, stdlib only. See [docs/maintenance.md § Email reports](../docs/maintenance.md#email-reports). |
| `rcdev` | Always-on Claude Code Remote Control server rooted at `~/dev`, run by launchd (`rcdev install`, `rcdev status`). See [docs/maintenance.md](../docs/maintenance.md#remote-control-server-rcdev). |
| `whatsup` | What is going on in the project you are in, on one screen: git state and last commits, the decision log's last entry and open `Verified` items, the changelog's `[Unreleased]` block, open TODO items, and what the current Claude Code session changed without a changelog line. `--brief` is what the `SessionStart` hook prints; outside a repo it shows the workspace TODO and recently active repos (`--all` scans every repo). Read-only. Rules: `docs/policy/repo-standards.md` § Changelog. |
| `vercel-project` | Gives the repo you are in its own Vercel project, set up the one way every project deploys: Git integration, GitHub deployments on, previews protected, and production held until `tests` and `security` pass (Deployment Checks). `init` (with `--dry-run`), `check` (exit 1 on drift). It refuses repos it does not own and uses the `vercel` CLI's own login. See [docs/deploy-pipeline.md](../docs/deploy-pipeline.md). Decision D42. |

## `bin/` vs `scripts/`

`scripts/` is management tooling for this repo itself — `sync-dotfiles.sh`,
`dev-audit.sh`, the `test-*.sh` suites. It is deliberately **not** on `PATH`;
putting it there would turn every one of those into a global command.

`bin/` is the PATH directory: general-purpose commands meant to be typed.

## Testing

`zsh -n` syntax checks plus behavioral tests run from the repo root:

```zsh
./test.sh zsh-syntax
./test.sh bin
./test.sh mail       # mail-report, against a fake Keychain; nothing is sent
```

The zsh scripts are not covered by the `shellcheck` suite — shellcheck does not
parse zsh. `weekly-disk-cleanup.sh` is never executed by the tests (it deletes
things); it is asserted statically instead, with a stub in place of `mail-report`.
`mail-report` is Python and is linted by `ruff` (`./test.sh ruff`).

