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
                echo "  --yes, -y          Automatically accept all prompts (split and commit)"
                echo "  --split, -s        Split changes across distinct scopes into atomic commits"
                echo "  --dry-run, -d      Build context and show prompt without calling LLM"
                echo "  --verbose, -v      Show temp file paths and enhanced context"
                echo "  --regenerate, -r   Re-run LLM on cached prompt without re-analyzing"
                echo ""
                echo "Examples:"
                echo "  git add -p && aicommit      Stage changes, then generate commit"
                echo "  aicommit --split             Intelligently split into atomic commits by scope"
                echo "  aicommit --yes               Auto-accept prompts and commit"
                echo "  aicommit --dry-run           Preview the prompt sent to LLM"
                echo "  aicommit --regenerate        Regenerate from last analysis"
                return 0
                ;;
            --yes|-y)        auto_yes=true ;;
            --split|-s)      split_mode=true ;;
            --no-split|--all) split_mode=false ;;
            --dry-run|-d)    dry_run=true ;;
            --verbose|-v)    verbose=true ;;
            --regenerate|-r) regenerate=true ;;
            *) echo "Unknown option: $1. Use --help for usage."; return 1 ;;
        esac
        shift
    done

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
            y|Y) process_commit "$commit_msg"; cleanup_aicommit_all; display_success ;;
            e|E) git commit -e -m "$commit_msg"; cleanup_aicommit_all ;;
            *)   echo "❌ Cancelled" ;;
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

    # Check for multi-scope staging
    local scope_groups num_scopes scope_names
    scope_groups=$(group_staged_files_by_scope "$staged_files")
    num_scopes=$(echo "$scope_groups" | grep -c '.' || echo "0")
    scope_names=$(echo "$scope_groups" | awk -F'|' '{print $1}' | tr '\n' ', ' | sed 's/, $//')

    # If changes span 2+ scopes and split_mode wasn't explicitly forced, handle splitting
    if [ "$split_mode" = "false" ] && [ "$num_scopes" -ge 2 ] && [ "$dry_run" != "true" ]; then
        if [ "$auto_yes" = "true" ]; then
            # When --yes permission is given (e.g. via aic or aicommit --yes), default to splitting
            split_mode=true
        else
            display_split_confirmation "$num_scopes" "$scope_names"
            read -r split_choice
            split_choice=${split_choice:-y}
            case "$split_choice" in
                y|Y|s|S|yes|Yes) split_mode=true ;;
                all|all-in-one|n|N|no) split_mode=false ;;
                *) echo "❌ Cancelled"; return 0 ;;
            esac
        fi
    fi

    # Split atomic commits workflow
    if [ "$split_mode" = "true" ]; then
        if [ "$dry_run" != "true" ] && ! validate_prerequisites; then
            return 1
        fi

        if [ "$dry_run" = "true" ]; then
            echo "🔍 Dry run — detected $num_scopes atomic commit groups:"
            while IFS= read -r group_line; do
                [ -z "$group_line" ] && continue
                local grp_scope grp_files
                grp_scope=$(echo "$group_line" | cut -d'|' -f1)
                grp_files=$(echo "$group_line" | cut -d'|' -f2)
                echo "  • Scope: $grp_scope -> $grp_files"
            done <<< "$scope_groups"
            return 0
        fi

        local idx=1
        while IFS= read -r group_line; do
            [ -z "$group_line" ] && continue
            local grp_scope grp_files grp_pathspecs
            grp_scope=$(echo "$group_line" | cut -d'|' -f1)
            grp_files=$(echo "$group_line" | cut -d'|' -f2)
            grp_pathspecs=$(echo "$grp_files" | tr ',' ' ')

            display_split_progress "$idx" "$num_scopes" "$grp_scope"

            local subset_changes subset_staged subset_numstat
            subset_changes=$(git diff --staged -- $grp_pathspecs)
            subset_staged=$(echo "$grp_files" | tr ',' '\n')
            subset_numstat=$(git diff --staged --numstat -- $grp_pathspecs)

            if [ -z "$subset_changes" ]; then
                echo "⚠️ No staged changes remaining for scope: $grp_scope"
                idx=$((idx + 1))
                continue
            fi

            build_ai_context "$subset_changes" "$subset_staged" "$subset_numstat"
            local grp_commit_msg
            if ! grp_commit_msg=$(generate_commit_message) || [ -z "$grp_commit_msg" ]; then
                display_error "Failed to generate commit message for scope: $grp_scope"
                return 1
            fi

            display_commit_message "$grp_commit_msg" "Suggested Commit ($idx/$num_scopes - scope: $grp_scope):"
            local grp_resp="y"
            if [ "$auto_yes" != "true" ]; then
                display_commit_confirmation
                read -r grp_resp
                grp_resp=${grp_resp:-y}
            fi
            case "$grp_resp" in
                y|Y)
                    commit_staged_subset "$grp_commit_msg" "$grp_files"
                    echo "✅ Committed scope '$grp_scope' ($grp_files)"
                    ;;
                e|E)
                    local edit_file="${tmp_dir}/COMMIT_EDITMSG"
                    printf '%s\n' "$grp_commit_msg" > "$edit_file"
                    ${EDITOR:-vi} "$edit_file"
                    local edited_msg
                    edited_msg=$(cat "$edit_file" 2>/dev/null || true)
                    rm -f "$edit_file"
                    if [ -n "$edited_msg" ]; then
                        commit_staged_subset "$edited_msg" "$grp_files"
                        echo "✅ Committed scope '$grp_scope' ($grp_files)"
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
        done <<< "$scope_groups"

        cleanup_aicommit_all
        echo "🎉 All atomic commits completed!"
        return 0
    fi

    # Validate prerequisites (skip for dry-run)
    if [ "$dry_run" != "true" ] && ! validate_prerequisites; then
        return 1
    fi

    # Build context first (this creates FILE_COUNT safely)
    build_ai_context "$changes" "$staged_files" "$numstat_data"
    if [ $? -ne 0 ]; then
        return 1
    fi

    local file_list file_count
    # Read count from temp file to avoid xtrace pollution in subshell capture
    file_count=$(cat "${tmp_dir}/FILE_COUNT" 2>/dev/null || echo "0")
    # Build list from staged_files safely
    file_list=$(printf '%s' "$staged_files" | tr '\n' ', ' | sed 's/,$//')

    display_setup_info "$file_count" "$file_list"
    if [ $? -ne 0 ]; then
        return 1
    fi

    if [ "$verbose" = "true" ]; then
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
        y|Y) process_commit "$commit_msg"; cleanup_aicommit_all; display_success ;;
        e|E) git commit -e -m "$commit_msg"; cleanup_aicommit_all ;;
        *)   echo "❌ Cancelled" ;;
    esac
}

# Quick AI commit — auto-commits without confirmation (--yes permission given)
# Automatically splits multi-scope changes into atomic commits unless --no-split/--all is given
aic() {
    aicommit --yes "$@"
}
