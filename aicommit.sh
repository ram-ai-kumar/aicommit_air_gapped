#!/usr/bin/env bash
# aicommit — AI-powered conventional commit message generator
# https://github.com/user/aicommit
#
# Sourced by .zshrc to provide `aicommit` and `aic` shell functions.
# Can also be sourced manually: source ~/.aicommit/aicommit.sh

# Resolve install directory
if [ -z "${AICOMMIT_DIR:-}" ] || [ ! -r "${AICOMMIT_DIR}/config/defaults.sh" ]; then
    _self_dir=""
    if [ -n "${BASH_SOURCE[0]:-}" ]; then
        _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    elif [ -n "${ZSH_VERSION:-}" ]; then
        _self_dir="$(cd "$(dirname "${(%):-%x}")" 2>/dev/null && pwd)"
    fi
    if [ -n "$_self_dir" ] && [ -r "${_self_dir}/config/defaults.sh" ]; then
        AICOMMIT_DIR="$_self_dir"
    else
        AICOMMIT_DIR="$HOME/.aicommit"
    fi
    unset _self_dir
fi

# Load user config (overrides), then defaults (fills gaps)
[ -f "$HOME/.aicommitrc" ] && [ -r "$HOME/.aicommitrc" ] && source "$HOME/.aicommitrc" 2>/dev/null || true
source "$AICOMMIT_DIR/config/defaults.sh"

# Source libraries
source "$AICOMMIT_DIR/lib/output-formatter.sh"
source "$AICOMMIT_DIR/lib/context-analyzer.sh"
source "$AICOMMIT_DIR/lib/backends.sh"
source "$AICOMMIT_DIR/lib/core.sh"
source "$AICOMMIT_DIR/lib/semver.sh"
source "$AICOMMIT_DIR/lib/single-flow.sh"
source "$AICOMMIT_DIR/lib/split-flow.sh"

# Load completions
if [ -n "$ZSH_VERSION" ] && [ -d "$AICOMMIT_DIR/completions" ]; then
    fpath=("$AICOMMIT_DIR/completions" $fpath)
fi

# ─── Main Commands ────────────────────────────────────────────────────────────

