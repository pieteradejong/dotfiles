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
lists the new form and changes nothing. 2026-10-13: the first scheduled real run
(launchd, Sun 2026-10-11 09:00, `~/.weekly-disk-cleanup.log`) ran every step without error and
reported `Reclaimed: 2561 MB`: npm 3.4G → 1.0G, pip 864M → 92K (1436 files; the PATH fix works,
where launchd's Xcode pip had removed 1 file a week), uv 28M → 288K. Brew had nothing to remove.
Trash was skipped as designed ("no Full Disk Access to ~/.Trash (launchd)"). NOT YET: a real
terminal run that exercises the Trash `-ctime` sweep on real items.

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

## D29 — `mac-maintenance.sh` stays, at the cleanup's standard and under test · 2026-10-10

**Problem.** `scripts/mac-maintenance.sh` was the one maintenance script with no test, no dry run
and no `--help`: bash with `set -e`, `bc` for the memory figure, and a quarantine that moved every
entry of `~/Library/Caches` to Trash, including the pip and Homebrew caches the weekly cleanup
already empties in place. `scripts/README.md`'s audit (item 4) had flagged it; the weekly cleanup
(D27) had meanwhile set the bar: `--dry-run`, one `act` helper, a hermetic test. Retiring it was
on the table.

**Decision.** Keep it, as the one deliberate cache reset for a Mac that feels slow, and bring it to
the same shape: `--dry-run`, `-h`, exit 0/2, every mutating step through `act`, no `set -e` (a
failing section must not stop the report), awk instead of `bc`. The quarantine stays a move, never
a delete: one dated folder in `~/.Trash`, purged by the weekly cleanup after 7 days, so a cache an
app still wanted can be put back for a week. Entries the weekly cleanup owns (`pip`, `pip-tools`,
`Homebrew`) are left to it; entries an app holds open are listed, not forced; an unreadable or
read-only Trash is reported and the step skipped. New suite `scripts/test-mac-maintenance.sh`
(`./test.sh maint`) runs the real script against a fake HOME — safe, because the script only ever
touches paths under `$HOME` — and asserts statically that no live `rm -rf` or `find -delete` ever
appears. Still manual: not scheduled.

**Rejected.** *Retire it* (Pieter: "it needs tests, for one thing"): the report half is useful and
the quarantine is the only cache reset that is reversible. *Schedule it*: a cache reset under
running apps is not a no-effect operation (D27's rule), so it stays a decision a person makes.
*`rm -rf` instead of a move*: no restore window. *Moving the log under `~/Library/Logs`*: it would
change what the weekly cleanup prunes; left at `~/maintenance-YYYYMMDD.log`.

**Cost.** One more suite in `test.sh`. The quarantine is still broad by design (every app cache but
three), so a run while apps are open costs their caches a rebuild.

**Verified: PARTIAL.** 2026-10-10: `./test.sh maint` → 37 passed, 0 failed (dry-run moves nothing
and writes no log; a real run on a fake HOME moves two app caches into one dated Trash folder,
leaves pip/pip-tools/Homebrew, is idempotent, says so when Trash is unreadable); `shellcheck`
clean. NOT YET: a real run on this Mac (`scripts/mac-maintenance.sh --dry-run`, then without).

## D30 — The audit reports what changed since the last run; acceptance stays in the register · 2026-10-10

**Problem.** From 2026-09-14 to 2026-10-04 every weekly report carried the same nine or ten FAILs
(two families of old secrets in GitHub history, three repos without Dependabot alerts, one loose
credential file), each known and tracked in the private findings register. The Sunday
notification said "10 FAIL" every week; nothing in it told a new finding from a known one, so it
had stopped carrying information.

**Decision.** `security-audit.sh` opens each report with `## Since last run (<date>)`: new,
resolved and unchanged FAIL/WARN lines against the newest previous *full* report in the same
directory, with the new and resolved findings listed. The notification, the terminal line and
`security-audit.log` carry the new/resolved counts. Comparison rules: date-stamped report paths
and the dotaudit totals are masked (the same finding on a new day is "unchanged"); only bullets
under a numbered section count (a report's own delta list is never compared); a `--quick` report
is never the baseline, and a `--quick` run compares only the sections it ran and says so. The
exit code is unchanged: 1 on any FAIL.

**Rejected.** *An accepted-findings list the script reads, demoting known FAILs to info*:
`private/registers/findings.md` already owns acceptance, with the verification discipline; a
machine-readable copy is a second source of truth that drifts, and a FAIL that is "accepted" in a
file nobody re-reads is how a known leak stays open. *Exit 0 when nothing is new*: the policy says
a FAIL is a FAIL; the launchd exit status stays the honest signal. *Comparing the dotaudit findings
TSVs row by row*: the dashboard's heatmap already does that per repo and check.

**Cost.** The delta is only as stable as the finding text: a reworded check reads as one resolved
plus one new the week it changes.

**Verified: PARTIAL.** 2026-10-10: `./test.sh tools` → the audit section passes on a fixture
baseline (names the newest full report and skips a newer `--quick` one; counts 2 new · 1 resolved ·
1 unchanged; excludes sections 2 and 4 under `--quick`; ignores the baseline's own delta list;
first-run message when there is no previous report). NOT YET: the real report of Sun 2026-10-11
10:00 against 2026-10-04's.

## D31 — Job results are mailed through Gmail SMTP with Keychain credentials; a missing mailbox never fails a job · 2026-10-12

**Problem.** `bin/weekly-disk-cleanup.sh` (launchd, Sunday 09:00) and `scripts/mac-maintenance.sh`
(by hand) only wrote a local log. Nobody reads `~/.weekly-disk-cleanup.log` unless something feels
wrong, and the maintenance log never leaves the Mac. Pieter asked for the result of every run in his
inbox. launchd jobs have no Mail.app and no GUI session; this Mac has no SMTP relay (Postfix is
unconfigured, no msmtp); and the repo is public, so no address may be committed — the gate blocks
real email addresses in any file (D24).

**Decision.** One sender, [`bin/mail-report`](../bin/mail-report): Python standard library only
(`smtplib` over implicit TLS to `smtp.gmail.com:465`), stdin as a plain-text body, one `--subject`.
Credentials are a single macOS Keychain item (`dotfiles-mail-report`: account = Gmail address,
password = a Gmail App Password), created once by hand with `security add-generic-password … -w`
so the password is typed at a prompt, never on a command line. Both jobs capture their run into a
per-run file (a `tee` into the log is asynchronous, so the last lines could not be read back
reliably), append it to their log, then mail it with the `Reclaimed:`/`Moved:` line as the subject.
Exit codes 1 (send failed) and 3 (no Keychain item) are a `WARN: report not mailed` line in the
output and the log; the job still exits 0. `--dry-run` never mails; `--no-mail` logs only.
`MAIL_REPORT_BIN` lets the suites point the jobs at a stub, so no test touches the Keychain or the
network and `./test.sh` passes on Linux CI, where `security` does not exist.

**Rejected.** *msmtp from Homebrew*: a second tool and a `~/.msmtprc` to back up, for what forty
lines of stdlib do. *A Postfix relay*: root-owned system config outside the repo, and a change to
how every local `mail` call behaves. *Mail.app via `osascript`*: needs a GUI session and a configured
account; fails silently under launchd. *A macOS notification* (what the audit does): gone the
moment it is dismissed, missed entirely when away from the Mac. *The address in the repo or the
plist*: the gate blocks it and the repo is public. *Password in an env file or the plist*: plaintext
on disk; the Keychain already solves this. *Failing the job when the mail fails*: a cleanup that
reclaimed 20 GB is not a failure because the inbox was unreachable.

**Cost.** Google receives the run's text (cache sizes, paths under `$HOME`, counts) — a processor of
log lines that contain no secret and no other person's data. One Keychain item is a by-hand setup
step on a reinstall (`docs/reinstall-commands.md` § Keychain items). An App Password bypasses
2-step verification for SMTP, so it is scoped to one purpose and revocable on its own.

**Verified: PARTIAL.** 2026-10-12: `./test.sh` → every suite passes: `mail` (13: fake Keychain,
exit 3 when unconfigured or without `security`, exit 2 usage, `--dry-run` composes From/To/Subject
and a UTF-8 body, `--test` probe, the password never on stdout or stderr, a refused SMTP connection
is exit 1), `maint` (52: a real run on a fake HOME mails once, subject carries the host and
`Moved: 2 item(s)`, the body is byte-identical to the log, the second run mails only its own run,
`--no-mail` and `--dry-run` send nothing, a sender exiting 3 leaves the run at exit 0 with the WARN
line in output and log), `bin` (101: `--dry-run` with a marker stub sends nothing, `--no-mail`
accepted, the log append precedes the mail call); `shellcheck`, `zsh -n` and `ruff` clean.
NOT YET: the Keychain item on this Mac, `mail-report --test`, and the first launchd run that mails
(Sun 2026-10-18 09:00) — which also confirms that `security` reads the item under launchd without a
prompt.

## D32 — `llm` owns the model lineup and the daemon, not just the prompt · 2026-10-06

**Problem.** `llm` routed prompts, but everything around them was manual: models were pulled by
hand with `ollama pull`, roles were guessed from names, and nothing said which models the machine
*should* have. A real case: `qwen3.6:27b-coding` didn't match the coder pattern (`coding` is not
`code`), so it would have been routed as general. The daemon had sat on an old version after a
`brew upgrade` because nothing prompted a restart. And it took Ollama, `brew services` and
`launchctl` knowledge to check that the lockdown still held.

**Decision.** [`config/llm/lineup`](../config/llm/lineup) (`role tag download_GB` per line) is the
one declaration of the installed models and their roles. Lineup roles take priority over name
classification, which still handles models outside the lineup. `llm` gains first-word commands,
following the same rule as `code`/`reason`:
- `status`: daemon up, version skew, `OLLAMA_NO_CLOUD`, loopback bind, disk, missing lineup models.
- `models`: what's installed, with role and size.
- `update`: makes the machine match the lineup. It shows the plan and asks once. It refuses a plan
  that would leave less than `LLM_MIN_FREE_GB` (15) free. It pulls one model at a time, removing
  unlisted models first only when that pull needs the space. Each pull must pass `/api/show` (no
  `remote_host`, a `FROM /…` local blob) or it is deleted again. *2026-10-15: the blob check is
  now the on-disk manifest plus layers, D36 — the `FROM /…` line is GGUF-only.*
- `free`: unload resident models.
- `restart`: restart the daemon.
- `fast`: a new role for a MoE coder, falling back to `coder`.

When nothing answers on the default endpoints, `llm` runs `brew services start ollama` itself.

**Rejected.** *Keeping roles purely name-derived*: names don't say intent (two coders: which is
`code` and which is `fast`?), and `coding` proved they miss. *Hardcoding tags in the script*: the
`ollm` function went stale exactly that way (see the `llm` history in [llm.md](llm.md)). *A
separate `llm-admin` command*: two entry points to remember for one tool. *Asking before
auto-start*: the idle daemon costs about 6 MB of RAM and no CPU, and memory is spent only while a
model is loaded, so there is nothing worth a prompt. *Removing all unlisted models before pulling*:
leaves the machine with no model if a pull fails.

**Cost.** `update` is the one command that downloads, so `llm` is no longer purely offline. That is
acceptable because it only ever runs when asked, and every pulled tag passes the same `cloud`
refusal as inference. `update` removes ad-hoc pulls not in the lineup, after a yes.

**Verified.** 2026-10-06: `./scripts/test-bin.sh` passes, including 13 new tests against a fake
Ollama on loopback. Those cover lineup-over-name routing, `fast` fallback, `status <words>`
refused, the update plan (pull missing, remove unlisted, keep the rest), the disk-floor refusal, a
`:cloud` lineup tag and an unknown role refused, and the shipped lineup parsing. Live run: `llm
update --yes` pulled 2 models and removed 2, verified both local, and ended at 37 GB free. From a
stopped service, `llm --dry-run` auto-started the daemon and answered in 2.75 s, bound to
`127.0.0.1:11434` only. `llm free` → `/api/ps` empty.


---

## D33 — Decisions and changelog are checked at session start, turn end and commit; `whatsup` answers "what's up" · 2026-10-13

**Problem.** Two logs were required in writing — a decision log with a `Verified:` line per entry
(`policy/ai-instructions.md`) and a Keep-a-Changelog `CHANGELOG.md` (`policy/repo-standards.md`)
— and nothing checked either: no hook, no gate rule, no dotaudit id, no Enforcement row. The
private log's #8 had kept steps 3 and 4 of the session workflow as prose on purpose, because
"is this a decision worth recording" is a judgment. The result was drift: 13 repos with a root
`DECISIONS.md` against 9 with `docs/`, five heading formats, and repos with code and no changelog.
And opening a project meant reading three files and running four git commands before knowing
what was going on.

**Decision.** One library, `security/lib/logs.sh`, says which file is the decision log
(`docs/DECISIONS.md`; root `DECISIONS.md` accepted where it exists; `docs/design-decisions.md`
here), which repos are exempt (scratch, `_to_delete`, a remote not ours, the skip list), which
paths are doc-only (`CHANGELOG_EXEMPT_ERE`), and how a log is read. Four consumers share it:

- `bin/whatsup`: the one-screen answer — git state, last commits, last decision and open
  `Verified` items, the `[Unreleased]` block, open TODO items, and what this session changed with
  no changelog line. `--brief` is six lines.
- `session-start.sh` prints `whatsup --brief` in every repo and writes a per-session baseline. The
  Rule of Silence ends for repos: the summary is wanted every time.
- `stop-log-check.sh`, a `Stop` hook: at the end of a turn that changed behaviour-relevant files it
  refuses to end the turn — once per set of changed files — until the entries exist or the
  assistant has said why none is owed. It asks the question #8 called a judgment; it does not
  answer it. Never loops, never nags twice, fails open.
- The gate blocks, in own repos after the first commit: `no-changelog-entry` (code staged with no
  `CHANGELOG.md` change, in a repo that has one), `changelog-no-unreleased`, `decision-unverified`
  (`NOT YET` passes, absence does not); warns `decision-ref-missing`. dotaudit reports
  `no-changelog` and `decisions-unverified`. A missing changelog is existing debt and is not
  blocked: the gate blocks what a commit introduces.

Entries in this log carry a `**Verified.**` line from here on (D22 onward already do).

**Rejected.** *A PreToolUse hook on every call* (the literal "every action"): never the moment an
entry is owed, and hundreds of silent firings a session. *Enforcing in CI*: a squash or a web edit
arrives there without its session, so the rule would fail on things nobody could have logged.
*Generating entries automatically*: the hook cannot judge whether an alternative was closed off,
and a generated entry is worse than none. *Blocking a commit in a repo with no changelog at all*:
it would have failed every existing gate fixture and contradicts the "what a commit introduces"
rule; the Stop hook and dotaudit carry that case. *Moving the 13 root `DECISIONS.md` files*: a
sweep over 13 repos for no behavioural gain; both locations are accepted.

**Cost.** Every Claude Code turn that changed code gets one extra prompt the first time; every
commit in a repo with a changelog needs a line in it, in that commit. `~/.local/state/claude-logs/`
holds a small file per session for seven days. The live `~/.claude/settings.json` gained a `Stop`
hook that must stay in step with the tracked copy (`./test.sh docs` checks).

**Verified.** `./test.sh` → all twelve suites pass; `logs` → `181 passed, 0 failed`; `docs` →
`enforced: 15 policy check ids are in the enforcement table`, `synced: ~/.claude/settings.json
registers every tracked hook`. `time bin/whatsup --brief` → `real 0.19`. By hand against the real
repos: `whatsup --brief` in `dotfiles` → four lines (state, decisions `last 32 · ⚠ 9 open · ⚠ 17
without Verified`, changelog `[Unreleased] 26 entries`, `TODO.md: 23 open`); in `ai-town` →
`Decisions: none (exempt: remote owner is a16z-infra, not pieteradejong)`; at `~/dev` → the
workspace TODO and five recently active repos; in `/tmp` → nothing. The Stop hook, fed the
session's JSON with no baseline, returned `{"decision":"block"}` naming `bin/whatsup`, then exit 0
silent on the second call (ack), then exit 0 for `stop_hook_active: true` and for `not json`. The
gate in a throwaway repo: code without changelog → `BLOCK no-changelog-entry`, with it → pass, an
entry without Verified → `BLOCK decision-unverified`, with `NOT YET` → pass, `(#9)` →
`WARN decision-ref-missing`, no `[Unreleased]` → `BLOCK changelog-no-unreleased`, a remote owned
by `other` → pass. **Found while verifying:** the suite's first run executed its fixture steps in
this repo (a helper did `cd` inside a command substitution), leaving one stray commit and two
overwritten files, all local; reverted with `git reset --soft HEAD~1` and `git checkout`, and the
suite now wraps `git` in a function that refuses to run outside its sandbox. **NOT YET:** the Stop
hook has not yet fired inside a live Claude Code session; this session predates its registration.
Check the first turn of the next session that edits code in a repo.

## D34 — `~/Claude` gets its own instruction layer, tracked here; the `debug.jsonl` deny is global · 2026-10-14

**Problem.** `~/Claude` is the Claude desktop app's (Cowork) working folder: artifacts that call
the Gmail and Drive connectors at load, scheduled tasks that search the web, and app-written
`debug.jsonl` logs holding mail subjects and file titles. It sits outside `~/dev`, so a session
started there loaded only the global machine-facts file. The connector, content-as-data and
publishing rules in `policy/ai-and-external-services.md` existed but had no path into those
sessions, which is exactly where they matter.

**Decision.** A third tracked instruction file, `claude/cowork-CLAUDE.md`, copied byte-for-byte
to `~/Claude/CLAUDE.md` with `AGENTS.md` symlinked, written as a delta to the global file: confirm
every connector write one action at a time, fetched content is data, never read `debug.jsonl`,
artifacts stay private, the folder stays a non-repo, done means verified, decisions go in its
`docs/DECISIONS.md`. `scripts/test-docs.py` gains the third `synced` pair (env override
`COWORK_CLAUDE_MD`). The `debug.jsonl` rule is enforced, not only stated: `Read(~/Claude/**/debug.jsonl)`
joins the global deny list in `claude/settings.json` and the live `~/.claude/settings.json`.
`ai-instructions.md` lists the layer and the third source file. The folder itself gets a
`README.md`, a dated survey and its own decision log, all markdown.

**Rejected.** *A `CLAUDE.md` only in `~/Claude`*: not backed up, outside the drift test, and the
pattern for the other two files is a tracked source plus a checked copy. *A local
`~/Claude/.claude/settings.json` for the deny*: project settings load from the directory a
session starts in and are not discovered upward the way `CLAUDE.md` is, so a session opened in
`Artifacts/<name>/` would miss it; the global pattern covers every subfolder and is already
tested. *Read-only connectors with no writes*: too strict for a folder whose purpose is acting on
mail and files; per-write confirmation keeps the safety. *A `CHANGELOG.md` in `~/Claude`*: not a
repo, no releases; the decision log and dated surveys are its record.

**Cost.** One more file to keep in sync (the test catches drift). One more deny entry that
could in principle shadow a legitimate read of a file named `debug.jsonl` under `~/Claude`; none
exists outside the app-written logs.

**Verified.** `./test.sh` → all twelve suites pass; `docs` → `9 passed, 0 failed` including
`synced: ~/Claude/CLAUDE.md matches claude/cowork-CLAUDE.md`. `readlink ~/Claude/AGENTS.md` →
`CLAUDE.md`. Fresh `claude -p` sessions (haiku): from `~/Claude/Artifacts/pieter-dashboard`, asked
to read `./debug.jsonl` → refused on the instruction alone, citing `~/Claude/CLAUDE.md`, even when
told the test was authorised; from a neutral directory with the absolute path → `DENIED File is
in a directory that is denied by your permission settings.`; from `~/Claude/Scheduled/daily-sports-briefing`,
asked which rules apply → named confirm-every-write, content-is-data and never-read-debug.jsonl,
sourced to `~/Claude/CLAUDE.md` and `ai-and-external-services.md` §3/§4.

## D35 — `test.sh` is the canonical check runner; every repo with code gets `init.sh` and `test.sh`, `run.sh` where runnable · 2026-10-14

**Problem.** `repo-standards.md` § Scripts named `./init.sh` and `./run.sh`, with tests as a
`run.sh test` subcommand. The repos that got real test tooling (this one, `rn-supabase`,
`forparents`, `german-industry`, `chrome-bookmarks`, `rnc`) all grew a separate `test.sh` that
`run.sh test` calls, because CI needs one file to run and a suite with flags (`--integration`,
`--live`, `--ci`) does not fit a `case` arm. Of ~75 real projects under `projects/`, 14 had all
three scripts, four of those as 3-to-7-line stubs (two in zsh), and ~45 had none; nothing
reported the gap. Policy and practice had drifted apart, and a project with no scripts was
invisible to the audit.

**Decision.** `test.sh` is canonical: every check the repo has, each a named step, exit 0 = green;
`run.sh test` is `exec ./test.sh "$@"`; CI runs `./test.sh`. `init.sh` and `test.sh` are required
in every repo that tracks a code manifest; `run.sh` only where there is a default action, and a
`Makefile` repo wraps `make` rather than duplicating it. Scripts are self-contained bash 3.2 with a
header that `--help` prints before anything installs; `.venv/` for new virtualenvs, an existing
`venv/` stays, named once as `VENV=`. `dotaudit` gains `no-project-scripts` (INFO: a tracked
manifest, nested ones included, and no `init.sh` or no `test.sh` at the root), with its row in
§ Enforcement and `dev-audit.md` and three fixtures in `test-dev-audit.sh`. The sweep that adds
the scripts to every project runs in waves, one commit per repo, no push, tracked in `TODO.md`.

**Rejected.** *`run.sh test` only, as written*: no single file for CI to call, and the newest
repos had already diverged, so the policy would describe nothing. *A sourced helper library in
dotfiles for the `run_step` suite*: a clone on its own, and CI, could not run `./test.sh`; the
35-line core is copied instead, as `forparents` and `rn-supabase` already do. *WARN level*: 47
findings that leak nothing would bury the FAILs the weekly audit exists for. *Generated scripts
from a `project.conf`* (the earlier `scripts/_common.sh` trio in `screenshot-analyzer`,
`transcribe`, `flowgraph`): 20 KB of script nobody reads; the root scripts there become six-line
wrappers instead.

**Cost.** One INFO row per repo until its wave lands. Repos with no `CHANGELOG.md` get scripts but
no changelog in the sweep (existing debt, `no-changelog` reports it), so the Stop hook is told why
none is owed in each of those turns. Two conventions still coexist in the trees (`venv/` and
`.venv/`); the rule keeps both rather than renaming working environments.

**Verified.** `./test.sh dotaudit` → 79 passed, 0 failed, including `standards-bad -> INFO
no-project-scripts` (nested `web/package.json`), `docs-only` and `clean-repo` silent,
`half-scripted` names only `test.sh`. `./test.sh docs` → 9 passed, `enforced: 16 policy check ids
are in the enforcement table`. `./test.sh shellcheck` → clean (30 files). Baseline from
`scripts/dev-audit.sh --only policy` on 2026-10-14: 47 `no-project-scripts` rows; the sweep burns
that number down (waves in `TODO.md`). Same day, after all four waves: 9 rows, every one excluded by the
scope (`c` is an exercise repo; the other eight are the non-template repos under `templates/`); 61
commits in 61 repos, none pushed; per-repo rows in `~/dev/audit-reports/project-scripts-sweep-2026-10-14.md`.

## D36 — "Local" means the manifest and every layer blob are on disk, not a `FROM /…` line · 2026-10-15

**Problem.** `llm update` verified each pull through `/api/show`: no `remote_host`, and a
`FROM /<blob path>` line in the modelfile. Ollama 0.40 serves MLX (safetensors) builds to Apple
Silicon for some tags; their modelfile reads `FROM <tag>` and the weights are 1,000-odd
per-tensor blobs. The first MLX pull (`qwen3.6:35b-a3b-coding`, 23 GB, fully local) was
therefore deleted again by the guard as "not backed by a local blob", and the guard would have
refused every MLX model from then on. The same heuristic sat in `local-llm`'s `test.sh --live`.

**Decision.** Local evidence is the filesystem: the model's manifest under the models dir
(`manifests/registry.ollama.ai/<ns>/<model>/<tag>`) and every `layers[].digest` present as a
blob there. `verify_local` checks that first and keeps the `FROM /…` line only as a fallback for
when the models dir cannot be resolved. `llm status` runs the same check on every installed
lineup model and warns when a manifest or layer is missing. `LLM_MODELS_DIR` overrides the
models dir (test hook, like `LLM_FREE_GB`). `local-llm/test.sh --live` applies the same rule.

**Rejected.** *Accepting `details.runner == mlx` or `format == safetensors` from `/api/show`*: it
says what the model is, not where it is; a daemon answer is not evidence that bytes are on this
disk. *Pulling the explicit GGUF tag instead (`…-mtp-q4_K_M`)*: another 23 GB to avoid fixing a
heuristic that was already wrong, and it gives up the MLX runner, which is the native engine on
this hardware. *Dropping the `FROM /…` fallback*: it still works for GGUF when launchd does not
expose `OLLAMA_MODELS`, and costs nothing.

**Cost.** `verify_local` and `status` read the manifest (a 247 KB JSON for the MLX model) and
stat up to ~1,000 blobs; sub-second. The check trusts the models dir it resolved; a wrong
`OLLAMA_MODELS` makes every model look missing, which `status` then says loudly.

**Verified.** `./test.sh bin` → 102 passed, 0 failed, 0 skipped, including the new case: a fake
models dir where alpha and beta are complete and delta's manifest names an absent blob —
`status` prints `ok` for the first two and `!!` for delta. Live on 2026-10-15: before the fix,
`llm update --yes` pulled the 23 GB and deleted it ("not backed by a local blob"); after it,
`llm status` shows all three lineup models `ok`, and `/api/show` for the MLX model reports
`runner: mlx`, `format: safetensors`, `FROM qwen3.6:35b-a3b-coding`, no `remote_host`, with 1,062
manifest layers and 0 missing blobs on disk.

## D37 — Every prompt under `~/dev` ends in markdown: decisions, TODO items, then a redundancy check · 2026-10-17

**Problem.** Pieter's standing instruction, repeated across sessions and stated again on
2026-10-17: every command typed in the workspace is followed up by documenting decisions and
TODOs in markdown, and those documents are then checked for duplicates and redundancy. Decisions
and the changelog were already enforced (D33: Stop hook, gate, dotaudit). Open work was not:
`TODO.md` was a convention in three places, the session workflow's step 5 put "what is still
open" in the closing summary — chat, which the next session never reads — and nothing fired on
a prompt that changed no file, or at `~/dev` itself, which is not a repo. Nothing checked any log
for duplicate entries; `~/dev/TODO.md` and the project lists were drifting apart by hand.

**Decision.** Three pieces, all reading `security/lib/logs.sh`. (1) A `UserPromptSubmit` hook,
`claude/hooks/prompt-followup.sh`, prints three lines into the context of every prompt typed
under `~/dev`: where this repo's decisions go (and the last entry), where its open items go (and
how many are open), and that the files written are to be checked with `doc-dupes`. Silent
outside `~/dev` and in exempt repos. (2) The Stop hook, `stop-log-check.sh`, gains three checks
inside its one-block-per-change-set ack: the closing summary names open work
(`LOGS_OPEN_WORK_ERE`: `NOT YET`, `PARTIAL`, `TODO`, "still open", "follow-up", …) or a new decision
entry is `NOT YET`, and no `TODO.md` was touched; a `TODO.md`, decision log or `CHANGELOG.md`
touched this session now holds a duplicate; and at the workspace root — `~/dev` or a non-repo
directory under it — the same two over the files the transcript shows written, against
`~/dev/TODO.md`. The ack key now covers the matched open-work lines too, so a newly named item
reopens the question once. (3) `bin/doc-dupes`, bash + awk like `whatsup`: duplicate decision
numbers and titles, duplicate and near-duplicate (token-Jaccard ≥ 0.8, 3+ tokens) TODO items,
items shared with `~/dev/TODO.md` (`--workspace`, says open-here/ticked-there), changelog lines
repeated inside `[Unreleased]` or already released; `--all` for the audit, which gains
`docs-redundant` (INFO). The rule is written in `ai-instructions.md` § Open items live in
`TODO.md` and § Logs are checked for redundancy, the workspace `CLAUDE.md` gets the hard rule and
workflow steps 5–6, and § Enforcement gets two rows.

