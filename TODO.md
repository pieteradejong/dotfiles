# TODO — dotfiles

Open work on this repo's tooling and the jobs it schedules (`docs/maintenance.md`). Security
findings that name repos live in the private findings register and are referenced here by ID
only; this file is public. Workspace-wide items: `~/dev/TODO.md`. Decisions: `docs/design-decisions.md`.

## Verify after the next scheduled runs

- [ ] D37 live check, 2026-10-17 — in a fresh Claude Code session under `~/dev/projects/chrome-bookmarks`
      every prompt shows the three `followup` lines; a reply naming open work with no `TODO.md`
      touched is blocked once by `stop-log-check`; the same at `~/dev` itself. Record in D37's
      `Verified:` (the suite covers it; the live check is what proves the hook is wired).
- [ ] First weekly `dotaudit` with `docs-redundant`, Sun 2026-10-18 — baseline was 0 findings over
      50 log files on 2026-10-17 (`doc-dupes --all`); record the count in D37.

- [ ] Sun 2026-10-11 09:00 — first launchd run of the rewritten `bin/weekly-disk-cleanup.sh`
      (D27 plus the Trash probe). `~/.weekly-disk-cleanup.log` should show every D27 step, the
      pip step reclaiming under launchd, the Trash step saying `no Full Disk Access … skipped`,
      and a `Reclaimed:` line. Record in D27's `Verified:`.
- [ ] Sun 2026-10-11 10:00 — first report with `## Since last run` (D30). Check it against the
      2026-10-04 report by eye; the notification shows new/resolved counts. Record in D30.
- [ ] Open `~/dev/audit-reports/dashboard.html` after that audit (D28 `Verified: NOT YET`).
- [ ] `scripts/mac-maintenance.sh --dry-run` on this Mac, then a real run; record in D29.
- [ ] Sun 2026-10-18 09:00 — first launchd run of the cleanup that mails its result (D31). The
      mail should arrive with subject `weekly-disk-cleanup on <host>: Reclaimed N MB` and the
      same text as `~/.weekly-disk-cleanup.log`; no Keychain prompt should have appeared, and
      the log must not end in `WARN: report not mailed`. Record in D31's `Verified:`.

## Needs Pieter

- [ ] **Mail reports: the one-time setup** (`docs/maintenance.md` § Email reports): a Gmail App
      Password, `security add-generic-password -U -s dotfiles-mail-report -a <address> -w`,
      then `mail-report --test`. Until then every real run logs `WARN: report not mailed
      (mail-report exit 3)` and otherwise behaves as before.

- [ ] **rclone: create a personal Google Drive client_id** before the shared one is retired
      (rclone says "during 2026"), or the daily docs backup stops. Seen in
      `~/docs/.backup/logs/launchd.out` on 2026-10-10. https://rclone.org/drive/#making-your-own-client-id
- [ ] Audit §3: three private repos lack Dependabot alerts, every week since 2026-09-27 —
      `scripts/github-security-sweep.sh --apply` (outward-facing: confirm first).
- [ ] Audit §6: the recovery-codes file at the root of `~/dev` — into the password manager, then
      delete it (open since 2026-09-07; also in `~/dev/TODO.md`).
- [ ] Audit §4: findings AU-1 and AU-2 in the private register (old secrets in GitHub history) —
      revoke or confirm dead, record the output. These are eight of the ten weekly FAILs.
- [ ] Full Disk Access for the cleanup under launchd: grant it to `/bin/zsh` (broad) or keep
      sweeping Trash by hand. Current: by hand.
- [ ] `macos/com.pieterdejong.rcdev.plist` differs from the live agent (`run` vs `run dev`);
      `dotfiles status` reports it. Decide which is canonical and copy it over.
- [ ] `./test.sh dotaudit`: two failures seen on 2026-10-10 before any maintenance change
      (`unpinned-deps-skipped` reported on the clean fixture; `unpinned-deps` count). Not part of
      the maintenance work.

## Roadmap

Planned additions, each with its reference doc. Nothing here is built yet. Source:
[`docs/mac-overheating.md`](docs/mac-overheating.md), the 2026-10-10 diagnosis of this Mac at
~100°C with `BTLEServer` at 82% CPU.

- [ ] **Thermal check in `mac-maintenance.sh`**: a `--- HOT PROCESSES ---` block in the report
      (the `top -o cpu -l 2` snapshot). Read-only, so it needs no decision entry. Doc § 2.
- [ ] **`restart_if_hot BTLEServer 50`** in `mac-maintenance.sh`, through `act` so `--dry-run`
      prints instead of kills; tested in `scripts/test-mac-maintenance.sh` with a fake `top` and
      `pgrep` on `PATH`. Needs a decision entry (D32; D31 went to the mailed reports): the
      script's first step that touches a running process, and the first `sudo` in any
      maintenance script. Doc § 4.
- [ ] **Sudoers rule** `/etc/sudoers.d/btleserver`, outside the repo, by hand with `visudo`;
      record it in `docs/reinstall-commands.md` once added. Doc § 5.
- [ ] **Every-30-min watchdog agent**, only if the spike recurs after a reboot. Would be the sixth
      `com.pieterdejong.*` plist and the first on an interval: At-a-glance row in
      `docs/maintenance.md`, `sync-dotfiles.sh status` coverage, same D32 entry. Doc § 6.
- [ ] **Find the device**: Bluetooth off for a minute to confirm, then unpair one at a time. The
      watchdog treats the symptom. Doc § 3.

## Tooling

- [ ] `security-audit.sh`: callees should print the path they wrote instead of the composer
      rebuilding `findings-$STAMP.tsv` (`scripts/README.md`, audit item 3).
- [ ] `test.sh`: shellcheck an explicit list → a glob, so a new script cannot fall through
      (audit item 7). `dothelp.sh`, `test-dotfiles-setup.sh`, `test-dev-audit.sh` are unlinted.
- [ ] `sync-dotfiles.sh`: `status` covers all five plists; `backup` and `restore` copy only the
      two with absolute paths. The other three are loadable as is — copy them by hand for now.
- [ ] Monthly checklist (`docs/maintenance.md` § Monthly): last completed — not recorded.
- [ ] Ideas deliberately not automated: the `IDEAS` block at the end of `bin/weekly-disk-cleanup.sh`.