# Interactive AI-powered conventional commit (implementation — the public
# `aicommit` wrapper at the bottom guarantees run-dir cleanup on every path,
# including the early returns below).
_aicommit_main() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local dry_run=false verbose=false regenerate=false split_mode=false auto_yes=false
    local explicit_split=false explicit_all=false clean_cache=false
    local is_aic="${AIC_SHORTCUT:-false}"
    local bump_opt="${AI_SEMVER_BUMP:-false}"
    local bump_level=""
    local tag_opt="${AI_SEMVER_TAG:-true}"

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                echo "Usage: aicommit [OPTIONS]"
                echo ""
                echo "AI-powered conventional commit message generator."
                echo "Analyzes staged changes and generates commit messages using local LLM."
                echo ""
                echo "Options:"
                echo "  --help, -h         Show this help message and exit"
                echo "  --yes, -y          Automatically accept generated commit messages without interactive prompts"
                echo "  --split, -s        Split staged changes into atomic commits by logical scope"
                echo "  --no-split, --all  Keep all staged changes in a single all-in-one commit"
                echo "  --bump, -b         Evaluate and bump SemVer version based on commit changes"
                echo "  --bump=*           Explicitly bump SemVer version (--bump=major|minor|patch)"
                echo "  --semver           Synonym for --bump"
                echo "  --semver=*         Synonym for --bump=*"
                echo "  --tag              Create Git tag for bumped version (default: true)"
                echo "  --no-tag           Do not create Git tag when version is bumped"
                echo "  --dry-run, -d      Build context and show prompt without calling LLM"
                echo "  --verbose, -v      Show diagnostics: staged file list, backend/model, temp paths"
                echo "  --regenerate, -r   Re-run LLM on cached prompt without re-analyzing"
                echo "  --reflect          Enable reflection prompt step (default: on-failure)"
                echo "  --reflect=always   Reflect unconditionally on every commit generation"
                echo "  --no-reflect       Disable reflection prompt step"
                echo "  --clean-cache      Remove the .git/aicommit working directory and exit"
                echo "Quick Shell Shims (non-interactive, CI/CD friendly):"
                echo "  aic                Fast all-in-one commit without SemVer"
                echo "  aicc               Fast atomic split commits without SemVer"
                echo "  aics               Fast all-in-one commit WITH SemVer bump & tag"
                echo "  aiccs              Fast atomic split commits WITH SemVer bump & tag"
                echo "  aicx               Verbose dry-run preview (0 changes made)"
                echo "  aiccx              Verbose dry-run split preview (0 changes made)"
                echo "  aicsx              Verbose dry-run preview with SemVer (0 changes made)"
                echo "  aiccsx             Verbose dry-run split preview with SemVer (0 changes made)"
                echo ""
                echo "Interactive Session:"
                echo "  aicommit           Fully interactive commit with scope and SemVer decisions"
                echo ""
                echo "Examples:"
                echo "  git add -p && aicommit        Interactive session: review message, scopes & SemVer"
                echo "  aicommit --bump               Interactive session with SemVer bump pre-selected"
                echo "  aicommit --bump=minor         Interactive session with explicit minor bump"
                echo "  aic                           Fast all-in-one commit (CI/CD / non-interactive)"
                echo "  aicc                          Fast atomic split commits (CI/CD / non-interactive)"
                echo "  aics                          Fast all-in-one commit + SemVer (CI/CD / non-interactive)"
                echo "  aiccs                         Fast atomic split commits + SemVer (CI/CD / non-interactive)"
                echo "  aicx                          Preview prompt and staged files (0 changes made)"
                echo "  aiccx                         Preview atomic scope groups (0 changes made)"
                echo "  aicommit --dry-run            Preview the prompt sent to LLM"
                echo "  aicommit --regenerate         Regenerate from last analysis"
                return 0
                ;;
            --yes|-y)        auto_yes=true ;;
            --split|-s)      split_mode=true; explicit_split=true ;;
            --no-split|--all) split_mode=false; explicit_all=true ;;
            --bump|-b)       bump_opt=true ;;
            --bump=*)        bump_opt=true; bump_level="${1#--bump=}" ;;
            --semver)        bump_opt=true ;;
            --semver=*)      bump_opt=true; bump_level="${1#--semver=}" ;;
            --tag)           tag_opt=true ;;
            --no-tag)        tag_opt=false ;;
            --shortcut)      is_aic=true ;;
            --dry-run|-d)    dry_run=true ;;
            --verbose|-v)    verbose=true ;;
            --regenerate|-r) regenerate=true ;;
            --reflect)       export AI_ENABLE_REFLECTION=true ;;
            --reflect=always) export AI_ENABLE_REFLECTION=true; export AI_REFLECTION_MODE="always" ;;
            --reflect=on-failure) export AI_ENABLE_REFLECTION=true; export AI_REFLECTION_MODE="on-failure" ;;
            --no-reflect|--no-reflection) export AI_ENABLE_REFLECTION=false ;;
            --warm)
                validate_prerequisites && warm_up_model "${AI_MODEL:-$DEFAULT_AI_MODEL}" true
                return $?
                ;;
            --clean-cache)   clean_cache=true ;;
            *) echo "Unknown option: $1. Use --help for usage."; return 1 ;;
        esac
        shift
    done

    if [ "$explicit_split" = "true" ] && [ "$explicit_all" = "true" ]; then
        display_error "Conflicting options: cannot specify both --split and --no-split/--all"
        return 1
    fi

    export AICOMMIT_MODE=true

    if [ "$clean_cache" = "true" ]; then
        aicommit_clean_cache
        return $?
    fi

    # Fresh per-invocation run dir under .git/aicommit/runs/, plus stale-run
    # purge. All context artifacts land there; preview/handoff artifacts live
    # in .git/aicommit/state/.
    if ! init_aicommit_run; then
        return 1
    fi
    local tmp_dir="$_AICOMMIT_RUN_DIR"
    local state_dir
    state_dir=$(get_aicommit_state_dir) || return 1

    # Remove the run dir on exit and on interrupt — runs/ must be empty after
    # a finished session.
    trap aicommit_cleanup_run_dir EXIT
    trap 'aicommit_cleanup_run_dir; trap - INT; kill -INT ${BASHPID:-$$}' INT
    trap 'aicommit_cleanup_run_dir; trap - TERM; kill -TERM ${BASHPID:-$$}' TERM

    # --regenerate: skip context building, re-run LLM on cached request
    if [ "$regenerate" = "true" ]; then
        _aicommit_regenerate_flow "$tmp_dir" "$state_dir" "$verbose" "$bump_opt" "$bump_level" "$tag_opt" "$auto_yes"
        local regen_rc=$?
        [ "$verbose" = "true" ] && [ -f "${tmp_dir}/TRACE" ] && display_trace_summary "${tmp_dir}/TRACE"
        return $regen_rc
    fi

    # Capture staged changes once per variant — every consumer reads the run
    # files instead of re-running git. core.quotePath=false (via agit) keeps
    # non-ASCII filenames as raw UTF-8 instead of octal-escaped
    # "quoted\342\204\242strings" that never match anything downstream
    # (pathspecs, case patterns, grep). The three variants run in parallel.
    local changes staged_files numstat_data
    { agit diff --staged -M --diff-algorithm=histogram > "${tmp_dir}/STAGED_DIFF" & } 2>/dev/null
    local _p_diff=$!
    { (agit diff --staged -z --name-only | tr '\0' '\n') > "${tmp_dir}/STAGED_NAMES" & } 2>/dev/null
    local _p_names=$!
    { agit diff --staged --numstat > "${tmp_dir}/NUMSTAT" & } 2>/dev/null
    local _p_numstat=$!
    wait "$_p_diff" "$_p_names" "$_p_numstat"

    changes=$(cat "${tmp_dir}/STAGED_DIFF")
    staged_files=$(cat "${tmp_dir}/STAGED_NAMES")
    numstat_data=$(cat "${tmp_dir}/NUMSTAT")

    if [ -z "$changes" ] || [ -z "$staged_files" ]; then
        display_error "No staged changes"
        return 1
    fi

    # Validate Ollama + LLM presence once upfront (skip for --dry-run)
    if [ "$dry_run" != "true" ] && ! validate_prerequisites; then
        return 1
    fi

    # Staged file list is diagnostics — shown only in --verbose
    [ "$verbose" = "true" ] && display_staged_files "$staged_files" "$numstat_data"

    local scope_groups="" num_scopes=0 scope_names=""

    # Check for multi-scope staging only when run as full aicommit, interactively,
    # without --yes (which by definition means "don't ask, just do the all-in-one commit").
    # When running as 'aic', assume all-in-one commit without checking for logical grouping.
    if [ "$is_aic" != "true" ] && [ "$auto_yes" != "true" ] && [ "$split_mode" = "false" ] && [ "$dry_run" != "true" ]; then
        scope_groups=$(group_staged_files_by_scope "$staged_files" "$changes" "$numstat_data")
        scope_groups=$(printf '%s\n' "$scope_groups" | awk -F'\t' 'NF>=2 && $1!="" && $2!="" && $1 !~ /=/ && $1 !~ /^(joined_files|staged_files|files)/ {print $0}')
        num_scopes=$(printf '%s\n' "$scope_groups" | count_lines)
        scope_names=$(printf '%s\n' "$scope_groups" | awk -F'\t' '{printf (NR>1?", ":"") $1} END{print ""}')

        # If changes span 2+ scopes, prompt user for approval
        if [ "$num_scopes" -ge 2 ]; then
            # Phase 6: Start background all-in-one generation during interactive think time
            local bg_subshell_pid=""
            (
                build_ai_context "$changes" "$staged_files" "$numstat_data" "" "$tmp_dir" >/dev/null 2>&1
                generate_commit_message "$tmp_dir" >/dev/null 2>&1
            ) &
            bg_subshell_pid=$!
            _AICOMMIT_BG_PID="$bg_subshell_pid"

            display_split_confirmation "$num_scopes" "$scope_names" "$scope_groups"
            if ! read -r split_choice; then
                [ -n "$_AICOMMIT_BG_PID" ] && kill "$_AICOMMIT_BG_PID" 2>/dev/null || true
                _AICOMMIT_BG_PID=""
                display_error "No input available to choose a commit strategy (stdin closed)" \
                    "Re-run with --yes (all-in-one) or --split (atomic commits) to choose explicitly"
                return 1
            fi
            split_choice=${split_choice:-y}
            case "$split_choice" in
                y|Y|yes|Yes|""|a|A|1|all|all-in-one)
                    split_mode=false
                    if [ -n "$_AICOMMIT_BG_PID" ]; then
                        wait "$_AICOMMIT_BG_PID" 2>/dev/null || true
                        _AICOMMIT_BG_PID=""
                    fi
                    ;;
                n|N|no|No|m|M|multi|split|s|S)
                    split_mode=true
                    if [ -n "$_AICOMMIT_BG_PID" ]; then
                        kill "$_AICOMMIT_BG_PID" 2>/dev/null || true
                        _AICOMMIT_BG_PID=""
                    fi
                    ;;
                *)
                    if [ -n "$_AICOMMIT_BG_PID" ]; then
                        kill "$_AICOMMIT_BG_PID" 2>/dev/null || true
                        _AICOMMIT_BG_PID=""
                    fi
                    echo "❌ Commit cancelled."
                    return 0
                    ;;
            esac
        fi
    fi

    local flow_rc=0
    # Split atomic commits workflow
    if [ "$split_mode" = "true" ]; then
        _aicommit_split_flow "$tmp_dir" "$state_dir" "$changes" "$staged_files" "$numstat_data" \
            "$scope_groups" "$dry_run" "$verbose" "$bump_opt" "$bump_level" "$tag_opt" "$auto_yes"
        flow_rc=$?
    else
        _aicommit_single_flow "$tmp_dir" "$state_dir" "$changes" "$staged_files" "$numstat_data" \
            "$dry_run" "$verbose" "$bump_opt" "$bump_level" "$tag_opt" "$auto_yes"
        flow_rc=$?
    fi

    [ "$verbose" = "true" ] && [ -f "${tmp_dir}/TRACE" ] && display_trace_summary "${tmp_dir}/TRACE"
    return $flow_rc

}