**Rejected.** *Blocking every turn unconditionally*: literal "every command", but it doubles the
cost of every answer, including questions, and produces a stream of empty "no entry owed" lines;
the per-prompt reminder is what fires every time, the block fires on evidence. *A gate rule for
duplicates*: a pre-existing duplicate would block an unrelated commit; what a commit adds is
already covered at turn end, and the weekly audit covers the rest. *A batch sweep creating
`TODO.md` and `DECISIONS.md` in the 137 project directories*: § Per-project files are lazy; files
are created on the first entry. *Python with `difflib` for the similarity*: `bin/` is bash, and
`SequenceMatcher` buys little over token Jaccard on one-line items. *Semantic duplicate
detection in the tool*: whether two entries mean the same thing is a judgment, so the Stop hook
asks for it, as D33 keeps "is this a decision" a judgment.

**Cost.** Three lines of context per prompt. One extra block per session where open work is
named without a TODO item — the intended cost. `doc-dupes` is O(n²) over the items of one file;
the largest list here (`~/dev/TODO.md`, ~60 items) takes well under a second. The open-work
pattern is a heuristic: a reply that discusses `TODO.md` itself trips it once, and "no item is
owed" closes it. The transcript read is the last 400 lines of the session's JSONL.

**Verified.** 2026-10-17, PARTIAL. `./test.sh logs` → `test-logs: 264 passed, 0 failed, 0 skipped`
(prompt hook: in a repo, at the root, non-repo dirs, scratch, skip list, foreign remote, outside
`~/dev`, malformed input; Stop hook: the `NOT YET` entry, open work named with and without a
`TODO.md` write, the ack on repeated lines and its reopening, lower-case tokens ignored,
`todo-dup`, `decision-dup-title`, `todo-cross-file`, the workspace root, scratch under it;
`doc-dupes`: every kind, `--quiet`, `--workspace`, `--all` with an exempt repo, `-h`;
dotaudit `docs-redundant`; registration and docs). `./test.sh docs` → `9 passed, 0 failed`
(synced copies, every check id in § Enforcement). `./test.sh dotaudit` → `All tests passed`,
fixture `dup-logs`: `2 duplicate or near-duplicate log entries: TODO.md:5 todo-dup;
docs/DECISIONS.md:6 decision-dup-title`. `./test.sh shellcheck` → exit 0. `./test.sh bin` → 102
passed. `bin/doc-dupes --all` → `clean — 50 file(s), no duplicates`. Live: the hook was added to
`~/.claude/settings.json` in the session that wrote this, and its next prompt carried
`followup (~/dev/CLAUDE.md § Session workflow, steps 3–6): … decisions → docs/design-decisions.md
(last: 38 · …) | open items → TODO.md (26 open)`. Not yet seen in a fresh session: the Stop hook
blocking on open work named with no `TODO.md` write, in a repo and at `~/dev` (`TODO.md`, recheck
in the next session).

