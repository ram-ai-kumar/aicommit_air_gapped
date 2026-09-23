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
                echo "  --help, -h         Show this help message and exit"
                echo "  --yes, -y          Automatically accept generated commit messages without interactive prompts"
                echo "  --split, -s        Split staged changes into atomic commits by logical scope"
                echo "  --no-split, --all  Keep all staged changes in a single all-in-one commit"
                echo "  --dry-run, -d      Build context and show prompt without calling LLM"
                echo "  --verbose, -v      Show diagnostics: staged file list, backend/model, temp paths"
                echo "  --regenerate, -r   Re-run LLM on cached prompt without re-analyzing"
                echo ""
                echo "Quick Shell Shims:"
                echo "  aic                Fast all-in-one commit (shorthand for: aicommit --yes --no-split)"
                echo "  aicc               Fast atomic split commits (shorthand for: aicommit --yes --split)"
                echo "  aicx               Verbose dry-run preview (shorthand for: aicommit --dry-run --verbose --no-split)"
                echo "  aiccx              Verbose dry-run split preview (shorthand for: aicommit --dry-run --verbose --split)"
                echo ""
                echo "Examples:"
                echo "  git add -p && aicommit        Stage changes, then generate commit"
                echo "  aic                           Fast all-in-one commit"
                echo "  aicc                          Split and auto-commit each atomic scope"
                echo "  aicx                          Preview prompt and staged files (0 changes made)"
                echo "  aiccx                         Preview atomic scope groups (0 changes made)"
                echo "  aicommit --dry-run            Preview the prompt sent to LLM"
                echo "  aicommit --regenerate         Regenerate from last analysis"
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
            # `read` returning non-zero here means stdin hit EOF with nothing to
            # read (e.g. invoked from a hook with stdin on /dev/null) — NOT the
            # same as piped input ("echo y | aicommit"), which still succeeds.
            # Without this check, `response=${response:-y}` would silently treat
            # "no input at all" as if the user had confirmed.
            if ! read -r response; then
                display_error "No input available to confirm the commit (stdin closed)" \
                    "Re-run with --yes to accept generated messages automatically"
                return 1
            fi
            response=${response:-y}
        fi
        case $response in
            y|Y) process_commit "$commit_msg" && display_success; cleanup_aicommit_all ;;
            e|E) git commit -e -m "$commit_msg"; cleanup_aicommit_all ;;
            *)   echo "❌ Commit cancelled." ;;
        esac
        return 0
    fi

    # Capture staged changes. core.quotePath=false (via agit) keeps non-ASCII
    # filenames as raw UTF-8 instead of octal-escaped "quoted\342\204\242strings"
    # that never match anything downstream (pathspecs, case patterns, grep).
    local changes staged_files numstat_data
    changes=$(agit diff --staged)
    staged_files=$(agit diff --staged -z --name-only | tr '\0' '\n')
    numstat_data=$(agit diff --staged --numstat)

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
            display_split_confirmation "$num_scopes" "$scope_names" "$scope_groups"
            if ! read -r split_choice; then
                display_error "No input available to choose a commit strategy (stdin closed)" \
                    "Re-run with --yes (all-in-one) or --split (atomic commits) to choose explicitly"
                return 1
            fi
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
        local groups_source="regrouped"

        if [ -z "$scope_groups" ]; then
            # Reuse the grouping decision from a preceding `aiccx`/`--dry-run --split`
            # when the staged set is unchanged, so the preview the user reviewed is
            # actually what gets committed — not a second, independently-computed
            # (and possibly LLM-nondeterministic) grouping.
            local fp_now
            fp_now=$(staged_fingerprint)
            if [ -f "${tmp_dir}/SCOPE_GROUPS" ] && [ -f "${tmp_dir}/STAGED_FINGERPRINT" ] \
               && [ "$(cat "${tmp_dir}/STAGED_FINGERPRINT" 2>/dev/null)" = "$fp_now" ]; then
                scope_groups=$(cat "${tmp_dir}/SCOPE_GROUPS")
                num_scopes=$(printf '%s\n' "$scope_groups" | count_lines)
                scope_names=$(printf '%s\n' "$scope_groups" | awk -F'\t' '{printf (NR>1?", ":"") $1} END{print ""}')
                groups_source="reused"
            else
                [ -f "${tmp_dir}/SCOPE_GROUPS" ] && echo "⚠️  Staged set changed since preview — regrouping"
                scope_groups=$(group_staged_files_by_scope "$staged_files" "$changes" "$numstat_data")
                scope_groups=$(printf '%s\n' "$scope_groups" | awk -F'\t' 'NF>=2 && $1!="" && $2!="" && $1 !~ /=/ && $1 !~ /^(joined_files|staged_files|files)/ {print $0}')
                num_scopes=$(printf '%s\n' "$scope_groups" | count_lines)
                scope_names=$(printf '%s\n' "$scope_groups" | awk -F'\t' '{printf (NR>1?", ":"") $1} END{print ""}')
            fi
        fi

        if [ "$dry_run" != "true" ] && ! validate_prerequisites; then
            return 1
        fi

        local grp_scope="" grp_files="" idx=1 group_line=""
        local subset_changes="" subset_staged="" subset_numstat="" grp_commit_msg="" grp_resp="y"
        local edit_file="" edited_msg="" f_item=""
        local -a grp_file_array=() grp_pathspec_array=()

        if [ "$dry_run" = "true" ]; then
            # Persist the decision so a subsequent `aicc` on the same staged set
            # executes exactly this grouping instead of recomputing its own.
            umask 077
            printf '%s\n' "$scope_groups" > "${tmp_dir}/SCOPE_GROUPS"
            staged_fingerprint > "${tmp_dir}/STAGED_FINGERPRINT"

            echo "🔍 Dry run — detected $num_scopes atomic commit groups:"
            while IFS= read -r group_line; do
                _aicommit_split_tab_line "$group_line"
                [ -z "$_aicommit_split_scope" ] && continue
                grp_scope="$_aicommit_split_scope"
                grp_files=$(printf ', %s' "${_aicommit_split_files[@]}"); grp_files="${grp_files#, }"
                echo "  • Scope: $grp_scope -> $grp_files"
            done <<< "$scope_groups"
            return 0
        fi

        # Show the resolved plan before the first commit — the user should never
        # be surprised by what `aicc` decided, regardless of whether it came from
        # a reused preview or a fresh grouping.
        if [ "$groups_source" = "reused" ]; then
            echo "♻️  Reusing $num_scopes group(s) from last preview:"
        else
            echo "📋 Resolved $num_scopes atomic commit group(s):"
        fi
        while IFS= read -r group_line; do
            _aicommit_split_tab_line "$group_line"
            [ -z "$_aicommit_split_scope" ] && continue
            grp_files=$(printf ', %s' "${_aicommit_split_files[@]}"); grp_files="${grp_files#, }"
            echo "  • $_aicommit_split_scope -> $grp_files"
        done <<< "$scope_groups"

        idx=1
        local committed_count=0
        while IFS= read -r -u 3 group_line; do
            _aicommit_split_tab_line "$group_line"
            [ -z "$_aicommit_split_scope" ] && continue
            grp_scope="$_aicommit_split_scope"
            grp_file_array=("${_aicommit_split_files[@]}")
            [ ${#grp_file_array[@]} -eq 0 ] && continue

            grp_pathspec_array=()
            for f_item in "${grp_file_array[@]}"; do
                grp_pathspec_array+=("$(to_pathspec "$f_item")")
            done

            display_split_progress "$idx" "$num_scopes" "$grp_scope"

            subset_changes=$(agit diff --staged -- "${grp_pathspec_array[@]}")
            subset_staged=$(printf '%s\n' "${grp_file_array[@]}")
            subset_numstat=$(agit diff --staged --numstat -- "${grp_pathspec_array[@]}")

            if [ -z "$subset_changes" ]; then
                # No longer a soft warning: an empty subset here means the group's
                # files no longer match the staged set (pathspec bug, stale reused
                # preview, or a file unstaged mid-run) — the run must stop, not
                # silently skip a scope and still report success (see RC4/RC5).
                display_error "No staged changes matched for scope '$grp_scope'" \
                    "Expected files: ${grp_file_array[*]}"
                return 1
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
                if ! read -r grp_resp; then
                    display_error "No input available to confirm scope '$grp_scope' (stdin closed)" \
                        "Re-run with --yes to accept generated messages automatically"
                    return 1
                fi
                grp_resp=${grp_resp:-y}
            fi
            case "$grp_resp" in
                y|Y)
                    if commit_staged_subset "$grp_commit_msg" "${grp_file_array[@]}"; then
                        display_scope_success "$grp_scope"
                        committed_count=$((committed_count + 1))
                    else
                        display_error "Commit failed for scope: $grp_scope"
                        return 1
                    fi
                    ;;
                e|E)
                    if [ ! -t 0 ]; then
                        display_error "Editing the commit message requires an interactive terminal" "stdin is not a TTY"
                        return 1
                    fi
                    edit_file="${tmp_dir}/COMMIT_EDITMSG"
                    printf '%s\n' "$grp_commit_msg" > "$edit_file"
                    ${EDITOR:-vi} "$edit_file"
                    edited_msg=$(cat "$edit_file" 2>/dev/null || true)
                    rm -f "$edit_file"
                    if [ -n "$edited_msg" ]; then
                        if commit_staged_subset "$edited_msg" "${grp_file_array[@]}"; then
                            display_scope_success "$grp_scope"
                            committed_count=$((committed_count + 1))
                        else
                            display_error "Commit failed for scope: $grp_scope"
                            return 1
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
        if [ "$committed_count" -eq "$num_scopes" ]; then
            echo "🎉 All atomic commits completed! ($committed_count/$num_scopes)"
            return 0
        else
            display_error "Only $committed_count of $num_scopes atomic commits completed" \
                "One or more scopes were skipped — see output above"
            return 1
        fi
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
        if ! read -r response; then
            display_error "No input available to confirm the commit (stdin closed)" \
                "Re-run with --yes to accept generated messages automatically"
            return 1
        fi
        response=${response:-y}
    fi

    case $response in
        y|Y) process_commit "$commit_msg" && display_success; cleanup_aicommit_all ;;
        e|E) git commit -e -m "$commit_msg"; cleanup_aicommit_all ;;
        *)   echo "❌ Commit cancelled." ;;
    esac
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
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--no-split "${args[@]}")
    AIC_SHORTCUT=true aicommit --yes --shortcut "${args[@]}"
}

# Quick AI commit categorized — auto-commits each atomic scope separately
aicc() {
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--split "${args[@]}")
    AIC_SHORTCUT=true aicommit --yes --shortcut "${args[@]}"
}

# Verbose dry-run inspection for single all-in-one commit (0 changes made)
aicx() {
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--no-split "${args[@]}")
    AIC_SHORTCUT=true aicommit --dry-run --verbose --shortcut "${args[@]}"
}

# Verbose dry-run inspection for atomic split commits (0 changes made)
aiccx() {
    local -a args=("$@")
    _aicommit_has_split_flag "$@" || args=(--split "${args[@]}")
    AIC_SHORTCUT=true aicommit --dry-run --verbose --shortcut "${args[@]}"
}
