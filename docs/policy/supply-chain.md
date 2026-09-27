# Supply chain

Code other people wrote, and the pipelines that build and deploy it. Pins and licensing:
[repo standards](repo-standards.md#dependencies). Secret scanning and GitHub settings:
[security & privacy §9–§10](security-and-privacy.md#9-secret-scanning-in-ci--the-standard-for-every-repo).
Why these rules: [D23](../design-decisions.md#d23--actions-pinned-by-sha-auto-allow-excludes-secret-printing-commands--2026-09-26).

**Every dependency and every CI action runs with your credentials.** An install script runs
as you on this Mac; a workflow step runs with the repo's token. Trust is granted per package
and per action, not per ecosystem.

---

## 1. Adding a dependency

Before the first `npm install <pkg>` or `pip install <pkg>`:

- **Need it?** The standard library, the framework already in use, or twenty lines of your own
  code beat a new dependency.
- **Is it the right package?** Check the exact name against the project's homepage or docs, not a
  search result: typosquats and look-alike names are the common attack. An assistant-suggested
  package name is checked the same way — models invent plausible names, and attackers register them.
- **Is it alive and used?** Recent releases, more than one maintainer, real download counts, an
  issue tracker that responds.
- **What runs at install?** `npm view <pkg> scripts` for `preinstall`/`postinstall`. An install
  script in a small utility package is a reason to pick another.
- **Licence** compatible with the project's ([licensing](repo-standards.md#licensing)).
- Pin exactly, as the repo standards require.

## 2. Lockfiles

- **Committed, and reviewed in the diff.** A lockfile change nobody asked for (a new transitive
  package, a changed `resolved` URL or registry host) is investigated before merging.
- **CI installs from the lockfile only**: `npm ci`, `pnpm install --frozen-lockfile`,
  `yarn install --frozen-lockfile`, `pip install --require-hashes -r requirements.txt` (or `uv sync
  --locked`) where the project supports it.
- **One registry.** No ad-hoc `--registry` flags or git-URL dependencies without a note in the
  README saying why.

## 3. GitHub Actions

- **Third-party actions are pinned by full commit SHA**, with the version as a comment, as this
  repo's workflows do:
  `uses: actions/checkout@<40-char sha> # v7.0.1`. A tag can be moved to malicious code after you
  reviewed it; a SHA cannot. Dependabot's `github-actions` ecosystem updates SHA pins too.
- **Workflow-level `permissions: contents: read`**, widened per job only where a job needs it.
- **`persist-credentials: false`** on `actions/checkout` unless a later step pushes.
- **Never `pull_request_target` or `workflow_run` together with a checkout of the PR's code.** That
  runs a stranger's code with your secrets.
- **Untrusted input is never interpolated into `run:`**. `${{ github.event.*.title }}`, branch
  names and PR bodies go through `env:` and are quoted in the shell.
- **Secrets are scoped to the job and environment that need them**; deploy secrets live in a
  protected GitHub environment, not repo-wide.
- **Reusable workflows called by `@main`** (the security workflow) are only called from repos owned by
  the same account; a third-party reusable workflow is pinned by SHA like an action.

## 4. Vulnerability response

Dependabot alerts are on for every repo ([baseline](security-and-privacy.md#10-github-baseline-settings)).
Exact pins mean nothing updates by itself, so response is deliberate:

| Severity | In a deployed or public project | Elsewhere |
|---|---|---|
| Critical / High | Within 7 days: upgrade, or record why it is not exploitable here | At next touch |
| Moderate / Low | At next touch | At next touch, or dismiss with a reason |

Dismissing an alert needs a reason in GitHub's dismissal field ("vulnerable code not reached",
"dev dependency only"), not a bare dismiss.

## 5. Running code from the internet

- **`curl … | sh` and `npx <pkg>` run unreviewed code.** Download first and read the script; give
  `npx` an exact version (`npx pkg@1.2.3`), never a bare name.
- **Homebrew is the default installer** for tools on this Mac (Brewfile); taps other than
  `homebrew/*` are a deliberate choice.
- **Containers:** pin images by digest in anything deployed; `latest` is a moving target.
- **Editor extensions and MCP servers** are code with your credentials too — install from the
  publisher you meant, and remove what is unused.

## 6. Deployed surfaces

Everything reachable on a URL, whatever the repo's visibility: Vercel projects, GitHub Pages,
Supabase projects, hosted previews.

- **Keep an inventory** (the private GitHub baseline register lists each surface and its owner
  repo). A surface nobody remembers is one nobody patches.
- **Preview deployments are protected** (Vercel Deployment Protection or equivalent) and never
  use production keys or production data.
- **Environment variables are scoped** per environment (development, preview, production).
- **Review what each surface serves before a repo goes public** and after it changes visibility
  ([policy §5](security-and-privacy.md#5-before-a-repo-goes-public)): Pages serves every committed
  file, including ones the site never links.
- **Retire what is unused.** Delete the project or domain; don't leave a stale deploy running old
  dependencies.

## 7. Checklist for a new repo's CI

1. `permissions: contents: read` at workflow level.
2. Every `uses:` pinned by SHA with a version comment.
3. `persist-credentials: false` on checkout.
4. Lockfile-only install (§2).
5. The security CI workflow ([policy §9](security-and-privacy.md#9-secret-scanning-in-ci--the-standard-for-every-repo)).
6. SAST per [secure development §7](secure-development.md#7-checks).
