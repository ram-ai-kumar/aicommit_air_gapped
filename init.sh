#!/usr/bin/env bash
# ~/.aicommit/init.sh — Shell initialization for aicommit
# Sourced by user's shell (e.g. via helpers or directly in .zshrc)

export AICOMMIT_DIR="${AICOMMIT_DIR:-$HOME/.aicommit}"

if [ -d "$AICOMMIT_DIR/bin" ]; then
    case ":$PATH:" in
        *":$AICOMMIT_DIR/bin:"*) ;;
        *) export PATH="$AICOMMIT_DIR/bin:$PATH" ;;
    esac
fi

# Load the live shell functions (aicommit, aic, aicc, aicx, aiccx) from the single
# source of truth in aicommit.sh. Do NOT redefine them here: a second definition
# with different flags (e.g. missing --shortcut) shadows the canonical one and
# silently changes behavior — that drift is exactly what made `aic` prompt
# interactively instead of committing non-interactively as documented.
source "$AICOMMIT_DIR/aicommit.sh"