---

## D38 — `pwd-gen`: passwords come from `secrets` in `bin/`, passphrases from a vendored EFF list, nothing is ever stored · 2026-10-17

**Problem.** Nothing in the repo generated a password; each new account meant an ad-hoc
`openssl rand` or a browser's suggestion, with no record of how strong the result was and no
passphrase option for things that have to be typed (disk encryption, Wi-Fi, a master password).

**Decision.** One command, `bin/pwd-gen`, in Python with the standard library only. Random
passwords draw every character with `secrets.choice` from lower, upper, digits and symbols and
require each class at least once, enforced by redrawing the whole candidate — never by placing
one character of each class at a fixed position, which would cut the search space. The entropy
printed on stderr is exact (inclusion–exclusion over the class sizes), so the class rule is
already priced in: 128.1 bits for the 20-character default, not the naive 128.3. Passphrases
(`-w N`) draw from the EFF large wordlist, shipped as `config/pwd-gen/wordlist.txt` with the dice
numbers stripped (CC BY 3.0, attributed in `bin/README.md`); `PWD_GEN_WORDLIST` overrides it and
`/usr/share/dict/words` is only a warned fallback. The tool never writes anything; `--copy` goes to
`pbcopy` with nothing on stdout, so the value is not in scrollback or a session log either.

