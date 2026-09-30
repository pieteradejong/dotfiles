# dotfiles

My macOS dev and home setup, kept in git for two reasons.

## 🎯 Goals

1. **Back up this machine's setup.** If this Mac dies, a new one gets back to a working state
   from `git clone`, `sync-dotfiles.sh restore` and `brew bundle` (Quick Start below), without
   hunting through memory. Deliberately **not** backed up here: secrets (`~/.zshrc.secret`, keys,
   tokens; see the secrets pattern below), app data, and the repos under `~/dev`, which live on
   GitHub.
2. **Let other people copy what they like.** Take a file, not the repo: each one below stands on
   its own, and the repo is MIT-licensed. Home paths are stored as `$HOME` and personal values
   are scrubbed, so what you copy is generic.

| Take | What it is | Needs |
|---|---|---|
| `shell/.zshrc`, `shell/.p10k.zsh` | zsh setup, aliases, Powerlevel10k prompt | oh-my-zsh, powerlevel10k |
| `git/.gitconfig`, `git/.gitignore_global` | git defaults | git |
| `tools/Brewfile` | every Homebrew package on this Mac | Homebrew |
| `editors/*` | VS Code and Cursor settings and extension lists | the editor |
| `macos/*.plist` | iTerm2 and Rectangle preferences | the app |
| `bin/llm` | prompt a local model, never the cloud ([docs/llm.md](docs/llm.md)) | Ollama, `jq` |
| `scripts/sync-dotfiles.sh` | copy-based backup/restore that sanitizes on the way in | bash, `jq` |

**Scope test for anything new:** *does it help restore this machine, or would someone copy it?*
If neither, it belongs somewhere else, or nowhere. The workspace security tooling
(`security/`, the audits, `docs/policy/`) fails that test. It governs every repo under `~/dev`,
not this setup, and is moving to its own repo. Retired material goes to [`archive/`](archive/).

## 🚀 Quick Start

### On a New Machine

```bash
# 1. Clone the repository
git clone git@github.com:YOUR_USERNAME/dotfiles.git ~/dev/dotfiles

# 2. Restore all configurations
~/dev/dotfiles/scripts/sync-dotfiles.sh restore

# 3. Reload shell
source ~/.zshrc

# 4. Install Homebrew packages (if on macOS)
brew bundle install --file=~/dev/dotfiles/tools/Brewfile

# 5. Install editor extensions
dotfiles extensions
```

### Daily Workflow

```bash
# After editing ~/.zshrc or any config
dotbackup    # Backup changes to repo and push to GitHub

# Check sync status
dotstatus    # See what differs between local and repo

# If you mess something up
dotrestore   # Restore from repo (with safety backup)
```

## 📋 Commands

| Command | Description |
|---------|-------------|
| `dotbackup` | Backup local configs → repo → commit → push |
| `dotrestore` | Restore repo configs → local (with confirmation) |
| `dotstatus` | Check sync status between local and repo |
| `dotfiles extensions` | Install VS Code/Cursor extensions from lists |
| `dottest` | Run comprehensive test suite |
| `dotaudit` | Read-only audit of every git repo under `~/dev` (see [docs/dev-audit.md](docs/dev-audit.md)) |
| `./test.sh` | Every test in this repo: shellcheck, the security gate, its tools, `dotaudit` (CI runs exactly this) |
| `security/gate.sh status` | Is the commit/push security gate installed and intact? |
| `security/gate.sh scan-tree` | What would the gate say about everything `git add -A` would commit? |
| `scripts/security-audit.sh` | The weekly security & privacy audit, on demand (see [docs/maintenance.md](docs/maintenance.md)) |
| `scripts/github-security-sweep.sh` | GitHub secret scanning / push protection / Dependabot alerts on every owned repo (dry run by default) |

## 📁 Repository Structure

