# `dev-audit` — read-only audit of every git repo under `~/dev`

`dotfiles/scripts/dev-audit.sh`. Run it with `dotaudit`.

One command that walks all ~91 git repos under `~/dev` and reports what is
broken, drifting, exposed, or at risk of being lost. It changes nothing.

---

## Why this exists

This is not a new capability. It is the *repeatable* version of an audit that
had already been run three times by hand, each time producing a markdown
snapshot that went stale the day it was written:

| Hand-run audit | What it cost | What it found |
|---|---|---|
| `~/dev/WORKSPACE_AUDIT_2026-09-01.md` | a full session | 13 repos with no `.gitignore`, 53 with gaps, 56 dirty trees, 4 repos with local-only commits, 13.7 GB of rebuildable dirs |
| `~/dev/LICENSING.md` | a full session | license state across 150 GitHub repos |
| `~/dev/projects/PROJECTS_META_NOTES.md` | a full session | CI coverage — an appendix in exact machine format that no script produced |

`~/dev/DOCS.md` files all three under *"Audit records — point-in-time, not
maintained."* That phrase was the problem. `BACKUP_AUDIT_2026-09-06.md` §13
named the missing piece directly: *"Add a `git-hygiene.sh`."*

Everything checked here is **already a rule in `~/dev/CLAUDE.md`**. The only
thing that changes is that checking takes 70 seconds instead of an afternoon,
so drift is caught in days rather than months.

---

## Usage

```bash
dotaudit                        # everything, writes a dated report
dotaudit --only privacy         # one category: git | policy | privacy | disk
dotaudit --github               # also fetch public/private from GitHub (see below)
dotaudit --history              # also scan git history, not just HEAD (slow; see below)
dotaudit --no-report            # terminal only, write nothing
dotaudit --out /some/dir        # report somewhere other than ~/dev/audit-reports/
dotaudit --quiet                # report file only, no terminal output
```

Exit status: `0` clean, `1` at least one FAIL, `2` bad usage, `3` refused to
write findings into a git repo.

`WARN` alone does not fail the run, so this is safe to put behind a scheduler
without it crying wolf about dirty working trees.

### Why `--github` matters

Without it, the tool cannot tell a public repo from a private one, and the
checks that only matter for public repos (an email address, a home path, an
ssh config) soften from FAIL to INFO rather than guessing. With it, one bulk
`gh repo list` call is cached for the run. It never uploads anything.

### Scoping the gitleaks pass, and why you will need to

A full-history `gitleaks` sweep across all ~115 repos **does not complete on this
machine.** Attempted three times on 2026-09-07; it ran 20+ minutes and was killed by
the OS for exhausting memory. Two repos here have 30 GB+ working trees.

The failure mode matters more than the fact: a scanner killed halfway produces
**nothing**, which in a report is indistinguishable from a clean result. So scope it and
state the boundary, rather than asking for everything and getting nothing:

```bash
# The high-value slice: public repos only, bounded, skipping the giants.
GITLEAKS_PUBLIC_ONLY=1 GITLEAKS_MAX_GIT_MB=300 GITLEAKS_TIMEOUT=90 \
  dotaudit --github --history --only privacy
```

| Env var | Default | Effect |
|---|---|---|
| `GITLEAKS_PUBLIC_ONLY` | `0` | Scan only repos GitHub reports as public. Needs `--github`. |
| `GITLEAKS_MAX_GIT_MB` | unset | Skip repos whose `.git` exceeds this, reporting `gitleaks-skipped`. |
| `GITLEAKS_TIMEOUT` | `300` | Per-repo bound, reporting `gitleaks-timeout`. |
| `DEV_AUDIT_NO_GITLEAKS` | `0` | Skip the pass entirely. For the test suite. |

Whatever you exclude is **unmeasured, not clean.** The `gitleaks-skipped` and
`gitleaks-timeout` findings exist so that distinction survives into the report instead of
living in someone's memory.

### Why `--history` matters

