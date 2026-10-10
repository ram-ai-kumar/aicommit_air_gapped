#!/usr/bin/env bash
# aicommit — Single Commit & Regenerate Flow
# Handles all-in-one commit generation, confirmation, semver planning, and committing.

[ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent

# Compute and optionally display the SemVer release plan.
# Sets globals:
#   _SEMVER_CUR_VER, _SEMVER_BUMP, _SEMVER_NEXT_VER, _SEMVER_EVAL_NEXT,
#   _SEMVER_IS_HIGHER, _SEMVER_TAG_NAME, _SEMVER_V_FILES
# Args: $1=cur_ver, $2=bump_level ("major"|"minor"|"patch"|"custom"|"custom:<ver>"), $3=show (default true)
_aicommit_semver_plan() {
    local cur_ver="$1" bump_level="$2" show="${3:-true}"
    _SEMVER_CUR_VER="$cur_ver"
    _SEMVER_IS_HIGHER=false

    if [[ "$bump_level" == custom:* ]]; then
        _SEMVER_BUMP="custom"
        _SEMVER_NEXT_VER="${bump_level#custom:}"
        _SEMVER_EVAL_NEXT="$_SEMVER_NEXT_VER"
    elif [ "$bump_level" = "custom" ]; then
        _SEMVER_BUMP="custom"
        _SEMVER_EVAL_NEXT="$_SEMVER_NEXT_VER"
    else
        _SEMVER_BUMP="$bump_level"
        _SEMVER_EVAL_NEXT=$(calculate_next_semver "$cur_ver" "$bump_level")
        local effective_next=""
        if effective_next=$(resolve_effective_semver "$_SEMVER_EVAL_NEXT"); then
            _SEMVER_IS_HIGHER=true
            _SEMVER_NEXT_VER="$effective_next"
        else
            _SEMVER_NEXT_VER="$_SEMVER_EVAL_NEXT"
        fi
    fi

    _SEMVER_TAG_NAME="${AI_SEMVER_TAG_PREFIX:-v}${_SEMVER_NEXT_VER}"
    _SEMVER_V_FILES=$(detect_version_files)
    if [ "${AI_SEMVER_CHANGELOG:-true}" = "true" ]; then
        local cl_cand
        cl_cand=$(detect_changelog_file 2>/dev/null || echo "${AI_SEMVER_CHANGELOG_FILE:-CHANGELOG.md}")
        [ -n "$_SEMVER_V_FILES" ] && _SEMVER_V_FILES=$(printf '%s\n%s' "$_SEMVER_V_FILES" "$cl_cand") || _SEMVER_V_FILES="$cl_cand"
    fi

    if [ "$show" = "true" ]; then
        display_semver_plan "$cur_ver" "$_SEMVER_BUMP" "$_SEMVER_NEXT_VER" "$_SEMVER_TAG_NAME" "$_SEMVER_V_FILES" "$_SEMVER_IS_HIGHER"
    fi
}

# Handle user response on commit confirmation prompt (a, s=, s<space>, s|b|c, y, e, etc.).
# Sets globals:
#   _CHOICE_RESP: action response ("y", "e", or abort)
#   _CHOICE_BUMP_OPT: "true" or "false"
#   _SEMVER_*: updated plan globals if semver was calculated
# Args: $1=response, $2=commit_msg, $3=cur_ver, $4=bump_level, $5=context_data, $6=bump_opt, $7=scope_name (optional)
_aicommit_apply_choice() {
    local resp="$1"
    local commit_msg="$2"
    local cur_ver="$3"
    local bump_level="$4"
    local context_data="$5"
    local bump_opt="${6:-false}"
    local scope_name="${7:-}"

    _CHOICE_RESP="$resp"
    _CHOICE_BUMP_OPT="$bump_opt"

    case "$resp" in
        a|A|ai|AI|s=ai|b=ai)
            if [ -n "$scope_name" ]; then
                printf "🤖 Asking AI to analyze scope '%s' and calculate SemVer...\n" "$scope_name"
            else
                printf "🤖 Asking AI to analyze changes and calculate SemVer...\n"
            fi
            local ai_level
            ai_level=$(ai_evaluate_semver "$commit_msg" "$context_data")
            if [ -n "$ai_level" ] && [[ "$ai_level" =~ ^(major|minor|patch)$ ]]; then
                _CHOICE_BUMP_OPT=true
                _aicommit_semver_plan "$cur_ver" "$ai_level" false
                printf "🤖 AI calculated SemVer: %s -> %s\n" "$(echo "$ai_level" | tr '[:lower:]' '[:upper:]')" "$_SEMVER_NEXT_VER"
                display_semver_plan "$cur_ver" "$_SEMVER_BUMP" "$_SEMVER_NEXT_VER" "$_SEMVER_TAG_NAME" "$_SEMVER_V_FILES" "$_SEMVER_IS_HIGHER"
            else
                echo "⚠️  AI evaluation unavailable — using standard recommendation."
            fi
            _CHOICE_RESP="y"
            ;;
        s=*|b=*)
            local inline_level="${resp#*=}"
            _CHOICE_BUMP_OPT=true
            _aicommit_semver_plan "$cur_ver" "$inline_level" true
            _CHOICE_RESP="y"
            ;;
        s\ *|b\ *)
            local inline_level="${resp#* }"
            _CHOICE_BUMP_OPT=true
            _aicommit_semver_plan "$cur_ver" "$inline_level" true
            _CHOICE_RESP="y"
            ;;
        s|S|b|B|semver|bump|c|C)
            local chosen_decision
            chosen_decision=$(prompt_semver_decision "$commit_msg" "$cur_ver" "$bump_level")
            if [ "$chosen_decision" = "skip" ]; then
                _CHOICE_BUMP_OPT=false
                if [ -n "$scope_name" ]; then
                    echo "⏩ Skipping SemVer bump for scope '$scope_name'."
                else
                    echo "⏩ Skipping SemVer bump for this commit."
                fi
            elif [[ "$chosen_decision" == custom:* ]]; then
                _CHOICE_BUMP_OPT=true
                _aicommit_semver_plan "$cur_ver" "$chosen_decision" true
            else
                _CHOICE_BUMP_OPT=true
                _aicommit_semver_plan "$cur_ver" "$chosen_decision" true
            fi
            _CHOICE_RESP="y"
            ;;
    esac
}

