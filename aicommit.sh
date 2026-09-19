#!/usr/bin/env bash
# aicommit — AI-powered conventional commit message generator
# https://github.com/user/aicommit
#
# Sourced by .zshrc to provide `aicommit` and `aic` shell functions.
# Can also be sourced manually: source ~/.aicommit/aicommit.sh

# Resolve install directory
AICOMMIT_DIR="${AICOMMIT_DIR:-$HOME/.aicommit}"

# Load user config (overrides), then defaults (fills gaps)
[ -f "$HOME/.aicommitrc" ] && source "$HOME/.aicommitrc"
source "$AICOMMIT_DIR/config/defaults.sh"

# Source libraries
source "$AICOMMIT_DIR/lib/output-formatter.sh"
source "$AICOMMIT_DIR/lib/context-analyzer.sh"
source "$AICOMMIT_DIR/lib/backends.sh"
source "$AICOMMIT_DIR/lib/core.sh"

# Load completions
if [ -n "$ZSH_VERSION" ] && [ -d "$AICOMMIT_DIR/completions" ]; then
    fpath=("$AICOMMIT_DIR/completions" $fpath)
fi

# ─── Main Commands ────────────────────────────────────────────────────────────

# Interactive AI-powered conventional commit
aicommit() {
    local dry_run=false verbose=false regenerate=false split_mode=false auto_yes=false
    local explicit_split=false explicit_all=false
    local is_aic="${AIC_SHORTCUT:-false}"

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                echo "Usage: aicommit [OPTIONS]"
                echo ""
                echo "AI-powered conventional commit message generator."
                echo "Analyzes staged changes and generates commit messages using local LLM."
                echo ""
                echo "Options:"
                echo "  --help, -h         Show this help message"
                echo "  --yes, -y          Automatically accept generated commit messages without interactive prompts"
                echo "  --split, -s        Split staged changes into atomic commits by logical scope"
                echo "  --no-split, --all  Keep all staged changes in a single all-in-one commit"
                echo "  --dry-run, -d      Build context and show prompt without calling LLM"
                echo "  --verbose, -v      Show diagnostics: staged file list, backend/model, temp paths"
                echo "  --regenerate, -r   Re-run LLM on cached prompt without re-analyzing"
                echo ""
                echo "Examples:"
                echo "  git add -p && aicommit        Stage changes, then generate commit"
                echo "  aicommit --split               Split into atomic commits by logical scope"
                echo "  aicommit --yes                 Auto-accept commit message and commit (all-in-one)"
                echo "  aicommit --split --yes         Split and auto-commit each atomic scope"
                echo "  aicommit --dry-run             Preview the prompt sent to LLM"
                echo "  aicommit --regenerate          Regenerate from last analysis"
                return 0
                ;;
            --yes|-y)        auto_yes=true ;;
            --split|-s)      split_mode=true; explicit_split=true ;;
            --no-split|--all) split_mode=false; explicit_all=true ;;
            --shortcut)      is_aic=true ;;
            --dry-run|-d)    dry_run=true ;;
            --verbose|-v)    verbose=true ;;
            --regenerate|-r) regenerate=true ;;
            *) echo "Unknown option: $1. Use --help for usage."; return 1 ;;
        esac
        shift
    done

    if [ "$explicit_split" = "true" ] && [ "$explicit_all" = "true" ]; then
        display_error "Conflicting options: cannot specify both --split and --no-split/--all"
        return 1
    fi

    export AICOMMIT_MODE=true
    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir)

    # Clean up ephemeral files on exit (keeps FULL_PROMPT if it exists)
    trap cleanup_aicommit_ephemeral EXIT

    # --regenerate: skip context building, re-run LLM on cached prompt
    if [ "$regenerate" = "true" ]; then
        if [ ! -f "${tmp_dir}/FULL_PROMPT" ]; then
            display_error "No cached prompt found in $tmp_dir" "Run aicommit first to build context"
            return 1
        fi
        if ! validate_prerequisites; then
            return 1
        fi
        echo "♻️  Regenerating from cached prompt..."
        [ "$verbose" = "true" ] && echo "📂 Prompt: ${tmp_dir}/FULL_PROMPT"

        local commit_msg
        if ! commit_msg=$(generate_commit_message) || [ -z "$commit_msg" ]; then
            return 1
        fi
        display_commit_message "$commit_msg"
        local response="y"
        if [ "$auto_yes" != "true" ]; then
            display_commit_confirmation
            read -r response
            response=${response:-y}
        fi
        case $response in
            y|Y) process_commit "$commit_msg" && display_success; cleanup_aicommit_all ;;
            e|E) git commit -e -m "$commit_msg"; cleanup_aicommit_all ;;
            *)   echo "❌ Commit cancelled." ;;
        esac
        return 0
    fi

    # Capture staged changes (3 git calls total)
    local changes staged_files numstat_data
    changes=$(git diff --staged)
    staged_files=$(git diff --staged --name-only)
    numstat_data=$(git diff --staged --numstat)

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

    # Check for multi-scope staging only when run as full aicommit (not as 'aic' shortcut)
    # When running as 'aic', assume all-in-one commit without checking for logical grouping
    if [ "$is_aic" != "true" ] && [ "$split_mode" = "false" ] && [ "$dry_run" != "true" ]; then
        scope_groups=$(group_staged_files_by_scope "$staged_files" "$changes" "$numstat_data")
        num_scopes=$(echo "$scope_groups" | grep -c '|' || echo "0")
        scope_names=$(echo "$scope_groups" | awk -F'|' '{printf (NR>1?", ":"") $1} END{print ""}')

        # If changes span 2+ scopes, prompt user for approval
        if [ "$num_scopes" -ge 2 ]; then
            display_split_confirmation "$num_scopes" "$scope_names" "$scope_groups"
            read -r split_choice
            split_choice=${split_choice:-y}
            case "$split_choice" in
                y|Y|yes|Yes|""|a|A|1|all|all-in-one) split_mode=false ;;
                n|N|no|No|m|M|multi|split|s|S) split_mode=true ;;
                x|X|abort|Abort|q|Q|cancel) echo "❌ Commit cancelled."; return 0 ;;
                *) echo "❌ Commit cancelled."; return 0 ;;
            esac
        fi
    fi

    # Split atomic commits workflow
    if [ "$split_mode" = "true" ]; then
        if [ -z "$scope_groups" ]; then
            scope_groups=$(group_staged_files_by_scope "$staged_files" "$changes" "$numstat_data")
            num_scopes=$(echo "$scope_groups" | grep -c '|' || echo "0")
            scope_names=$(echo "$scope_groups" | awk -F'|' '{printf (NR>1?", ":"") $1} END{print ""}')
        fi

        if [ "$dry_run" != "true" ] && ! validate_prerequisites; then
            return 1
        fi

        local group_line="" grp_scope="" grp_files="" idx=1
        local subset_changes="" subset_staged="" subset_numstat="" grp_commit_msg="" grp_resp="y"
        local edit_file="" edited_msg="" f_item=""
        local -a grp_file_array=()

        if [ "$dry_run" = "true" ]; then
            echo "🔍 Dry run — detected $num_scopes atomic commit groups:"
            while IFS= read -r group_line; do
                [ -z "$group_line" ] && continue
                grp_scope=$(echo "$group_line" | cut -d'|' -f1)
                grp_files=$(echo "$group_line" | cut -d'|' -f2)
                echo "  • Scope: $grp_scope -> $grp_files"
            done <<< "$scope_groups"
            return 0
        fi

        idx=1
        while IFS= read -r -u 3 group_line; do
            [ -z "$group_line" ] && continue
            grp_scope=$(echo "$group_line" | cut -d'|' -f1)
            grp_files=$(echo "$group_line" | cut -d'|' -f2)
            IFS=',' read -r -a grp_file_array <<< "$grp_files"

            display_split_progress "$idx" "$num_scopes" "$grp_scope"

            subset_changes=$(git diff --staged -- "${grp_file_array[@]}")
            subset_staged=$(echo "$grp_files" | tr ',' '\n')
            subset_numstat=$(git diff --staged --numstat -- "${grp_file_array[@]}")

            if [ -z "$subset_changes" ]; then
                echo "⚠️ No staged changes remaining for scope: $grp_scope"
                idx=$((idx + 1))
                continue
            fi

            build_ai_context "$subset_changes" "$subset_staged" "$subset_numstat" "$grp_scope"
            if ! grp_commit_msg=$(generate_commit_message) || [ -z "$grp_commit_msg" ]; then
                display_error "Failed to generate commit message for scope: $grp_scope"
                return 1
            fi

            display_commit_message "$grp_commit_msg" "Suggested Commit ($idx/$num_scopes - scope: $grp_scope):"
            grp_resp="y"
            if [ "$auto_yes" != "true" ]; then
                display_commit_confirmation
                read -r grp_resp
                grp_resp=${grp_resp:-y}
            fi
            case "$grp_resp" in
                y|Y)
                    if commit_staged_subset "$grp_commit_msg" "$grp_files"; then
                        display_scope_success "$grp_scope"
                    fi
                    ;;
                e|E)
                    edit_file="${tmp_dir}/COMMIT_EDITMSG"
                    printf '%s\n' "$grp_commit_msg" > "$edit_file"
                    ${EDITOR:-vi} "$edit_file"
                    edited_msg=$(cat "$edit_file" 2>/dev/null || true)
                    rm -f "$edit_file"
                    if [ -n "$edited_msg" ]; then
                        if commit_staged_subset "$edited_msg" "$grp_files"; then
                            display_scope_success "$grp_scope"
                        fi
                    else
                        echo "⚠️ Commit message was empty. Skipping scope '$grp_scope'."
                    fi
                    ;;
                *)
                    echo "❌ Stopped split committing. Remaining files stay staged."
                    cleanup_aicommit_all
                    return 0
                    ;;
            esac
            idx=$((idx + 1))
        done 3<<< "$scope_groups"

        cleanup_aicommit_all
        echo "🎉 All atomic commits completed!"
        return 0
    fi

    # Validate prerequisites (skip for dry-run)
    if [ "$dry_run" != "true" ] && ! validate_prerequisites; then
        return 1
    fi

    # Build context for the LLM prompt
    build_ai_context "$changes" "$staged_files" "$numstat_data"
    if [ $? -ne 0 ]; then
        return 1
    fi

    if [ "$verbose" = "true" ]; then
        display_setup_info
        echo "📂 Temp dir: ${tmp_dir}"
        echo "   CHANGES_CONTEXT: ${tmp_dir}/CHANGES_CONTEXT"
        echo "   FULL_PROMPT:     ${tmp_dir}/FULL_PROMPT"
    fi

    # --dry-run: assemble prompt and exit
    if [ "$dry_run" = "true" ]; then
        generate_commit_message --dry-run > /dev/null 2>&1 || true
        echo ""
        echo "🔍 Dry run — prompt written to: ${tmp_dir}/FULL_PROMPT"
        echo "   cat ${tmp_dir}/FULL_PROMPT"
        return 0
    fi

    # Generate and display
    local commit_msg
    if ! commit_msg=$(generate_commit_message) || [ -z "$commit_msg" ]; then
        return 1
    fi

    display_commit_message "$commit_msg"
    local response="y"
    if [ "$auto_yes" != "true" ]; then
        display_commit_confirmation
        read -r response
        response=${response:-y}
    fi

    case $response in
        y|Y) process_commit "$commit_msg" && display_success; cleanup_aicommit_all ;;
        e|E) git commit -e -m "$commit_msg"; cleanup_aicommit_all ;;
        *)   echo "❌ Commit cancelled." ;;
    esac
}

# Quick AI commit — auto-commits all-in-one without confirmation or scope grouping
aic() {
    AIC_SHORTCUT=true aicommit --yes --shortcut "$@"
}