Added 2026-09-07. Every other privacy check reads `git ls-files`, which is
`HEAD` — so a secret that was committed and later deleted is invisible to them
while remaining fully present in history and, on a public repo, fetchable by
anyone. `--history` walks `git log --all --diff-filter=A` for paths that once
existed and no longer do, and puts `gitleaks` into full-history mode.

It is off by default because it walks every commit in every repo. Findings are
prefixed `history-` so they never blur with a currently-tracked file.

A history finding is **not** fixable by deleting the file. It needs either a
history rewrite (`git filter-repo`), or — usually cheaper and always the first
question — treating the credential as disclosed and rotating it.

---

## Severity

| | Meaning |
|---|---|
| **FAIL** | Work or data at risk, or a stated rule broken. Act on these. |
| **WARN** | Drift worth fixing, no immediate risk. |
| **INFO** | Inventory, not a problem. Dirty working trees live here on purpose — a dirty tree is normal mid-task and only matters in aggregate. |

---

## The checks

### `git` — is the work safe, and is it anywhere but this laptop?

| Check | Sev | What it means |
|---|---|---|
| `no-remote` | FAIL | No git remote. This disk is the only copy. |
| `unpushed` | FAIL | Commits exist only on this machine. |
| `no-upstream` | WARN | Current branch tracks nothing. Normal on a fork's local branch. |
| `stale-lock` | WARN | A leftover `.git/index.lock` blocks every git command in that repo. Reported, never deleted — if a git process really is running, removing it corrupts the index. |
| `git-bloat` | WARN | `.git` over 100 MB. |
| `never-gcd` | WARN | Over 5,000 loose objects. `git gc` would repack. |
| `not-a-repo` | WARN | A directory under `projects/` with no git repo: no history, no remote, no backup. |
| `dirty-tree` | INFO | Uncommitted paths. |
| `behind` | INFO | Behind upstream. |
| `stale-branches` | INFO | Merged branches untouched 90+ days. |

### `policy` — the rules in `CLAUDE.md`

| Check | Sev | `CLAUDE.md` rule |
|---|---|---|
| `no-license` | FAIL on public | *"Public repo ⇒ LICENSE file, in the first commit."* A public repo with no LICENSE is all-rights-reserved. |
| `copyright-drift` | WARN | *"Canonical copyright line: `Copyright (c) <year> Pieter de Jong`."* Catches the existing "Peter" / "Pieter Arthur" drift. |
| `license-mismatch` | WARN | *"Keep the manifest field and the LICENSE file in agreement."* Catches `npm init -y`'s `"ISC"` default. |
| `no-gitignore` | FAIL | *"Every project should have a `.gitignore` before the first commit."* |
| `gitignore-gaps` | WARN | The baseline set is missing. Tested with `git check-ignore` — what git actually does — not by grepping the `.gitignore` text, which misses negations and directory scoping. |
| `no-ci` | INFO | No `.github/workflows`. Informational: `CLAUDE.md` does not require CI everywhere. |

Forks are skipped for this whole category. `CLAUDE.md`: *"Never relicense a
fork or an upstream clone."*

### `privacy` — what got committed that should not have been

Implements the `CLAUDE.md` § Security & privacy checklist.

