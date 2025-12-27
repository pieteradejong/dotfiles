#!/bin/bash

# dothelp.sh
# Shows help for all dotfiles management commands

DOTFILES_DIR="$HOME/dotfiles"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo ""; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; }
section() { echo ""; echo -e "${BOLD}${BLUE}── $1 ──${NC}"; }
cmd() { echo -e "  ${GREEN}$1${NC}"; }
desc() { echo -e "     $1"; }
warn_text() { echo -e "     ${YELLOW}⚠${NC} $1"; }
info() { echo -e "  ${BLUE}→${NC} $1"; }

main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║           DOTFILES HELP - Quick Reference           ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    
    header "MAIN COMMANDS"
    
    section "dotbackup"
    cmd "dotbackup"
    desc "Backup local configs → repo → GitHub"
    desc "Usage: dotbackup"
    desc "When: After editing ~/.zshrc or other configs"
    desc "Does: Copies live files to repo, commits, and pushes to GitHub"
    
    section "dotrestore"
    cmd "dotrestore"
    desc "Restore configs from repo → local"
    desc "Usage: dotrestore"
    desc "When: You've messed up local configs and need to recover"
    warn_text "Creates safety backup in ~/.dotfiles-backup/ before restoring"
    desc "Does: Copies repo files to live locations (with confirmation prompt)"
    
    section "dotstatus"
    cmd "dotstatus"
    desc "Check sync status (local vs repo)"
    desc "Usage: dotstatus"
    desc "When: Want to see what differs between live and repo"
    desc "Does: Compares local files with repo versions"
    
    section "dottest"
    cmd "dottest [--help] [--verbose]"
    desc "Run comprehensive test suite"
    desc "Usage: dottest"
    desc "       dottest --verbose  (for detailed output)"
    desc "When: Verify setup is working correctly"
    desc "Does: Tests directory structure, files, aliases, sync status, etc."
    
    section "dothelp"
    cmd "dothelp"
    desc "Show this help message"
    desc "Usage: dothelp"
    
    header "FLAGS"
    
    section "--dry-run / -n"
    cmd "dotfiles --dry-run <command>"
    desc "Preview what a command would do without making changes"
    desc "Usage: dotfiles --dry-run backup"
    desc "       dotfiles --dry-run restore"
    desc "       dotfiles --dry-run push"
    desc "       dotfiles -n backup  (short form)"
    desc "When: Want to see what would happen before actually doing it"
    desc "Does: Shows all file copies and git operations that would occur"
    warn_text "Dry-run works with 'dotfiles' command, not aliases (dotbackup, etc.)"
    
    header "SUBCOMMANDS (via dotfiles)"
    
    section "dotfiles backup"
    cmd "dotfiles [--dry-run] backup"
    desc "Backup only (no commit/push)"
    desc "Usage: dotfiles backup"
    desc "       dotfiles --dry-run backup  (preview mode)"
    desc "When: Want to backup but not commit yet"
    
    section "dotfiles restore"
    cmd "dotfiles [--dry-run] restore"
    desc "Same as dotrestore (restore from repo)"
    desc "Usage: dotfiles restore"
    desc "       dotfiles --dry-run restore  (preview mode)"
    
    section "dotfiles status"
    cmd "dotfiles status"
    desc "Same as dotstatus (check sync status)"
    desc "Usage: dotfiles status"
    
    section "dotfiles extensions"
    cmd "dotfiles extensions"
    desc "Install editor extensions from repo"
    desc "Usage: dotfiles extensions"
    desc "When: Setting up on a new machine"
    desc "Does: Installs VS Code and Cursor extensions from saved lists"
    
    section "dotfiles push"
    cmd "dotfiles [--dry-run] push"
    desc "Same as dotbackup (backup + commit + push)"
    desc "Usage: dotfiles push"
    desc "       dotfiles --dry-run push  (preview mode)"
    
    header "WORKFLOW EXAMPLES"
    
    echo ""
    info "Preview what backup would do (dry-run):"
    echo -e "  ${GREEN}dotfiles --dry-run backup${NC}"
    echo ""
    info "Edit your .zshrc, then save to repo:"
    echo -e "  ${GREEN}dotbackup${NC}"
    echo ""
    info "Preview restore before actually doing it:"
    echo -e "  ${GREEN}dotfiles --dry-run restore${NC}"
    echo ""
    info "Messed up your config? Restore from repo:"
    echo -e "  ${GREEN}dotrestore${NC}"
    echo ""
    info "Check what's different between local and repo:"
    echo -e "  ${GREEN}dotstatus${NC}"
    echo ""
    info "Verify everything works:"
    echo -e "  ${GREEN}dottest${NC}"
    echo ""
    info "Set up on a new Mac:"
    echo -e "  1. Clone repo: ${GREEN}git clone <repo-url> ~/dotfiles${NC}"
    echo -e "  2. Restore configs: ${GREEN}dotrestore${NC}"
    echo -e "  3. Reload shell: ${GREEN}source ~/.zshrc${NC}"
    echo -e "  4. Install extensions: ${GREEN}dotfiles extensions${NC}"
    echo -e "  5. Test setup: ${GREEN}dottest${NC}"
    
    header "FILE LOCATIONS"
    
    echo ""
    info "Live configs (what your shell uses):"
    echo -e "  ${BLUE}~/.zshrc${NC}"
    echo -e "  ${BLUE}~/.gitconfig${NC}"
    echo -e "  ${BLUE}~/.p10k.zsh${NC}"
    echo -e "  ${BLUE}~/.ssh/config${NC}"
    echo ""
    info "Repo location (version controlled):"
    echo -e "  ${BLUE}~/dotfiles/${NC}"
    echo ""
    info "Backup location (safety backups):"
    echo -e "  ${BLUE}~/.dotfiles-backup/${NC}"
    
    header "TROUBLESHOOTING"
    
    echo ""
    section "Aliases not working"
    info "Check if aliases are defined:"
    echo -e "  ${GREEN}grep 'alias dot' ~/.zshrc${NC}"
    echo ""
    info "If missing, restore from repo:"
    echo -e "  ${GREEN}dotrestore${NC}"
    echo ""
    info "Then reload shell:"
    echo -e "  ${GREEN}source ~/.zshrc${NC}"
    
    section ".zshrc: DIFFERS warning"
    info "This means your live .zshrc has changes not in repo"
    info "To sync changes to repo:"
    echo -e "  ${GREEN}dotbackup${NC}"
    
    section "Need more help?"
    info "Run test suite to diagnose issues:"
    echo -e "  ${GREEN}dottest --verbose${NC}"
    echo ""
    info "Check sync script help:"
    echo -e "  ${GREEN}dotfiles${NC}  (shows usage)"
    echo ""
    info "Check test script help:"
    echo -e "  ${GREEN}dottest --help${NC}"
    
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
    echo ""
}

main "$@"
