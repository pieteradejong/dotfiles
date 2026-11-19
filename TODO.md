# TODO — dotfiles

Open work on this repo's tooling and the jobs it schedules (`docs/maintenance.md`). Security
findings that name repos live in the private findings register and are referenced here by ID
only; this file is public. Workspace-wide items: `~/dev/TODO.md`. Decisions: `docs/design-decisions.md`.

## Verify after the next scheduled runs

- [ ] D79, 2026-11-17: after the Sunday audit (2026-11-22), check section 11 *CI status*: counts match a by-hand `scripts/ci-status.py`, `~/dev/audit-reports/ci-status/ci-status-2026-11-22.{md,tsv}` exist at mode 600, and red security workflows are FAIL lines. Check the next daily report's `## CI` line and its one Needs-action line. Record it in D79's `Verified:`.

- [ ] D78, 2026-11-16: after the first Saturday run with the Expo phase (2026-11-21), read `~/dev/audit-reports/latest-deps/expo-2026-11-21.md`. Commit any `applied` bump in its repo with a CHANGELOG line (and a DECISIONS entry for an SDK major). Check that `reverted` and `broken-by-latest` checkouts are byte-identical. Check the daily report's *All launchd jobs* section and its Expo counts the next morning. Record it in D78's `Verified:`.
- [ ] D76, 2026-11-16: check the `latestdeps` agent's first Saturday run (2026-11-21): the report in `~/dev/audit-reports/latest-deps/`, how long it took, nothing left in `~/Library/Caches/latest-deps`, `git status` clean in the projects. Then section 10 in the Sunday audit (2026-11-22) and the daily report's `latestdeps` row. Record it in D76's `Verified:`.
- [ ] D76, 2026-11-16: add a `--ci` flag (skip the local gate scan) to every project the first report marks `needs-ci`, and fix or skip-list the `already-failing` ones. Each is a change in that project's repo, with its own CHANGELOG line.
- [ ] D74, 2026-11-15: `~/dev/CLAUDE.md` § Where this file reaches says to re-run `codex-agents-sync` after editing it, but no such tool exists in dotfiles (searched `bin/`, `scripts/`, `claude/`). Either write it (build `~/.codex/AGENTS.md` from the workspace file, the global file and the do-not-touch register) or correct the sentence. Until then Codex lacks the new data rule. Record it in D74's `Verified:`.
- [ ] D72, 2026-11-15: open `maintenance-app` after the next daily report (07:00) and check the
      Backups tile, table and grid over the real register. The new encrypted target shows
      `missing` until its remote is set up (`~/dev/TODO.md`). Record it in D72's `Verified:`.
- [ ] D73, 2026-11-15: use `notes-app` in the browser: search a word, a phrase, open a note, and
      check the highlighting and the light/dark styling. Record it in D73's `Verified:`.
      2026-11-19: now always on at `127.0.0.1:8749` (D81). Get the bookmark with
      `notes-app --port 8749 --token-file ~/.config/notes-app/token --print-url`.
- [ ] D81, 2026-11-19: after the next reboot or login, check that `com.pieterdejong.notesapp` came
      back up (`launchctl print gui/$(id -u)/com.pieterdejong.notesapp | grep state`) and that the
      bookmark still works with the same token. Record it in D81's `Verified:`.
- [ ] D70, 2026-11-14: check the first scheduled 07:00 run of `com.pieterdejong.dailyreport` (Sun
      2026-11-15): `~/dev/audit-reports/daily/daily-2026-11-15.md` exists, its window starts at the
      2026-11-14 run, Administrative work is a real diff (no baseline note), the notification
      appeared, `launchctl list` shows exit 0 or 1. Record it in D70's `Verified:`.
- [ ] D70, 2026-11-14: after the 03:00 backup that follows, `rclone lsf
      gdrive:Backups/dev-backup/audit-reports/daily/` lists the reports. Note that the `dev` target
      currently ends FAIL (check differences), which the report flags daily. Record it in D70.
