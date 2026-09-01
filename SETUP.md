# Dotfiles: Audit, Consolidate, and Publish to GitHub

## Background

I have two local repos that need to be resolved into one:

- `~/dev/dotfiles` — my active repo (currently private). Organized into `shell/`, `git/`, `editors/`,
  `scripts/`, `tools/`, `macos/`, `ssh/`. Has working aliases: `dotbackup`, `dotrestore`,
  `dotstatus`. This is the one we're keeping.
- `~/config` — a stale public repo, last touched ~June 2025. Largely superseded by `~/dev/dotfiles`
  but may contain unique files: `.cursorrules`, `LEARNINGS.md`, `docs/`, `.eslintrc.json`.

**End state:**
- `~/dev/dotfiles` is the single source of truth, public on GitHub, fully safe to share
- Secrets are gitignored and sourced from a local-only `~/.zshrc.secrets` file
- `~/config` is archived/superseded
- A new machine can be bootstrapped from a single `git clone` + `./install.sh`

---

## Step 0 — Reconnaissance (STOP here and report before doing anything else)

Run the following and report all findings:

```bash
echo "=== DOTFILES STRUCTURE ===" && find ~/dev/dotfiles -not -path '*/.git/*' -type f | sort
echo "=== DOTFILES GIT ===" && cd ~/dev/dotfiles && git log --oneline -5 && git status && git remote -v
echo "=== CONFIG REPO ===" && (ls -la ~/config 2>/dev/null && cd ~/config && git log --oneline -5 && git status && git remote -v) || echo "~/config not found"
echo "=== ALIASES ===" && type dotbackup dotrestore dotstatus 2>&1
echo "=== STRAY FILES AT ROOT ===" && ls -la ~/dev/dotfiles/.*  2>/dev/null | grep -v "^total\|^\.\.\?\s"
```

Then run a secrets scan across all tracked files:

```bash
grep -rn -E "(API_KEY|SECRET|TOKEN|PASSWORD|PRIVATE|ssh-rsa|ghp_|sk-[a-zA-Z0-9]{20,}|xox[bpoa]-)" \
  ~/dev/dotfiles \
  --include="*.zsh" --include="*.sh" --include="*.json" --include="*.conf" \
  --include="*.md" --include="*.toml" --include="*.env" --include="*.txt" \
  --exclude-dir=".git"
```

Also scan for sensitive files:

```bash
find ~/dev/dotfiles -not -path '*/.git/*' \
  \( -name "*.env" -o -name "*secret*" -o -name "*private*" -o -name "*.pem" -o -name "*.key" \) \
  2>/dev/null
```

**Do not proceed past Step 0 until I have reviewed the output and given the go-ahead.**

---

## Step 1 — Migrate unique content from ~/config

Diff `~/config` against `~/dev/dotfiles`. For each file that exists in `~/config` but is absent
from or meaningfully different in `~/dev/dotfiles`, propose:

1. Where it belongs in the `~/dev/dotfiles` structure
2. Whether to copy it as-is or merge it

Files to check specifically: `.cursorrules`, `LEARNINGS.md`, `docs/`, `.eslintrc.json`,
plus anything else not already covered.

Show me the proposed moves and wait for confirmation before touching anything.

Once confirmed: copy the files, stage, and commit with message `chore: migrate unique content from ~/config`.

---

## Step 2 — Fix known issues

### 2a. Stray `.gitignore_global` at repo root
If `~/dev/dotfiles/.gitignore_global` exists as an untracked file and
`~/dev/dotfiles/git/.gitignore_global` already has the real one, delete the stray root copy.

### 2b. Secrets sourcing in .zshrc
Confirm that `~/dev/dotfiles/shell/.zshrc` (or whichever file is the active zshrc) has this
at the bottom:

```bash
[ -f ~/.zshrc.secrets ] && source ~/.zshrc.secrets
```

If it's missing, add it.

### 2c. `.gitignore` completeness
Confirm `~/dev/dotfiles/.gitignore` includes at minimum:

```
.zshrc.secrets
.zshrc.local
*.local
.env
.env.*
*secret*
*private*
*.pem
*.key
```

Add any missing entries.

