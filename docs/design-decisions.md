# Security & privacy design decisions

Why the commit/push gate, the weekly audit and the public/private split are
built the way they are. Each entry: the problem, the decision, what was rejected,
and what it costs. Dated entries are appended, never rewritten — a later decision
supersedes an earlier one by number.

The rules themselves live in [`policy/security-and-privacy.md`](policy/security-and-privacy.md).
Decisions that name a specific repo or exposure are recorded in the private
companion repo (`private/DECISIONS.md`), not here.

---

## D1 — Enforce at commit and push time, not only by audit · 2026-09-14

**Problem.** Every protection that existed was after the fact: a read-only audit run
by hand, and CI in one repo. Nothing on the machine stood between `git add -A` and a
public remote — including the dotfiles backup command, which commits and pushes
automatically.

**Decision.** A gate runs on every commit and every push in every repo on this
machine, and blocks. Audits remain, as the second line.

**Rejected.** Audit-only (finds leaks after they are public, when "delete it" no longer
works). Per-repo hooks (11 of ~120 repos had any; a new repo starts with none).

**Cost.** Every commit pays a scan (measured: ~0.2 s typical, 200 files well under 5 s).

## D2 — Install as git config-based hooks, not `core.hooksPath` · 2026-09-14

**Problem.** A global `core.hooksPath` replaces each repo's own hook directory. Tested
against this workspace it would have silently disabled the hand-written hooks in four
repos, never run at all in seven repos that set their own `core.hooksPath` (a local
setting wins), and made `pre-commit install` refuse to work.

**Decision.** Register two `[hook "<name>"]` entries in `~/.gitconfig` (git 2.54+).
Verified on throwaway repos before building: the config hook runs first, the repo's own
hook (`.git/hooks` or its `core.hooksPath`) still runs after it, both receive pre-push's
stdin, `~` expands, a failing config hook blocks, and `--no-verify` skips both.

**Rejected.** Global `core.hooksPath` with a dispatcher that chains to each repo's hooks
(fragile; still loses to a repo-local `core.hooksPath`). `init.templateDir` (only affects
new clones, and writes into each repo).

**Cost.** Apple's `/usr/bin/git` (2.50) ignores config hooks. Mitigated: Homebrew git first
on PATH (checked by `gate.sh status`), editors pinned to it via `git.path`, the assistant
guard denies `/usr/bin/git`, and GitHub push protection catches secrets server-side.

## D3 — One gate script, referenced in place · 2026-09-14

**Decision.** `~/.gitconfig` points at `~/dev/dotfiles/security/gate.sh` directly; nothing
is copied into repos or into `~`. An update to the gate applies to every repo at once. If
the script is missing, git fails the hook and the commit is blocked — fail closed, and
`gate.sh status` says why.

**Rejected.** Copy-on-restore like the rest of dotfiles (a stale copy would keep enforcing
old rules without any sign).

## D4 — Secrets always block; personal data blocks only on the way to public · 2026-09-14