- [ ] D71, 2026-11-14: open `maintenance-app` in the browser and check the four views over the
      real report (the Chrome extension was not connected, so only HTTP checks ran). Record in D71.
- [ ] D70, 2026-11-14: `security-audit.log` holds a 2026-11-10 line pointing at a report in a
      Claude scratchpad. A test or by-hand run appended to the real log, and `maintenance-status`
      reads its last line. Find which run and make it use a fixture log.
- [ ] D71, 2026-11-14: optional follow-ups: a *Daily* tile on `dashboard.html`, and backfilling
      history from old logs (the app starts at the first daily report).
- [ ] D63, 2026-11-10: run `./test.sh --docker` once (`colima start`; pulls `debian:bookworm-slim`),
      and see the `toolchain`, `coverage` and `scan` suites pass in CI on the next push.
- [ ] D63, 2026-11-10: decide on `ruff format`: 10 Python files would be reformatted. Either one
      `./run.sh format` commit, then a `ruff format --check` step in `test.sh`, or leave it.
- [ ] D62, 2026-11-10: a fresh Claude Code session in `~/dev` shows the `✗` detail lines at start,
      and the Sun 2026-11-15 10:00 audit's section 6 (through `security/lib/loose-files.sh`) reads
      as before. Then fill in D62's `Verified:` line.

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

- [ ] D79, 2026-11-17: approve creating the private canary repo: `gh repo create pieteradejong/template-ci-canary --private --description "Generated: curated template CI runs (dotfiles D79)"`, with a README saying it is generated and the GitHub baseline (`github-security-sweep.sh --check`). Then run `scripts/template-canary.sh --only ts-web/minimal-mvp`, check the run in `gh run list -R pieteradejong/template-ci-canary`, then run all 7. Record the result in D79's `Verified:`. A red template there is fixed in `~/dev/templates`, with its own changelog line.
- [ ] D79, 2026-11-17: decide whether the weekly audit runs the template canary unattended (each run pushes 7 `canary/*` branches to the private repo). If yes, make it a section 12 behind the existing `--templates`-style flag and record the standing OK in D79. Until then it runs by hand after a template change.
- [ ] D79, 2026-11-17: this session's work is uncommitted on branch `daily-report`: the gate, dotaudit, `ci-status.py`, `template-canary.sh`, audit section 11, daily report, `test.sh` suites, docs. Commit and push through `ship` once Pieter OKs it (public repo). After the push, check that this repo's CI goes green with `actionlint` in the brew install.

