# dotfiles

> 🔄 **Backup & Reproducible System Configuration** - Version-controlled dotfiles for rapid development environment setup

A copy-based dotfiles management system that backs up your live configuration files and enables rapid restoration on new machines. Perfect for maintaining consistent development environments across work and personal machines.

## 🎯 Purpose

This repo exists so the entire computer — dev environment, shell, editor
config, tool versions, macOS app settings — can be reproduced from
scratch on a new machine, using nothing but `git clone` and this repo.
If this Mac dies or gets replaced, cloning the repo and running
`dotrestore` should get a new one back to a working state without
hunting through memory for what was configured where.

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
│   └── com.pieterdejong.weeklycleanup.plist   # LaunchAgent: weekly cache/trash cleanup
├── scripts/        # Management scripts
│   ├── sync-dotfiles.sh      # Main sync script
│   ├── test-dotfiles-setup.sh
│   ├── mac-maintenance.sh          # System stats report (only copy, run from here)
│   └── weekly-disk-cleanup.sh      # Weekly cache/trash cleanup (manual copy, not sync'd)
└── docs/           # Documentation
    └── weekly-cleanup.md    # Weekly disk cleanup: setup, schedule, known limitations
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

### Never Committed

- SSH keys (`id_rsa*`, `id_ed25519*`, `*.pem`, `*.key`)
- Credentials (`*.secret`, `*token*`, `*password*`, `.env*`)
- Shell history (`.zsh_history`, `.bash_history`)
- Personal API keys or tokens

The `.gitignore` file blocks 25+ sensitive file patterns. **Always verify before committing.**

### Secrets pattern

Anything that shouldn't be public (API keys, personal tokens, etc.) goes in
`~/.zshrc.secrets` — a file that lives outside this repo and is never
committed:

1. Copy the template: `cp shell/.zshrc.secrets.template ~/.zshrc.secrets`
2. Fill in real values in `~/.zshrc.secrets` (exports, aliases — anything
   you don't want public).
3. `shell/.zshrc` sources it automatically if present:
   `[ -f ~/.zshrc.secrets ] && source ~/.zshrc.secrets` — no per-machine
   setup needed beyond creating the file.
4. `.gitignore` blocks `.zshrc.secrets`, `.zshrc.local`, and any
   `*secret*`-matching filename (except `*.template` files, which are meant
   to be committed as examples) — so `dotbackup` can never accidentally
   commit it.

### Last audit — 2026-08-20

Full-history scan (all commits, all files) for realistic secret patterns
(GitHub PATs, Anthropic/OpenAI/AWS keys, Slack tokens, PEM private keys):
**clean, nothing ever leaked.** No private key has ever been committed
(confirmed via `git log --all -- "*id_ed25519*" "*siteground_private*"`).

Two pre-existing, already-public privacy items were found (not secrets —
nothing here grants access on its own) and are tracked in Known TODOs below:
- `git/.gitconfig` — real full name + personal email (also visible via commit author metadata regardless)
- `ssh/config` — real personal domain and a real hosting account username (private key correctly excluded)

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
- Weekly disk cleanup LaunchAgent schedule (see [docs/weekly-cleanup.md](docs/weekly-cleanup.md))

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

- [ ] **Secrets filename mismatch — singular vs plural** ⚠️ *regressed 2026-09-01*: The live (and now tracked) `shell/.zshrc` sources `~/.zshrc.secret` (**singular**, line 2), which is the file that actually exists and holds the real values. But `shell/.zshrc.secrets.template`, the [Secrets pattern](#secrets-pattern) section above, and `scripts/test/assertions.sh:56` all reference `.zshrc.secrets` (**plural**) — so **that assertion currently fails**. Not a security hole: `.gitignore` covers both via `*secret*`, and no secrets file has ever been committed. Fix by picking one name — aligning the docs/template/test to the singular reality is the lower-risk direction, since it doesn't touch a live file holding real credentials.
- [ ] **`shell/.zshrc` sources a dead path**: `[[ -f ~/scripts/ollm.zsh ]] && source ~/scripts/ollm.zsh` — `~/scripts/` no longer exists (contents moved to `~/dev/projects/scripts/`), so this is a silent no-op. Update the path to `~/dev/projects/scripts/ollm.zsh` in the *live* `~/.zshrc`, then `dotbackup`.
- [x] **`.gitignore` — add missing patterns**: `.zshrc.secrets`, `.zshrc.local`, and `*secret*` are all covered (verified 2026-09-04)
- [ ] ~~**Create `install.sh`**~~: Skipped — `sync-dotfiles.sh restore` already handles file placement; a separate `install.sh` adds no real value
- [x] **README — expand secrets pattern section**: See [Secrets pattern](#secrets-pattern) above
- [x] **README — add recovery section**: See [Recovery](#-recovery) below
- [x] **Clean up `~/config`**: Reviewed file-by-file (2026-08-31) — everything was superseded or stale (old `.cursorrules`, a ~2019 package list, generic editor snippets, unused `.bashrc`, a one-off license-generator script). Nothing migrated; the directory was renamed to `~/config.archived-2026-08-31` rather than deleted.
- [x] **Remove stray `.gitignore_global` at repo root**: Deleted; `git/.gitignore_global` remains the real one
- [x] **Commit `SETUP.md`**: Now tracked
- [x] **Add Docker integration test**: `scripts/test/assertions.sh` exists and runs via `docker run --rm -v ~/dev/dotfiles:/dotfiles debian:bookworm-slim bash -c "apt-get install -qq -y zsh git && /dotfiles/scripts/test/assertions.sh"`
- [ ] **`ssh/config` — hostname/account exposure**: Reviewed 2026-08-31 — **accepted as-is**. Real personal domain and hosting account username are public in this file, but it's key-auth only (private key correctly gitignored, never committed) and grants nothing on its own.
- [ ] **`git/.gitconfig` — identity exposure**: Reviewed 2026-08-31 — **accepted as-is**. Real full name and personal email are committed here, but commit author metadata already exposes both on every commit regardless, so redacting this file alone wouldn't change the actual exposure.

## 📚 Documentation

- [LEARNINGS.md](LEARNINGS.md) - Key learnings and best practices
- [docs/devprocess.md](docs/devprocess.md) - Development process notes
- [docs/reinstall-commands.md](docs/reinstall-commands.md) - Commands to reconstruct system
- [docs/weekly-cleanup.md](docs/weekly-cleanup.md) - Weekly disk cleanup automation (npm/pip cache, Docker prune, Trash)
- [docs/mac-maintenance.md](docs/mac-maintenance.md) - Manual health/cleanup script (uptime, memory, Library/Caches)
- [docs/maintenance-audit-2026-09.md](docs/maintenance-audit-2026-09.md) - Full record of the Aug/Sep 2026 cleanup, `~/config` retirement, and security/privacy audit

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

**Made for developers who want reliable, reproducible development environments.**
