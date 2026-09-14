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
