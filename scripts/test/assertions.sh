#!/bin/bash
# Docker integration test — verifies a clean restore produces the expected end state.
#
# Usage:
#   docker run --rm -v ~/dev/dotfiles:/dotfiles debian:bookworm-slim \
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
# sync-dotfiles.sh resolves everything from $HOME/dev/dotfiles, so the mount has
# to appear there. It used to be $HOME/dotfiles; the repo moved on 2026-09-01 and
# this line did not follow, which silently failed 10 of 16 assertions — restore
# had nothing to copy from, and every "not placed" looked like a real regression.
mkdir -p "$HOME/dev"
ln -sf "$DOTFILES" "$HOME/dev/dotfiles"

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

# .zshrc sources .zshrc.secret
grep -q '\.zshrc\.secrets' "$HOME/.zshrc" \
    && pass ".zshrc sources .zshrc.secret" \
    || fail ".zshrc does not source .zshrc.secret"

# .zshrc.secret must NOT be present in the repo or placed by restore
[ ! -f "$HOME/.zshrc.secret" ] \
    && pass ".zshrc.secret absent (not committed)" \
    || fail ".zshrc.secret present — must not be committed"

# Secrets template exists in repo with the correct name
[ -f "$DOTFILES/shell/.zshrc.secret.template" ] \
    && pass ".zshrc.secret.template present in repo" \
    || fail ".zshrc.secret.template missing"

# .gitignore covers critical patterns
for pattern in '.zshrc.secret' '*.key' '*.pem' '.env'; do
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