- [ ] D78, 2026-11-16: six launchd plists point at programs that no longer exist (the daily report's *All launchd jobs*, flag `program missing`): two Homebrew agents in `~/Library/LaunchAgents` (mongodb-community@5.0, rabbitmq) and four daemons in `/Library/LaunchDaemons` (an old postgresql@14, istatmenus installer helper, an ExpressVPN daemon, an Edge updater). Decide which to remove. The `/Library` ones need `sudo` (`launchctl bootout system/<label>`, then the plist to the Trash), and every removal is one approval per step.
- [x] D76, 2026-11-16: approve installing the launch agent `com.pieterdejong.latestdeps` (Saturdays 22:00): `cp macos/com.pieterdejong.latestdeps.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pieterdejong.latestdeps.plist`, then flip its row in the launchd register to `yes` with a dated § Changes line. Done 2026-11-16 (D78 session): installed, register row `yes`, `launchctl list` shows it.
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
- [ ] **Docs backup failing**: `com.pieterdejong.docsbackup` last exit 1, `dev: FAILED rc=1` in
      `~/docs/.backup/logs/launchd.out` (`~/docs/.backup/backup_docs.py`), so the `~/dev` part of
      the daily backup is not completing. Flagged by the first `maintenance-status` line (D60) on
      2026-11-09; not yet investigated. Clears when the status line stops listing `docsbackup`.
- [x] Audit §3: three private repos lack Dependabot alerts, every week since 2026-09-27 —
      `scripts/github-security-sweep.sh --apply` (outward-facing: confirm first).
      **Done 2026-11-12** (12 repos by then): `--apply` → `12 applied, 0 error(s)`; `--check` →
      `0 need changes`, exit 0. Alert triage follow-ups are in `~/dev/TODO.md`.
- [ ] Audit §3 refills: a new or recreated private repo starts with Dependabot alerts off (10 of
      the 12 fixed on 2026-11-12 were created after the 2026-09-14 sweep). Turn alerts on at repo
      creation (first-commit checklist, `security-and-privacy.md` §4, or the creation script) —
      2026-11-12, `audit-reports/github-security-2026-11-12-apply.tsv`.
- [ ] `scripts/security-audit.sh` §3 FAIL text names secret scanning, push protection and
      Dependabot alerts even when only one is missing; print the actions actually pending (TSV
      column 6) — 2026-11-12.
- [ ] `scripts/github-security-sweep.sh`: a private repo reporting secret scanning `disabled`
      (not `unavailable`) gets a PATCH that will likely fail on this plan; treat it like
      `unavailable` or add a stub test for it — 2026-11-12, read from the code, not reproduced.
- [ ] Pieter: `origin-backend-take-home-assignment` (public) had Dependabot alerts on 2026-10-25
      and off by 2026-11-01, cause unrecorded (re-enabled 2026-11-12). Check the repo's settings
      audit log if it matters — `audit-reports/github-security-2026-11-01.tsv`.
- [x] Audit §6: the recovery-codes file at the root of `~/dev` — into the password manager, then
      delete it (open since 2026-09-07; also in `~/dev/TODO.md`). **Done 2026-11-08** by Pieter;
      verified: no match on disk, and the live section-6 scan has no FAIL (D62).
- [ ] Pieter: regenerate the GitHub recovery codes (Settings → Password and authentication) so
      copies of the deleted file in backup history are useless — 2026-11-10,
      `docs/warnings-runbook.md` § secret file on disk, step 3.
- [x] Pieter's OK to commit D62 in the live checkout. `CHANGELOG.md`, `TODO.md`,
      `docs/design-decisions.md`, `docs/maintenance.md`, `scripts/security-audit.sh` and `test.sh`
      also hold another session's uncommitted D61 work, so either both go in together or my hunks
      are staged alone — 2026-11-10, D62. **Done 2026-11-11:** "commit and push all"; D61, D62 and
      D63 went in together on `gate-hardening` after a green `./test.sh`.
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

- [x] 2026-11-19 (D38): `pwd-gen` hardening review. (1) no `-I`, (2) unpinned wordlist,
      (3) clipboard never cleared → done 2026-11-19, D83. (5) no uniformity test → done, D82.
      (4) weak-output floor → now suggestion 3 below.
- [ ] 2026-11-19 (D83): live-check `pwd-gen --copy` on the real clipboard: paste works, the
      clipboard is empty after 30 s, and something copied in between survives. Also check whether
      the clear reaches Universal Clipboard on another Apple device. Record it in D83's `Verified:`.
- [ ] 2026-11-19 (`docs/pwd-gen.md` § Suggested changes): pick from the seven suggestions. They are:
      copy by default on a TTY, a concealed pasteboard type, a strength floor, a
      double-click-safe preset, `--copy` with `-n` > 1, `passwordrules` input, and site-safe
      passphrases. Each is its own change with a CHANGELOG line.
- [ ] 2026-11-19 (test-sh skill lint): `test.sh` has `set -u` but no `pipefail` (lint `strict`).
      Add `set -uo pipefail` as its own change, and check that no suite relies on a failing pipe
      stage being ignored. The lint's `cd-first`, `summary` and `step-what` FAILs are naming
      mismatches (`BASH_SOURCE`, the `════ summary` table, `suite_what`), so either teach
      `testsh-lint.sh` those names (skills repo) or rename here.
- [ ] 2026-11-16 (D77): confirm in a fresh session that the workflow skills load unasked (they are
      linked and their private repo is pushed). Open items for the skills themselves:
      `~/dev/skills/TODO.md`.
- [ ] 2026-11-16 (D77): this session's edits here (D77, the changelog line, `claude/dev-CLAUDE.md`,
      this file, `docs/SESSIONS.md`) are uncommitted, on a branch that already held other
      uncommitted work. Commit them with that work or on their own.