# Public entry point — guarantees the per-invocation run dir is removed on
# every return path (success, early error, abort). The EXIT/INT/TERM traps set
# inside _aicommit_main additionally cover subshell/script exits.
aicommit() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local _rc _saved_traps="" _saved_monitor=false
    if [ -n "$BASH_VERSION" ]; then
        _saved_traps=$(trap -p INT TERM)
        [[ "$-" =~ m ]] && _saved_monitor=true
        set +m
    fi
    _aicommit_main "$@"
    _rc=$?
    aicommit_cleanup_run_dir
    if [ -n "$BASH_VERSION" ]; then
        trap - INT TERM EXIT
        [ -n "$_saved_traps" ] && eval "$_saved_traps"
        [ "$_saved_monitor" = "true" ] && set -m
    fi
    return $_rc
}

# True if $@ already includes an explicit split-mode flag. The quick shims below
# each inject a default (--no-split for aic/aicx, --split for aicc/aiccx) — without
# this check, a caller override (e.g. `aic --split`) collides with that injected
# default and `aicommit` rejects the call as "Conflicting options", even though the
# override is exactly what a "shorthand for X, but you can still pass flags" shim
# should honor.
_aicommit_has_split_flag() {
    local a
    for a in "$@"; do
        case "$a" in
            --split|-s|--no-split|--all) return 0 ;;
        esac
    done
    return 1
}