**Rejected.** *A bash script*: bash 3.2 has no CSPRNG primitive, and `head -c … /dev/urandom |
tr -dc` is modulo-biased unless the rejection is done by hand, which then needs its own tests;
zsh would dodge shellcheck. *`scripts/`*: that directory is repo tooling and deliberately off
`PATH`; a generator is a command one types, so it is `bin/` (bin/README.md § bin vs scripts).
*`/usr/share/dict/words` as the wordlist*: 236k entries with proper nouns, obscure and offensive
words, and it differs per machine; the EFF list is curated for memorability and typing.
*Fixed-position class guarantee*: cheaper than redrawing, but lowers entropy and makes the printed
number a lie. *Storing in the Keychain or printing to a file*: the password manager is the store;
a second copy is a second place to leak from. *A `genpass` name*: Pieter asked for `pwd-gen`. *Testing it from `scripts/test-bin.sh`*: that
suite is bash around two zsh tools; a Python tool gets a Python suite (`scripts/test-pwd-gen.py`,
like `test-mail-report.py`) so the entropy string can be recomputed in the test. *No minimum
wordlist size*: a three-word file would silently yield 1.6-bit words; the floor is 1024 distinct
words (10 bits each), and a smaller list exits 1 instead.

**Cost.** 64 KB of wordlist in the repo. Redrawing costs about 1.2 attempts at the default
length; at `-l 4` with four classes it is about 10, still instant. The entropy line is on stderr
unless `-q`, so `pwd-gen | pbcopy` stays clean.