> **Superseded in part.** Personal data now blocks at commit in a repo that is already public
> ([D19](#d19--personal-data-blocks-the-commit-once-a-repo-is-public--2026-09-22)), and on every push
> to GitHub, private repos included, unless the repo is listed as a personal-data repo
> ([D24](#d24--nothing-reaches-github-unchecked-the-gate-enforces-the-repo-standards--2026-09-26)).
> The table below is the original decision; the current rules are in policy §2.

**Problem.** Home paths, emails and phone numbers are routine in private repos and personal
tooling; blocking them everywhere trains the habit of bypassing. The same values in a
public repo are published permanently.

**Decision.**

| Rule | commit | push → private | push → public / unknown |
|---|---|---|---|
| secret (gitleaks), key/credential files, file > 50 MB, `private/` in dotfiles, scanner missing | block | block | block |
| home paths, real emails, phone numbers, exact private values, non-noreply author | warn | warn | block |

Warnings at commit time mean the problem is seen early, while it is cheap to fix.

**Rejected.** Warn-only (relies on attention at the worst moment). Block-everything (false
positives on private personal-data repos; bypass fatigue).

## D5 — Unknown visibility is treated as public · 2026-09-14

**Decision.** Remote visibility comes from `gh repo view`. Offline, unauthenticated,
non-GitHub, or any error ⇒ PUBLIC. Answers are cached asymmetrically: public for 24 h,
private for 1 h, so a repo flipped to public is noticed within the hour.

**Cost.** A push while offline to a private repo that carries personal data needs the
logged bypass.

## D6 — gitleaks as the scanner, with one shared rule set · 2026-09-14

**Decision.** gitleaks' default rules (hundreds of providers) are the secret scanner; the
gate, the audit and CI all pass `security/gitleaks.toml` explicitly, so a repo's own
`.gitleaks.toml` cannot allowlist its way past the gate. File-name and personal-data rules
live once in `security/patterns.sh`, sourced by both the gate and dotaudit — they cannot
drift apart.

**Rejected.** The hand-maintained regex list dotaudit started with (7 providers; kept only
as its fallback). trufflehog / detect-secrets (not installed; no clear gain for this use).

**Cost.** Inline `gitleaks:allow` comments are still honored — an escape hatch visible in
review, standard across tools.

**Amended the same day, after the template rollout exposed two gaps.** (1) gitleaks' default
config allowlists dependency lockfiles by path, so `gitleaks git` never reads them; the gate
now pipes added lockfile lines through `gitleaks stdin`, which has no path to allowlist. The
same lockfiles are exempt from the personal-data rules, because they embed third-party
maintainers' addresses nobody here can change. (2) File-name rules had inherited the broad
"path contains test/fixture/mock/spec" exemption meant for personal data, which let
`.env.test` through; they now exempt only `.example` / `.template` / `.sample` suffixes. A
sweep of every local repo found no tracked file that had slipped through.

## D7 — The bypass is explicit, reasoned and logged · 2026-09-14

**Decision.** `SECURITY_GATE_BYPASS="<reason of 10+ characters>"` downgrades blocks to
warnings for one command and appends time, repo, event, rules and reason — never the
matched values — to `~/.local/state/security-gate/bypass.log` (mode 600, outside every
repo). The weekly audit lists every bypass. A `security-gate:allow` marker on a line
silences personal-data rules for that line only, never secret rules.

**Rejected.** `--no-verify` as the escape (silent and unrecorded; it still works, but it is
not sanctioned and the assistant is denied it). An allowlist file per repo (drifts,
invisible in review).

## D8 — Findings never contain the matched value · 2026-09-14

**Decision.** Gate output, audit reports and logs name the rule and the file. The value
itself is never printed — output gets pasted into chats, terminals get screen-shared,
reports get committed by accident. Tests assert this with runtime-generated secrets.

## D9 — Public doctrine, private registers, one place on disk · 2026-09-14

**Problem.** The policy was spread over ~40 files with the same rules repeated up to seven
times, and the "generic in public, specific in private" split had already leaked:
uncommitted edits in the public repo named a client organisation, and an untracked report
quoting real values sat one `git add -A` away from publication.

**Decision.** `dotfiles` (public) holds all generic rules, code and tests. `dotfiles/private/`
is the private companion repo cloned in place: registers of findings, do-not-touch list,
per-repo state, dated reports, decisions that name real repos, the audit skip list and the
exact personal values the gate looks for. Four independent layers keep `private/` out of
the public repo: `.gitignore` (`/private/`), the gate at commit, the gate at push, and a
CI job that fails if `private/` or any gitlink is tracked or ever appeared in history.

**Rejected.** Making dotfiles private (does not retract what was already public; loses the
public reference). A git submodule (the submodule URL and pointer would themselves be
published). Deleting the registers (loses the audit trail).

## D10 — Exact personal values exist only in the private repo · 2026-09-14

**Decision.** Public patterns describe shapes (`/Users/<name>/`, an email, a phone number).
The literal values the gate must never let out — the personal email, real hostnames and
account names — live in `private/security/personal-patterns.conf`, loaded when present.
A public file that contains the value it guards against has already published it.

## D11 — Fix forward; no history rewrites · 2026-09-14

**Problem.** Some values are already in public git history (committer email across many
repos; an SSH target in dotfiles).

**Decision.** Stop the accrual (noreply identity, gate, redaction on backup), rotate or
harden what leaked, and leave history alone.

**Rejected.** `git filter-repo` + force-push: published history has already been cloned,
forked, cached and indexed, so a rewrite does not retract it — it only breaks every clone
and every link to a commit, and gives a false sense of closure.

## D12 — The free stack instead of paid GitHub Secret Protection · 2026-09-14

**Problem.** GitHub secret scanning and push protection are free for public repos but, for
private repos, require the paid Secret Protection add-on, sold only to organizations on a
paid plan.

**Decision.** Private repos are covered by the local gate (every commit and push), gitleaks
in CI, and the weekly audit's full-history scan.

**Residual risk, accepted.** A private-repo push made with `--no-verify` reaches GitHub
unscanned; CI flags it on that push and the weekly audit within seven days. Revisit if
private repos gain other committers.

## D13 — GitHub settings are swept, not committed · 2026-09-14

**Decision.** `scripts/github-security-sweep.sh` enables secret scanning + push protection
(public) and Dependabot vulnerability alerts (all) on every owned, non-fork, non-archived
repo — through the settings API only. Dry run by default; `--apply` changes; `--check` is
what the weekly audit runs. Repos on the private skip list are never queried. Dependabot
*update PRs* stay off: they would be commits.

**Rejected.** A bulk commit of CI files to ~120 repos in one sweep (large blast radius,
touches repos with uncommitted work). CI is added per repo instead — see D14.

## D14 — gitleaks in CI is the standard for every repo · 2026-09-14

**Decision.** Every repo's CI calls the reusable workflow
`pieteradejong/dotfiles/.github/workflows/gitleaks-reusable.yml`: full history, the shared
rule set, gitleaks downloaded from the official release and verified against a pinned
SHA-256, redacted logs, `contents: read` only. It is added when a repo is created (templates
ship it) or next touched, never to do-not-touch repos, forks or upstream clones.

**Why a reusable workflow.** One place to bump the version or rules; three lines in each repo.

**Why not the marketplace action.** Running the verified binary directly keeps the config
explicit and avoids a third-party action's runtime behaviour.

## D15 — A weekly local audit, reports outside git · 2026-09-14

**Decision.** `scripts/security-audit.sh` runs from launchd every Sunday at 10:00 (once on
wake if the Mac slept through it): gate intact, dotaudit over every local repo (full
history in the first week of each month), GitHub settings drift, GitHub repos with no local
clone (mirrored into `~/.cache/security-audit/` and scanned), bypasses, credential-shaped
files outside version control, and the account's SSH keys. One report in
`~/dev/audit-reports/` (never inside a git repo, mode 600), a notification with counts only,
exit 1 on any FAIL.

**Rejected.** A cloud or GitHub Actions schedule (the report names exposures; it must stay
on this machine). Scanning only cloned repos (tens of public repos had never been checked).

## D16 — The assistant cannot switch the gate off · 2026-09-14

**Decision.** A Claude Code `PreToolUse` hook (`claude/hooks/guard-git-bypass.sh`) denies
commands that skip or reconfigure the gate: `--no-verify` (and its abbreviations),
`git commit -n`, `core.hooksPath`, `hook.*` settings, `GIT_CONFIG_*` overrides,
`SECURITY_GATE_*`, `HOME=… git`, `/usr/bin/git`. Quoted text is ignored so a commit message
that mentions a flag is not mistaken for one.

**Scope, stated plainly.** A guardrail against an assistant taking a shortcut — not a
sandbox. A person at the terminal can still do any of these deliberately.

## D17 — One test entry point, secrets generated at runtime · 2026-09-14

**Decision.** `./test.sh` runs shellcheck, the gate suite, the tools suite (guard hook,
sweep, weekly audit, dotaudit gate module) and the dotaudit suite; CI runs exactly that on
macOS so bash 3.2, BSD userland and git 2.54+ are what is tested. Fixture secrets are
generated from `/dev/urandom` at runtime, so the repo contains nothing secret-shaped for its
own scanners to trip on, and every suite asserts that no generated value ever appears in
output.

## D18 — `bin/` on PATH, run in place; `scripts/` stays off PATH · 2026-09-22

**Decision.** Commands meant to be typed live in `bin/`, which is the single `PATH` entry
(`shell/.zshrc`). Tooling for this repo — `sync-dotfiles.sh`, `dev-audit.sh`, the `test-*.sh`
suites — stays in `scripts/`, which is deliberately not on `PATH`. `bin/` files are executed
straight out of the repo with no live copy in `~`, joining `scripts/mac-maintenance.sh` as an
exception to this repo's copy-based model.

**Why.** The predecessor was `~/dev/projects/scripts/`: on `PATH`, not a git repo, nothing in
it versioned anywhere. A copy of `weekly-disk-cleanup.sh` had been taken into `scripts/` as a
"backup" and had already drifted from the live one that launchd actually ran — the repo copy
was 92 lines to the live script's 191. A copy that is never executed is a copy nobody notices
is wrong. Running in place removes the second copy entirely, so drift has nowhere to live.

**Why not `scripts/` on PATH instead.** It would turn `sync-dotfiles.sh`, `dev-audit.sh` and
five test suites into global commands, and make `test-bin.sh` shadowable by anything earlier
in `PATH`. The two directories answer different questions — "what can I type?" versus "what
maintains this repo?" — and only the first belongs on `PATH`.

**Rejected.** Keeping `llm` in a private repo because its reference doc lived there. This
repo is the public account of the dev workflow, and `llm` — loopback-only, refusing to read
any `*_API_KEY` — is part of that account. The doc was rewritten self-contained as
[docs/llm.md](llm.md); only machine-specific daemon lockdown detail stays private.

**Verified.** `./test.sh` — all seven suites pass, including the new `zsh-syntax` and `bin`
suites. `env -i … zsh -i -l -c 'whence -p llm'` resolves to `bin/llm` in a clean login shell.
`launchctl list` shows the agent loaded against the new path.

## D19 — Personal data blocks the commit once a repo is public · 2026-09-22

**Decision.** `cmd_pre_commit` resolves `origin`'s visibility and sets `STRICT_PERSONAL=1` on
a definite `PUBLIC`, so a home path, email or phone number is a BLOCK at commit time in a repo
that is already public, not only at push.

**Why.** Previously `STRICT_PERSONAL` was set only in `cmd_pre_push` and `cmd_scan_tree`, so
personal data committed cleanly to a public repo and was caught at push — after it was in
history, where removing it means a rewrite that [D11](#d11--fix-forward-no-history-rewrites--2026-09-14)
says not to do. Blocking one commit is cheaper than every option available afterwards.

**The one inversion of fail-closed, stated so it is not mistaken for an oversight.** UNKNOWN
visibility does **not** count as public here. UNKNOWN is the ordinary answer offline,
unauthenticated, or on a non-GitHub remote, and treating it as public would block every commit
made on a plane. The push is the real boundary and keeps failing closed; commit-time strictness
is an early warning, not the enforcement. `scan-tree` remains unconditionally strict and is the
check to run before a first commit.

**Cost.** One `gh repo view` per repo per day at most: `remote_visibility()` already caches
PUBLIC for 24h and PRIVATE for 1h behind a 10s timeout, and degrades to UNKNOWN rather than
hanging.

**Verified.** `./test.sh gate` — 119 pass, including the four new cases (PUBLIC blocks,
PRIVATE warns, UNKNOWN warns, no-origin warns), that the matched value is still never printed
([D8](#d8--findings-never-contain-the-matched-value--2026-09-14)), and that a second commit in the same
repo uses the cache rather than a second `gh` call.

## D20 — Sanitize with a `$HOME` marker, not `~` · 2026-09-22

**Decision.** Files that must carry absolute paths to work — the LaunchAgent plist, iTerm2's
prefs, VS Code and Cursor settings — are stored with a literal `$HOME` marker and expanded back by
`sync restore`. `~/.zshrc` and `~/.ssh/config` are **not** filtered: both accept `$HOME` and `~`
natively, so those were fixed at the source instead.

**Why not `~`, the obvious choice.** It was the first implementation and it was wrong. iTerm2's
prefs already contain a genuine `~/Library/Application Support/iTerm2/Scripts`, and a `~` marker
cannot distinguish a tilde the sanitizer produced from one that was always there — so the restore
expanded a real value and the round-trip stopped being lossless. `$HOME` appears in none of these
files, which makes the mapping one-to-one and leaves any pre-existing `~` untouched. The
round-trip test is what caught it; the assertion that a pre-existing `~` survives is now permanent.

**Two match forms.** A home path is not always a prefix. iTerm2's "Working Directory" is the bare
`/Users/<name>` with nothing after it, which a trailing-slash-only rule misses — it is exactly how
that value survived the first pass.

**iTerm2's prefs are converted to XML on the way in.** Stored binary they were both unreadable in
a diff and invisible to text scanners: the weekly audit's home-path check reported "4 tracked
file(s)" because it could not see inside the fifth. Converting makes it diffable and scannable.

**The rule that makes it stick.** `test-security-tools.sh` asserts that **no tracked file in this
repo contains this machine's real home path** — fixtures using `/Users/alice` and `/Users/someone`
stay allowed. A per-file check would have been re-passed while a newly backed-up file reintroduced
the value; only a tree-wide assertion closes that.

**Verified.** `./test.sh tools` — all sanitizer assertions pass, and each was mutation-tested:
reverting the marker to `~` fails four of them, and reintroducing a real home path into a tracked
file fails the tree-wide guard. All four sanitized files round-trip byte-identical to their live
counterparts, and stay valid under `plutil -lint` / `json.tool`.

## D21 — `scripts/` is small single-purpose tools in any language, composed · 2026-09-24

**Decision.** Every file in `scripts/` does one job and follows one contract whatever its
language: a header that is also its `--help`, exit codes `0`/`1`/`2`, results on stdout and
diagnostics on stderr, output files named by the caller (with the written path printed), a
read-only default with an explicit flag to mutate, `$SCRIPT_DIR`-relative paths with env
overrides, no personal values, and a test plus a lint step in `test.sh`. A new need is met by a
new script or by a composer that calls existing ones, not by another subcommand. Bash is the
default for glue; Python 3 (stdlib only) for anything that parses or transforms data. The contract
and the current inventory live in [`scripts/README.md`](../scripts/README.md).

**Why.** The scripts that already work this way — `dev-audit.sh` and its `audit/` modules,
`github-security-sweep.sh`, `containers-doctor.sh` — are the ones with hermetic tests, and
`security-audit.sh` could be built as a composer over them. The ones that don't —
`sync-dotfiles.sh` (five subcommands, one of which commits and pushes this public repo),
`mac-maintenance.sh` (reports and mutates in one run), `dothelp.sh` (a hand-kept copy of the
docs) — are the untested and drifting ones.

**Rejected.**
- *One big `dot` CLI with subcommands.* That is the shape of `sync-dotfiles.sh`, and it's
  the script that is hardest to test and easiest to misuse (`dotbackup` runs `push`).
- *Bash only.* It keeps one linter, but pushes data handling into `awk`/`sed` pipelines that a
  short Python script would state plainly. The cost is one more lint step in `test.sh` when the
  first non-bash script lands.

**Cost.** The existing non-conforming scripts must be split or retrofitted. The gaps are listed
in order in `scripts/README.md` § Audit; none is done yet.

**Verified: PARTIAL.** The contract is written down; existing scripts do not all meet it yet.
Evidence for the audit, 2026-09-24:
`for f in scripts/*.sh scripts/*/*.sh; do head -n1 "$f"; done | sort | uniq -c` →
`7 #!/bin/bash`, `14 #!/usr/bin/env bash` (no non-bash script yet). Scripts missing from
`test.sh`'s shellcheck list: `dothelp.sh`, `mac-maintenance.sh`, `test-dev-audit.sh`,
`test-dotfiles-setup.sh`, `test/assertions.sh`. Recheck when the first README § Audit item is fixed.

## D22 — Policy covers what the code does, not only what gets committed · 2026-09-26

**Decision.** Four policy docs join `security-and-privacy.md`, each owning one question:
[secure development](policy/secure-development.md) (what the code must do),
[privacy by design](policy/privacy-by-design.md) (how running code treats personal data),
[supply chain](policy/supply-chain.md) (dependencies, CI, deployed surfaces) and
[AI and external services](policy/ai-and-external-services.md) (what assistants and connectors
may read and send). `security-and-privacy.md` keeps its scope, commits and publishing, and links
out to the four.

**Why.** Everything up to D21 guards the repo boundary: the gate, tiers, identity, leak response.
A deployed app with no row-level security, a workflow pinned to a movable tag, or an export of
other people's messages pasted into a hosted model all pass that boundary cleanly. The private
findings register already listed the gap (no SAST, deployed surfaces unreviewed, no data
classification).

**Rejected.**
- *Extend `security-and-privacy.md`.* It is already ~300 lines, and it is the doc read before every
  first commit and every push. Burying runtime and data-handling rules in it would make both
  halves harder to find.
- *One `SECURITY.md` per template.* Copies drift ([one source of truth](policy/ai-instructions.md#one-source-of-truth-for-assistant-config)).
  Templates link to the policy when next touched.

**Cost.** Rules without a check accumulate findings ([§13](policy/security-and-privacy.md#13-audit-tool-design-rules)).
Only link integrity is enforced so far: `scripts/test-docs.py` checks that every relative link
and anchor under `docs/` resolves, that every policy doc is linked from `security-and-privacy.md`
and listed in the workspace `CLAUDE.md`, and that the live workspace copy matches. SAST and
deployed-surface checks are still a rollout, not a check.

**Verified: PARTIAL.** The docs and their link check exist; `./test.sh docs` passes (output in
the commit that added this entry). The rules themselves are not yet enforced by any audit
module. Recheck when SAST is rolled out to the first repo.

## D23 — Actions pinned by SHA; auto-allow excludes secret-printing commands · 2026-09-26

**Decision.** Two rules that close off a convenient default:
1. Every third-party GitHub Action is pinned by full commit SHA with the version as a comment
   ([supply chain §3](policy/supply-chain.md#3-github-actions)). Tags are not accepted, even
   major-version tags from GitHub itself.
2. An assistant's auto-allow list holds only commands that can neither print a secret nor run
   arbitrary code ([AI and external services §5](policy/ai-and-external-services.md#5-permission-allowlists)).
   `env`, `printenv`, `echo`, `ps`, `cat:*`, `grep`, `find`, `git:*`, `git diff`, `npx:*`,
   `time` and interpreters are excluded.

**Why.** A tag is a mutable pointer: whoever controls the action's repo can move it to new code
after it was reviewed, and that code runs with the repo's token. Compromised actions have
exfiltrated secrets this way. An auto-allowed `printenv` or `cat .env` sends every token in the
shell to a hosted model with no prompt, which makes the "never print credential files" rule
depend on the assistant's judgement alone.

**Rejected.** *Tags for first-party `actions/*`.* That is safer than third-party tags, but it is
still mutable, and a single rule is easier to check than an exception list. *Keep the broad
allowlist for speed.* Prompts cost a click; a leaked token costs a rotation.

**Cost.** SHA pins need Dependabot's `github-actions` ecosystem or a manual bump to stay current.
The allowlist prompts more often.

**Verified: PARTIAL.** Rule 1 holds for this repo: `grep -hE '^\s*-?\s*uses:'
.github/workflows/*.yml | grep -vE '@[0-9a-f]{40}|uses: \./|#\s+uses' | wc -l` → `0`. The same
count over the five templates' CI → `16` tag-pinned uses, which is an open finding. Rule 2 holds
since 2026-09-26. The global and workspace allow lists were narrowed to the safe column, and
`test-security-tools.sh` now asserts it for the tracked `claude/settings.json`:
`./test.sh tools` → `✓ PASS: no auto-allowed command can print a secret or run arbitrary code`.
Adding `Bash(cat:*)` back makes it fail. The live `~/.claude/settings.json` is not covered by any
test (it is outside the repo). Recheck when rule 1 is fixed.

## D24 — Nothing reaches GitHub unchecked; the gate enforces the repo standards · 2026-09-26

**Decision.** Four rules that close off leniencies:
1. Personal data and non-noreply identities **block on every push to GitHub**, private repos
   included. The only exception is a private repo listed in the private
   `private/security/personal-data-repos.conf`. The list is central, so a repo cannot exempt
   itself.
2. The gate enforces the repo standards (exact pins, one package manager, SHA-pinned actions, no
   media, public ⇒ LICENSE with the canonical holder, security CI present) in repos owned by
   `pieteradejong`. It blocks only what a commit or push **introduces**; dotaudit FAILs the debt
   already there ([enforcement](policy/repo-standards.md#enforcement)).
3. The same gate runs on GitHub (`gate.sh ci` in `security-reusable.yml`) over every push and PR.
   Every own repo must call it. `gitleaks-reusable.yml` alone no longer counts.
4. The assistant may not write repository content through the GitHub API
   (`guard-github-write.sh`); content goes through git, so through the gate.

**Why.** "Private" on GitHub is a setting on a third party's server, one click from public, and
history never shrinks. GitHub secret scanning isn't available for private personal repos, so for
them the gate and CI are the only scanners. A rule that lives only in a doc is enforced when
somebody remembers; the audit mapped 10 such gaps (pins, lockfiles, actions, media by type, CI
presence, LICENSE at push time, drift between instruction copies). The local gate cannot see a
commit made on another machine, with `--no-verify`, or in the web editor. CI can.

**Rejected.** *Judge the whole repo at commit time.* Every old repo would then block its next
commit on debt the commit didn't add. The honest fix would be a cleanup commit before any work;
the dishonest one a bypass, and a gate that invites bypass is weaker. *Full-history gate on
scheduled CI runs.* dotfiles' own published history already holds home paths and an address, so
every scheduled run would fail forever; history debt is dotaudit's to report. *Pin the reusable
workflow by SHA in callers.* Every rule change would then need a commit in every repo; own
reusable workflows (`pieteradejong/*`) are exempt from the action-pin rule and called `@main` on
purpose. *Exact pins for `peerDependencies`.* They declare compatibility and install nothing, so
they are exempt.

**Cost.** First pushes of old repos will block until the repo has the security workflow and, if
public, a canonical LICENSE. Private-repo pushes carrying personal data now need the value
removed, or the line marked `security-gate:allow` for a genuine false positive. `pyproject.toml`
checks need Python 3.11+ (`tomllib`); without it the gate warns and does not check.

**Verified: PARTIAL.**
- `./test.sh` passes in the commit that adds this entry, with new gate, tools and dotaudit cases
  for every rule above.
- `security/gate.sh ci` over this repo's full history → `BLOCK home-path`, `BLOCK email`,
  `BLOCK author-email`. That is known and accepted history (D11, no rewrite). It is also why the gate
  judges only what an event brings.
- NOT YET: the workflow's first run on GitHub, the live `~/.claude/settings.json` hook
  registration, and the first strict dotaudit baseline.

## D25 — The docs are tested against the enforcement · 2026-09-27

**Decision.** `scripts/test-docs.py` gains a `coverage` check, run by `./test.sh`:
- every filename the gate blocks (`TRACKED_FILE_RULES` and `GATE_FILE_RULES` in
  `security/patterns.sh`) appears in [policy §2](policy/security-and-privacy.md#2-the-commitpush-gate);
- each of their rule ids has a row in the findings table;
- every hook in `claude/hooks/` and every LaunchAgent in `macos/` is named in some doc.

A self-test fixture with an undocumented rule, rule id and hook must be reported.

**Why.** An audit of "is everything documented" on 2026-09-27 found 14 enforced rules the
docs never mentioned, 13 partly documented, and policy that overstated what was enforced (every
repo "runs" gitleaks CI; 6 of 102 did). All of them came from code changing without the doc. D22
made the audit map every check to a rule. This decision makes the reverse direction mechanical
for the parts that can be listed: a new blocked filename or hook fails the tests until it is
written down.

**Rejected.**
- *A periodic manual review.* That review is what just found about 30 gaps.
- *Generating the docs from the code.* The policy explains why; a generated list only says
  what.
- *Checking every rule, including content patterns and sanitizers.* The regexes are shapes the
  policy describes in prose, and matching prose to regex would be brittle. The check covers what
  has a name.

**Cost.** Adding a blocked filename now needs a doc edit in the same commit.

**Verified.**
- `scripts/test-docs.py --verbose` → `✓ PASS: coverage: 23 blocked filenames, their rule ids, 5
  hooks and agents are documented` and `10 passed, 0 failed`.
- Mutation: with `.pypirc` renamed in the policy doc, the check failed with `coverage: blocked
  filename .pypirc (package-auth) is not listed in security-and-privacy.md`, then passed once the
  doc was restored.
- D24 follow-up: the live `~/.claude/settings.json` now registers `guard-github-write.sh`. `./test.sh`
  → `synced: ~/.claude/settings.json registers every tracked hook` PASS. Still NOT YET from D24:
  the first `security-reusable.yml` run on GitHub and the first strict dotaudit baseline.

## D26 — Where docs and enforcement disagree, the docs describe what is enforced · 2026-09-27

**Decision.** When a doc claims more than the code does, the doc is corrected to what is
enforced today, and the gap becomes an open finding in the private register. Examples:
- The personal-data exemption matches `test|spec|mock|fixture` anywhere in a path. Policy §2 now
  says so; tightening it is finding GW-1.
- Security CI coverage is 1 of 102 local own repos. §9 now gives the count; the rollout is EN-2.
- Only the tracked allowlist is tested. AI and external services §5 says which files are
  untested; closing that is AI-2.

**Why.** A policy that describes the intended state reads as done. That is the failure
[decisions need verification](policy/ai-instructions.md#decisions-need-verification) exists to
stop. An accurate doc plus an open finding keeps both the rule and the gap visible.

**Rejected.**
- *Fix every behaviour gap in the same pass.* Tightening the exemption shifts dotaudit's
  baseline, and rolling out CI touches 96 repos with pushes. Each deserves its own review.
- *Leave the aspirational wording and add caveats elsewhere.* A reader of the policy would never
  see the caveat.

**Verified.** `grep -n 'anywhere in the path' docs/policy/security-and-privacy.md` → §2 bullet;
`grep -n 'Rollout is lazy' docs/policy/security-and-privacy.md` → §9 bullet. GW-1, AI-2 and the
2026-09-27 EN-2 count are in the private findings register.

## D27 — Sync drops literal credentials; it doesn't rely on the gate to catch them · 2026-09-27

**Decision.** `sync-dotfiles.sh` sanitizes auth on the way in:
- `sanitize_npmrc` deletes any `_authToken`, `_auth` or `_password` line whose value is not an
  env-var reference.
- New `sanitize_docker_config` empties every `auths` entry, keeping registry names and
  `credsStore`. Without `jq` it writes nothing, so it fails closed.

**Why.** `tools/.npmrc` was safe only because the live file happened to use `${GITHUB_TOKEN}`,
and `tools/docker-config.json` only because `credsStore` happened to keep `auths` empty. One
`npm login` or a `docker login` without a helper would have put a literal credential into the
repo's working tree. The gate would probably block the commit (gitleaks knows npm tokens), but
the value would already sit untracked in a public repo's tree. The rule from
[§6](policy/security-and-privacy.md#syncing-live-config-into-a-repo) is to sanitize at the copy.

**Rejected.**
- *Rely on the gate.* It is the last layer, not the only one.
- *Stop syncing these files.* The registry configuration and the keychain helper are worth
  restoring.

**Verified.**
- `scripts/test-security-tools.sh` → `sanitize_npmrc drops literal auth values and scoped
  registries, keeps references` and `sanitize_docker_config drops auth values, keeps registries
  and credsStore`, both PASS. The token fixtures are generated at runtime.
- Mutation with the old sanitizers (no auth rule; `cat` for docker): both tests FAIL.

## D28 — The global gitignore stays editor and OS noise only · 2026-09-27

**Decision.** `~/.gitignore_global` keeps `.DS_Store`, `.vscode`, `.idea` and `Thumbs.db`, and
gets no `.env` or credential patterns. Protection lives in each repo's `.gitignore` (the
[baseline](policy/repo-standards.md#gitignore-baseline)) and in the gate.

**Why.**
- A global pattern protects only this machine. A clone elsewhere, a CI checkout or a
  collaborator gets none of it, so a repo that looked safe here isn't.
- A globally ignored `.env` also vanishes from `git status` in every repo. The missing
  per-repo rule, which the audit's `gitignore-env` check and the SessionStart hook exist to
  surface, would go quiet.

**Rejected.** *Add `.env*` globally as belt and braces.* It hides the per-repo gap that
matters, and the gate already blocks the file at commit on this machine.

**Verified.** `cat git/.gitignore_global` → four noise entries, no `.env`. Documented in
[§7](policy/security-and-privacy.md#7-gitignore-facts).

## D29 — The shell secrets file is `~/.zshrc.secret`, singular · 2026-09-27

**Decision.** Settle the singular/plural mismatch that had been open since 2026-09-01 on the name
the live file already has:
- The template becomes `shell/.zshrc.secret.template`.
- README, SETUP, `scripts/test/assertions.sh` and the policy all follow.

**Why.** The alternative means renaming the live file, which means moving a credential file.
Assistants are barred from that, and it gains nothing. `.gitignore` covers both spellings
through `*secret*`, with `!*secret*.template` letting the template through.

**Rejected.** *Plural everywhere.* It needs the live rename, and an earlier repo-only attempt
was reverted by the next `dotbackup` (LEARNINGS).

**Verified.**
- `ls -l ~/.zshrc.secret` → present, mode `-rw-------`; `~/.zshrc.secrets` → absent.
- `git check-ignore -v shell/.zshrc.secret` → `.gitignore:19:*secret*`.
- `git check-ignore -v shell/.zshrc.secret.template` → no match, exit 1: the template is tracked
  and not ignored.

## D30 — Machine snapshots go to `audit-reports/`, never `docs/` · 2026-09-27

**Decision.** Every inventory command in [reinstall commands](reinstall-commands.md) writes to
`~/dev/audit-reports/snapshot/` under `umask 077`. That covers the brew and app lists, pip
packages, `system_profiler`, the global git config, aliases and the snapshot script. The one
exception is files `dotbackup` tracks on purpose (editor extension lists, `.nvmrc`).

**Why.**
- The old commands wrote the Mac's serial number and the full global git config into
  `dotfiles/docs/`, a public repo.
- None of those filenames were gitignored, so they were untracked but unignored: one
  `git add -A` from publication ([§7](policy/security-and-privacy.md#7-gitignore-facts)).

**Rejected.** *Gitignore the outputs.* The inventory is still one machine's fingerprint sitting
in a public repo's tree, readable by every tool and assistant that searches it.

**Verified.** `grep -c 'dotfiles/docs/' docs/reinstall-commands.md` → `0`. No output files
existed in `docs/` at the time (`ls docs`).

## D31 — Assistant trust scope and catch-all hooks · 2026-09-27

**Decision.**
- Auto mode's "trusted repo" is every git repo under `~/dev` whose `origin` owner is
  `pieteradejong`, excluding the do-not-touch register. Before this it named a single project,
  left over from an earlier session.
- The iTerm2 status hook (`~/.config/iterm2/cc-status`), registered with no matcher and so seeing
  every tool payload and prompt, is accepted as part of iTerm2: a symlink into the signed app
  bundle, talking to iTerm2 over a local socket. Any other catch-all hook needs tracked source,
  no network access and no payload logging
  ([AI and external services §7](policy/ai-and-external-services.md#7-memory-and-transcripts)).

**Why.**
- A trust scope naming one project either over-trusts the others or makes every other session
  mis-scoped. The owner test is the one policy §4 already requires before committing.
- The terminal already sees everything on screen, so the hook adds no new party.

**Rejected.**
- *Delete the auto-mode environment block.* It also carries the org-wide defaults (visibility
  assumptions, `prod` heuristics).
- *Remove the status hook.* It sends nothing beyond iTerm2.

**Verified.**
- `jq '.autoMode.environment[] | select(startswith("**Trusted repo"))' ~/.claude/settings.json`
  → the owner-based scope.
- `readlink ~/.config/iterm2/cc-status` → inside `/Applications/iTerm.app`.
- `codesign -dv` → `TeamIdentifier=H7V7XYVQ7D`. That the team ID belongs to iTerm2's developer
  is assumed, not independently checked.
- A backup of the settings from before the edit is at
  `~/dev/audit-reports/settings.json.bak-2026-09-27` (mode 600).
