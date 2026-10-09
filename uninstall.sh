#!/usr/bin/env bash
# aicommit uninstaller
set -e

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RESET="\033[0m"

INSTALL_DIR="${AICOMMIT_DIR:-$HOME/.aicommit}"
ZSHRC="$HOME/.zshrc"

echo ""
echo "  Uninstalling aicommit..."
echo ""

# ─── Remove source line from .zshrc ──────────────────────────────────────────

if [ -f "$ZSHRC" ]; then
    if grep -qF "aicommit" "$ZSHRC"; then
        # Remove the comment line and source line
        sed -i '' '/# aicommit —/d' "$ZSHRC"
        sed -i '' '/aicommit\/aicommit\.sh/d' "$ZSHRC"
        # Clean up any resulting blank lines
        sed -i '' '/^$/N;/^\n$/d' "$ZSHRC"
        echo -e "  ${GREEN}✓${RESET} Removed aicommit from .zshrc"
    else
        echo -e "  ${YELLOW}•${RESET} No aicommit entry found in .zshrc"
    fi
fi

# ─── Remove install directory ─────────────────────────────────────────────────

if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo -e "  ${GREEN}✓${RESET} Removed $INSTALL_DIR"
else
    echo -e "  ${YELLOW}•${RESET} $INSTALL_DIR not found"
fi

# ─── Optionally remove config ─────────────────────────────────────────────────

if [ -f "$HOME/.aicommitrc" ]; then
    echo -n "  Remove ~/.aicommitrc config? (y/n) "
    read -r response
    if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
        rm -f "$HOME/.aicommitrc"
        echo -e "  ${GREEN}✓${RESET} Removed ~/.aicommitrc"
    else
        echo -e "  ${YELLOW}•${RESET} Kept ~/.aicommitrc"
    fi
fi

# ─── Remove .zshrc backup ─────────────────────────────────────────────────────

if [ -f "${ZSHRC}.aicommit-backup" ]; then
    rm -f "${ZSHRC}.aicommit-backup"
    echo -e "  ${GREEN}✓${RESET} Removed .zshrc backup"
fi

# ─── Clean temp files ─────────────────────────────────────────────────────────
# Legacy shared /tmp dir plus the current repo's .git/aicommit working data.

if [ -d "/tmp/.aicommit" ]; then
    rm -rf "/tmp/.aicommit"
    echo -e "  ${GREEN}✓${RESET} Cleaned legacy temp files"
fi

_git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null || true)
if [ -n "$_git_dir" ] && [ -d "${_git_dir}/aicommit" ]; then
    rm -rf "${_git_dir}/aicommit"
    echo -e "  ${GREEN}✓${RESET} Cleaned .git/aicommit working data"
fi

echo ""
echo -e "${GREEN}aicommit uninstalled.${RESET} Restart your shell: exec zsh"
echo ""
