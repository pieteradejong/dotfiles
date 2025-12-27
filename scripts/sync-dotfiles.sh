#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$HOME/dotfiles"
BACKUP_ROOT="$HOME/.dotfiles-backup"
LOG_FILE="$BACKUP_ROOT/sync.log"
SHELL_DIR="$DOTFILES_DIR/shell"
GIT_DIR="$DOTFILES_DIR/git"
EDITORS_DIR="$DOTFILES_DIR/editors"
SSH_DIR="$DOTFILES_DIR/ssh"
TOOLS_DIR="$DOTFILES_DIR/tools"
MACOS_DIR="$DOTFILES_DIR/macos"
SCRIPTS_DIR="$DOTFILES_DIR/scripts"
DRY_RUN=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log() { mkdir -p "$BACKUP_ROOT"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; echo -e "$1"; }
success() { log "${GREEN}✓${NC} $1"; }
warn() { log "${YELLOW}⚠${NC} $1"; }
safe_copy() {
    [ ! -f "$1" ] && return 1
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would copy: $(basename "$1")"
        return 0
    fi
    cp "$1" "$2" && success "$(basename "$1")" && return 0
    return 1
}
ensure_dirs() { mkdir -p "$SHELL_DIR" "$GIT_DIR" "$EDITORS_DIR" "$SSH_DIR" "$TOOLS_DIR" "$MACOS_DIR" "$SCRIPTS_DIR" "$BACKUP_ROOT"; }

do_backup() {
    log ""; log "========================================"; log "BACKUP: Local → Repo"; log "========================================"
    ensure_dirs
    log ""; log "${BLUE}Shell:${NC}"
    safe_copy ~/.zshrc "$SHELL_DIR/.zshrc" || true; safe_copy ~/.p10k.zsh "$SHELL_DIR/.p10k.zsh" || true; safe_copy ~/.zprofile "$SHELL_DIR/.zprofile" || true
    log ""; log "${BLUE}Git:${NC}"
    safe_copy ~/.gitconfig "$GIT_DIR/.gitconfig" || true; safe_copy ~/.gitignore_global "$GIT_DIR/.gitignore_global" || true
    log ""; log "${BLUE}SSH:${NC}"
    safe_copy ~/.ssh/config "$SSH_DIR/config" || true
    log ""; log "${BLUE}Editors:${NC}"
    safe_copy ~/Library/Application\ Support/Code/User/settings.json "$EDITORS_DIR/vscode-settings.json" || true
    safe_copy ~/Library/Application\ Support/Cursor/User/settings.json "$EDITORS_DIR/cursor-settings.json" || true
    if [ "$DRY_RUN" = true ]; then
        command -v code &>/dev/null && log "  [DRY-RUN] Would export: vscode-extensions.txt"
        command -v cursor &>/dev/null && log "  [DRY-RUN] Would export: cursor-extensions.txt"
    else
        command -v code &>/dev/null && code --list-extensions > "$EDITORS_DIR/vscode-extensions.txt" 2>/dev/null && success "vscode-extensions.txt"
        command -v cursor &>/dev/null && cursor --list-extensions > "$EDITORS_DIR/cursor-extensions.txt" 2>/dev/null && success "cursor-extensions.txt"
    fi
    log ""; log "${BLUE}Tools:${NC}"
    safe_copy ~/.npmrc "$TOOLS_DIR/.npmrc" || true; safe_copy ~/.docker/config.json "$TOOLS_DIR/docker-config.json" || true
    if [ "$DRY_RUN" = true ]; then
        command -v node &>/dev/null && log "  [DRY-RUN] Would export: .nvmrc"
        command -v brew &>/dev/null && log "  [DRY-RUN] Would export: Brewfile"
    else
        command -v node &>/dev/null && node --version > "$TOOLS_DIR/.nvmrc" && success ".nvmrc"
        command -v brew &>/dev/null && brew bundle dump --file="$TOOLS_DIR/Brewfile" --force 2>/dev/null && success "Brewfile"
    fi
    log ""; log "${BLUE}macOS:${NC}"
    safe_copy ~/Library/Preferences/com.googlecode.iterm2.plist "$MACOS_DIR/com.googlecode.iterm2.plist" || true
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would export: rectangle.plist"
    else
        defaults export com.knollsoft.Rectangle "$MACOS_DIR/rectangle.plist" 2>/dev/null && success "rectangle.plist"
    fi
    if [ "$DRY_RUN" = true ]; then
        log ""; log "[DRY-RUN] Backup preview complete. No changes were made."
    else
        log ""; log "Backup complete!"
    fi
}

