#!/usr/bin/env bats
# Negative Tests — failure paths and rejection of invalid input.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── aicommit entry point ────────────────────────────────────────────────────

@test "aicommit --dry-run fails with no staged changes" {
    run aicommit --dry-run
    [ "$status" -eq 1 ]
    assert_output_contains "No staged changes"
}

@test "aicommit fails with an unknown option" {
    run aicommit --not-a-real-flag
    [ "$status" -eq 1 ]
}

@test "aicommit unknown option shows helpful message" {
    run aicommit --not-a-real-flag
    assert_output_contains "Unknown option"
}

# ─── aic entry point ─────────────────────────────────────────────────────────

@test "aic fails with no staged changes" {
    run aic
    [ "$status" -eq 1 ]
    assert_output_contains "No staged changes"
}

# ─── validate_backend_prerequisites ──────────────────────────────────────────

@test "validate_backend_prerequisites rejects unknown backend" {
    export AI_BACKEND="totally_bogus"
    run validate_backend_prerequisites
    [ "$status" -eq 1 ]
}

# ─── generate_commit_message ─────────────────────────────────────────────────

@test "generate_commit_message --dry-run fails when CHANGES_CONTEXT is missing" {
    local d
    d=$(get_aicommit_tmp_dir)
    rm -f "${d}/CHANGES_CONTEXT"
    run generate_commit_message --dry-run
    [ "$status" -eq 1 ]
}

@test "generate_commit_message --dry-run fails when CHANGES_CONTEXT is empty" {
    local d
    d=$(get_aicommit_tmp_dir)
    : > "${d}/CHANGES_CONTEXT"   # create but empty
    run generate_commit_message --dry-run
    [ "$status" -eq 1 ]
}

# ─── build_ai_context ────────────────────────────────────────────────────────

@test "build_ai_context returns 1 when staged_files is empty" {
    run build_ai_context "" "" ""
    [ "$status" -eq 1 ]
}

@test "build_ai_context shows No staged files error" {
    run build_ai_context "" "" ""
    assert_output_contains "No staged files"
}

# ─── validate_ollama_prerequisites ───────────────────────────────────────────

@test "validate_ollama_prerequisites fails when the API is down" {
    mock_bin "curl" "exit 1"
    run validate_ollama_prerequisites "$(get_default_ai_model)"
    [ "$status" -eq 1 ]
    assert_output_contains "not running"
}

@test "validate_ollama_prerequisites fails when the model metadata cannot load" {
    mock_ollama_api
    cat > "$TEST_TEMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in */api/*) url="$a" ;; esac; done
case "$url" in
    */api/version)  echo '{"version":"0.40.1"}' ;;
    */api/tags)     echo '{"models":[{"name":"test-model"}]}' ;;
    */api/show)     exit 1 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    run validate_ollama_prerequisites "test-model"
    [ "$status" -eq 1 ]
}

@test "validate_ollama_prerequisites fails when model not found" {
    mock_ollama_api
    export MOCK_OLLAMA_MODEL="other-model:latest"
    run validate_ollama_prerequisites "missing-model"
    [ "$status" -eq 1 ]
    assert_output_contains "Model 'missing-model' not found"
}