**Verified.** 2026-10-17: `./test.sh pwdgen` → `Ran 24 tests … OK` (lengths, every class present
over 20 draws, `--no-symbols`, `--symbols #`, `--no-ambiguous` over 30 draws, five distinct lines
for `-n 5`, the exact entropy string recomputed in the test, `-q` silent, the shipped list is
7776 unique words starting `abacus`, comments/blanks/dice format accepted via `PWD_GEN_WORDLIST`,
missing and too-small lists exit 1, `--copy` against a fake `pbcopy` writes 24 chars and prints
nothing, no `pbcopy` on PATH exits 1, `--bogus` and `-l 3` exit 2, stdlib-only imports).
`./test.sh ruff` → clean including both new files. Live: `pwd-gen` → 20 chars, `entropy: 128.1
bits (20 chars, 85-symbol alphabet, every class present)`; `pwd-gen -n 3 --no-ambiguous -q` → 0
ambiguous characters; `pwd-gen -w 6` → 6 words, 77.5 bits; `pwd-gen --copy -q` → empty stdout,
`pbpaste | wc -c` → 20; `pwd-gen --bogus` → exit 2.

## D39 — Model-routing guidance lives once, in the workspace `CLAUDE.md` · 2026-10-17

**Problem.** Which model to hand a coding task to (and at what effort) was a per-session judgment
call, re-derived from memory each time and never written down. Pieter wrote a short routing table
(default Sonnet 5.5 or GPT-6 Sol, cheap models for well-scoped volume, Opus 5.5 / Fable for
escalation, effort and caching rules of thumb) and asked that every assistant working anywhere in
`~/dev` read it — copying it into every project's `CLAUDE.md` if that was what it took.

