#!/bin/bash

# test-dotfiles-setup.sh
# Comprehensive test script for dotfiles configuration

set -u

DOTFILES_DIR="$HOME/dev/dotfiles"
BACKUP_ROOT="$HOME/.dotfiles-backup"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
VERBOSE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo ""; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; }
subheader() { echo ""; echo -e "${BLUE}── $1 ──${NC}"; }
pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; ((PASS_COUNT++)) || true; return 0; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; ((FAIL_COUNT++)) || true; return 0; }
warn() { echo -e "  ${YELLOW}⚠ WARN${NC}: $1"; ((WARN_COUNT++)) || true; return 0; }
info() { echo -e "  ${BLUE}→${NC} $1"; }

test_directory_structure() {
    header "TEST 1: Directory Structure"
    subheader "Checking ~/dotfiles exists"
    if [ -d "$DOTFILES_DIR" ]; then
        pass "~/dotfiles directory exists"
        [ "$VERBOSE" = true ] && info "Path: $DOTFILES_DIR"
    else
        fail "~/dotfiles NOT found"
        return 1
    fi
    
    subheader "Checking subdirectories"
    for dir in shell git editors ssh tools macos scripts; do
        if [ -d "$DOTFILES_DIR/$dir" ]; then
            count=$(find "$DOTFILES_DIR/$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            pass "$dir/ exists ($count files)"
        else
            fail "$dir/ NOT found"
        fi
    done
    
    subheader "Checking git repo"
    if [ -d "$DOTFILES_DIR/.git" ]; then
        pass "Git repository initialized"
        remote=$(cd "$DOTFILES_DIR" && git remote get-url origin 2>/dev/null)
        [ -n "$remote" ] && pass "Remote: $remote" || warn "No git remote configured"
    else
        fail "Not a git repository"
    fi
}

test_required_files() {
    header "TEST 2: Required Files in Repo"
    
    subheader "Shell configs"
    for f in .zshrc .p10k.zsh .zprofile; do
        [ -f "$DOTFILES_DIR/shell/$f" ] && pass "shell/$f" || warn "shell/$f not found"
    done
    
    subheader "Git configs"
    for f in .gitconfig .gitignore_global; do
        [ -f "$DOTFILES_DIR/git/$f" ] && pass "git/$f" || fail "git/$f NOT found"
    done
    
    subheader "Editor configs"
    for f in vscode-settings.json cursor-settings.json vscode-extensions.txt cursor-extensions.txt; do
        [ -f "$DOTFILES_DIR/editors/$f" ] && pass "editors/$f" || warn "editors/$f not found"
    done
    
    subheader "Tools"
    for f in Brewfile .npmrc .nvmrc; do
        [ -f "$DOTFILES_DIR/tools/$f" ] && pass "tools/$f" || warn "tools/$f not found"
    done
    
    subheader "Sync script"
    if [ -f "$DOTFILES_DIR/scripts/sync-dotfiles.sh" ]; then
        pass "scripts/sync-dotfiles.sh exists"
        [ -x "$DOTFILES_DIR/scripts/sync-dotfiles.sh" ] && pass "sync-dotfiles.sh is executable" || fail "sync-dotfiles.sh NOT executable"
    else
        fail "scripts/sync-dotfiles.sh NOT found (CRITICAL)"
    fi
}

test_sync_script() {
    header "TEST 3: Sync Script Functionality"
    script="$DOTFILES_DIR/scripts/sync-dotfiles.sh"
    [ ! -f "$script" ] && { fail "Script not found"; return 1; }
    
    subheader "Syntax check"
    bash -n "$script" 2>/dev/null && pass "Script syntax valid" || fail "Script has syntax errors"
    
    subheader "Required functions"
    for func in do_backup do_restore do_status do_push; do
        grep -q "$func" "$script" && pass "Has function: $func" || fail "Missing: $func"
    done
}

test_shell_aliases() {
    header "TEST 4: Shell Aliases"
    
    subheader "Checking .zshrc for aliases"
    if [ -f ~/.zshrc ]; then
        grep -q "export DOTFILES=" ~/.zshrc && pass "DOTFILES var in .zshrc" || fail "DOTFILES var missing from .zshrc"
        for a in dotfiles dotbackup dotrestore dotstatus; do
            grep -q "alias $a=" ~/.zshrc && pass "Alias in .zshrc: $a" || fail "Missing alias: $a"
        done
    else
        fail "~/.zshrc not found"
    fi
}

test_local_configs() {
    header "TEST 5: Local Config Files"
    
    subheader "Shell"
    [ -f ~/.zshrc ] && pass "~/.zshrc exists" || fail "~/.zshrc missing"
    [ -f ~/.p10k.zsh ] && pass "~/.p10k.zsh exists" || warn "~/.p10k.zsh missing"
    
    subheader "Git"
    [ -f ~/.gitconfig ] && pass "~/.gitconfig exists" || fail "~/.gitconfig missing"
    [ -f ~/.gitignore_global ] && pass "~/.gitignore_global exists" || warn "~/.gitignore_global missing"
    
    excludes=$(git config --global core.excludesfile 2>/dev/null)
    [ -n "$excludes" ] && pass "core.excludesfile: $excludes" || warn "core.excludesfile not set"
    
    subheader "SSH"
    if [ -f ~/.ssh/config ]; then
        pass "~/.ssh/config exists"
        perms=$(stat -f "%OLp" ~/.ssh/config 2>/dev/null || stat -c "%a" ~/.ssh/config 2>/dev/null)
        [ "$perms" = "600" ] && pass "SSH config permissions OK (600)" || warn "SSH perms: $perms (want 600)"
    else
        warn "~/.ssh/config not found"
    fi
}

test_sync_status() {
    header "TEST 6: Sync Status (Local vs Repo)"
    
    compare() {
        name="$1"; local_f="$2"; repo_f="$3"
        if [ ! -f "$local_f" ] && [ ! -f "$repo_f" ]; then return
        elif [ ! -f "$local_f" ]; then warn "$name: missing locally"
        elif [ ! -f "$repo_f" ]; then warn "$name: not in repo"
        elif diff -q "$local_f" "$repo_f" >/dev/null 2>&1; then pass "$name: in sync"
        else warn "$name: DIFFERS"
        fi
    }
    
    compare ".zshrc" ~/.zshrc "$DOTFILES_DIR/shell/.zshrc"
    compare ".p10k.zsh" ~/.p10k.zsh "$DOTFILES_DIR/shell/.p10k.zsh"
    compare ".gitconfig" ~/.gitconfig "$DOTFILES_DIR/git/.gitconfig"
    compare "vscode" ~/Library/Application\ Support/Code/User/settings.json "$DOTFILES_DIR/editors/vscode-settings.json"
}

test_git_status() {
    header "TEST 7: Git Repository Status"
    [ ! -d "$DOTFILES_DIR/.git" ] && { fail "Not a git repo"; return 1; }
    cd "$DOTFILES_DIR"
    
    branch=$(git branch --show-current 2>/dev/null)
    [ -n "$branch" ] && pass "Branch: $branch" || warn "Unknown branch"
    
    status=$(git status --porcelain 2>/dev/null)
    [ -z "$status" ] && pass "Working tree clean" || warn "$(echo "$status" | wc -l | tr -d ' ') uncommitted changes"
    
    ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
    [ "$ahead" = "0" ] && pass "No unpushed commits" || warn "$ahead unpushed commits"
}

test_security() {
    header "TEST 8: Security Check"
    
    subheader "Dangerous files"
    found=0
    for pattern in "id_rsa" "id_ed25519" "*.pem" "*.key" ".env"; do
        matches=$(find "$DOTFILES_DIR" -name "$pattern" -not -path "*/.git/*" 2>/dev/null)
        [ -n "$matches" ] && { fail "DANGER: Found $pattern"; ((found++)); }
    done
    [ "$found" -eq 0 ] && pass "No sensitive files found"
    
    subheader ".gitignore patterns"
    if [ -f "$DOTFILES_DIR/.gitignore" ]; then
        for p in "*.secret" ".env" "id_rsa"; do
            grep -q "$p" "$DOTFILES_DIR/.gitignore" && pass "Ignores: $p" || warn "Missing: $p"
        done
    else
        fail ".gitignore not found"
    fi
}

test_backup_dir() {
    header "TEST 9: Backup Directory"
    if [ -d "$BACKUP_ROOT" ]; then
        pass "Backup dir exists: $BACKUP_ROOT"
        count=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "pre-*" 2>/dev/null | wc -l | tr -d ' ')
        info "Found $count backup(s)"
    else
        info "Backup dir not yet created (OK)"
    fi
}

print_summary() {
    header "SUMMARY"
    echo ""
    echo -e "  ${GREEN}Passed${NC}: $PASS_COUNT"
    echo -e "  ${RED}Failed${NC}: $FAIL_COUNT"
    echo -e "  ${YELLOW}Warnings${NC}: $WARN_COUNT"
    echo ""
    [ "$FAIL_COUNT" -eq 0 ] && echo -e "  ${GREEN}${BOLD}All critical tests passed!${NC}" || echo -e "  ${RED}${BOLD}Some tests failed.${NC}"
    echo ""
}

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
    
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║     DOTFILES TEST SUITE - $(date '+%Y-%m-%d %H:%M')          ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    [ "$VERBOSE" = true ] && info "Verbose mode enabled"
    
    test_directory_structure
    test_required_files
    test_sync_script
    test_shell_aliases
    test_local_configs
    test_sync_status
    test_git_status
    test_security
    test_backup_dir
    print_summary
    
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
