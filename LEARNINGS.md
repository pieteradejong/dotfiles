# Dotfiles Setup Learnings

## Overview
This document captures key learnings from setting up and improving the dotfiles management system.

## Dotfiles Workflow

### Core Concept
The dotfiles setup uses a **copy-based workflow** (not symlinks):
- **Live files**: `~/.zshrc`, `~/.gitconfig`, etc. (what your shell actually uses)
- **Repo files**: `~/dotfiles/shell/.zshrc`, `~/dotfiles/git/.gitconfig`, etc. (version controlled)
- **Sync direction**: 
  - `dotbackup` → copies live → repo → commits → pushes to GitHub
  - `dotrestore` → copies repo → live (with safety backup first)

### Key Aliases (in `~/.zshrc`)
```bash
export DOTFILES="$HOME/dotfiles"
alias dotfiles="$DOTFILES/scripts/sync-dotfiles.sh"
alias dotbackup="$DOTFILES/scripts/sync-dotfiles.sh push"
alias dotrestore="$DOTFILES/scripts/sync-dotfiles.sh restore"
alias dotstatus="$DOTFILES/scripts/sync-dotfiles.sh status"
alias dottest="$DOTFILES/scripts/test-dotfiles-setup.sh"
```

### Workflow Commands
- **After editing `~/.zshrc`**: Run `dotbackup` to save changes to repo
- **If you mess up `~/.zshrc`**: Run `dotrestore` to recover from repo
- **Check sync status**: Run `dotstatus` to see what differs
- **Test setup**: Run `dottest` to verify everything works

## Test Script Improvements

### Issues Fixed

#### 1. `--help` Flag Not Working
**Problem**: Running `--help` executed the full test suite instead of showing help.

**Root Cause**: Argument parsing was missing from `main()` function.

**Solution**: Added argument parsing at the **start** of `main()` function, before any test execution:
```bash
main() {
    # Parse command line arguments FIRST
    for arg in "$@"; do
        case "$arg" in
            --help|-h)
                echo "Usage: $0 [--help] [--verbose]"
                echo "Runs comprehensive dotfiles test suite"
                exit 0
                ;;
            --verbose|-v)
                VERBOSE=true
                ;;
            *)
                echo "Unknown option: $arg" >&2
                echo "Use --help for usage information" >&2
                exit 1
                ;;
        esac
    done
    # ... rest of function
}
```

**Key Learning**: Always parse command-line arguments **before** executing main logic.

#### 2. TEST 1 Showing Both PASS and FAIL
**Problem**: Directory check showed both "✓ PASS: ~/dotfiles directory exists" and "✗ FAIL: ~/dotfiles NOT found".

**Root Cause**: Using `&&/||` chain where `pass()` function didn't explicitly return 0, causing the `||` branch to execute even when the test passed.

**Original (broken) code**:
```bash
[ -d "$DOTFILES_DIR" ] && pass "~/dotfiles directory exists" || { fail "~/dotfiles NOT found"; return 1; }
```

**Solution**: 
1. Changed to `if/else` structure for clarity
2. Made `pass()`, `fail()`, and `warn()` functions explicitly return 0:
```bash
pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; ((PASS_COUNT++)) || true; return 0; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; ((FAIL_COUNT++)) || true; return 0; }
warn() { echo -e "  ${YELLOW}⚠ WARN${NC}: $1"; ((WARN_COUNT++)) || true; return 0; }
```

**Fixed code**:
```bash
if [ -d "$DOTFILES_DIR" ]; then
    pass "~/dotfiles directory exists"
    [ "$VERBOSE" = true ] && info "Path: $DOTFILES_DIR"
else
    fail "~/dotfiles NOT found"
    return 1
fi
```

**Key Learning**: 
- Functions used in `&&/||` chains must explicitly return 0
- `if/else` is clearer and safer than `&&/||` chains for conditional logic
- Arithmetic expansion `((PASS_COUNT++))` can return non-zero in some cases, so use `|| true` to ensure success

