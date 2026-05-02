#!/bin/bash
# Docker integration test — verifies a clean restore produces the expected end state.
#
# Usage:
#   docker run --rm -v ~/dotfiles:/dotfiles debian:bookworm-slim \
#     bash -c "apt-get update -qq && apt-get install -qq -y zsh git \
#              && /dotfiles/scripts/test/assertions.sh"

DOTFILES=/dotfiles
PASS=0
FAIL=0

pass() { printf "  PASS: %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "  FAIL: %s\n" "$1"; FAIL=$((FAIL + 1)); }

echo "=== dotfiles integration test ==="
echo ""

# ── Setup ──────────────────────────────────────────────────────────────────
# sync-dotfiles.sh resolves paths from $HOME/dotfiles, so symlink the mount
ln -sf "$DOTFILES" "$HOME/dotfiles"

# Stub macOS-only commands so restore doesn't abort on Linux
mkdir -p /tmp/stubs
printf '#!/bin/sh\nexit 0\n' > /tmp/stubs/defaults
chmod +x /tmp/stubs/defaults
export PATH="/tmp/stubs:$PATH"

# ── Run restore ────────────────────────────────────────────────────────────
echo "--- Running sync-dotfiles.sh restore ---"
echo "y" | "$DOTFILES/scripts/sync-dotfiles.sh" restore 2>&1
echo ""

# ── Assertions ─────────────────────────────────────────────────────────────
echo "--- Assertions ---"

# Core files placed by restore
[ -f "$HOME/.zshrc" ]            && pass ".zshrc placed"            || fail ".zshrc not placed"
[ -f "$HOME/.gitconfig" ]        && pass ".gitconfig placed"        || fail ".gitconfig not placed"
[ -f "$HOME/.gitignore_global" ] && pass ".gitignore_global placed" || fail ".gitignore_global not placed"
[ -f "$HOME/.ssh/config" ]       && pass "ssh/config placed"        || fail "ssh/config not placed"

# SSH permissions
perms=$(stat -c "%a" "$HOME/.ssh/config" 2>/dev/null || echo "???")
[ "$perms" = "600" ] && pass "ssh/config permissions 600" || fail "ssh/config permissions: $perms (want 600)"

# Aliases wired in .zshrc
for alias_name in dotbackup dotrestore dotstatus; do
    grep -q "alias ${alias_name}=" "$HOME/.zshrc" \
        && pass "alias ${alias_name} in .zshrc" \
        || fail "alias ${alias_name} missing from .zshrc"
done

# .zshrc sources .zshrc.secrets
# NOTE: will fail until the open TODO in README is addressed
grep -q '\.zshrc\.secrets' "$HOME/.zshrc" \
    && pass ".zshrc sources .zshrc.secrets" \
    || fail ".zshrc does not source .zshrc.secrets (open TODO)"

# .zshrc.secrets must NOT be present in the repo or placed by restore
[ ! -f "$HOME/.zshrc.secrets" ] \
    && pass ".zshrc.secrets absent (not committed)" \
    || fail ".zshrc.secrets present — must not be committed"

# Secrets template exists in repo with the correct name
# NOTE: will fail until the rename TODO in README is addressed
[ -f "$DOTFILES/shell/.zshrc.secrets.template" ] \
    && pass ".zshrc.secrets.template present in repo" \
    || fail ".zshrc.secrets.template missing (open TODO: rename from zshrc.secret.template)"

# .gitignore covers critical patterns
for pattern in '.zshrc.secrets' '*.key' '*.pem' '.env'; do
    grep -q "$pattern" "$DOTFILES/.gitignore" \
        && pass ".gitignore covers: $pattern" \
        || fail ".gitignore missing: $pattern"
done

# .zshrc has no syntax errors
zsh -n "$HOME/.zshrc" 2>/dev/null \
    && pass ".zshrc syntax valid (zsh -n)" \
    || fail ".zshrc has syntax errors"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
