#!/usr/bin/env bats
# Smoke Tests — basic sanity checks in ideal conditions.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── Loading ─────────────────────────────────────────────────────────────────

@test "aicommit.sh sources without error" {
    # setup already sourced it; verify all 9 command entry-points exist as functions
    declare -f aicommit > /dev/null
    declare -f aic      > /dev/null
    declare -f aicc     > /dev/null
    declare -f aicx     > /dev/null
    declare -f aiccx    > /dev/null
    declare -f aics     > /dev/null
    declare -f aiccs    > /dev/null
    declare -f aicsx    > /dev/null
    declare -f aiccsx   > /dev/null
}

@test "all library functions are available after source" {
    # core.sh
    declare -f validate_prerequisites     > /dev/null
    declare -f get_aicommit_base_dir      > /dev/null
    declare -f get_aicommit_tmp_dir       > /dev/null
    declare -f get_aicommit_state_dir     > /dev/null
    declare -f init_aicommit_run          > /dev/null
    declare -f aicommit_purge_dead_runs   > /dev/null
    declare -f aicommit_cleanup_run_dir   > /dev/null
    declare -f aicommit_acquire_lock      > /dev/null
    declare -f aicommit_release_lock      > /dev/null
    declare -f aicommit_clean_cache       > /dev/null
    declare -f agit                       > /dev/null
    declare -f to_pathspec                > /dev/null
    declare -f staged_fingerprint         > /dev/null
    declare -f _aicommit_split_tab_line   > /dev/null
    declare -f count_lines                > /dev/null
    declare -f build_file_context         > /dev/null
    declare -f filter_and_truncate_diff   > /dev/null
    declare -f build_facts                > /dev/null
    declare -f infer_allowed_types        > /dev/null
    declare -f collect_scope_candidates   > /dev/null
    declare -f build_ai_context           > /dev/null
    declare -f extract_conventional_commit > /dev/null
    declare -f suggest_semver_bump        > /dev/null
    declare -f validate_commit_grounding  > /dev/null
    declare -f template_commit_from_facts > /dev/null
    declare -f generate_commit_message    > /dev/null
    declare -f regenerate_commit_message  > /dev/null
    declare -f generate_group_messages    > /dev/null
    declare -f process_commit             > /dev/null
    declare -f commit_staged_subset       > /dev/null
    declare -f cleanup_aicommit_ephemeral > /dev/null
    declare -f cleanup_aicommit_all       > /dev/null

    # backends.sh
    declare -f validate_backend_prerequisites > /dev/null
    declare -f invoke_llm                 > /dev/null
    declare -f build_ollama_request       > /dev/null
    declare -f get_available_ollama_models > /dev/null
    declare -f validate_ollama_prerequisites > /dev/null
    declare -f invoke_ollama              > /dev/null

    # context-analyzer.sh
    declare -f is_sensitive_path          > /dev/null
    declare -f categorize_staged_files    > /dev/null
    declare -f infer_file_scope           > /dev/null
    declare -f infer_logical_file_context > /dev/null
    declare -f cluster_staged_files_deterministic > /dev/null
    declare -f build_cochange_cache       > /dev/null
    declare -f group_staged_files_heuristically > /dev/null
    declare -f name_groups_with_ai        > /dev/null
    declare -f reconcile_grouping_json    > /dev/null
    declare -f group_staged_files_logically > /dev/null
    declare -f group_staged_files_by_scope > /dev/null
    declare -f count_staged_scopes        > /dev/null

    # output-formatter.sh
    declare -f display_staged_files       > /dev/null
    declare -f display_setup_info         > /dev/null
    declare -f display_commit_message     > /dev/null
    declare -f display_split_confirmation > /dev/null
    declare -f display_split_progress     > /dev/null
    declare -f display_error              > /dev/null
    declare -f display_success            > /dev/null
    declare -f display_semver_hint        > /dev/null
    declare -f display_scope_success      > /dev/null
    declare -f display_commit_confirmation > /dev/null
    declare -f display_semver_plan        > /dev/null
    declare -f display_tag_success        > /dev/null

    # semver.sh
    declare -f semver_gt                  > /dev/null
    declare -f get_version_from_git_head  > /dev/null
    declare -f get_last_version           > /dev/null
    declare -f get_current_version        > /dev/null
    declare -f calculate_next_semver      > /dev/null
    declare -f detect_version_files       > /dev/null
    declare -f update_version_in_file     > /dev/null
    declare -f apply_semver_file_updates  > /dev/null
    declare -f create_version_tag         > /dev/null
    declare -f extract_semver_decision    > /dev/null
    declare -f ai_evaluate_semver         > /dev/null
    declare -f evaluate_commit_semver     > /dev/null
    declare -f prompt_semver_decision     > /dev/null
    declare -f detect_changelog_file      > /dev/null
    declare -f update_changelog           > /dev/null
    declare -f restore_semver_updates     > /dev/null
    declare -f resolve_effective_semver   > /dev/null
    declare -f apply_semver_release       > /dev/null

    # aicommit.sh helper
    declare -f _aicommit_has_split_flag   > /dev/null
}

