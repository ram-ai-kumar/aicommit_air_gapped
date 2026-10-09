#!/usr/bin/env bats
# Edge Tests — boundary conditions and extreme inputs.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── filter_and_truncate_diff ────────────────────────────────────────────────

@test "filter_and_truncate_diff handles completely empty input" {
    local result
    result=$(printf '' | filter_and_truncate_diff)
    [ -z "$result" ]
}

@test "filter_and_truncate_diff excludes .lock file content" {
    local result
    result=$(printf 'diff --git a/package-lock.json b/package-lock.json\n+"lockfileVersion":3\n' \
             | filter_and_truncate_diff)
    ! echo "$result" | grep -qF "lockfileVersion"
}

@test "filter_and_truncate_diff excludes .png diffs" {
    local result
    result=$(printf 'diff --git a/logo.png b/logo.png\nBinary files differ\n' \
             | filter_and_truncate_diff)
    ! echo "$result" | grep -qF "Binary files differ"
}

@test "filter_and_truncate_diff excludes dist/ directory diffs" {
    local result
    result=$(printf 'diff --git a/dist/bundle.js b/dist/bundle.js\n+minifiedContent\n' \
             | filter_and_truncate_diff)
    ! echo "$result" | grep -qF "minifiedContent"
}

@test "filter_and_truncate_diff truncates long markdown diffs at 20 lines" {
    local input
    input="diff --git a/README.md b/README.md"$'\n'
    for i in $(seq 1 40); do
        input="${input}+readme line ${i}"$'\n'
    done
    local count
    count=$(printf '%s' "$input" | filter_and_truncate_diff | grep -c "^+readme" || true)
    [ "$count" -le 20 ]
}

@test "filter_and_truncate_diff truncates long source diffs at 80 lines" {
    local input
    input="diff --git a/main.sh b/main.sh"$'\n'
    for i in $(seq 1 120); do
        input="${input}+src_line_${i}=true"$'\n'
    done
    local count
    count=$(printf '%s' "$input" | filter_and_truncate_diff | grep -c "^+src_line_" || true)
    [ "$count" -le 80 ]
}

@test "filter_and_truncate_diff adds truncation notice for capped files" {
    local input
    input="diff --git a/main.sh b/main.sh"$'\n'
    for i in $(seq 1 100); do
        input="${input}+line ${i}"$'\n'
    done
    local result
    result=$(printf '%s' "$input" | filter_and_truncate_diff)
    echo "$result" | grep -q "truncated"
}

# ─── build_file_context ──────────────────────────────────────────────────────

@test "build_file_context handles files with spaces in name" {
    echo "test" > "file with spaces.txt"
    git add "file with spaces.txt"
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)
    build_file_context "$staged" "$numstat"
    local d
    d=$(get_aicommit_tmp_dir)
    [ -f "${d}/FILE_CONTEXT" ]
}

@test "build_file_context silently skips only sensitive files, counts them" {
    echo "SECRET=abc" > .env
    echo "normal" > app.js
    git add .env app.js
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)
    build_file_context "$staged" "$numstat"
    local d count
    d=$(get_aicommit_tmp_dir)
    count=$(cat "${d}/FILE_COUNT")
    # Both files counted, sensitive one just skipped from CHANGE_STATS
    [ "$count" = "2" ]
}

# ─── get_aicommit_tmp_dir ────────────────────────────────────────────────────

@test "get_aicommit_tmp_dir path contains no path traversal sequences" {
    local d
    d=$(get_aicommit_tmp_dir)
    [[ "$d" != *".."* ]]
}

# ─── categorize_staged_files ─────────────────────────────────────────────────

@test "categorize_staged_files handles asset files" {
    local files
    files="$(printf 'assets/logo.png\nassets/banner.jpg')"
    run categorize_staged_files "$files" "$TEST_TEMP_DIR"
    assert_output_contains "Static Assets"
}

@test "categorize_staged_files writes ASSET_FILES when tmp_dir given" {
    local files
    files="assets/logo.png"
    categorize_staged_files "$files" "$TEST_TEMP_DIR" > /dev/null
    [ -f "${TEST_TEMP_DIR}/ASSET_FILES" ]
}

@test "invoke_ollama handles an API request timeout" {
    mock_bin "curl" "exit 28"
    echo '{"model":"m","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    run invoke_ollama "slow-model" "$TEST_TEMP_DIR/request.json" \
        "$TEST_TEMP_DIR/r.txt" "$TEST_TEMP_DIR/e.txt" "5"
    [ "$status" -eq 1 ]
}

@test "get_available_ollama_models handles malformed output" {
    mock_bin "curl" "echo 'not json'"
    mock_bin "ollama" "echo 'invalid output without proper structure'"
    run get_available_ollama_models
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