| Check | Sev | What it means |
|---|---|---|
| `env-file`, `private-key`, `ssh-key`, `shell-history`, `aws-credentials` | FAIL | A file of that shape is **tracked**. |
| `service-account-json`, `private-key-block`, `github-token`, `aws-access-key`, `openai-key`, `slack-token`, `google-api-key` | FAIL | Secret-shaped **content** in a tracked file. |
| `ssh-config` | FAIL on public | A tracked ssh config with a real hostname or account name. |
| `home-path` | FAIL on public | Absolute `/Users/…` paths in tracked files. |
| `email` | FAIL on public | A real email address in a tracked file. The `…@users.noreply.github.com` form is excluded — that is the fix `CLAUDE.md` recommends, not a leak. |
| `secret-assignment` | WARN | A tracked file assigns a quoted literal of 8+ characters to a `key`/`secret`/`token`/`password`-shaped name. This is the `CLAUDE.md` "grep for `api[_-]?key\|secret\|token\|password`" rule, narrowed to the shape that indicates a committed *value* — the bare grep matches ordinary code in most repos and would bury the rules above it. Placeholders (`${VAR}`, `<fill-me>`, empty) do not match. WARN because it is a heuristic. |
| `committer-email` | FAIL on public | Commits carry a non-`noreply` committer address. `CLAUDE.md`: a public repo "permanently publishes the committer's name and email to anyone, including scrapers," and it cannot be scrubbed without rewriting history. Counted over the whole history, because that is what is published. The address is never printed. |
| `history-*` | FAIL | `--history` only. A path matching one of the tracked-file rules was committed at some point and is no longer in `HEAD`. Still in history, still fetchable. |
| `gitleaks` | FAIL | `gitleaks` reported findings. Run with `--redact` so the report never carries the value; rerun by hand to see them. Its ~150-rule default set covers what the seven hand-written content rules do not: Anthropic, Stripe, Twilio, SendGrid, HuggingFace, database URLs with embedded passwords, JWTs, generic high-entropy strings. |
| `gitleaks-skipped` | WARN | A repo's `.git` exceeded `GITLEAKS_MAX_GIT_MB` and **was not scanned**. Same principle as `gitleaks-timeout`: an unscanned repo must never be silently indistinguishable from a clean one. |
| `gitleaks-timeout` | WARN | A repo's gitleaks scan exceeded `GITLEAKS_TIMEOUT` (default 300s) and **was not scanned**. Reported rather than skipped silently, because an unscanned repo and a clean repo must never look the same. Needs `timeout`/`gtimeout` on PATH; without one, the bound is skipped. |
| `gitleaks-absent` | INFO | `gitleaks` is not installed; the content rules above are the fallback. |

### `disk` — what is large, and what has no copy anywhere else

| Check | Sev | What it means |
|---|---|---|
| `no-offmachine-copy` | FAIL | No remote, or a remote the current branch was never pushed to. Closes the loop with `BACKUP_AUDIT_2026-09-06.md` §5, *"`~/dev` is not backed up at all."* |
| `large-files` | WARN | Files over 100 MB — GitHub's hard limit, and history never shrinks once pushed. |
| `large-repo`, `dep-dirs` | INFO | Working trees over 500 MB; rebuildable dependency dirs. Each project's `init.sh` recreates these, so the space is reclaimable rather than lost. |

---

## Design rules

These are load-bearing. Keep them if you extend this.

### 1. It never writes to a scanned repo

No commits, no pushes, no `git gc`, no `.gitignore` patching, and **no
`--fix` mode**. 91 repos is too many to let a script loose in.

Every git call goes through `git_ro()` in `audit/lib.sh`, which passes
`--no-optional-locks`. That flag is not decoration: the hand-run sweep on
2026-09-01 left a stale `.git/index.lock` in **92 repos**, blocking every
subsequent git command in them until they were moved to `_to_delete/`. A
read-only audit must not be able to do that. `git_ro()` is also the single
choke point that makes "this cannot write to your repos" verifiable by reading
one function instead of auditing every call site.

To verify after a run:

```bash
touch /tmp/stamp && dotaudit --no-report
find ~/dev -newer /tmp/stamp -not -path '*/.git/*' -not -path '*/node_modules/*'
find ~/dev -name index.lock -newer /tmp/stamp | wc -l   # expect 0
```

### 2. Findings never quote the matched value

A secret hit reports the file and the rule that fired — `creds/prod.json —
matched rule: service-account-json` — and stops. The report is written to disk
and may be read on a screen, pasted into a chat, or committed by accident; it
must not become a second copy of the secret. This is why nothing in
`30-privacy.sh` uses `grep` without `-l` or `-q`.

### 3. Reports live outside this repo

`dotfiles` is **public**. A report saying "repo X has a tracked `.env`" is a
targeting aid, so it must never be published.

Default output is `~/dev/audit-reports/`. `~/dev` is not a git repo, so
anything there is inherently local-only — the same reasoning that keeps
`~/dev/DATA_PRIVACY.md` out of `dotfiles`.