# Finalize commit (execute commit, tag, changelog, and cleanup) for single commits.
# Args: $1=response, $2=commit_msg, $3=cur_ver, $4=next_ver, $5=evaluated_next,
#       $6=bump_opt, $7=tag_opt, $8=tag_name
_aicommit_finalize_commit() {
    local response="$1"
    local commit_msg="$2"
    local cur_ver="$3"
    local next_ver="$4"
    local evaluated_next="$5"
    local bump_opt="$6"
    local tag_opt="$7"
    local tag_name="$8"

    case "$response" in
        y|Y)
            local updated_files=""
            if [ "$bump_opt" = "true" ]; then
                updated_files=$(apply_semver_release "$cur_ver" "$next_ver" "$commit_msg" "$evaluated_next")
            fi
            if process_commit "$commit_msg"; then
                display_success
                if [ "$bump_opt" = "true" ]; then
                    local applied_tag=""
                    if [ "$tag_opt" = "true" ]; then
                        create_version_tag "$next_ver" "$commit_msg"
                        applied_tag="$tag_name"
                    fi
                    display_tag_success "$applied_tag" "$updated_files"
                else
                    display_semver_hint "$(suggest_semver_bump "$commit_msg")"
                fi
                cleanup_aicommit_all
                return 0
            else
                if [ "$bump_opt" = "true" ] && [ -n "$updated_files" ]; then
                    restore_semver_updates "$updated_files"
                fi
                cleanup_aicommit_all
                return 1
            fi
            ;;
        e|E)
            local updated_files=""
            if [ "$bump_opt" = "true" ]; then
                updated_files=$(apply_semver_release "$cur_ver" "$next_ver" "$commit_msg" "$evaluated_next")
            fi
            local edit_rc=0
            if aicommit_acquire_lock; then
                git commit -e -m "$commit_msg" || edit_rc=$?
                aicommit_release_lock
            else
                return 1
            fi
            if [ "$edit_rc" -eq 0 ]; then
                display_success
                local final_msg
                final_msg=$(git log -1 --pretty=%B)
                if [ "$bump_opt" = "true" ]; then
                    local applied_tag=""
                    if [ "$tag_opt" = "true" ]; then
                        create_version_tag "$next_ver" "$final_msg"
                        applied_tag="$tag_name"
                    fi
                    display_tag_success "$applied_tag" "$updated_files"
                else
                    display_semver_hint "$(suggest_semver_bump "$final_msg")"
                fi
                cleanup_aicommit_all
                return 0
            else
                if [ "$bump_opt" = "true" ] && [ -n "$updated_files" ]; then
                    restore_semver_updates "$updated_files"
                fi
                cleanup_aicommit_all
                return 1
            fi
            ;;
        *)
            echo "❌ Commit cancelled."
            return 0
            ;;
    esac
}

