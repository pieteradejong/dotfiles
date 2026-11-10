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
- [ ] Sun 2026-11-01 09:00 — first launchd run with the stale-node_modules step (D47).
      `~/.weekly-disk-cleanup.log` should show `--- Stale node_modules …`, about 43 folders, and
      `Stale: 0` (nothing is 60 days idle yet). Check that `git` and `find` worked under launchd's
      PATH (no errors in that section). Record in D47's `Verified:`.

## Needs Pieter

- [x] **Committed 2026-10-23.** `claude/settings.json` had an uncommitted `statusLine` block (model · directory, via `jq`) from an earlier session; commit it with a CHANGELOG line or drop it. Left out of the 2026-10-22 merge on purpose — 2026-10-22, D41 merge (`c6d3ed2`)
- [ ] Push branch `prompt-followup` (D37, commit `007a3a0`) and fast-forward `main`, 2026-10-17 —
      waits for Pieter's go-ahead (push is outward-facing). The D38 `pwd-gen` work was left in the
      working tree and is committed separately by its own session; D37's hunks of `CHANGELOG.md`,
      `TODO.md`, both READMEs, `test.sh` and the decision log were staged alone (`git hash-object` +
      `update-index`, no pwd-gen line in the commit) rather than committed together, so each decision
      has its own commit.
      The branch also carries D38 (`3033ca6`) and D39 (`fd09cb4`, model-selection section in
      `claude/dev-CLAUDE.md`), 2026-10-17; one push covers all three.

- [x] **Mail reports: the one-time setup** (`docs/maintenance.md` § Email reports): a Gmail App
      Password, `security add-generic-password -U -s dotfiles-mail-report -a <address> -w`,
      then `mail-report --test`. Until then every real run logs `WARN: report not mailed
      (mail-report exit 3)` and otherwise behaves as before.
      Closed 2026-11-09, never done: superseded by D60 (reports stay on the Mac, `mail-report`
      archived).

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

- [ ] `stop-log-check` counted committed files and another session's uncommitted files as this session's changes: `vercel-live-reusable.yml` and `vercel-project` were committed under D42, and `media-backup` is D46. In the same turn it said no `CHANGELOG.md`, decision or `TODO.md` change was made, although D52's session had edited all three. Same family as the re-ask item in `~/dev/TODO.md`. Added 2026-10-29.
- [ ] Schedule `scripts/claude-md-check.py`: in the weekly maintenance job (mailed with the rest), or in `whatsup` at `~/dev` (it adds about 2s of probes to every session start). Added 2026-10-29, D52.
- [ ] D52 live check: a fresh Claude Code session under `~/dev/templates/` lists `templates/CLAUDE.md` among the loaded memory files. Then set D52 `Verified` to yes. Added 2026-10-29.
- [ ] `stop-log-check`: `LOGS_OPEN_WORK_ERE` matches `TODO` anywhere, so a reply saying "no decision, changelog or TODO entry is needed" was blocked as naming open work (2026-10-29, the D52 session). Match `TODO` only as an item marker, or skip it in a negated clause, and add the sentence as a case in `scripts/test-logs.sh`. Added 2026-10-29.
- [ ] A `bin/` command for the do-not-touch register's non-personal-remotes `find` loop, so the check is one word instead of a pasted snippet. The command goes here; the register (private) points to it. Added 2026-10-29, D52 review.
- [ ] Spot-check D41 in the next session that looks up library docs: did it try `<domain>/llms.txt` first, and fall back silently on a 404? Then set D41 `Verified` to yes. Added 2026-10-20, `docs/design-decisions.md` D41.
- [ ] `security-audit.sh`: callees should print the path they wrote instead of the composer
      rebuilding `findings-$STAMP.tsv` (`scripts/README.md`, audit item 3).
- [ ] `test.sh`: shellcheck an explicit list → a glob, so a new script cannot fall through
      (audit item 7). `dothelp.sh`, `test-dotfiles-setup.sh`, `test-dev-audit.sh` are unlinted.
- [ ] `sync-dotfiles.sh`: `status` covers all five plists; `backup` and `restore` copy only the
      two with absolute paths. The other three are loadable as is — copy them by hand for now.