**Decision.** The section goes once into `claude/dev-CLAUDE.md`, the source of `~/dev/CLAUDE.md`,
under its own heading after *Where the rules live*. Claude Code loads the `CLAUDE.md` of the
working directory and of every ancestor up to `/`, so a session started in any project under
`~/dev` reads the workspace file as well as its own; Codex gets the same file through the
`AGENTS.md → CLAUDE.md` symlink. That is the same mechanism that already delivers the hard rules,
the do-not-touch register and the session workflow to every project (`ai-instructions.md` §
instruction-file layering). The table is dated and says *re-check quarterly*; the re-check is a
workspace `TODO.md` item, not a copy to maintain.

**Rejected.** *Copying the section into all 31 project `CLAUDE.md` files*: 31 copies of a table
that changes quarterly, with no sync check (only the three dotfiles ↔ live pairs are checked by
`scripts/test-docs.py`), and `ai-instructions.md` keeps project files to what is specific to that
project. *A policy doc under `docs/policy/`*: those are read on demand, and the point is that the
assistant has the routing in front of it without being told to look. *Rewriting the numbers*: the
Anthropic prices were checked against the current model table (Sonnet 5.5 $2/$10, cache reads
$0.20, Opus 5.5 $4/$20) and match; the other vendors' figures are Pieter's and go in as written.

