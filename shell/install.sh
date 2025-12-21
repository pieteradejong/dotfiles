#!/bin/bash
set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions for consistent output
print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

# Configuration
CONFIG_DIR="$HOME/config"
BACKUP_DIR="$HOME/.config_backup_$(date +%Y%m%d_%H%M%S)"

echo -e "${BLUE}🚀 Development Environment Shell Setup${NC}"
echo "=================================================="

# Check if we're in the right directory
if [[ ! -f "$(pwd)/shell/.zshrc" ]]; then
    print_error "Please run this script from the config repository root directory"
    exit 1
fi

# Create backup directory
print_info "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# Backup existing configurations
backup_file() {
    local file="$1"
    if [[ -f "$file" ]] || [[ -L "$file" ]]; then
        print_warning "Backing up existing $file"
        cp "$file" "$BACKUP_DIR/" 2>/dev/null || true
    fi
}

# Backup existing files
backup_file "$HOME/.zshrc"
backup_file "$HOME/.bashrc"
backup_file "$HOME/.gitconfig"
backup_file "$HOME/.gitignore_global"

# Install Oh My Zsh if not present
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    print_info "Installing Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    print_status "Oh My Zsh installed"
else
    print_status "Oh My Zsh already installed"
fi

# Install Powerlevel10k theme if not present
if [[ ! -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]]; then
    print_info "Installing Powerlevel10k theme..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
    print_status "Powerlevel10k theme installed"
else
    print_status "Powerlevel10k theme already installed"
fi

# Create symbolic links
create_symlink() {
    local source="$1"
    local target="$2"
    
    # Remove existing file/link
    [[ -f "$target" ]] || [[ -L "$target" ]] && rm "$target"
    
    # Create symlink
    ln -sf "$source" "$target"
    print_status "Linked $target -> $source"
}

# Link configuration files
print_info "Creating symbolic links..."
create_symlink "$(pwd)/shell/.zshrc" "$HOME/.zshrc"
create_symlink "$(pwd)/shell/.bashrc" "$HOME/.bashrc"
create_symlink "$(pwd)/git/.gitconfig" "$HOME/.gitconfig"
create_symlink "$(pwd)/git/.gitignore_global" "$HOME/.gitignore_global"

# Create secret configuration template
if [[ ! -f "$HOME/.zshrc.secret" ]]; then
    print_info "Creating secret configuration template..."
    cp "$(pwd)/shell/zshrc.secret.template" "$HOME/.zshrc.secret"
    chmod 600 "$HOME/.zshrc.secret"  # Secure permissions
    print_warning "IMPORTANT: Edit ~/.zshrc.secret with your personal settings"
    print_warning "This file contains sensitive data and should never be committed"
else
    print_status "Secret configuration already exists at ~/.zshrc.secret"
fi

# Verify installation
print_info "Verifying installation..."

# Test zsh configuration syntax
if zsh -n "$HOME/.zshrc" 2>/dev/null; then
    print_status "Zsh configuration syntax is valid"
else
    print_error "Zsh configuration has syntax errors"
    exit 1
fi

# Check if git configuration is working
if git config --global --list >/dev/null 2>&1; then
    print_status "Git configuration is valid"
else
    print_warning "Git configuration may have issues"
fi

echo ""
echo -e "${GREEN}🎉 Installation completed successfully!${NC}"
echo ""
echo "Next steps:"
echo "1. Edit ~/.zshrc.secret with your personal API keys and settings"
echo "2. Reload your shell: source ~/.zshrc"
echo "3. Configure Powerlevel10k: p10k configure"
echo ""
echo "Backup created at: $BACKUP_DIR"
echo ""
print_warning "Remember: Never commit ~/.zshrc.secret to version control!" 