- [ ] Monthly checklist (`docs/maintenance.md` § Monthly): last completed — not recorded.
- [ ] Ideas deliberately not automated: the `IDEAS` block at the end of `bin/weekly-disk-cleanup.sh`.
- [x] Commit `bin/pwd-gen` + `config/pwd-gen/` + `scripts/test-pwd-gen.py` (D38), 2026-10-17 — the tree
      also holds the uncommitted `doc-dupes` work (D37) in the same files (`CHANGELOG.md`, both
      READMEs, `test.sh`, the decision log); decide whether to commit both together or split the
      hunks, then push after confirming.
      → Split, 2026-10-17: D37 went alone as `007a3a0` on `prompt-followup`; the pwd-gen hunks are
      what remains unstaged in this tree.
      → Committed 2026-10-17 on `prompt-followup` as its own commit (D38); push still needs Pieter's
      confirmation, together with the D37 push/merge item above.
- [x] `./test.sh logs` failed once as of 2026-10-17 07:50: `todo-cross-file: reported against the file checked,
      with both states` (`scripts/test-logs.sh:516`, the uncommitted `doc-dupes` work of D37). Seen while
      verifying D38; not caused by `pwd-gen`. Fix or confirm fixed before the D37 commit.
      → Resolved 2026-10-17 07:55 by the D37 commit `007a3a0`: `./test.sh logs` → 264 passed, 0 failed.

## Privacy coverage of this repo (2026-10-29 review)

This repo is public. Pieter asked whether anything checks that it holds no sensitive data. The
gate, CI and the weekly audit do, but with the gaps below. They were mapped read-only on 2026-10-29.
`gate.sh scan-tree` on that day's tree was clean. Specifics live in the private findings register
and are cited here by ID only. Each fix earns its own decision entry when it is built.

- [ ] Full-history personal-data scan of dotfiles itself. Nothing reads this repo's history for
      personal data: `security-audit.sh` step 4 skips repos with a local clone (`:153`), dotaudit's
      history pass reads file names only, and CI history is gitleaks (secrets) only. Run step 4's
      `git log -p --all` scan of shapes and personal values on local public repos too, starting
      with this one. It would have reported SA-2.2h and the 16 historical home-path lines (SA-2.5,
      accepted under D11). Added 2026-10-29.
- [ ] The gate never applies `CONTENT_RULES` or `SECRETISH_RE`; only dotaudit does, weekly. Either
      wire them into `scan_added` in `security/gate.sh`, or correct the `security/patterns.sh`
      header, which says the gate uses them. Added 2026-10-29.
- [ ] Block binary plists in the gate (`bplist00` magic). Early `macos/*.plist` commits were binary,
      which gitleaks and `scan_added` cannot read. HEAD is XML now, but nothing stops a binary one
      coming back. Add a case to `scripts/test-security-gate.sh`. Added 2026-10-29.
- [ ] The fixture exemption also skips the personal-values check: in `gate.sh:182-184` the
      `EXAMPLE_PATH_ERE` filter runs before the personal-pattern check at `:215`. Fix this together
      with GW-1, which narrows the match to path segments. Also: fixture emails on domains outside
      the placeholder list (`company.io`, `npmjs-mail.io`) should move to `example.*`.
      Added 2026-10-29.
- [ ] New shape rules in `security/patterns.sh`, each with gate tests: private IPv4 ranges,
      `.local`/`.internal` hostnames, AWS ARNs and S3 bucket URLs outside mermaid diagrams, and
      SSH `Host`/`IdentityFile` lines. Street addresses (asked for by policy §5): decide whether a
      regex is worth its false positives. Added 2026-10-29.
- [ ] `scripts/sync-dotfiles.sh` copies these raw, with no sanitizer: `.zshrc`, `.zprofile`,
      `.p10k.zsh`, `.gitignore_global`, `Brewfile` and `rectangle.plist`. The gitconfig sanitizer
      strips home paths but not the email; the ssh config one keeps `Host` aliases and
      `IdentityFile`. Run all of them through home-path and email sanitizing. Added 2026-10-29.
