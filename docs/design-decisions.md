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

## D25 — Assistant config review: a deny list, no stray instruction copies · 2026-10-01

**Problem.** A review of the Claude Code config found three gaps. Nothing but the hooks and the
assistant's judgement stood between a session and `~/.ssh`, `~/.aws` or a `.env` file, and the
allowlist only grows over time. `Bash(top:*)` was auto-allowed, but `top` never exits without a
TTY, so it hangs a session. And `~/AGENTS.md` was a stale hand-kept copy, not the symlink
[ai-instructions](policy/ai-instructions.md#agentsmd-is-a-symlink) requires. It loaded into every
session started under `~` and contradicted the global file: it said Docker Desktop (the machine
uses Colima), `~/scripts` (the PATH has `~/dev/dotfiles/bin`), and zsh-only scripts (D21 says
bash 3.2).

**Decision.**
1. `claude/settings.json` gets a `permissions.deny` list: `Read(~/.ssh/**)`, `Read(~/.aws/**)`,
   `Read(**/.env)`, `Read(**/.env.*)`, `Bash(git push --force:*)`, `Bash(git push -f:*)`,
   `Bash(rm -rf /:*)`. The same list goes into the live `~/.claude/settings.json`.
2. `Bash(top:*)` is removed from both allowlists and from the safe column of
   [AI and external services §5](policy/ai-and-external-services.md#5-permission-allowlists).
3. `~/AGENTS.md` is retired, moved to `~/.claude/backups/config-review-2026-10-01/home-AGENTS.md`
   and not deleted. No symlink replaces it: `~` is not a project, and a symlink to the global
   `CLAUDE.md` would load the same text twice.

**Rejected.** *Symlink `~/.claude/settings.json` and `CLAUDE.md` into dotfiles.* That would undo
the copies-not-symlinks decision of 2026-09-14
([ai-instructions](policy/ai-instructions.md#one-source-of-truth-for-assistant-config)): the live
settings are a superset holding machine-local hooks, and `test-docs.py` already catches drift.
*Strip the version tables from the global `CLAUDE.md`.* The same policy says that file is where
toolchain versions belong. *Auto-allow `git diff`, `git show` or `rg` to save prompts.* D23 says no.
*`cleanupPeriodDays` to cap the 407 MB of transcripts.* It deletes data automatically, and
transcripts are kept.

**Cost.** Reading a `.env` now always needs a manual step outside the assistant, even when the
file is harmless. A deny rule matches patterns, not intent, so it is a second layer, not a
replacement for §14 or the guard hooks.

**Verified: YES.** `./scripts/test-security-tools.sh` → `✓ PASS: deny list covers credential
reads and force pushes`. Removing an entry from the deny list makes it fail.
`python3 scripts/test-docs.py` → `8 passed, 0 failed`. The live settings still register every
tracked hook. The pre-change copies of both settings files are in the same backup folder.

## D26 — A global gitignore baseline for secrets and rebuildable output · 2026-10-05

**Problem.** `git/.gitignore_global` only covered editor and OS litter. Whether a repo kept `.env`
files, dependency trees and caches out of git depended entirely on its own `.gitignore`, which
does not exist until someone writes one. Between `git init` and that first `.gitignore`,
`git add -A` would take all of it. The machine's file backup now also selects files by what git
would keep, so a missing ignore costs twice: secrets reach the backup, and gigabytes of
`node_modules` and virtualenvs get uploaded every night.

**Decision.** The global ignore gets a baseline under every repo's own rules:
1. Secrets: `.env`, `.env.*`, re-including `.env.example`, `.env.sample` and `.env.template`.
2. Dependencies and virtualenvs: `node_modules/`, `.venv/`, `venv/`.
3. Caches and build output: `__pycache__/`, `*.pyc`, `.pytest_cache/`, `.mypy_cache/`,
   `.ruff_cache/`, `.next/`, `.terraform/`.

A repo can still re-include a path with `!pattern`. Files already tracked are unaffected.

**Rejected.** *A sweep adding these lines to every repo's `.gitignore`.* It would touch forks and
do-not-touch repos, which the sweep rules forbid, and it does not cover the next new repo.
*Broad build names (`dist/`, `build/`, `target/`).* Too many projects commit a `dist/` or have a
source folder called `build/`. Silently ignoring real source is worse than a noisy `git status`.
*Ignoring the backup's own selection files here.* The selection lives outside every repo, so
nothing needs ignoring.

**Cost.** A repo that really wants to commit a `.env.*` file needs a `!` line. A global ignore is
invisible from inside the repo: `git check-ignore -v <path>` names the global file when it is the
cause.

**Verified: YES.** Throwaway repo with `.env`, `.env.local`, `.env.example`, `node_modules/x/a`,
`venv/a`, `.venv/a`, `__pycache__/a.pyc`, `keep.py`: `git check-ignore -v` attributes each ignored
path to `~/.gitignore_global` (lines 16–28), and `git ls-files -o --exclude-standard` lists only
`.env.example` and `keep.py`.

## D27 — The weekly cleanup covers every cache that regenerates for free, and nothing else · 2026-10-06

**Problem.** With the disk at 96%, the weekly cleanup was reclaiming about 2G a week: npm, pip,
Docker when running, and old Trash. Several caches that regenerate at no cost were never touched,
and safe steps sat commented out in its `IDEAS` block. Under launchd, the pip step was a no-op: the
bare `PATH` found Xcode's pip 21 at `/usr/bin/pip3`, which does not purge pip's current cache layout.
Pieter wanted a script he can rerun now and then that removes only what has no bad effect.

**Decision.** The rule for a live step is that the only cost of deleting it is a later download or
rebuild that happens without anyone noticing. Added live: pip-tools cache, `uv cache prune`,
`brew cleanup -s --prune=all`, `pnpm store prune`, Xcode DerivedData, Electron/Squirrel updater
leftovers (`Caches/*.ShipIt`, `Caches/*-updater`) untouched for 3+ days, and
`maintenance-*.log` older than 30 days. 2026-10-09: Sparkle apps stage updates under
`Caches/<id>/org.sparkle-project.Sparkle/Installation/`; the same sweep and 3-day guard now cover
that path too (a 1.8G Codex zip from 2026-09-15 prompted it). Also:
1. A `--dry-run` flag. Every mutating command goes through one `act` helper, so the dry run is a
   single switch, not one per section, and it writes no log.
2. The script sets `PATH` itself (Homebrew first, then `~/.local/bin`).
3. A terminal run prints as well as logs. The log is trimmed before the run, so the trim cannot
   race the `tee` still writing.
4. *Fix:* the Trash sweep ages items by `-ctime`, not `-mtime`. `mv` into Trash keeps a file's
   mtime, so the old rule purged any old file the moment it was trashed (on 2026-10-08 it would
   have taken 25 items instead of 15, including media trashed two days earlier). `mv` sets ctime,
   so ctime measures time in Trash.

**Rejected.** *`brew autoremove`*: it removes a dependency you have started using directly.
*Updater folders of any age*: a fresh one can be an update staged for the next relaunch, hence the
3-day glob qualifier `(N/m+3)`. *HuggingFace models, Playwright browsers, Claude's `vm_bundles`,
old nvm versions, project `node_modules`/`.venv`*: all regenerable, but each costs a multi-GB
download or a broken run until it is fetched again. *Caches of apps usually open (Spotify,
Chrome)*: deleting under a running app is not a no-effect operation. *Media, Downloads, iPhone
backups, the local Drive mirror*: personal data, decided by hand.

**Cost.** The static test can no longer say "the only `rm -rf` is in Trash". It needs an explicit
allowlist of target paths, which has to grow with each new step.

**Verified: PARTIAL.** 2026-10-08: `./scripts/test-bin.sh` → 89 passed, 0 failed (allowlist,
3-day updater guard, `-ctime` Trash rule, `--dry-run` on a fake HOME removes nothing and writes no
log). Mutation check: a copy with `rm -rf "$HOME"/*`, an unguarded `*.ShipIt` sweep,
`docker system prune -a` or `find … -name "*.mp4" -delete` appended fails the suite each time.
`weekly-disk-cleanup.sh --dry-run` on this Mac lists every step and changes nothing (log mtime
unchanged). 2026-10-09: Sparkle form added; `./test.sh bin` → 90 passed, 0 failed; `--dry-run`
lists the new form and changes nothing. NOT YET: a real run, and the next Sunday launchd log.

## D28 — The maintenance dashboard is a local file built from the reports · 2026-10-07

**Problem.** The weekly audit, dotaudit and the disk cleanup each write their own output
(`security-audit-*.md`, `findings-*.tsv`, `~/.weekly-disk-cleanup.log`). Seeing a trend, or which
repo keeps failing which check, meant opening several files and reading tables by eye. The
findings are the most sensitive output this repo produces (secrets paths, personal values, repo
names), so anything that summarises them inherits the same handling rules.

**Decision.** `scripts/audit-dashboard.py` renders one self-contained HTML page,
`~/dev/audit-reports/dashboard.html`, from what is already on disk; it stores nothing of its own.
`security-audit.sh` calls it last, and a failure to draw the page prints a WARN and never changes
the audit's exit code: the dashboard is a view over the reports, not a step of the audit. Four
views: FAIL/WARN trend with a sparkline per check, a repo × check heatmap whose cells open their
findings, space reclaimed per cleanup run, and an action list of FAILs grouped by the fix they
need. Ticks on the action list live in the browser's local storage, so the page itself stays a
pure function of the reports. Rules it shares with the reports: written mode 600, refused (exit 3)
if the output path is inside a git repo, inline SVG only, no external scripts or fonts, and a
Content-Security-Policy that blocks network loads. Stdlib Python only, like the other scripts.

**Rejected.** *A hosted page or a notebook*: the content must never leave the machine
(`policy/ai-and-external-services.md`), and a hosted page is a second place to secure. *A
terminal summary at the end of the audit*: it shows one run, not a trend, and the heatmap does
not fit. *A chart library from a CDN*: a network load from a page that lists secret locations is
the wrong default; inline SVG is enough for sparklines and a heatmap. *Storing state (ticks) in
the page or a sidecar file*: it would make the page something other than a rendering of the
reports; the browser's local storage is per-viewer and disposable.

**Cost.** One more Python script to keep stdlib-only, and the audit test suite needs fixture
reports to exercise it. The heatmap is only as good as the dotaudit check ids; a renamed check
starts a new column.

**Verified: PARTIAL.** 2026-10-09: `./test.sh tools` passes, including "audit run regenerates
the dashboard", "writes dashboard.html next to the reports", "dashboard is mode 600" and "refuses
to write the dashboard into a git repo" on fixture reports. NOT YET: the page rendered from the
real `~/dev/audit-reports/` after the next Sunday audit, and a look at it in a browser.
