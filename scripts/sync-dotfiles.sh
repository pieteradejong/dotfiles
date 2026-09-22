#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$HOME/dev/dotfiles"
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
fail() { log "${RED}✗${NC} $1"; exit 1; }
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

# --- Sanitizers -------------------------------------------------------------
# This repo is PUBLIC. Two of the files backed up here carry values that must
# not be published: ~/.ssh/config names a real host, account and port, and
# ~/.gitconfig has held a real email and an absolute /Users/<name>/ path.
# Backing them up verbatim is how they got here (SECURITY_AUDIT_2026-09-07
# §2.2, §2.4, §2.5), and redacting the committed copies alone does not hold:
# the next `sync backup` would copy the real values straight back in.
#
# So sanitizing happens on the way IN, at the copy itself. These filters match
# by directive name and never contain a real value — they live in the public
# repo too, and a sanitizer that embeds the secret defeats itself.
sanitize_ssh_config() {
    sed -E \
        -e 's/^([[:space:]]*HostName[[:space:]]+).*$/\1<HOSTNAME>/' \
        -e 's/^([[:space:]]*User[[:space:]]+).*$/\1<USERNAME>/' \
        -e 's/^([[:space:]]*Port[[:space:]]+).*$/\1<PORT>/'
}

# Only rewrites absolute home paths; the committer email is expected to be the
# GitHub noreply address, which is safe to publish and stays readable.
sanitize_gitconfig() {
    sed -E -e 's#/Users/[^/[:space:]]+/#~/#g'
}

# Some files must carry ABSOLUTE paths to work at all, so they cannot simply be
# rewritten in place the way ~/.zshrc and ~/.ssh/config were (both accept $HOME
# and ~ natively, so those are fixed at the source, not filtered):
#
#   launchd plists      launchd does not expand `~` in ProgramArguments
#   editor settings     VS Code's Project Manager `git.baseFolders` is not
#                       documented to expand `~`, so the live file keeps real paths
#
# Same treatment as .gitconfig: store `~/` in the repo, expand it back on
# restore. That makes the committed copy a backup rather than a directly usable
# file — which is what it already was; `sync restore` is the supported way to
# reinstall it, and it puts the real paths back.
# The stored marker is a literal `$HOME`, NOT `~`. That distinction is the whole
# correctness argument: iTerm2's prefs already contain a genuine
# `~/Library/Application Support/iTerm2/Scripts`, and a `~`-based marker cannot
# tell a tilde the sanitizer produced from one that was always there — expanding
# on the way out rewrote that real value and the round-trip stopped being
# lossless. `$HOME` appears in none of these files, so the mapping is one-to-one
# and any pre-existing `~` passes through untouched.
#
# Two match forms, because a home path is not always a prefix: iTerm2's "Working
# Directory" is the bare `/Users/<name>` with nothing after it, which a
# trailing-slash-only rule silently misses.
sanitize_home_paths() {
    # shellcheck disable=SC2016 # $HOME is a literal marker in the output, not an expansion
    sed -E \
        -e 's#/Users/[^/"<[:space:]]+/#$HOME/#g' \
        -e 's#/Users/[^/"<[:space:]]+(["<]|$)#$HOME\1#g'
}

# The inverse. Unambiguous by construction: `$HOME` only ever got there from the
# sanitizer above.
expand_home_paths() {
    sed -E -e "s#\\\$HOME#$HOME#g"
}

# Scoped registry lines (@<org>:registry=...) name the orgs whose private
# packages this machine can install — a client relationship, not a setting.
sanitize_npmrc() {
    sed -E -e '/^@[^:]+:registry[[:space:]]*=/d'
}

# safe_copy, but the source passes through $3 on the way to the destination.
sanitize_copy() {
    [ ! -f "$1" ] && return 1
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would copy (sanitized): $(basename "$1")"
        return 0
    fi
    "$3" < "$1" > "$2" && success "$(basename "$1") (sanitized)" && return 0
    return 1
}

# Restore direction for a file whose repo copy is a redacted TEMPLATE. Writing
# it over a live file would replace a working config with placeholders, so an
# existing file always wins and the user is told where the template is.
install_template() {
    [ ! -f "$1" ] && return 1
    if [ -f "$2" ]; then
        warn "$(basename "$2") exists - left untouched (repo copy is a redacted template: $1)"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would install template: $(basename "$1")"
        return 0
    fi
    cp "$1" "$2" && warn "$(basename "$2") installed from template - fill in the <PLACEHOLDER> values" && return 0
    return 1
}