```
dotfiles/
├── shell/          # Shell configurations
│   ├── .zshrc      # Main zsh config (with dotfiles aliases)
│   ├── .p10k.zsh   # Powerlevel10k theme config
│   └── .zprofile   # Zsh profile
├── git/            # Git configuration
│   ├── .gitconfig
│   └── .gitignore_global
├── editors/        # Editor settings
│   ├── vscode-settings.json
│   ├── cursor-settings.json
│   ├── vscode-extensions.txt
│   └── cursor-extensions.txt
├── ssh/            # SSH config (NEVER keys)
│   └── config
├── tools/          # Tool configurations
│   ├── Brewfile    # Homebrew packages
│   ├── .npmrc      # npm configuration
│   ├── .nvmrc      # Node version
│   └── docker-config.json
├── macos/          # macOS-specific configs
│   ├── com.googlecode.iterm2.plist
│   ├── rectangle.plist
│   ├── com.pieterdejong.weeklycleanup.plist   # LaunchAgent: weekly cache/trash cleanup
│   └── com.pieterdejong.securityaudit.plist   # LaunchAgent: weekly security & privacy audit
├── security/       # The commit/push security gate (runs in every repo on this machine)
│   ├── gate.sh                     # pre-commit | pre-push | scan-tree | status
│   ├── patterns.sh                 # what must never be published — shared with dotaudit
│   ├── gitleaks.toml               # shared gitleaks config (gate, dotaudit, CI)
│   └── lib/visibility.sh           # is this push going somewhere public?
├── claude/
│   ├── hooks/guard-git-bypass.sh   # Claude Code hook: the assistant cannot bypass the gate
│   └── hooks/guard-github-write.sh # Claude Code hook: no content writes through the GitHub API
├── bin/            # On PATH - general commands, run in place from here
│   ├── llm                         # prompt a local model, never the cloud (docs/llm.md)
│   └── weekly-disk-cleanup.sh      # only copy; launchd runs this path
├── scripts/        # Management scripts for this repo - deliberately NOT on PATH
│   ├── sync-dotfiles.sh            # Main sync script
│   ├── test-dotfiles-setup.sh
│   ├── mac-maintenance.sh          # System stats report (only copy, run from here)
│   ├── test-bin.sh                 # bin/ routing, zero-cloud guards, cleanup safety
│   ├── security-audit.sh           # weekly full security & privacy audit
│   ├── github-security-sweep.sh    # GitHub-side settings for every owned repo
│   ├── dev-audit.sh                # `dotaudit`: read-only audit of all ~/dev git repos
│   ├── test-dev-audit.sh           # its test suite
│   ├── test-security-gate.sh       # the gate's test suite
│   ├── test-security-tools.sh      # guard hook, sweep, weekly audit, dotaudit gate module
│   └── audit/                      # dotaudit's checks - see docs/dev-audit.md
│       ├── lib.sh                  #   git_ro(), findings, repo discovery
│       ├── skiplist.example.conf   #   format only; the real list is in private/
│       ├── 10-git-hygiene.sh       #   unpushed work, no remote, bloat
│       ├── 20-policy.sh            #   LICENSE, .gitignore, CI
│       ├── 30-privacy.sh           #   secrets/personal data in TRACKED files
│       ├── 40-disk.sh              #   large files, rebuildable dirs, backup gaps
│       ├── 50-gate.sh              #   the gate is registered, intact, not bypassed
│       └── render-report.sh        #   TSV -> markdown
├── .github/workflows/
│   ├── ci.yml                      # security + private/ guard + ./test.sh
│   ├── security-reusable.yml       # the CI every repo calls: gitleaks + gate.sh ci
│   └── gitleaks-reusable.yml       # secrets-only predecessor, kept for old callers
├── docs/           # Documentation
│   ├── policy/                     # the rules: security & privacy, repo standards, AI instructions, backups
│   ├── design-decisions.md         # why the gate, audit and public/private split work as they do
│   ├── maintenance.md              # everything scheduled, and the monthly manual checklist
│   └── dev-audit.md                # dotaudit: checks, design rules, gotchas
├── test.sh         # runs every test suite
├── archive/        # retired files, kept for reference; never loaded, run or linked from active docs
└── private/        # NOT PART OF THIS REPO — a separate private repo cloned in place, gitignored
```

## 🔄 How It Works

### Copy-Based Workflow

This repository uses a **copy-based workflow** (not symlinks):

- **Live files**: `~/.zshrc`, `~/.gitconfig`, etc. (what your system uses)
- **Repo files**: `~/dev/dotfiles/shell/.zshrc`, `~/dev/dotfiles/git/.gitconfig`, etc. (version controlled)
- **Sync direction**:
  - `dotbackup` → copies live → repo → commits → pushes
  - `dotrestore` → copies repo → live (with safety backup first)

### Why Copy-Based?