# Quick AI commit — auto-commits all-in-one without confirmation or scope grouping
aic() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--no-split "${args[@]}")
    AIC_SHORTCUT=true aicommit --yes --shortcut "${args[@]}"
}

# Quick AI commit categorized — auto-commits each atomic scope separately
aicc() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--split "${args[@]}")
    AIC_SHORTCUT=true aicommit --yes --shortcut "${args[@]}"
}

# Verbose dry-run inspection for single all-in-one commit (0 changes made)
aicx() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--no-split "${args[@]}")
    AIC_SHORTCUT=true aicommit --dry-run --verbose --shortcut "${args[@]}"
}

# Verbose dry-run inspection for atomic split commits (0 changes made)
aiccx() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--split "${args[@]}")
    AIC_SHORTCUT=true aicommit --dry-run --verbose --shortcut "${args[@]}"
}

# Quick AI commit with SemVer — auto-commits all-in-one with SemVer bump & tag (non-interactive, CI/CD friendly)
aics() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--no-split "${args[@]}")
    AIC_SHORTCUT=true aicommit --yes --bump --shortcut "${args[@]}"
}

# Quick AI commit categorized with SemVer — auto-commits each atomic scope with SemVer bump & tag (non-interactive, CI/CD friendly)
aiccs() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--split "${args[@]}")
    AIC_SHORTCUT=true aicommit --yes --bump --shortcut "${args[@]}"
}

# Verbose dry-run inspection for single commit with SemVer preview (0 changes made)
aicsx() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--no-split "${args[@]}")
    AIC_SHORTCUT=true aicommit --dry-run --verbose --bump --shortcut "${args[@]}"
}

# Verbose dry-run inspection for atomic split commits with SemVer preview (0 changes made)
aiccsx() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--split "${args[@]}")
    AIC_SHORTCUT=true aicommit --dry-run --verbose --bump --shortcut "${args[@]}"
}

# Export functions for subshells if running in bash
if [ -n "$BASH_VERSION" ]; then
    export -f aicommit aic aicc aicx aiccx aics aiccs aicsx aiccsx 2>/dev/null || true
fi

# Run directly when executed as a script rather than sourced
if [ -n "$BASH_SOURCE" ] && [ "$BASH_SOURCE" = "$0" ]; then
    aicommit "$@"
fi
