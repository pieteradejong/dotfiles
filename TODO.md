# TODO — dotfiles

Open work on this repo's tooling and the jobs it schedules (`docs/maintenance.md`). Security
findings that name repos live in the private findings register and are referenced here by ID
only; this file is public. Workspace-wide items: `~/dev/TODO.md`. Decisions: `docs/design-decisions.md`.

## Verify after the next scheduled runs

- [ ] Sun 2026-10-11 09:00 — first launchd run of the rewritten `bin/weekly-disk-cleanup.sh`
      (D27 plus the Trash probe). `~/.weekly-disk-cleanup.log` should show every D27 step, the
      pip step reclaiming under launchd, the Trash step saying `no Full Disk Access … skipped`,
      and a `Reclaimed:` line. Record in D27's `Verified:`.
- [ ] Sun 2026-10-11 10:00 — first report with `## Since last run` (D30). Check it against the
      2026-10-04 report by eye; the notification shows new/resolved counts. Record in D30.
- [ ] Open `~/dev/audit-reports/dashboard.html` after that audit (D28 `Verified: NOT YET`).
- [ ] `scripts/mac-maintenance.sh --dry-run` on this Mac, then a real run; record in D29.

## Needs Pieter

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

## Tooling

- [ ] `security-audit.sh`: callees should print the path they wrote instead of the composer
      rebuilding `findings-$STAMP.tsv` (`scripts/README.md`, audit item 3).
- [ ] `test.sh`: shellcheck an explicit list → a glob, so a new script cannot fall through
      (audit item 7). `dothelp.sh`, `test-dotfiles-setup.sh`, `test-dev-audit.sh` are unlinted.
- [ ] `sync-dotfiles.sh`: `status` covers all five plists; `backup` and `restore` copy only the
      two with absolute paths. The other three are loadable as is — copy them by hand for now.
- [ ] Monthly checklist (`docs/maintenance.md` § Monthly): last completed — not recorded.
- [ ] Ideas deliberately not automated: the `IDEAS` block at the end of `bin/weekly-disk-cleanup.sh`.