- More reliable than symlinks (some apps don't follow symlinks)
- Easier to debug (files exist in expected locations)
- Safer (can restore without breaking existing configs)

## 🔒 Security

**This repo is public on GitHub.** Anything committed here is world-readable and stays recoverable from git history even if later deleted from the working tree — treat every commit as permanent and public.

The rules live in [docs/policy/security-and-privacy.md](docs/policy/security-and-privacy.md); the
reasoning in [docs/design-decisions.md](docs/design-decisions.md). In short:

- **Every commit and push on this machine passes the security gate** (`security/gate.sh`,
  registered in `~/.gitconfig`): secrets, key and `.env` files and files over 50 MB are
  blocked everywhere; personal data is blocked on the way to a public remote.
- **Private material lives in `private/`**, a separate private repo cloned in place. It is
  gitignored, refused by the gate at commit and push, and refused again by CI.
- **CI** runs a full-history gitleaks scan, the `private/` guard and `./test.sh` on every push.
- **Weekly**, `scripts/security-audit.sh` audits every repo, GitHub's settings and this machine.

**Quick safety check** before committing here (about a second): `security/gate.sh scan-tree`
checks everything `git add -A` would commit (secrets, credential files, personal data) and prints
nothing when clean. `./test.sh` (a few minutes; run it as `./test.sh </dev/null`) tests the tooling
itself.

### Never Committed

- SSH keys (`id_rsa*`, `id_ed25519*`, `*.pem`, `*.key`)
- Credentials (`*.secret`, `*token*`, `*password*`, `.env*`)
- Shell history (`.zsh_history`, `.bash_history`)
- Personal API keys or tokens

The `.gitignore` blocks these by name (layer one); the gate checks content and names
independently (layer two).

### Secrets pattern

Anything that shouldn't be public (API keys, personal tokens, etc.) goes in
`~/.zshrc.secret` — a file that lives outside this repo and is never
committed:

1. Copy the template: `cp shell/.zshrc.secret.template ~/.zshrc.secret`
2. Fill in real values in `~/.zshrc.secret` (exports, aliases — anything
   you don't want public).
3. `shell/.zshrc` sources it automatically if present:
   `[ -f ~/.zshrc.secret ] && source ~/.zshrc.secret` — no per-machine
   setup needed beyond creating the file.
4. `.gitignore` blocks `.zshrc.secret`, `.zshrc.local`, and any
   `*secret*`-matching filename (except `*.template` files, which are meant
   to be committed as examples) — so `dotbackup` can never accidentally
   commit it.

### Audits

Continuous: the weekly audit report in `~/dev/audit-reports/` (never committed). History of
past findings is kept in the private companion repo, not here.

## 🛠️ What Gets Backed Up

### Shell
- `.zshrc` - Main shell configuration
- `.p10k.zsh` - Powerlevel10k theme
- `.zprofile` - Zsh profile

### Git
- `.gitconfig` - Global git settings
- `.gitignore_global` - Global ignore patterns

### Editors
- VS Code settings and extensions
- Cursor settings and extensions

### Tools
- Homebrew packages (`Brewfile`)
- Node version (`.nvmrc`)
- npm config (`.npmrc`)
- Docker config

### macOS
- iTerm2 preferences
- Rectangle window manager settings
- Weekly disk cleanup and weekly security audit LaunchAgents (see [docs/maintenance.md](docs/maintenance.md))

## 📝 Maintenance

### Adding New Config Files

1. Edit `scripts/sync-dotfiles.sh`
2. Add to `do_backup()` function
3. Add to `do_restore()` function
4. Add to `do_status()` function
5. Run `dotbackup` to test

### Testing

```bash
# Run comprehensive test suite
dottest

# Run with verbose output
dottest --verbose
```

## 🐛 Troubleshooting

### Issue: `.zshrc: DIFFERS` warning
**Solution**: Run `dotbackup` to sync changes to repo

### Issue: Aliases not working
**Solution**: 
1. Check aliases exist: `grep "alias dot" ~/.zshrc`
2. Source `.zshrc`: `source ~/.zshrc`
3. If missing, run `dotrestore`

### Issue: Restore overwrote my changes
**Solution**: Check `~/.dotfiles-backup/pre-restore-*/` for safety backups

## 🩹 Recovery

If `~/.zshrc` (or another tracked config) gets broken — a bad edit, a
misconfigured tool that clobbered it, whatever — restore the last known-good
version from this repo:

```bash
dotrestore
# equivalent to: ~/dev/dotfiles/scripts/sync-dotfiles.sh restore
```

This copies every file from `~/dev/dotfiles` back to its live location in `~`,
after first snapshotting whatever is currently live into
`~/.dotfiles-backup/pre-restore-<timestamp>/` — so a bad restore is itself
recoverable. A fresh shell (or `source ~/.zshrc`) picks up the restored
config immediately; `dotrestore` also sources `~/.zshrc` automatically at
the end of the run.

If `dotrestore` itself won't run because the shell is too broken to load the
`dotrestore` alias, run the underlying script directly:

```bash
zsh ~/dev/dotfiles/scripts/sync-dotfiles.sh restore
```

## 🚧 Known TODOs

Items identified in the last audit — most are now done; a couple were
deliberately decided against or accepted as-is rather than "fixed":

- [x] **Secrets filename mismatch — singular vs plural**: settled 2026-09-27 on the singular `~/.zshrc.secret`, the live file that holds the values (renaming it would mean moving a credential file). Template renamed to `shell/.zshrc.secret.template`; this README, `SETUP.md` and `scripts/test/assertions.sh` follow.
- [x] ~~**`shell/.zshrc` sources a dead path** (`~/scripts/ollm.zsh`)~~: Obsolete as written — the source line is gone from the live `~/.zshrc`, and `ollm.zsh` was itself deleted rather than moved when `llm` replaced it, so there was no path to repoint at. The directory it lived in (`~/dev/projects/scripts/`) is also gone: its contents are now `bin/` in this repo (2026-09-22).
- [x] **`.gitignore` — add missing patterns**: `.zshrc.secret`, `.zshrc.local`, and `*secret*` are all covered (verified 2026-09-04)
- [ ] ~~**Create `install.sh`**~~: Skipped — `sync-dotfiles.sh restore` already handles file placement; a separate `install.sh` adds no real value
- [x] **README — expand secrets pattern section**: See [Secrets pattern](#secrets-pattern) above
- [x] **README — add recovery section**: See [Recovery](#-recovery) below
- [x] **Clean up `~/config`**: Reviewed file-by-file (2026-08-31) — everything was superseded or stale (old `.cursorrules`, a ~2019 package list, generic editor snippets, unused `.bashrc`, a one-off license-generator script). Nothing migrated; the directory was renamed to `~/config.archived-2026-08-31` rather than deleted.
- [x] **Remove stray `.gitignore_global` at repo root**: Deleted; `git/.gitignore_global` remains the real one
- [x] **Commit `SETUP.md`**: Now tracked
- [x] **Add Docker integration test**: `scripts/test/assertions.sh` exists and runs via `docker run --rm -v ~/dev/dotfiles:/dotfiles debian:bookworm-slim bash -c "apt-get install -qq -y zsh git && /dotfiles/scripts/test/assertions.sh"`
- [x] **`ssh/config` — hostname/account exposure**: the 2026-08-31 "accept as-is" was reversed. The file is now a placeholder template, `sync-dotfiles.sh backup` sanitizes it on the way in, and the gate blocks the real values. Earlier history is not rewritten (see design decision D11).
- [x] **`git/.gitconfig` — identity exposure**: reversed likewise — noreply address, home paths sanitized on backup; the gate blocks non-noreply authors on public pushes.

## 📚 Documentation

- [docs/system-overview.md](docs/system-overview.md) - **Start here** - what this repo is for, where everything lives, the maintenance model, and run history
- [LEARNINGS.md](LEARNINGS.md) - Key learnings and best practices
- [docs/devprocess.md](docs/devprocess.md) - Development process notes
- [docs/reinstall-commands.md](docs/reinstall-commands.md) - Commands to reconstruct system
- [docs/policy/](docs/policy/) - The rules: security & privacy, repo standards, AI instruction files, backups
- [docs/design-decisions.md](docs/design-decisions.md) - Why the security gate, weekly audit and public/private split are built as they are
- [docs/maintenance.md](docs/maintenance.md) - Every scheduled job (security audit, disk cleanup, docs backup), the manual script, and the monthly checklist
- [docs/dev-audit.md](docs/dev-audit.md) - `dotaudit`: what each check means

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

**Made for developers who want reliable, reproducible development environments.**
