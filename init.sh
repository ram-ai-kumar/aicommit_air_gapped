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

# Live execution shims
aicommit() { "$AICOMMIT_DIR/bin/aicommit" "$@"; }
aic()      { "$AICOMMIT_DIR/bin/aicommit" --yes --no-split "$@"; }
aicc()     { "$AICOMMIT_DIR/bin/aicommit" --yes --split "$@"; }

# Verbose dry-run inspection shims (zero changes made)
aicx()     { "$AICOMMIT_DIR/bin/aicommit" --dry-run --verbose --no-split "$@"; }
aiccx()    { "$AICOMMIT_DIR/bin/aicommit" --dry-run --verbose --split "$@"; }
