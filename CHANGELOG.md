# Changelog

Behaviour-relevant changes to this repo, newest first, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
shape. An entry is added in the session that makes the change (`docs/policy/repo-standards.md` § Changelog).
History before this file: `git log`.

## [Unreleased]

### Added
- `scripts/test-mac-maintenance.sh`, run by `./test.sh maint`: the real `mac-maintenance.sh` against a fake HOME, plus static checks that it never deletes (D29).
- `scripts/security-audit.sh`: every report opens with `## Since last run` — new, resolved and unchanged findings against the newest previous full report; the notification, terminal line and `security-audit.log` carry the new/resolved counts (D30).
- `bin/weekly-disk-cleanup.sh`: one `Reclaimed: N MB` line at the end of a real run.
- `macos/com.pieterdejong.docsbackup.plist`: repo copy of the daily docs-backup agent (`$HOME` marker, D20). `sync-dotfiles.sh backup`/`restore` cover it; `status` now checks all five `com.pieterdejong.*` plists against the live agents.
- `TODO.md` and this changelog.

### Changed
- `scripts/mac-maintenance.sh`: `--dry-run`, `--help`, exit 0/2, every mutating step through one `act` helper, no `set -e`, awk instead of `bc`; leaves the `pip`, `pip-tools` and `Homebrew` caches to the weekly cleanup; lists entries in use instead of failing; says so when Trash is not accessible (D29).
- `bin/weekly-disk-cleanup.sh`: when `~/.Trash` is unreadable (launchd without Full Disk Access) the Trash step says so and is skipped, instead of printing empty sizes that the dashboard read as zero reclaimed.
- `docs/maintenance.md` rewritten as the README for every maintenance job: at-a-glance table (script, schedule, safe mode, output, tests, plist, decisions), testing, decisions and open-items sections.

### Fixed
- `docs/maintenance.md` said the `rm -rf` allowlist test was pending; it has been in `scripts/test-bin.sh` since D27.
- `docs/policy/repo-standards.md` gained the § Changelog that `claude/dev-CLAUDE.md` already pointed to.
