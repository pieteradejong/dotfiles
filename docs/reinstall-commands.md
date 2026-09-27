# Commands to Reconstruct System Installation List

Use these commands to generate up-to-date lists of installed software on a new machine or when documenting your setup.

**Output goes outside the repo.** These lists include the Mac's serial number (`system_profiler`),
the full global git config, installed apps and pip packages: inventory of one machine, not
something to publish. Write them to `~/dev/audit-reports/snapshot/`, private to you, never into
`docs/` ([policy §7](policy/security-and-privacy.md#7-gitignore-facts): untracked-but-unignored
files are one `git add -A` from publication). Once per shell before running any of them:

```bash
umask 077 && mkdir -p ~/dev/audit-reports/snapshot
```

The exceptions are the files `dotbackup` already tracks on purpose (editor extension lists,
`tools/.nvmrc`); those commands still write into the repo.

## Homebrew Packages

```bash
# List all installed Homebrew packages (leaves only, no dependencies)
brew leaves > ~/dev/audit-reports/snapshot/brew-leaves.txt

# List all installed packages including dependencies
brew list > ~/dev/audit-reports/snapshot/brew-list.txt

# Generate Brewfile (already done automatically by dotbackup)
brew bundle dump --file=~/dev/dotfiles/tools/Brewfile --force
```

## Homebrew Casks (macOS Apps)

```bash
# List all installed casks
brew list --cask > ~/dev/audit-reports/snapshot/brew-casks.txt

# Or get both packages and casks
brew list --formula > ~/dev/audit-reports/snapshot/brew-formulae.txt
brew list --cask > ~/dev/audit-reports/snapshot/brew-casks.txt
```

## macOS Applications

```bash
# List all applications in /Applications
ls -1 /Applications > ~/dev/audit-reports/snapshot/macos-applications.txt

# List with more details (name, version, date)
find /Applications -maxdepth 1 -name "*.app" -exec basename {} \; | sort > ~/dev/audit-reports/snapshot/macos-applications-sorted.txt
```

## VS Code Extensions

```bash
# List installed extensions (already done automatically by dotbackup)
code --list-extensions > ~/dev/dotfiles/editors/vscode-extensions.txt
```

## Cursor Extensions

```bash
# List installed extensions (already done automatically by dotbackup)
cursor --list-extensions > ~/dev/dotfiles/editors/cursor-extensions.txt
```

## Node.js Version

```bash
# Get current Node version (already done automatically by dotbackup)
node --version > ~/dev/dotfiles/tools/.nvmrc
```

## Python Packages

```bash
# List all installed pip packages
pip3 list > ~/dev/audit-reports/snapshot/pip-packages.txt

# Or with versions in requirements format
pip3 freeze > ~/dev/audit-reports/snapshot/requirements.txt
```

## System Information

```bash
# macOS version
sw_vers > ~/dev/audit-reports/snapshot/system-info.txt

# Hardware info
system_profiler SPHardwareDataType >> ~/dev/audit-reports/snapshot/system-info.txt
```

## Git Configuration

```bash
# View global git config (already backed up in git/.gitconfig)
git config --global --list > ~/dev/audit-reports/snapshot/git-config.txt
```

## Shell Aliases and Functions

```bash
# Extract aliases from .zshrc
grep "^alias" ~/.zshrc > ~/dev/audit-reports/snapshot/shell-aliases.txt

# Extract functions
grep "^function\|^[a-zA-Z_][a-zA-Z0-9_]*()" ~/.zshrc > ~/dev/audit-reports/snapshot/shell-functions.txt
```

## Complete System Snapshot

```bash
# Create a complete snapshot script
cat > ~/dev/audit-reports/snapshot/generate-snapshot.sh << 'EOF'
#!/bin/bash
echo "=== System Snapshot $(date) ===" > ~/dev/audit-reports/snapshot/system-snapshot.txt
echo "" >> ~/dev/audit-reports/snapshot/system-snapshot.txt

echo "--- macOS Version ---" >> ~/dev/audit-reports/snapshot/system-snapshot.txt
sw_vers >> ~/dev/audit-reports/snapshot/system-snapshot.txt
echo "" >> ~/dev/audit-reports/snapshot/system-snapshot.txt

echo "--- Homebrew Packages ---" >> ~/dev/audit-reports/snapshot/system-snapshot.txt
brew leaves >> ~/dev/audit-reports/snapshot/system-snapshot.txt
echo "" >> ~/dev/audit-reports/snapshot/system-snapshot.txt

echo "--- Homebrew Casks ---" >> ~/dev/audit-reports/snapshot/system-snapshot.txt
brew list --cask >> ~/dev/audit-reports/snapshot/system-snapshot.txt
echo "" >> ~/dev/audit-reports/snapshot/system-snapshot.txt

echo "--- VS Code Extensions ---" >> ~/dev/audit-reports/snapshot/system-snapshot.txt
code --list-extensions >> ~/dev/audit-reports/snapshot/system-snapshot.txt
echo "" >> ~/dev/audit-reports/snapshot/system-snapshot.txt

echo "--- Node Version ---" >> ~/dev/audit-reports/snapshot/system-snapshot.txt
node --version >> ~/dev/audit-reports/snapshot/system-snapshot.txt
echo "" >> ~/dev/audit-reports/snapshot/system-snapshot.txt

echo "Snapshot saved to ~/dev/audit-reports/snapshot/system-snapshot.txt"
EOF

chmod +x ~/dev/audit-reports/snapshot/generate-snapshot.sh
```

## Notes

- Most of these are already automated by `dotbackup` (Brewfile, extensions, .nvmrc)
- Run these commands periodically to keep documentation up to date
- Consider adding a cron job or reminder to regenerate these lists monthly