do_restore() {
    safety_dir="$BACKUP_ROOT/pre-restore-$(date +%Y%m%d-%H%M%S)"
    if [ "$DRY_RUN" = true ]; then
        log ""; log "${YELLOW}[DRY-RUN] Would create safety backup at: $safety_dir${NC}"
    else
        mkdir -p "$safety_dir"
        log ""; log "${YELLOW}Creating safety backup...${NC}"
        [ -f ~/.zshrc ] && cp ~/.zshrc "$safety_dir/"; [ -f ~/.p10k.zsh ] && cp ~/.p10k.zsh "$safety_dir/"; [ -f ~/.gitconfig ] && cp ~/.gitconfig "$safety_dir/"
        success "Safety backup: $safety_dir"
    fi
    log ""; log "${BLUE}Shell:${NC}"
    safe_copy "$SHELL_DIR/.zshrc" ~/.zshrc; safe_copy "$SHELL_DIR/.p10k.zsh" ~/.p10k.zsh; safe_copy "$SHELL_DIR/.zprofile" ~/.zprofile
    log ""; log "${BLUE}Git:${NC}"
    safe_copy "$GIT_DIR/.gitconfig" ~/.gitconfig; safe_copy "$GIT_DIR/.gitignore_global" ~/.gitignore_global
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would run: git config --global core.excludesfile ~/.gitignore_global"
    else
        git config --global core.excludesfile ~/.gitignore_global 2>/dev/null
    fi
    log ""; log "${BLUE}SSH:${NC}"
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would create ~/.ssh with permissions 700"
    else
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
    fi
    safe_copy "$SSH_DIR/config" ~/.ssh/config
    [ "$DRY_RUN" = false ] && chmod 600 ~/.ssh/config 2>/dev/null
    log ""; log "${BLUE}Editors:${NC}"
    if [ "$DRY_RUN" = false ]; then
        mkdir -p ~/Library/Application\ Support/Code/User; mkdir -p ~/Library/Application\ Support/Cursor/User
    fi
    safe_copy "$EDITORS_DIR/vscode-settings.json" ~/Library/Application\ Support/Code/User/settings.json
    safe_copy "$EDITORS_DIR/cursor-settings.json" ~/Library/Application\ Support/Cursor/User/settings.json
    log ""; log "${BLUE}macOS:${NC}"
    safe_copy "$MACOS_DIR/com.googlecode.iterm2.plist" ~/Library/Preferences/com.googlecode.iterm2.plist
    if [ -f "$MACOS_DIR/rectangle.plist" ]; then
        if [ "$DRY_RUN" = true ]; then
            log "  [DRY-RUN] Would import: rectangle.plist"
        else
            defaults import com.knollsoft.Rectangle "$MACOS_DIR/rectangle.plist" 2>/dev/null && success "rectangle.plist"
        fi
    fi
    if [ "$DRY_RUN" = true ]; then
        log ""; log "[DRY-RUN] Restore preview complete. No changes were made."
    else
        log ""; log "Restore complete! Run: source ~/.zshrc"
    fi
}

do_status() {
    log ""; log "STATUS: Local vs Repo"
    check() { [ ! -f "$2" ] && [ ! -f "$3" ] && return; [ ! -f "$2" ] && warn "$1: missing locally" && return; [ ! -f "$3" ] && warn "$1: not in repo" && return; diff -q "$2" "$3" >/dev/null 2>&1 && success "$1: in sync" || warn "$1: DIFFERS"; }
    check ".zshrc" ~/.zshrc "$SHELL_DIR/.zshrc"; check ".p10k.zsh" ~/.p10k.zsh "$SHELL_DIR/.p10k.zsh"; check ".gitconfig" ~/.gitconfig "$GIT_DIR/.gitconfig"
}

do_push() {
    do_backup || true  # Don't exit if backup has warnings
    log ""; log "${BLUE}Committing and pushing...${NC}"; cd "$DOTFILES_DIR"
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would run: git add -A"
        log "[DRY-RUN] Would run: git commit -m 'backup $(date '+%Y-%m-%d %H:%M')'"
        log "[DRY-RUN] Would run: git push"
        return 0
    fi
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

do_extensions() {
    [ -f "$EDITORS_DIR/vscode-extensions.txt" ] && command -v code &>/dev/null && while IFS= read -r ext; do [ -n "$ext" ] && code --install-extension "$ext" --force 2>/dev/null && success "$ext"; done < "$EDITORS_DIR/vscode-extensions.txt"
    [ -f "$EDITORS_DIR/cursor-extensions.txt" ] && command -v cursor &>/dev/null && while IFS= read -r ext; do [ -n "$ext" ] && cursor --install-extension "$ext" --force 2>/dev/null && success "$ext"; done < "$EDITORS_DIR/cursor-extensions.txt"
}

# Parse flags
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[ "$DRY_RUN" = true ] && log "${YELLOW}[DRY-RUN MODE]${NC} No changes will be made"

case "${1:-}" in
    backup) do_backup ;;
    restore) echo -e "${YELLOW}WARNING: This will overwrite local configs.${NC}"; [ "$DRY_RUN" = false ] && read -p "Continue? [y/N] " -n 1 -r && echo && [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0; do_restore ;;
    status) do_status ;;
    extensions) do_extensions ;;
    push) do_push ;;
    *) echo "Usage: $0 [--dry-run|-n] [backup|restore|status|extensions|push]"; exit 1 ;;
esac
