# Commands to Reconstruct System Installation List

Use these commands to generate up-to-date lists of installed software on a new machine or when documenting your setup.

## Homebrew Packages

```bash
# List all installed Homebrew packages (leaves only, no dependencies)
brew leaves > ~/dotfiles/docs/brew-leaves.txt

# List all installed packages including dependencies
brew list > ~/dotfiles/docs/brew-list.txt

# Generate Brewfile (already done automatically by dotbackup)
brew bundle dump --file=~/dotfiles/tools/Brewfile --force
```

## Homebrew Casks (macOS Apps)

```bash
# List all installed casks
brew list --cask > ~/dotfiles/docs/brew-casks.txt

# Or get both packages and casks
brew list --formula > ~/dotfiles/docs/brew-formulae.txt
brew list --cask > ~/dotfiles/docs/brew-casks.txt
```

## macOS Applications

```bash
# List all applications in /Applications
ls -1 /Applications > ~/dotfiles/docs/macos-applications.txt

# List with more details (name, version, date)
find /Applications -maxdepth 1 -name "*.app" -exec basename {} \; | sort > ~/dotfiles/docs/macos-applications-sorted.txt
```

## VS Code Extensions

```bash
# List installed extensions (already done automatically by dotbackup)
code --list-extensions > ~/dotfiles/editors/vscode-extensions.txt
```

## Cursor Extensions

```bash
# List installed extensions (already done automatically by dotbackup)
cursor --list-extensions > ~/dotfiles/editors/cursor-extensions.txt
```

## Node.js Version

```bash
# Get current Node version (already done automatically by dotbackup)
node --version > ~/dotfiles/tools/.nvmrc
```

## Python Packages

```bash
# List all installed pip packages
pip3 list > ~/dotfiles/docs/pip-packages.txt

# Or with versions in requirements format
pip3 freeze > ~/dotfiles/docs/requirements.txt
```

## System Information

```bash
# macOS version
sw_vers > ~/dotfiles/docs/system-info.txt

# Hardware info
system_profiler SPHardwareDataType >> ~/dotfiles/docs/system-info.txt
```

## Git Configuration

```bash
# View global git config (already backed up in git/.gitconfig)
git config --global --list > ~/dotfiles/docs/git-config.txt
```

## Shell Aliases and Functions

```bash
# Extract aliases from .zshrc
grep "^alias" ~/.zshrc > ~/dotfiles/docs/shell-aliases.txt

# Extract functions
grep "^function\|^[a-zA-Z_][a-zA-Z0-9_]*()" ~/.zshrc > ~/dotfiles/docs/shell-functions.txt
```

## Complete System Snapshot

```bash
# Create a complete snapshot script
cat > ~/dotfiles/docs/generate-snapshot.sh << 'EOF'
#!/bin/bash
echo "=== System Snapshot $(date) ===" > ~/dotfiles/docs/system-snapshot.txt
echo "" >> ~/dotfiles/docs/system-snapshot.txt

echo "--- macOS Version ---" >> ~/dotfiles/docs/system-snapshot.txt
sw_vers >> ~/dotfiles/docs/system-snapshot.txt
echo "" >> ~/dotfiles/docs/system-snapshot.txt

echo "--- Homebrew Packages ---" >> ~/dotfiles/docs/system-snapshot.txt
brew leaves >> ~/dotfiles/docs/system-snapshot.txt
echo "" >> ~/dotfiles/docs/system-snapshot.txt

echo "--- Homebrew Casks ---" >> ~/dotfiles/docs/system-snapshot.txt
brew list --cask >> ~/dotfiles/docs/system-snapshot.txt
echo "" >> ~/dotfiles/docs/system-snapshot.txt

echo "--- VS Code Extensions ---" >> ~/dotfiles/docs/system-snapshot.txt
code --list-extensions >> ~/dotfiles/docs/system-snapshot.txt
echo "" >> ~/dotfiles/docs/system-snapshot.txt

echo "--- Node Version ---" >> ~/dotfiles/docs/system-snapshot.txt
node --version >> ~/dotfiles/docs/system-snapshot.txt
echo "" >> ~/dotfiles/docs/system-snapshot.txt

echo "Snapshot saved to ~/dotfiles/docs/system-snapshot.txt"
EOF

chmod +x ~/dotfiles/docs/generate-snapshot.sh
```

## Notes

- Most of these are already automated by `dotbackup` (Brewfile, extensions, .nvmrc)
- Run these commands periodically to keep documentation up to date
- Consider adding a cron job or reminder to regenerate these lists monthly