Three guards, because one is not enough:

1. `dev-audit.sh` **refuses to run** if the output directory is inside any git
   repo (exit 3). Checked at runtime, not trusted to the default.
2. Report and TSV are written `chmod 600`.
3. `.gitignore` covers `reports/`, `audit-reports/`, `*.report.md`,
   `findings-*.tsv` and `audit-????-??-??.md` as a second layer.

### 4. Tracked files only, unless you ask for history

Everything in `30-privacy.sh` goes through `git ls-files`. An untracked `.env`
in a working tree is correct and normal; a **committed** one is the incident.
Scanning the working tree would bury the real signal under every project's
local config.

The deliberate exception is `--history` (added 2026-09-07), which reads history
rather than the working tree — the opposite direction from "scan everything on
disk," and the one place where `HEAD` genuinely is not enough.

**Know what this rule costs you.** A file that is untracked *today* and one
`git add -A` away from being published is invisible to every check here. That is
not hypothetical: `docs/security-review-2026-09-06.md` — a report quoting this
repo's own real hostname, account name and email as evidence — sat untracked and
un-gitignored in this public repo, and no run flagged it. The scanner's scope and
the risk's scope are not the same set. Read `git status` before a broad `git add`;
no tool here does it for you.

---

## Gotchas

**Do not put `secret`, `token`, `password`, `credential` or `api_key` in a
filename here.** `dotfiles/.gitignore` ignores all of those as glob patterns,
so git would silently refuse to track the file and it would vanish on the next
clone. This is why the privacy module is `30-privacy.sh` and not
`30-secrets.sh`:

```
$ git check-ignore -v audit-secrets.sh
.gitignore:11:*secret*   audit-secrets.sh
```

`dottest` asserts this, so it cannot regress.

**bash 3.2.** macOS still ships `/bin/bash` 3.2, so: no associative arrays, no
`mapfile`/`readarray`, no `${var,,}`. The Debian test container runs bash 5;
both have to work.

**`CAT` is function-local, deliberately.** `dev-audit.sh` sources every module
before running any of them, so a module-level `CAT=disk` global would overwrite
every other module's category — which it did, silently filing all 344 findings
under `disk`. Each `audit_*` function declares `local CAT=…` instead; `local`
is dynamically scoped in bash, so the `check_*` helpers still see it.

**Counters and subshells.** `finding()` increments `N_FAIL`/`N_WARN` in the
main shell. Any loop that calls it must use `done < <(…)`, never a pipe — a
pipe puts the loop in a subshell and the counts are lost.

---

## Files

```
scripts/dev-audit.sh              entrypoint: args, discovery, dispatch, summary
scripts/audit/lib.sh              git_ro(), finding(), repo discovery, skip list
scripts/audit/skiplist.conf       do-not-touch repos and forks, with reasons
scripts/audit/10-git-hygiene.sh
scripts/audit/20-policy.sh
scripts/audit/30-privacy.sh
scripts/audit/40-disk.sh
scripts/audit/render-report.sh    TSV -> markdown; separate so an old TSV can
                                  be re-rendered without re-running the sweep
```

Outputs, per run, in `~/dev/audit-reports/`:
- `findings-YYYY-MM-DD.tsv` — `severity, category, repo, check, detail`
- `audit-YYYY-MM-DD.md` — the same, rendered

## Testing

```bash
./scripts/test-dev-audit.sh            # 36 assertions
./scripts/test-dev-audit.sh --verbose  # show the findings behind a failure
dottest                                # the dotfiles suite also covers this tool
```

This tool walks ~91 real repos, so its safety properties cannot be tested by
running it against the real workspace and hoping. `test-dev-audit.sh` builds a
throwaway `DEV_ROOT` of fixture repos with deliberate defects — a committed
`.env`, an AWS-key-shaped string, a wrong copyright holder, a manifest that
disagrees with its LICENSE, a published `ssh/config`, a repo that must be
skipped entirely — and asserts on what the audit reports and, more
importantly, on what it did not touch.