# Regenerate flow (--regenerate): replay LLM from cached request without rebuilding context.
_aicommit_regenerate_flow() {
    local tmp_dir="$1"
    local state_dir="$2"
    local verbose="$3"
    local bump_opt="$4"
    local bump_level="$5"
    local tag_opt="$6"
    local auto_yes="$7"

    if [ ! -f "${state_dir}/MSG_REQUEST" ]; then
        display_error "No cached prompt found in $state_dir" "Run aicommit first to build context"
        return 1
    fi
    if ! validate_prerequisites; then
        return 1
    fi
    echo "♻️  Regenerating from cached prompt..."
    [ "$verbose" = "true" ] && echo "📂 Request: ${state_dir}/MSG_REQUEST"

    local commit_msg
    if ! commit_msg=$(regenerate_commit_message) || [ -z "$commit_msg" ]; then
        return 1
    fi
    display_commit_message "$commit_msg"

    local cur_ver rec_summary=""
    cur_ver=$(get_last_version)
    if [ "$bump_opt" = "true" ]; then
        local evaluated_bump
        evaluated_bump=$(evaluate_commit_semver "$commit_msg" "$bump_level" "${tmp_dir}/RELEASE_HINT" "$tmp_dir")
        _aicommit_semver_plan "$cur_ver" "$evaluated_bump" true
    elif [ "$auto_yes" != "true" ]; then
        local rec_bump rec_next
        rec_bump=$(evaluate_commit_semver "$commit_msg" "" "${tmp_dir}/RELEASE_HINT" "$tmp_dir")
        rec_next=$(calculate_next_semver "$cur_ver" "$rec_bump")
        rec_summary="${rec_bump}: ${cur_ver} -> ${rec_next}"
    fi

    local response="y"
    if [ "$auto_yes" != "true" ]; then
        display_commit_confirmation "$bump_opt" "$rec_summary"
        if ! read -r response; then
            display_error "No input available to confirm the commit (stdin closed)" \
                "Re-run with --yes to accept generated messages automatically"
            return 1
        fi
        response=${response:-y}
    fi

    _aicommit_apply_choice "$response" "$commit_msg" "$cur_ver" "$bump_level" "${tmp_dir}/CHANGES_CONTEXT" "$bump_opt"
    response="$_CHOICE_RESP"
    bump_opt="$_CHOICE_BUMP_OPT"

    _aicommit_finalize_commit "$response" "$commit_msg" "$cur_ver" "${_SEMVER_NEXT_VER:-}" "${_SEMVER_EVAL_NEXT:-}" "$bump_opt" "$tag_opt" "${_SEMVER_TAG_NAME:-}"
}

# Single commit flow: standard all-in-one commit.
_aicommit_single_flow() {
    local tmp_dir="$1"
    local state_dir="$2"
    local changes="$3"
    local staged_files="$4"
    local numstat_data="$5"
    local dry_run="$6"
    local verbose="$7"
    local bump_opt="$8"
    local bump_level="$9"
    local tag_opt="${10}"
    local auto_yes="${11}"

    # Build context for the LLM prompt
    if ! build_ai_context "$changes" "$staged_files" "$numstat_data"; then
        return 1
    fi

    if [ "$verbose" = "true" ]; then
        display_setup_info
        echo "📂 Run dir:   ${tmp_dir}"
        echo "   CHANGES_CONTEXT: ${tmp_dir}/CHANGES_CONTEXT"
        echo "   FULL_PROMPT:     ${state_dir}/FULL_PROMPT"
    fi

    # --dry-run: assemble prompt and exit
    if [ "$dry_run" = "true" ]; then
        generate_commit_message --dry-run > /dev/null 2>&1 || true
        echo ""
        echo "🔍 Dry run — prompt written to: ${state_dir}/FULL_PROMPT"
        echo "   cat ${state_dir}/FULL_PROMPT"
        if [ "$bump_opt" = "true" ]; then
            echo ""
            local cur_ver evaluated_bump
            cur_ver=$(get_last_version)
            evaluated_bump=$(evaluate_commit_semver "feat: preview" "$bump_level")
            _aicommit_semver_plan "$cur_ver" "$evaluated_bump" true
        fi
        return 0
    fi

    # Generate and display
    local commit_msg
    if ! commit_msg=$(generate_commit_message) || [ -z "$commit_msg" ]; then
        return 1
    fi

    display_commit_message "$commit_msg"

    local cur_ver rec_summary=""
    cur_ver=$(get_last_version)
    if [ "$bump_opt" = "true" ]; then
        local evaluated_bump
        evaluated_bump=$(evaluate_commit_semver "$commit_msg" "$bump_level" "${tmp_dir}/RELEASE_HINT" "$tmp_dir")
        _aicommit_semver_plan "$cur_ver" "$evaluated_bump" true
    elif [ "$auto_yes" != "true" ]; then
        local rec_bump rec_next
        rec_bump=$(evaluate_commit_semver "$commit_msg" "" "${tmp_dir}/RELEASE_HINT" "$tmp_dir")
        rec_next=$(calculate_next_semver "$cur_ver" "$rec_bump")
        rec_summary="${rec_bump}: ${cur_ver} -> ${rec_next}"
    fi

    local response="y"
    if [ "$auto_yes" != "true" ]; then
        display_commit_confirmation "$bump_opt" "$rec_summary"
        if ! read -r response; then
            display_error "No input available to confirm the commit (stdin closed)" \
                "Re-run with --yes to accept generated messages automatically"
            return 1
        fi
        response=${response:-y}
    fi

    _aicommit_apply_choice "$response" "$commit_msg" "$cur_ver" "$bump_level" "${tmp_dir}/CHANGES_CONTEXT" "$bump_opt"
    response="$_CHOICE_RESP"
    bump_opt="$_CHOICE_BUMP_OPT"

    _aicommit_finalize_commit "$response" "$commit_msg" "$cur_ver" "${_SEMVER_NEXT_VER:-}" "${_SEMVER_EVAL_NEXT:-}" "$bump_opt" "$tag_opt" "${_SEMVER_TAG_NAME:-}"
}