- [ ] A private name denylist the gate reads, next to `private/security/personal-patterns.conf`:
      private repo names, clients, family. Today nothing reads `docs/`, `CHANGELOG.md`, `TODO.md` or
      the decision log for meaning, only for shapes. Decide whether this is worth its upkeep.
      Added 2026-10-29.
- [ ] Docs and code disagree: the `patterns.sh` header (`:5-11`) says the personal-patterns file is
      loaded "only" by the gate, but `security-audit.sh` loads it too; and `audit/30-privacy.sh:35`
      lists `PHONE_RE` but never calls it. Added 2026-10-29.

Found in the 2026-11-02 review (plan `~/.claude/plans/velvety-brewing-robin.md`). Not built that
day because Claude Code's auto-mode classifier refused edits to `security/gate.sh` as "Security
Weaken". Built on 2026-11-04 (the edits went through), except the GitHub settings.

- [x] The gate judges itself. `ci.yml` passes `policy-ref: ${{ github.sha }}`, so a commit that
      weakens `gate.sh` or `gitleaks.toml` is checked by the weakened rules. Add a second
      `security-reusable.yml` job pinned to the previous tip (PR base, or `github.event.before`,
      with `main` as the fallback). Added 2026-11-02. Done 2026-11-04: `security-prev` job (D56).
- [ ] D56 `Verified: NOT YET`: after the next push, check that both `security` and
      `security-prev` ran and passed, and that `security-prev`'s policy checkout is the previous
      tip's SHA. Added 2026-11-04.
- [ ] GitHub side of `main`: no branch protection and no ruleset (404 and empty, 2026-11-02).
      Non-provider patterns, validity checks and Dependabot are off. Proposal: a ruleset that
      blocks deletion and non-owner force-push, and the two scanning settings turned on. This is
      outward-facing, so it needs Pieter's yes. Added 2026-11-02.
- [x] Filename rules missing from `GATE_FILE_RULES`: `.git-credentials`, `*.tfstate*`, `*.kdbx`,
      `*.keychain-db`, `.docker/config.json`, `*.ovpn`. Added 2026-11-02. Done 2026-11-04 (`CHANGELOG.md`).
- [x] Two regex holes. `EMAIL_PLACEHOLDER_RE`'s `^(user|…|name|you|your)[-_.@]` exempts real
      addresses such as `name.surname@<real domain>`. `scan_range` reads diffs with `--no-merges`,
      so lines a merge commit adds are never scanned for personal data. Added 2026-11-02.
      Done 2026-11-04: prefix rule is bare-local-part only; merges read as remerge diffs (D57).
- [x] Tests for the personal-values list need a fixture list. Don't add an env override for its
      path (the classifier flagged that as a weakening, and rightly so: anyone could point it at
      `/dev/null`). Copy `security/` into the test sandbox with its own `private/` instead.
      Added 2026-11-02. Done 2026-11-04: fixture copy in `scripts/test-security-gate.sh`.
- [ ] `./test.sh pwdgen` (`scripts/test-pwd-gen.py`) is flaky: it failed once in a full
      `./test.sh` run on 2026-11-04, then passed three runs in a row and on the committed tree. It
      is probably a randomness-dependent assertion. Find it and make it deterministic. Added 2026-11-04.

## Open decisions

- [ ] Add the media bucket name and AWS account id to `private/security/personal-patterns.conf`?
      This only works if the media repo is also added to `personal-data-repos.conf`, otherwise its
      pushes are blocked, 2026-10-26 — D45 Rejected
- [ ] Sun 2026-11-15 09:00 — first launchd run with the self-check and the new cleanup steps
      (npx, headless Chrome, Library caches, Docker with Colima start/stop). The run now checks
      itself: run `weekly-cleanup-check` (or read the `Self-check:` line at the end of
      `~/.weekly-disk-cleanup.log`). Expect `Self-check: OK`; if not, each `PROBLEM:` line names
      the step. Also check that the run's macOS notification appeared (Notification Center) and
      that the session-start `Maintenance:` line reads `cleanup 0d ago, Self-check OK`. Record the
      result in the D27 addenda's and D60's `Verified:` — 2026-11-09, D27 addenda 2026-11-08/09,
      D60 (`private/reports/disk-survey-2026-11-08.md`)