- [ ] 2026-11-16 (D77): `codex-agents-sync` is not on this branch (it is in the `dotfiles-wt-claude-md`
      worktree), so `~/.codex/AGENTS.md` was not rebuilt after the § Session workflow edit to
      `claude/dev-CLAUDE.md`. Re-run it once that branch lands.
- [ ] 2026-11-16 (D75): CI runs `./test.sh mobile`, but without the skill's npm deps and WebKit its audit
      and template cases skip, leaving only the static and simulator-stub cases. Add to `ci.yml`:
      `npm ci --prefix claude/skills/mobile-vetting` and
      `npx --prefix claude/skills/mobile-vetting playwright install --with-deps webkit chromium`. On Linux
      the Chrome lookup finds nothing and Playwright's Chromium is used. Then make a skip a failure under CI.
- [ ] 2026-11-16 (D75): `scripts/sync-dotfiles.sh restore` should create the
      `~/.claude/skills/mobile-vetting` symlink and run its `npm ci`. It was made by hand this session, and
      `init.sh` never writes into `$HOME`. Add a case to `scripts/test-dotfiles-setup.sh`.
- [ ] 2026-11-16 (D75): `scripts/ios-simulator.sh` has only run against stub `xcrun`. This Mac has no
      iPhone simulator runtime. Install one (Xcode → Settings → Components), run it on a real page, and
      check the boot, screenshot and shutdown steps.
- [ ] 2026-11-16 (D75): a new Claude Code session under `~/dev` lists `mobile-vetting` and loads it on its
      own for a UI change (trigger check), without being named. This session only saw it appear in the
      skill list.

- [ ] 2026-11-14: `scripts/test-dev-audit.sh` § 9 (full run against `~/dev`, fork exhaustion) passes no
      skip list. On CI, which has no `private/`, `dev-audit.sh` exits 2 at once, so the case passes without
      testing anything. Give it the fixture skip list, or skip it explicitly when `private/` is absent. Found
      while fixing the launchd cases' CI failure (`1fbf26b`).
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

### Byte-level comparison (planned 2026-11-13, waits for the branch merges)

Planned in session 2026-11-13. Pieter chose *merge first, then build*: `merge-originals` (D51,
`bin/originals` with SHA-256 manifests and `verify`) and `claude-md-reach` (D66) both rewrite the
files this work touches (`scripts/test-bin.sh`, `scripts/test-docs.py`, `docs/design-decisions.md`).
The merge itself is `~/dev/TODO.md` "merge dotfiles branch `claude-md-reach`" (2026-11-12, D66).
Byte-level checks already in place: `test-docs.py` synced checks (`read_bytes() ==`),
`test-bin.sh:755,760` (`cmp -s`), `test-entrypoints.sh:75`, `test-security-tools.sh:587`,
`test-dotfiles-setup.sh:156` and `sync-dotfiles.sh:340` (`diff -q`); `sync-dotfiles.sh:352` also
accepts a match after `expand_home_paths`, which is weaker than "in sync" suggests.

- [ ] `scripts/test-docs.py` synced hints always say "copy the repo file to the live one". When the
      live file is the newer one (as `~/dev/CLAUDE.md` vs `claude/dev-CLAUDE.md` was on 2026-11-13),
      following that hint deletes the newer rules. Make the hint say which side is newer, show the
      first differing line, and name the copy in the right direction. The check itself stays
      byte-exact. Add a test with `DEV_CLAUDE_MD` pointing at a newer fixture. After both merges —
      2026-11-13