**Cost.** Twenty lines in the file every session under `~/dev` loads. A table that will be stale
within a quarter unless the `TODO.md` item is acted on.

**Verified.** 2026-10-17: `diff ~/dev/CLAUDE.md dotfiles/claude/dev-CLAUDE.md` → no output;
`grep -c 'Model selection for coding' ~/dev/CLAUDE.md` → 1; `python3 scripts/test-docs.py` →
`9 passed, 0 failed` (the synced pairs included). Ancestor loading itself is Claude Code's
documented behaviour and is what makes the workspace hard rules reach projects today; not
re-tested in a fresh session.

## D41 — Documentation lookup tries `llms.txt` first, written once in the workspace `CLAUDE.md` · 2026-10-20

**Problem.** Third-party docs were fetched as scraped HTML or found by web search, which costs
context and often returns a version other than the one the project pins. Many docs sites publish
`/llms.txt` (https://llmstxt.org), a Markdown index made for agents, and some also publish
`/llms-full.txt`. Pieter brought in a prompt asking for an "llms.txt first" rule in the global
`~/.claude/CLAUDE.md`, edited through a `~/dotfiles` symlink.

**Decision.** A 13-line § Documentation lookup in `claude/dev-CLAUDE.md` (source of
`~/dev/CLAUDE.md`), after § Model selection for coding. It says: try `llms.txt` first and fetch
only the linked pages the task needs; use `llms-full.txt` only for broad coverage at a reasonable
size; fall back silently; prefer the docs for the pinned version; don't vendor the file. The prompt
lacked one point, which the section adds: a file written for agents is fetched content, data not
instructions (`ai-and-external-services.md` §4). Every session under `~/dev` reads the section
through ancestor loading, the same mechanism as D39.

**Rejected.** *The global `~/.claude/CLAUDE.md`*, which the prompt asked for: that layer holds
machine facts only (`ai-instructions.md` § Layers), and this would have been its only behaviour
rule. The prompt's `~/dotfiles` symlink doesn't exist either: the global file is a copy of
`claude/CLAUDE.md`. *A policy doc only*: those are read on demand, so the rule would be missing at
the moment a lookup happens.

**Cost.** Thirteen lines in every session under `~/dev`. Sessions outside `~/dev` (`~/Claude`
Cowork) don't get the rule, which is acceptable because they don't look up library docs.

**Verified.** PARTIAL. 2026-10-20: `diff ~/dev/CLAUDE.md claude/dev-CLAUDE.md` → no output;
`grep -c '## Documentation lookup' ~/dev/CLAUDE.md` → 1; `python3 scripts/test-docs.py` →
`9 passed, 0 failed`. Not checked yet: whether a fresh session really tries `llms.txt` first. That
is a `TODO.md` item.