@test "all 9 bin command wrappers exist and are executable in AICOMMIT_DIR/bin" {
    local commands=("aicommit" "aic" "aicc" "aicx" "aiccx" "aics" "aiccs" "aicsx" "aiccsx")
    for cmd in "${commands[@]}"; do
        local bin_path="$AICOMMIT_DIR/bin/$cmd"
        [ -f "$bin_path" ]
        [ -s "$bin_path" ]
        [ -x "$bin_path" ]
    done
}

# ─── Configuration ───────────────────────────────────────────────────────────

@test "default AI_BACKEND is ollama" {
    [ "$AI_BACKEND" = "ollama" ]
}

@test "default AI_MODEL is the configured default" {
    [ "$AI_MODEL" = "$(get_default_ai_model)" ]
}

@test "default AI_TIMEOUT is 120" {
    [ "$AI_TIMEOUT" = "120" ]
}

@test "AI_PROMPT_FILE points to an existing file" {
    [ -f "$AI_PROMPT_FILE" ]
}

@test "AICOMMIT_DIR is set and exists" {
    [ -n "$AICOMMIT_DIR" ]
    [ -d "$AICOMMIT_DIR" ]
}

@test "prompt template defines the JSON output contract" {
    grep -qF 'OUTPUT CONTRACT' "$AI_PROMPT_FILE"
    grep -qF '"type"' "$AI_PROMPT_FILE"
}

@test "prompt template enforces grounding and subject length" {
    grep -qi 'GROUNDING' "$AI_PROMPT_FILE"
    grep -q "60" "$AI_PROMPT_FILE"
}

# ─── Help ────────────────────────────────────────────────────────────────────

@test "aicommit --help exits 0" {
    run aicommit --help
    [ "$status" -eq 0 ]
}

@test "aicommit --help shows usage line" {
    run aicommit --help
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "aicommit --help documents --dry-run flag" {
    run aicommit --help
    assert_output_contains "--dry-run"
}

@test "aicommit --help documents --verbose flag" {
    run aicommit --help
    assert_output_contains "--verbose"
}

@test "aicommit -h is an alias for --help" {
    run aicommit -h
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

# ─── Temp directory ──────────────────────────────────────────────────────────

@test "get_aicommit_tmp_dir creates the directory" {
    local d
    d=$(get_aicommit_tmp_dir)
    [ -d "$d" ]
}

@test "get_aicommit_tmp_dir returns a path under .git/aicommit/runs" {
    local d
    d=$(get_aicommit_tmp_dir)
    [[ "$d" == "$(git rev-parse --absolute-git-dir)/aicommit/runs/"* ]]
}

@test "get_available_ollama_models returns model list" {
    local default_model
    default_model=$(get_default_ai_model)
    export MOCK_OLLAMA_MODEL="$default_model"
    mock_ollama_api
    run get_available_ollama_models
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$default_model" ]
}

@test "validate_ollama_prerequisites succeeds against a healthy API" {
    mock_ollama_api
    export AI_MODEL="test-model"
    run validate_ollama_prerequisites "test-model"
    [ "$status" -eq 0 ]
}