What it covers:

| # | Asserts |
|---|---|
| 1 | **Read-only.** No file under the scanned root changed; no `index.lock` left; `git_ro()` passes `--no-optional-locks`; no mutating git subcommand is invoked anywhere in the sources — with a self-check proving that detector can actually fail. |
| 2 | Each check fires on a known-bad fixture. |
| 3 | No false positives: a correct repo (with a real remote, pushed) produces zero FAILs, and test fixtures containing `john.doe@example.com` are not reported. |
| 4 | The `skip:` list is honoured — a do-not-touch repo with a tracked `.env` produces **no** findings at all. |
| 5 | **No fixture secret value appears** in the TSV or the rendered report. |
| 6 | Report is `chmod 600`, and the tool exits 3 rather than writing findings into a git repo. |
| 7 | Exit codes: 1 on FAIL, 2 on bad usage. |
| 8 | Every category produces output — the regression that caught the `CAT` global collision. |
| 9 | A full run against the real `~/dev` completes with no fork/resource errors — the regression that caught the `Bus error`. |
| 10 | Portability: everything parses; no bash 4+ features; no GNU-only flags. |
| 11 | The `.gitignore` naming trap: no audit source is ignored, and all output patterns are. |

Tests 8 and 9 exist because both bugs were real and both failed *silently* —
the first filed all 344 findings under `disk`, the second made the disk module
report nothing at all while the run appeared to succeed. Neither would have
been caught by checking the exit code.

## Adding a check

1. Add it to the module for its category as a `check_*` function.
2. Call `finding SEV "$CAT" "$name" <check-name> "<detail>"`. Never put a
   matched value in `<detail>`.
3. Use `git_ro` for every git call.
4. Document the row in the table above — a check nobody can interpret gets
   ignored.

## Excluding a repo

Edit `private/audit/skiplist.conf` — the real list names repos, so it lives in
the private companion repo; `scripts/audit/skiplist.example.conf` shows the
shape. If the private file is missing the audit refuses to run rather than
silently dropping a skip. Format `<mode>:<repo>:<reason>`:

- `skip:` — excluded entirely; no git command ever runs in it. Reserved for
  do-not-touch repos, where running anything at all is the problem. The report
  prints `SKIP <name> (<reason>)` so the absence is visible rather than silent.
- `fork:` — excluded from **policy** checks only, since reshaping or
  relicensing someone else's repo is against `CLAUDE.md`. Still gets git
  hygiene, privacy and disk checks, which are about this machine.

## Not in scope

Deliberately separate, each its own decision:

- **Fixing anything.** See design rule 1.
- **Cache cleanup.** That is `weekly-disk-cleanup.sh`, which is scheduled and
  destructive by design. This tool is neither.
- **Scheduling.** Not wired to launchd. Run it when you want an answer; a
  weekly `--quiet` job is a reasonable later step, and the exit code supports it.
- **Repos that are not checked out here.** The sweep is `~/dev`. As of
  2026-09-07 there are 153 repos on GitHub and 115 under `~/dev`, so roughly 61
  — most of them public — are outside every check in this tool. Enumerate them
  with `gh repo list` before calling any audit complete.
- **Dependency and supply-chain vulnerabilities.** No `npm audit`, `pip-audit`,
  or Dependabot anywhere in the workspace.
- **Static analysis of your own code.** The single CodeQL workflow present
  belongs to a fork.
- **Deployed surfaces.** What Vercel and GitHub Pages actually serve is not
  checked; a repo going private does not by itself retract a published page.
- **GitHub account posture.** Branch protection, push protection, deploy keys,
  PATs, webhooks, OAuth grants.
- **Anything outside a git repo.** `~/dev` is not a repo, so loose files sitting
  in it are invisible here. That is not hypothetical: a plaintext credential
  file sat in `~/dev` for over a year without any run noticing.
- **Data classification.** These rules find secret-*shaped* strings. They have
  no notion of whether a tracked CSV or `.db` holds personal data. See
  `docs/policy/security-and-privacy.md` § Data tiers for that procedure.
