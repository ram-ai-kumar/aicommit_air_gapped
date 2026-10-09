#!/usr/bin/env bats
# Exception Tests — error handling and graceful failure.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── aicommit entry-point errors ─────────────────────────────────────────────

@test "aicommit exits 1 on no staged changes" {
    run aicommit --dry-run
    [ "$status" -eq 1 ]
}

@test "aicommit exits 1 on unknown flag" {
    run aicommit --this-flag-does-not-exist
    [ "$status" -eq 1 ]
}

@test "aicommit --regenerate exits 1 when no cached prompt exists" {
    local s
    s=$(get_aicommit_state_dir)
    rm -f "${s}/MSG_REQUEST"
    run aicommit --regenerate
    [ "$status" -eq 1 ]
    assert_output_contains "No cached prompt"
}

# ─── aic entry-point errors ───────────────────────────────────────────────────

@test "aic exits 1 on no staged changes" {
    run aic
    [ "$status" -eq 1 ]
}

# ─── generate_commit_message errors ──────────────────────────────────────────

@test "generate_commit_message returns 1 when CHANGES_CONTEXT is absent" {
    local d
    d=$(get_aicommit_tmp_dir)
    rm -f "${d}/CHANGES_CONTEXT"
    run generate_commit_message --dry-run
    [ "$status" -eq 1 ]
    assert_output_contains "Context files not found"
}

@test "generate_commit_message returns 1 when CHANGES_CONTEXT is empty" {
    local d
    d=$(get_aicommit_tmp_dir)
    : > "${d}/CHANGES_CONTEXT"
    run generate_commit_message --dry-run
    [ "$status" -eq 1 ]
}

# ─── build_ai_context errors ─────────────────────────────────────────────────

@test "build_ai_context returns 1 for empty staged files" {
    run build_ai_context "" "" ""
    [ "$status" -eq 1 ]
}

@test "build_ai_context shows No staged files error message" {
    run build_ai_context "" "" ""
    assert_output_contains "No staged files"
}

# ─── backend errors ───────────────────────────────────────────────────────────

@test "invoke_ollama returns 1 when the API is unreachable" {
    mock_bin "curl" "exit 1"
    local rf="$TEST_TEMP_DIR/response.txt"
    local ef="$TEST_TEMP_DIR/error.txt"
    echo '{"model":"model","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    run invoke_ollama "model" "$TEST_TEMP_DIR/request.json" "$rf" "$ef" "5"
    [ "$status" -eq 1 ]
}

@test "invoke_ollama shows generation failed message on error" {
    mock_bin "curl" "exit 2"
    local rf="$TEST_TEMP_DIR/response.txt"
    local ef="$TEST_TEMP_DIR/error.txt"
    echo '{"model":"model","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    run invoke_ollama "model" "$TEST_TEMP_DIR/request.json" "$rf" "$ef" "5"
    assert_output_contains "generation failed"
}

@test "validate_ollama_prerequisites returns 1 when the API is down" {
    mock_bin "curl" "exit 1"
    run validate_ollama_prerequisites "$(get_default_ai_model)"
    [ "$status" -eq 1 ]
}

@test "invoke_ollama handles memory-related errors" {
    mock_bin "curl" "echo 'Error: out of memory' >&2
exit 1"
    echo '{"model":"memory-hog-model","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    local response_file="$TEST_TEMP_DIR/response.txt"
    local error_file="$TEST_TEMP_DIR/error.txt"

    run invoke_ollama "memory-hog-model" "$TEST_TEMP_DIR/request.json" "$response_file" "$error_file" 30
    [ "$status" -eq 1 ]
    assert_output_contains "insufficient memory"
}

@test "invoke_ollama respects configured AI_MODEL" {
    export AI_MODEL="configured-model"
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; data=""
while [ $# -gt 0 ]; do
    case "$1" in
        */api/*) url="$1" ;;
        --data-binary) shift; data="${1#@}" ;;
    esac
    shift
done
case "$url" in
    */api/chat)
        if grep -q 'configured-model' "$data"; then
            printf '{"message":{"role":"assistant","content":"Generated commit message"}}'
        else
            exit 1
        fi
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    echo '{"model":"configured-model","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    local response_file="$TEST_TEMP_DIR/response.txt"
    local error_file="$TEST_TEMP_DIR/error.txt"

    run invoke_ollama "original-model" "$TEST_TEMP_DIR/request.json" "$response_file" "$error_file" 30
    [ "$status" -eq 0 ]
    unset AI_MODEL
}

# ─── Conventional Commits contract ───────────────────────────────────────────

@test "malformed or truncated JSON response falls back without crashing and satisfies contract" {
    echo "test" > app.sh
    git add app.sh
    export AI_MODEL="test-model"
    # Mock returns truncated JSON
    mock_ollama_api '{"type":"feat","scope":"none","breaking":false,"subject":'
    run aic
    [ "$status" -eq 0 ]
    local recorded
    recorded=$(git log -1 --format="%B")
    assert_conventional_commit_contract "$recorded"
}

@test "batched response with fewer commits than groups invokes sequential filler and satisfies contract" {
    mkdir -p lib tests
    echo "core code" > lib/core.sh
    echo "test code" > tests/test.sh
    git add lib/core.sh tests/test.sh
    export AI_MODEL="test-model"
    # Batch response only returns 1 commit for 2 groups; sequential filler then provides commits
    mock_ollama_api '{"commits":[{"type":"feat","scope":"core","breaking":false,"subject":"update core library"}]}'
    run aicc
    [ "$status" -eq 0 ]
    local msg1 msg2
    msg1=$(git log -1 --skip=0 --format="%B")
    msg2=$(git log -1 --skip=1 --format="%B")
    assert_conventional_commit_contract "$msg1"
    assert_conventional_commit_contract "$msg2"
}

@test "perl missing from PATH still yields message satisfying contract from extraction" {
    mock_bin "perl" "exit 127"
    local raw="feat(core): implement feature without perl

- add feature implementation details"
    local res
    res=$(extract_conventional_commit "$raw")
    assert_conventional_commit_contract "$res"
}