- [ ] `bin/same`, a read-only comparison tool (bash 3.2): `same A B` (lstat type, size, `cmp`;
      names CRLF/BOM/final-newline/whitespace-only differences), `-r` trees (`.git` skipped), `--meta`
      (mode, flags, xattr names), `--nfc` (NFC/NFD name clashes), `--dupes DIR…` (size → SHA-256 → `cmp`,
      hardlinks reported as already linked, never deletes). No manifest mode: that is
      `originals verify`'s job. Tests in their own file or in `test-bin.sh` after the merge; decision
      entry rejecting `fdupes`/`jdupes` (extra dependency, delete modes). After `merge-originals` —
      2026-11-13
- [ ] Hash-check the irreplaceable gitignored data in `~/docs/.backup/dev-includes.txt`.
      `backup_docs.py` runs `rclone check`, which compares local and remote as they are now, so a
      silent local change is synced and passes. Decide whether `originals verify` covers it (move or
      adopt the data into `originals_read_only/`) or whether a manifest is needed for paths that
      can't move (the memorial repo is do-not-touch: nothing may be written inside it). Record it
      as `~/docs/BACKUP.md` D24. After `merge-originals` — 2026-11-13
- [ ] `projects/media` verify checks only the size of each S3 object (`backup-media-to-s3.sh`
      verify block). Content proof is a single sampled file, through `restore-drill.sh`. Option:
      upload with `--checksum-algorithm CRC64NVME` (aws-cli 2.40 already checks in transit by
      default) and compare `head-object --checksum-mode ENABLED` with a local CRC64NVME for every
      key; fallback is presence only, with content proof left to the drill. Waits until the 12
      uncommitted files in `projects/media` (seen 2026-11-13) are committed; the item moves to
      media's `TODO.md` then — 2026-11-13
- [ ] `scripts/claude-md-check.py` on `gate-hardening` reports 3 FAIL in `claude/CLAUDE.md`: gh 2.103
      vs 2.104.0, Docker Compose 5.6 vs 5.7.1, Supabase CLI 2.122 vs 3.1.0. The live
      `~/.claude/CLAUDE.md` already has 5.7 and 3.1 (newer, likely from `claude-md-reach`). Re-run
      after the merge, then `--apply` whatever is still stale — 2026-11-13

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
- [x] `./test.sh pwdgen` (`scripts/test-pwd-gen.py`) is flaky: it failed once in a full
      `./test.sh` run on 2026-11-04, then passed three runs in a row and on the committed tree. It
      is probably a randomness-dependent assertion. Find it and make it deterministic. Added 2026-11-04.
      → Likely cause, 2026-11-12 (read from the code, not reproduced): the EFF list holds four
      hyphenated words (`drop-down`, `felt-tip`, `t-shirt`, `yo-yo`) and the default separator is
      `-`, so `test_passphrase_from_shipped_list` (splits on `-`, expects 6 parts) and
      `test_separator_flag` (asserts no `-`) fail when one is drawn, about 0.5% of runs. It is
      also a product bug: a six-word passphrase can read as seven. Left out of D64 at Pieter's
      choice.
      → Done 2026-11-12 (D65): `pwd-gen` no longer draws a word that contains the separator;
      cause reproduced with a half-hyphenated list, suite passed 15 runs in a row.

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
- [ ] Sun 2026-11-15 10:00 — first scheduled audit with section 9 *Local model lineup*: check
      `~/dev/audit-reports/security-audit-2026-11-15.md` § 9 (one line per lineup role) and
      `model-versions-2026-11-15.md` beside it, and that a markup change on ollama.com shows as
      "check incomplete", not as "nothing newer". Record it in D61's `Verified:` — 2026-11-10, D61
- [ ] Pieter: push `83830af` (SESSIONS note on the 2026-11-19 ship of D79/D80) on `daily-report`, or leave it for the next push, 2026-11-19 — docs/SESSIONS.md 2026-11-17 (evening)