### 2d. `.zshrc.secrets.template`
If `~/dev/dotfiles/shell/.zshrc.secrets.template` doesn't exist:
- Read `~/.zshrc.secrets` (local only — never commit it) and extract key names only
- Create the template with empty values, e.g.:
  ```bash
  # Copy to ~/.zshrc.secrets and fill in actual values
  # This file is gitignored — never commit ~/.zshrc.secrets itself

  export ANTHROPIC_API_KEY=""
  export OPENAI_API_KEY=""
  # add others from your actual ~/.zshrc.secrets
  ```
- If `~/.zshrc.secrets` doesn't exist, create a minimal template with common keys

Commit Step 2 changes with message `chore: secrets pattern, gitignore, zshrc sourcing`.

---

## Step 3 — Verify and fix install.sh

`~/dev/dotfiles/install.sh` must:
- Symlink all tracked dotfiles to their correct `~` locations
- Back up any pre-existing file before overwriting (timestamped to `~/.dotfiles-backup/`)
- Be fully idempotent (safe to run multiple times without side effects)
- Cover at minimum: `shell/.zshrc`, `shell/.p10k.zsh`, `shell/.zprofile`,
  `git/.gitconfig`, `git/.gitignore_global`, `ssh/config`
- Print clear output for each symlink created or skipped

Show me the full `install.sh` content before committing. If it already exists and meets
the above, just confirm it and move on.

Commit with message `chore: install.sh symlink setup`.

---

## Step 4 — Verify and update README.md

The README must document:

1. **Repo structure** — what each directory (`shell/`, `git/`, `editors/`, etc.) contains
2. **New machine setup** — step-by-step:
   - `git clone` the repo
   - Install Homebrew if needed
   - `brew bundle install --file=tools/Brewfile`
   - `./install.sh`
   - Copy `shell/.zshrc.secrets.template` to `~/.zshrc.secrets` and fill in values
   - Reload shell
3. **Commands** — `dotbackup`, `dotrestore`, `dotstatus` (what each does)
4. **Secrets pattern** — explain `.zshrc.secrets`, the template, and why it's gitignored
5. **Recovery** — how to restore from a backup in `~/.dotfiles-backup/`

Show me the diff vs the current README before committing.

Commit with message `docs: update README for public release`.

---

## Step 5 — Final pre-publish checklist

Run a final check and report pass/fail for each item:

- [ ] Secrets scan from Step 0 is clean (no hits in tracked files)
- [ ] All unique `~/config` content migrated
- [ ] Stray `.gitignore_global` at root removed
- [ ] `.zshrc` sources `~/.zshrc.secrets`
- [ ] `.gitignore` covers all sensitive patterns
- [ ] `.zshrc.secrets.template` committed (with no real values)
- [ ] `install.sh` present, idempotent, and covers all key dotfiles
- [ ] README is complete and accurate
- [ ] `git remote -v` shows the correct GitHub origin
- [ ] `git status` is clean — no uncommitted changes
- [ ] No `.env` files or key/pem files tracked

**Wait for my explicit "go ahead" before flipping visibility.**

Once I approve, make the repo public:

```bash
gh repo edit --visibility public --accept-visibility-change-warnings
```

Confirm by printing the public repo URL.

---

## Step 6 — Archive ~/config

After `~/dev/dotfiles` is confirmed public:

1. Update `~/config/README.md` to say it's been superseded, with a link to the new repo
2. Commit and push that to the `~/config` remote
3. Ask me before archiving — if I confirm, run:
   ```bash
   gh repo archive $(cd ~/config && git remote get-url origin | sed 's/.*github.com[:/]//' | sed 's/\.git$//')
   ```
4. Leave `~/config` local directory in place — I'll clean it up manually

---

## Rules

- **Stop after Step 0** and wait for my confirmation before proceeding
- **Never commit** `~/.zshrc.secrets` or any file containing actual secret values
- **Show diffs** for any changes to `.zshrc`, `install.sh`, and `README.md` before committing
- **Commit each step separately** with the message specified
- **Ask before acting** on anything ambiguous — don't infer or guess
- If `gh` CLI is not installed, flag it early and suggest `brew install gh` + `gh auth login`