do_backup() {
    log ""; log "========================================"; log "BACKUP: Local → Repo"; log "========================================"
    ensure_dirs
    log ""; log "${BLUE}Shell:${NC}"
    safe_copy ~/.zshrc "$SHELL_DIR/.zshrc" || true; safe_copy ~/.p10k.zsh "$SHELL_DIR/.p10k.zsh" || true; safe_copy ~/.zprofile "$SHELL_DIR/.zprofile" || true
    log ""; log "${BLUE}Git:${NC}"
    sanitize_copy ~/.gitconfig "$GIT_DIR/.gitconfig" sanitize_gitconfig || true; safe_copy ~/.gitignore_global "$GIT_DIR/.gitignore_global" || true
    log ""; log "${BLUE}SSH:${NC}"
    sanitize_copy ~/.ssh/config "$SSH_DIR/config" sanitize_ssh_config || true
    log ""; log "${BLUE}Editors:${NC}"
    sanitize_copy ~/Library/Application\ Support/Code/User/settings.json "$EDITORS_DIR/vscode-settings.json" sanitize_home_paths || true
    sanitize_copy ~/Library/Application\ Support/Cursor/User/settings.json "$EDITORS_DIR/cursor-settings.json" sanitize_home_paths || true
    if [ "$DRY_RUN" = true ]; then
        command -v code &>/dev/null && log "  [DRY-RUN] Would export: vscode-extensions.txt"
        command -v cursor &>/dev/null && log "  [DRY-RUN] Would export: cursor-extensions.txt"
    else
        command -v code &>/dev/null && code --list-extensions > "$EDITORS_DIR/vscode-extensions.txt" 2>/dev/null && success "vscode-extensions.txt"
        command -v cursor &>/dev/null && cursor --list-extensions > "$EDITORS_DIR/cursor-extensions.txt" 2>/dev/null && success "cursor-extensions.txt"
    fi
    log ""; log "${BLUE}Tools:${NC}"
    sanitize_copy ~/.npmrc "$TOOLS_DIR/.npmrc" sanitize_npmrc || true; safe_copy ~/.docker/config.json "$TOOLS_DIR/docker-config.json" || true
    if [ "$DRY_RUN" = true ]; then
        command -v node &>/dev/null && log "  [DRY-RUN] Would export: .nvmrc"
        command -v brew &>/dev/null && log "  [DRY-RUN] Would export: Brewfile"
    else
        command -v node &>/dev/null && node --version > "$TOOLS_DIR/.nvmrc" && success ".nvmrc"
        command -v brew &>/dev/null && brew bundle dump --file="$TOOLS_DIR/Brewfile" --force 2>/dev/null && success "Brewfile"
    fi
    log ""; log "${BLUE}macOS:${NC}"
    # iTerm2 writes a BINARY plist that embeds $HOME. Stored binary it is both
    # unreadable in a diff ("Binary file changed") and invisible to text-based
    # scanners — the weekly audit's home-path check counted the four text files
    # and skipped this one. Convert to XML on the way in, then sanitize like any
    # other file. macOS reads XML plists, so restore stays a plain copy.
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would copy (xml + sanitized): com.googlecode.iterm2.plist"
    elif [ -f ~/Library/Preferences/com.googlecode.iterm2.plist ]; then
        if plutil -convert xml1 -o "$BACKUP_ROOT/iterm2.xml" ~/Library/Preferences/com.googlecode.iterm2.plist 2>/dev/null \
           && sanitize_home_paths < "$BACKUP_ROOT/iterm2.xml" > "$MACOS_DIR/com.googlecode.iterm2.plist"; then
            success "com.googlecode.iterm2.plist (xml + sanitized)"
        else
            warn "could not convert com.googlecode.iterm2.plist"
        fi
        rm -f "$BACKUP_ROOT/iterm2.xml"
    fi
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would export: rectangle.plist"
    else
        defaults export com.knollsoft.Rectangle "$MACOS_DIR/rectangle.plist" 2>/dev/null && success "rectangle.plist"
    fi
    sanitize_copy ~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist "$MACOS_DIR/com.pieterdejong.weeklycleanup.plist" sanitize_home_paths || true
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
    install_template "$SSH_DIR/config" ~/.ssh/config
    [ "$DRY_RUN" = false ] && chmod 600 ~/.ssh/config 2>/dev/null
    log ""; log "${BLUE}Editors:${NC}"
    if [ "$DRY_RUN" = false ]; then
        mkdir -p ~/Library/Application\ Support/Code/User; mkdir -p ~/Library/Application\ Support/Cursor/User
    fi
    # Expand ~/ back to real absolute paths: some editor settings do not expand ~.
    if expand_home_paths < "$EDITORS_DIR/vscode-settings.json" > ~/Library/Application\ Support/Code/User/settings.json; then
        success "vscode-settings.json (paths expanded)"
    else
        warn "could not restore vscode-settings.json"
    fi
    if expand_home_paths < "$EDITORS_DIR/cursor-settings.json" > ~/Library/Application\ Support/Cursor/User/settings.json; then
        success "cursor-settings.json (paths expanded)"
    else
        warn "could not restore cursor-settings.json"
    fi
    log ""; log "${BLUE}macOS:${NC}"
    [ "$DRY_RUN" = false ] && mkdir -p ~/Library/Preferences
    # Stored as sanitized XML; expand ~/ back before installing it.
    if [ "$DRY_RUN" = true ]; then
        log "  [DRY-RUN] Would copy (paths expanded): com.googlecode.iterm2.plist"
    elif [ -f "$MACOS_DIR/com.googlecode.iterm2.plist" ]; then
        if expand_home_paths < "$MACOS_DIR/com.googlecode.iterm2.plist" > ~/Library/Preferences/com.googlecode.iterm2.plist; then
            success "com.googlecode.iterm2.plist (paths expanded)"
            log "  ${YELLOW}Note:${NC} quit iTerm2 and run 'killall cfprefsd' for it to be re-read"
        else
            warn "could not restore com.googlecode.iterm2.plist"
        fi
    fi
    if [ -f "$MACOS_DIR/rectangle.plist" ]; then
        if [ "$DRY_RUN" = true ]; then
            log "  [DRY-RUN] Would import: rectangle.plist"
        else
            defaults import com.knollsoft.Rectangle "$MACOS_DIR/rectangle.plist" 2>/dev/null && success "rectangle.plist"
        fi
    fi
    if [ "$DRY_RUN" = false ]; then
        mkdir -p ~/Library/LaunchAgents
        # Expand ~/ back to real absolute paths: launchd will not do it.
        if expand_home_paths < "$MACOS_DIR/com.pieterdejong.weeklycleanup.plist" > ~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist; then
            success "com.pieterdejong.weeklycleanup.plist (paths expanded)"
        else
            warn "could not restore com.pieterdejong.weeklycleanup.plist"
        fi
        log "  ${YELLOW}Note:${NC} run 'launchctl load ~/Library/LaunchAgents/com.pieterdejong.weeklycleanup.plist' to activate"
    else
        log "  [DRY-RUN] Would copy: com.pieterdejong.weeklycleanup.plist (not loaded automatically)"
    fi
    if [ "$DRY_RUN" = true ]; then
        log ""; log "[DRY-RUN] Restore preview complete. No changes were made."
    else
        log ""; log "Restore complete!"
        # Source zshrc in this subshell (won't affect parent shell)
        if [ -f ~/.zshrc ]; then
            log ""; log "${BLUE}Sourcing ~/.zshrc...${NC}"
            # shellcheck source=/dev/null
            if source ~/.zshrc 2>/dev/null; then success "Sourced ~/.zshrc"; else warn "Could not source ~/.zshrc"; fi
        fi
        log ""; log "${YELLOW}Note:${NC} For your current terminal session, run: ${GREEN}source ~/.zshrc${NC} or open a new terminal"
    fi
}

do_status() {
    log ""; log "STATUS: Local vs Repo"
    check() {
        [ ! -f "$2" ] && [ ! -f "$3" ] && return
        [ ! -f "$2" ] && warn "$1: missing locally" && return
        [ ! -f "$3" ] && warn "$1: not in repo" && return
        if diff -q "$2" "$3" >/dev/null 2>&1; then success "$1: in sync"; else warn "$1: DIFFERS"; fi
    }
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
        # The global security gate runs on this commit and push. If it blocks,
        # stop: a backup that silently skipped the push is worse than a loud one.
        if git commit -m "backup $(date '+%Y-%m-%d %H:%M')"; then success "Committed changes"
        else fail "Commit failed (security gate?) - nothing pushed"; fi
    fi
    if git push; then success "Pushed to remote"; else fail "Push failed (security gate?)"; fi
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
