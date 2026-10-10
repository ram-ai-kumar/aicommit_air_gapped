#!/usr/bin/env bash
# aicommit — Split Commit Flow
# Handles atomic split commit preview, generation, confirmation, and committing per group.

[ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent

_aicommit_split_flow() {
    local tmp_dir="$1"
    local state_dir="$2"
    local changes="$3"
    local staged_files="$4"
    local numstat_data="$5"
    local scope_groups="$6"
    local dry_run="$7"
    local verbose="$8"
    local bump_opt="$9"
    local bump_level="${10}"
    local tag_opt="${11}"
    local auto_yes="${12}"

    local groups_source="regrouped"
    local num_scopes=0 scope_names=""

    if [ -z "$scope_groups" ]; then
        # Reuse the grouping decision from a preceding `aiccx`/`--dry-run --split`
        # when the staged set is unchanged.
        local fp_now
        fp_now=$(staged_fingerprint)
        if [ -f "${state_dir}/SCOPE_GROUPS" ] && [ -f "${state_dir}/STAGED_FINGERPRINT" ] \
           && [ "$(cat "${state_dir}/STAGED_FINGERPRINT" 2>/dev/null)" = "$fp_now" ]; then
            scope_groups=$(cat "${state_dir}/SCOPE_GROUPS")
            num_scopes=$(printf '%s\n' "$scope_groups" | count_lines)
            scope_names=$(printf '%s\n' "$scope_groups" | awk -F'\t' '{printf (NR>1?", ":"") $1} END{print ""}')
            groups_source="reused"
        else
            [ -f "${state_dir}/SCOPE_GROUPS" ] && echo "⚠️  Staged set changed since preview — regrouping"
            scope_groups=$(group_staged_files_by_scope "$staged_files" "$changes" "$numstat_data")
            scope_groups=$(printf '%s\n' "$scope_groups" | awk -F'\t' 'NF>=2 && $1!="" && $2!="" && $1 !~ /=/ && $1 !~ /^(joined_files|staged_files|files)/ {print $0}')
            num_scopes=$(printf '%s\n' "$scope_groups" | count_lines)
            scope_names=$(printf '%s\n' "$scope_groups" | awk -F'\t' '{printf (NR>1?", ":"") $1} END{print ""}')
        fi
    else
        num_scopes=$(printf '%s\n' "$scope_groups" | count_lines)
        scope_names=$(printf '%s\n' "$scope_groups" | awk -F'\t' '{printf (NR>1?", ":"") $1} END{print ""}')
    fi

    if [ "$dry_run" != "true" ] && ! validate_prerequisites; then
        return 1
    fi

    if [ "$dry_run" = "true" ]; then
        umask 077
        printf '%s\n' "$scope_groups" > "${state_dir}/SCOPE_GROUPS"
        staged_fingerprint > "${state_dir}/STAGED_FINGERPRINT"

        echo "🔍 Dry run — detected $num_scopes atomic commit groups:"
        display_resolved_atomic_groups "$scope_groups"
        if [ "$bump_opt" = "true" ]; then
            echo ""
            local s_cur_ver s_eval_bump
            s_cur_ver=$(get_last_version)
            s_eval_bump=$(evaluate_commit_semver "feat: preview" "$bump_level")
            _aicommit_semver_plan "$s_cur_ver" "$s_eval_bump" true
        fi
        return 0
    fi

    if [ "$groups_source" = "reused" ]; then
        echo "♻️  Reusing $num_scopes group(s) from last preview:"
    else
        echo "📋 Resolved $num_scopes atomic commit group(s):"
    fi
    display_resolved_atomic_groups "$scope_groups"

    if ! generate_group_messages "$scope_groups" "$tmp_dir"; then
        return 1
    fi

    local idx=1 committed_count=0 group_line=""
    local grp_scope="" subset_changes="" grp_commit_msg="" grp_resp="y"
    local -a grp_file_array=()

    while IFS= read -r -u 3 group_line; do
        _aicommit_split_tab_line "$group_line"
        [ -z "$_aicommit_split_scope" ] && continue
        grp_scope="$_aicommit_split_scope"
        grp_file_array=("${_aicommit_split_files[@]}")
        [ ${#grp_file_array[@]} -eq 0 ] && continue

        grp_commit_msg="${_AICOMMIT_GRP_MSGS[$idx]:-}"
        if [ -z "$grp_commit_msg" ]; then
            display_error "Failed to generate commit message for scope: $grp_scope"
            return 1
        fi
        subset_changes=$(cat "${tmp_dir}/groups/${idx}/DIFF" 2>/dev/null)

        display_split_progress "$idx" "$num_scopes" "$grp_scope"
        display_commit_message "$grp_commit_msg" "Suggested Commit ($idx/$num_scopes - scope: $grp_scope):"

        local grp_cur_ver grp_rec_summary=""
        grp_cur_ver=$(get_last_version)
        if [ "$bump_opt" = "true" ]; then
            local grp_eval_bump
            grp_eval_bump=$(evaluate_commit_semver "$grp_commit_msg" "$bump_level" "${tmp_dir}/groups/${g}/RELEASE_HINT" "${tmp_dir}/groups/${g}")
            _aicommit_semver_plan "$grp_cur_ver" "$grp_eval_bump" true
        elif [ "$auto_yes" != "true" ]; then
            local grp_rec_bump grp_rec_next
            grp_rec_bump=$(evaluate_commit_semver "$grp_commit_msg" "" "${tmp_dir}/groups/${g}/RELEASE_HINT" "${tmp_dir}/groups/${g}")
            grp_rec_next=$(calculate_next_semver "$grp_cur_ver" "$grp_rec_bump")
            grp_rec_summary="${grp_rec_bump}: ${grp_cur_ver} -> ${grp_rec_next}"
        fi

        grp_resp="y"
        if [ "$auto_yes" != "true" ]; then
            display_commit_confirmation "$bump_opt" "$grp_rec_summary"
            if ! read -r grp_resp; then
                display_error "No input available to confirm scope '$grp_scope' (stdin closed)" \
                    "Re-run with --yes to accept generated messages automatically"
                return 1
            fi
            grp_resp=${grp_resp:-y}
        fi

        _aicommit_apply_choice "$grp_resp" "$grp_commit_msg" "$grp_cur_ver" "$bump_level" "$subset_changes" "$bump_opt" "$grp_scope"
        grp_resp="$_CHOICE_RESP"
        local grp_bump_active="$_CHOICE_BUMP_OPT"

        case "$grp_resp" in
            y|Y)
                local grp_updated_files=""
                if [ "$grp_bump_active" = "true" ]; then
                    grp_updated_files=$(apply_semver_release "$grp_cur_ver" "$_SEMVER_NEXT_VER" "$grp_commit_msg" "$_SEMVER_EVAL_NEXT")
                    if [ -n "$grp_updated_files" ]; then
                        while IFS= read -r uf; do
                            [ -n "$uf" ] && grp_file_array+=("$uf")
                        done <<< "$grp_updated_files"
                    fi
                fi
                if commit_staged_subset "$grp_commit_msg" "${grp_file_array[@]}"; then
                    display_scope_success "$grp_scope"
                    if [ "$grp_bump_active" = "true" ]; then
                        local applied_tag=""
                        if [ "$tag_opt" = "true" ]; then
                            create_version_tag "$_SEMVER_NEXT_VER" "$grp_commit_msg"
                            applied_tag="$_SEMVER_TAG_NAME"
                        fi
                        display_tag_success "$applied_tag" "$grp_updated_files"
                    else
                        display_semver_hint "$(suggest_semver_bump "$grp_commit_msg")"
                    fi
                    committed_count=$((committed_count + 1))
                else
                    if [ "$grp_bump_active" = "true" ] && [ -n "$grp_updated_files" ]; then
                        restore_semver_updates "$grp_updated_files"
                    fi
                    display_error "Commit failed for scope: $grp_scope"
                    return 1
                fi
                ;;
            e|E)
                if [ ! -t 0 ]; then
                    display_error "Editing the commit message requires an interactive terminal" "stdin is not a TTY"
                    return 1
                fi
                local edit_file="${tmp_dir}/COMMIT_EDITMSG"
                printf '%s\n' "$grp_commit_msg" > "$edit_file"
                ${EDITOR:-vi} "$edit_file"
                local edited_msg
                edited_msg=$(cat "$edit_file" 2>/dev/null || true)
                rm -f "$edit_file"
                if [ -n "$edited_msg" ]; then
                    local grp_updated_files=""
                    if [ "$bump_opt" = "true" ]; then
                        local e_eval_bump
                        e_eval_bump=$(evaluate_commit_semver "$edited_msg" "$bump_level" "${tmp_dir}/groups/${g}/RELEASE_HINT" "${tmp_dir}/groups/${g}")
                        _aicommit_semver_plan "$grp_cur_ver" "$e_eval_bump" false
                        grp_updated_files=$(apply_semver_release "$grp_cur_ver" "$_SEMVER_NEXT_VER" "$edited_msg" "$_SEMVER_EVAL_NEXT")
                        if [ -n "$grp_updated_files" ]; then
                            while IFS= read -r uf; do
                                [ -n "$uf" ] && grp_file_array+=("$uf")
                            done <<< "$grp_updated_files"
                        fi
                    fi
                    if commit_staged_subset "$edited_msg" "${grp_file_array[@]}"; then
                        display_scope_success "$grp_scope"
                        if [ "$bump_opt" = "true" ]; then
                            local applied_tag=""
                            if [ "$tag_opt" = "true" ]; then
                                create_version_tag "$_SEMVER_NEXT_VER" "$edited_msg"
                                applied_tag="$_SEMVER_TAG_NAME"
                            fi
                            display_tag_success "$applied_tag" "$grp_updated_files"
                        else
                            display_semver_hint "$(suggest_semver_bump "$edited_msg")"
                        fi
                        committed_count=$((committed_count + 1))
                    else
                        if [ "$bump_opt" = "true" ] && [ -n "$grp_updated_files" ]; then
                            restore_semver_updates "$grp_updated_files"
                        fi
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
}