### Verbose Mode
Added `--verbose` flag support:
- Added `VERBOSE=false` variable at top
- Parse `--verbose` or `-v` flag in argument parsing
- Show additional details (file sizes, paths) when verbose mode is enabled

## Bash Scripting Best Practices

### Function Return Values
- Always explicitly `return 0` for success in functions used in conditional chains
- Use `|| true` after arithmetic expansion to ensure it doesn't fail
- Prefer `if/else` over `&&/||` chains for complex conditionals

### Argument Parsing
- Parse arguments **first** in `main()` function
- Use `case` statement for multiple flag options
- Exit early for help/version flags
- Validate unknown arguments and show helpful error messages

### Error Handling
- Use `set -u` to catch undefined variables
- Use `set -e` (or `set -euo pipefail`) for strict error handling
- Return appropriate exit codes (0 for success, 1+ for failure)

## Test Script Features

### Test Coverage
The test script (`test-dotfiles-setup.sh`) validates:
1. Directory structure (dotfiles repo exists, subdirectories present)
2. Required files in repo (shell configs, git configs, editor configs, tools)
3. Sync script functionality (syntax, required functions)
4. Shell aliases (DOTFILES var and all aliases present)
5. Local config files (existence and permissions)
6. Sync status (local vs repo comparison)
7. Git repository status (branch, working tree, unpushed commits)
8. Security check (no sensitive files, .gitignore patterns)
9. Backup directory (existence and backup count)

### Usage
```bash
# Show help
~/dotfiles/scripts/test-dotfiles-setup.sh --help

# Run normal tests
~/dotfiles/scripts/test-dotfiles-setup.sh

# Run with verbose output
~/dotfiles/scripts/test-dotfiles-setup.sh --verbose

# Using alias (after adding to .zshrc)
dottest
dottest --verbose
```

## File Structure

```
~/dotfiles/
├── shell/          # Shell configuration files
│   ├── .zshrc      # Main zsh config (with dotfiles aliases)
│   ├── .p10k.zsh   # Powerlevel10k theme config
│   └── .zprofile   # Zsh profile
├── git/            # Git configuration
│   ├── .gitconfig
│   └── .gitignore_global
├── editors/        # Editor settings
│   ├── vscode-settings.json
│   ├── cursor-settings.json
│   └── *-extensions.txt
├── ssh/            # SSH config
│   └── config
├── tools/          # Tool configurations
│   ├── Brewfile
│   ├── .npmrc
│   └── .nvmrc
├── scripts/        # Management scripts
│   ├── sync-dotfiles.sh      # Main sync script
│   └── test-dotfiles-setup.sh # Test suite
└── macos/          # macOS-specific configs
```

## Common Issues and Solutions

### Issue: `.zshrc: DIFFERS` warning
**Cause**: Live `~/.zshrc` has changes not yet synced to repo.

**Solution**: Run `dotbackup` to sync changes to repo.

### Issue: Aliases not working
**Cause**: `.zshrc` not sourced or aliases not defined.

**Solution**: 
1. Check aliases exist: `grep "alias dot" ~/.zshrc`
2. Source `.zshrc`: `source ~/.zshrc`
3. If missing, run `dotrestore` to restore from repo

### Issue: Test script shows both PASS and FAIL
**Cause**: Function doesn't explicitly return 0, causing `||` branch to execute.

**Solution**: Ensure functions return 0 explicitly: `return 0;`

## Future Improvements

- [ ] Add `dottest` alias to `.zshrc` template in repo
- [ ] Add verbose output throughout all test functions
- [ ] Consider adding `--quiet` flag for minimal output
- [ ] Add test for alias execution (not just presence)
- [ ] Add integration test that actually runs `dotbackup` and `dotrestore`

## Date
Last updated: 2025-12-27
