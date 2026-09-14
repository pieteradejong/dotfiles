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
alias dothelp="$DOTFILES/scripts/dothelp.sh"
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
│   ├── test-dotfiles-setup.sh # Test suite
│   └── dothelp.sh            # Help command
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

### Issue: Edits made in the repo silently disappear after `dotbackup`

**Problem**: On 2026-08-31, `shell/.zshrc` was edited *in the repo* to source
`~/.zshrc.secrets`. The next `dotbackup` (2026-09-01) reverted it, and the
change was gone with no warning — while the README still claimed it was done.

**Root cause**: This repo is **copy-based, and `dotbackup` only flows one way
— live → repo.** It copies `~/.zshrc` over `shell/.zshrc` wholesale. Any edit
made to the repo copy that was not *also* made to the live file in `~` is
overwritten the next time you back up. The repo copy is a backup artifact,
not a source you edit.

**Solution**: Edit the **live** file in `~`, then run `dotbackup` to
propagate it into the repo. If you've already edited the repo copy, either
re-apply the change to the live file, or run `dotrestore` to push the repo
version out to `~` *before* the next backup — but note `dotrestore`
overwrites live files, so check `dotstatus` first.

**Watch for**: a repo-side edit plus a doc update describing it as done. The
doc survives (docs aren't overwritten by `dotbackup`), the actual change
doesn't — leaving documentation that confidently describes a state the repo
is no longer in. Verify against the live file, not the README.

### Issue: Test script shows both PASS and FAIL
**Cause**: Function doesn't explicitly return 0, causing `||` branch to execute.

**Solution**: Ensure functions return 0 explicitly: `return 0;`

### Issue: `dotbackup` not committing all files
**Problem**: After running `dotbackup`, uncommitted files remained (e.g., new `scripts/dothelp.sh`, modified `shell/.zshrc`).

**Root Cause**: 
1. With `set -euo pipefail`, if `do_backup` returns non-zero (even for warnings), the script exits before reaching commit/push code
2. The commit check logic was flawed - `git diff --staged --quiet` returns non-zero when there ARE staged changes, which with `set -e` causes script to exit

**Original (broken) code**:
```bash
do_push() {
    do_backup; log ""; log "${BLUE}Committing and pushing...${NC}"; cd "$DOTFILES_DIR"
    git add -A; git commit -m "backup $(date '+%Y-%m-%d %H:%M')" || warn "Nothing to commit"; git push && success "Pushed to remote"
}
```

**Solution**:
1. Added `|| true` after `do_backup` to prevent script exit on warnings
2. Fixed commit check logic to properly handle exit codes:
```bash
do_push() {
    do_backup || true  # Don't exit if backup has warnings
    log ""; log "${BLUE}Committing and pushing...${NC}"; cd "$DOTFILES_DIR"
    git add -A
    staged_changes=$(git diff --staged --quiet 2>/dev/null && echo "0" || echo "1")
    unstaged_changes=$(git diff --quiet 2>/dev/null && echo "0" || echo "1")
    if [ "$staged_changes" = "0" ] && [ "$unstaged_changes" = "0" ]; then
        warn "Nothing to commit"
    else
        git commit -m "backup $(date '+%Y-%m-%d %H:%M')" && success "Committed changes" || fail "Commit failed"
    fi
    git push && success "Pushed to remote" || warn "Push failed or nothing to push"
}
```

**Key Learning**:
- With `set -euo pipefail`, any non-zero exit code causes script to exit
- Use `|| true` after commands that might fail but shouldn't stop execution
- `git diff --quiet` returns non-zero when there ARE differences - capture exit code in variable instead of using directly in conditionals
- Always test commit logic with actual staged/unstaged changes

## Sync Script Improvements

### dothelp Command
Added `dothelp` command to provide comprehensive help for all dotfiles commands:
- **Location**: `~/dotfiles/scripts/dothelp.sh`
- **Purpose**: Shows all commands, their usage, workflow examples, file locations, and troubleshooting
- **Usage**: `dothelp` (or `~/dotfiles/scripts/dothelp.sh`)
- **Features**:
  - Colorized output matching test script style
  - Sections for main commands, subcommands, workflows, file locations, troubleshooting
  - Clear explanations of when to use each command

## Future Improvements

- [ ] Add `dottest` alias to `.zshrc` template in repo
- [ ] Add verbose output throughout all test functions
- [ ] Consider adding `--quiet` flag for minimal output
- [ ] Add test for alias execution (not just presence)
- [ ] Add integration test that actually runs `dotbackup` and `dotrestore`

## Date
Last updated: 2025-12-27

## Additional Notes

### Understanding `dotbackup` Behavior
- `dotbackup` copies files FROM live locations TO repo (one-way sync)
- It then commits ALL changes in the repo (including new files like `dothelp.sh`)
- If you modify files directly in the repo, `dotbackup` will overwrite them with live versions
- Best practice: Edit live files, then run `dotbackup` to sync to repo
- For new repo-only files (like scripts), commit them separately or they'll be included in the next `dotbackup` commit

### Issue: An audit reported 94 repos and there were 115

**Problem**: On 2026-09-07, `dev-audit.sh` was found to be scanning 94 of the
115 git repos under `~/dev`. One of the 21 it never saw, a third-party client repo
cloned under a grouping directory, tracks a live `.env.production` with database,
signing, payment and cloud credentials in it — committed long before, and present
in every audit run made since the tool was written.

**Root cause**: `list_repos()` used `find -maxdepth 3`, which reaches
`projects/<repo>/.git` but not `projects/<group>/<repo>/.git`. Everything
organised one level deeper — the eight `templates/<stack>/<repo>` sources, every
client/org grouping directory, and a nested private repo — was outside the sweep.

**The part that made it worse**: `list_non_repo_project_dirs()` tested only for
`$d/.git` directly beneath `projects/<dir>`, so those grouping directories were
reported as `not-a-repo` WARN. The report did not merely omit them — it
positively asserted there was no version control under a path holding five
repos. A silent omission invites a second look; a confident wrong answer does
not.

**Key learning**: a depth or count bound inside a *discovery* function is not a
tuning knob, it is a correctness bound on every result the tool produces — and
its failure mode is a report that looks complete. When a sweep reports N items,
check N against an independent count before trusting anything it says. Two
lines: `find … -name .git -type d | wc -l` against the tool's own total.

**Solution**: `maxdepth 5` (115 repos; 4 would do, 5 is headroom), and grouping
directories that contain a repo further down are no longer reported at all.

### Issue: A secret scanner that only reads HEAD

**Problem**: Every privacy check in `dev-audit.sh` worked from `git ls-files`,
which is the current commit. A credential committed and later deleted was
reported as clean.

**Root cause**: "Tracked files only" was adopted for a good reason — scanning the
working tree buries the signal under every project's local, correct, untracked
`.env` — and then quietly generalised into "HEAD only," which does not follow
from it. Deleting a secret and committing the deletion *is* the most common
response to noticing one, and it changes nothing about what a public repo will
hand to anyone who asks for the history.

**Key learning**: for anything published, the unit of exposure is the history,
not the checkout. A check that reads `HEAD` answers "is it there now," when the
question is "was it ever there." And note what the fix is *not*: a history
finding cannot be resolved by deleting the file. It needs a history rewrite, or
— cheaper and always the first question — treating the credential as disclosed
and rotating it.

**Solution**: `dotaudit --history`, plus `gitleaks` in full-history mode. Off by
default because it walks every commit in every repo; findings are prefixed
`history-` so they never blur with a currently-tracked file.

### Issue: A test suite hung for 20 minutes in CI and never locally

**Problem**: The first CI run of `./test.sh` was cancelled at its 20-minute
timeout, stuck at the very first gate test. Locally the whole suite takes about
two minutes.

**Root cause**: fixture secrets were generated with
`tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 36`. That idiom only terminates
because `head` exits and `tr` is killed by SIGPIPE on its next write. The CI
runner starts jobs with SIGPIPE ignored, so `tr` got EPIPE instead, kept reading
an infinite `/dev/urandom`, and the orphan was still spinning when the job was
cancelled.

**Fix**: bound the input, not just the output:
`head -c 8192 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36`.

**Reproduce locally before pushing**: `(trap '' PIPE; ./test.sh)` runs every
suite with SIGPIPE ignored, the way the runner does.

**Lesson**: any pipeline reading an endless source and relying on a downstream
`head` to stop it is environment-dependent. Bound the source.
