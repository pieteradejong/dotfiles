# Changelog

Behaviour-relevant changes to this repo, newest first, in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
shape. An entry is added in the session that makes the change (`docs/policy/repo-standards.md` § Changelog).
History before this file: `git log`.

## [Unreleased]

### Added
- `bin/llm`: `config/llm/lineup` declares the local models and their roles; new commands `status`, `models`, `update` (installs the lineup: plan, one yes, disk floor, each pull verified local), `free`, `restart`, and the `fast` role. Starts the Ollama daemon on demand; `LLM_NO_AUTOSTART` opts out (D32).
- `docs/policy/ai-and-external-services.md` §5: a per-project allow for one outward command is permitted in that project's tracked `.claude/settings.json`, exact command, neighbouring actions denied, with its own decision entry; `eu27-data-sovereignty` #106 is the first example.
- `bin/mail-report`: sends stdin as a plain-text email over Gmail SMTP, credentials from one macOS Keychain item (`dotfiles-mail-report`); `--test`, `--dry-run`, exit 3 when unconfigured. Tested by `scripts/test-mail-report.py` (`./test.sh mail`) against a fake `security`; nothing is sent (D31).
- `bin/weekly-disk-cleanup.sh` and `scripts/mac-maintenance.sh` mail every real run — the same text as the log, subject from the `Reclaimed:`/`Moved:` line. New `--no-mail`; `--dry-run` never mails. A failed send is one `WARN: report not mailed` line, never a non-zero exit (D31).
- `scripts/test-mac-maintenance.sh`, run by `./test.sh maint`: the real `mac-maintenance.sh` against a fake HOME, plus static checks that it never deletes (D29).
- `scripts/security-audit.sh`: every report opens with `## Since last run` — new, resolved and unchanged findings against the newest previous full report; the notification, terminal line and `security-audit.log` carry the new/resolved counts (D30).
- `bin/weekly-disk-cleanup.sh`: one `Reclaimed: N MB` line at the end of a real run.
- `macos/com.pieterdejong.docsbackup.plist`: repo copy of the daily docs-backup agent (`$HOME` marker, D20). `sync-dotfiles.sh backup`/`restore` cover it; `status` now checks all five `com.pieterdejong.*` plists against the live agents.
- `TODO.md` and this changelog.
- `docs/mac-overheating.md`: the 2026-10-10 overheating diagnosis (finding the hot process, what `BTLEServer` is, a threshold-gated `restart_if_hot`, the sudoers rule and a watchdog agent), and `TODO.md` § Roadmap with the items it implies for `mac-maintenance.sh`. Notes only; nothing is automated yet.

### Changed
- `bin/weekly-disk-cleanup.sh`, `scripts/mac-maintenance.sh`: a real run is captured into a per-run file and then appended to the log, instead of `exec`-ing stdout into it through `tee` (whose flush could not be waited for). Same log content; `~/.weekly-disk-cleanup.launchd.log` now only catches output before the capture starts (D31).
- `scripts/mac-maintenance.sh`: `--dry-run`, `--help`, exit 0/2, every mutating step through one `act` helper, no `set -e`, awk instead of `bc`; leaves the `pip`, `pip-tools` and `Homebrew` caches to the weekly cleanup; lists entries in use instead of failing; says so when Trash is not accessible (D29).
- `bin/weekly-disk-cleanup.sh`: when `~/.Trash` is unreadable (launchd without Full Disk Access) the Trash step says so and is skipped, instead of printing empty sizes that the dashboard read as zero reclaimed.
- `docs/maintenance.md` rewritten as the README for every maintenance job: at-a-glance table (script, schedule, safe mode, output, tests, plist, decisions), testing, decisions and open-items sections.

### Fixed
- `bin/llm`: a model name containing `coding` now classifies as coder (D32).
- `scripts/test-bin.sh` closes stdin. Under any non-terminal harness, every `llm` call had blocked in `cat` forever.
- `docs/maintenance.md` said the `rm -rf` allowlist test was pending; it has been in `scripts/test-bin.sh` since D27.
- `docs/policy/repo-standards.md` gained the § Changelog that `claude/dev-CLAUDE.md` already pointed to.
