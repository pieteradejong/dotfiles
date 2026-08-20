# dotfiles

> 🔄 **Backup & Reproducible System Configuration** - Version-controlled dotfiles for rapid development environment setup

A copy-based dotfiles management system that backs up your live configuration files and enables rapid restoration on new machines. Perfect for maintaining consistent development environments across work and personal machines.

## 🚀 Quick Start

### On a New Machine

```bash
# 1. Clone the repository
git clone git@github.com:YOUR_USERNAME/dotfiles.git ~/dotfiles

# 2. Restore all configurations
~/dotfiles/scripts/sync-dotfiles.sh restore

# 3. Reload shell
source ~/.zshrc

# 4. Install Homebrew packages (if on macOS)
brew bundle install --file=~/dotfiles/tools/Brewfile

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
│   ├── mac-maintenance.sh          # System stats report (manual copy, not sync'd)
│   └── weekly-disk-cleanup.sh      # Weekly cache/trash cleanup (manual copy, not sync'd)
└── docs/           # Documentation
    └── weekly-cleanup.md    # Weekly disk cleanup: setup, schedule, known limitations
```

## 🔄 How It Works

### Copy-Based Workflow

This repository uses a **copy-based workflow** (not symlinks):

- **Live files**: `~/.zshrc`, `~/.gitconfig`, etc. (what your system uses)
- **Repo files**: `~/dotfiles/shell/.zshrc`, `~/dotfiles/git/.gitconfig`, etc. (version controlled)
- **Sync direction**:
  - `dotbackup` → copies live → repo → commits → pushes
  - `dotrestore` → copies repo → live (with safety backup first)

### Why Copy-Based?

- More reliable than symlinks (some apps don't follow symlinks)
- Easier to debug (files exist in expected locations)
- Safer (can restore without breaking existing configs)

## 🔒 Security

### Never Committed

- SSH keys (`id_rsa*`, `id_ed25519*`, `*.pem`, `*.key`)
- Credentials (`*.secret`, `*token*`, `*password*`, `.env*`)
- Shell history (`.zsh_history`, `.bash_history`)
- Personal API keys or tokens

The `.gitignore` file blocks 25+ sensitive file patterns. **Always verify before committing.**

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

## 🚧 Known TODOs

Items identified in the last audit that still need to be done:

- [ ] **`shell/.zshrc` — add secrets sourcing**: Add `[ -f ~/.zshrc.secrets ] && source ~/.zshrc.secrets` at the bottom of `shell/.zshrc`
- [ ] **Rename secrets template**: Rename `shell/zshrc.secret.template` → `shell/.zshrc.secrets.template` (add leading dot, fix plural) to match the filename it's a template for
- [ ] **`.gitignore` — add missing patterns**: Add explicit entries for `.zshrc.secrets`, `.zshrc.local`, and `*secret*` glob (currently has `*.secret` but not `*secret*`)
- [ ] ~~**Create `install.sh`**~~: Skipped — `sync-dotfiles.sh restore` already handles file placement; a separate `install.sh` adds no real value
- [ ] **README — expand secrets pattern section**: Document the `.zshrc.secrets` pattern (what it is, how to set it up, what goes in it)
- [ ] **README — add recovery section**: Add a dedicated section explaining how to recover from a broken shell config using `dotrestore`
- [ ] **Clean up `~/config`**: The `~/config` directory still exists as a separate git repo; determine if it's superseded and remove or archive it
- [ ] **Remove stray `.gitignore_global` at repo root**: `~/dotfiles/.gitignore_global` is a duplicate of `git/.gitignore_global` — delete the root copy and commit
- [ ] **Commit `SETUP.md`**: `SETUP.md` is untracked — either commit it or add it to `.gitignore`
- [ ] **Add Docker integration test**: Create `scripts/test/assertions.sh` — run via `docker run --rm -v ~/dotfiles:/dotfiles debian:bookworm-slim bash -c "apt-get install -qq -y zsh git && /dotfiles/scripts/test/assertions.sh"`. No custom Dockerfile or image build. Assertions to cover: files land in expected locations after `sync-dotfiles.sh restore`, `.zshrc` sources without errors, `dotbackup`/`dotrestore`/`dotstatus` aliases resolve in zsh, `.zshrc.secrets` is absent (not committed). macOS-specific items (Homebrew, iTerm2/Rectangle plists) are explicitly out of scope for this test.

## 📚 Documentation

- [LEARNINGS.md](LEARNINGS.md) - Key learnings and best practices
- [docs/devprocess.md](docs/devprocess.md) - Development process notes
- [docs/reinstall-commands.md](docs/reinstall-commands.md) - Commands to reconstruct system
- [docs/weekly-cleanup.md](docs/weekly-cleanup.md) - Weekly disk cleanup automation (npm/pip cache, Docker prune, Trash)

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

**Made for developers who want reliable, reproducible development environments.**
