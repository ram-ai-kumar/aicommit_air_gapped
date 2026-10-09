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

# ─── Conventional Commits contract ───────────────────────────────────────────

@test "header exactly 72 chars is unchanged and 73 chars splits" {
    local header72="feat: $(printf 'a%.0s' {1..66})"
    local res72
    res72=$(enforce_conventional_commit "$header72")
    [ "$res72" = "$header72" ]
    assert_conventional_commit_contract "$res72"

    local header73="feat: $(printf 'a%.0s' {1..60}) extra words"
    local res73
    res73=$(enforce_conventional_commit "$header73")
    local line1
    line1=$(printf '%s\n' "$res73" | head -n 1)
    [ "${#line1}" -le 72 ]
    assert_conventional_commit_contract "$res73"
}

@test "subject with no boundary cuts at word boundary and keeps overflow in body" {
    local input="feat(core): implement robust semantic versioning engine and comprehensive version comparison logic across multiple languages"
    local res
    res=$(enforce_conventional_commit "$input")
    local first_line
    first_line=$(printf '%s\n' "$res" | head -n 1)
    [ "${#first_line}" -le 72 ]
    printf '%s\n' "$res" | grep -qF "comparison logic"
    assert_conventional_commit_contract "$res"
}

@test "subject of a single long token hard cuts within 72" {
    local input="feat: $(printf 'x%.0s' {1..80})"
    local res
    res=$(enforce_conventional_commit "$input")
    local first_line
    first_line=$(printf '%s\n' "$res" | head -n 1)
    [ "${#first_line}" -le 72 ]
    assert_conventional_commit_contract "$res"
}

@test "empty body array yields single-line message with no trailing blank line" {
    local json='{"type":"chore","scope":"none","breaking":false,"subject":"update config","body":[]}'
    local res
    res=$(_commit_msg_from_json_obj "$json")
    local line_count
    line_count=$(printf '%s\n' "$res" | wc -l | tr -d ' ')
    [ "$line_count" -eq 1 ]
    assert_conventional_commit_contract "$res"
}

@test "breaking true with no breaking_change emits bang and footer using description" {
    local json='{"type":"feat","scope":"api","breaking":true,"subject":"remove old endpoint","body":[]}'
    local res
    res=$(_commit_msg_from_json_obj "$json")
    printf '%s\n' "$res" | grep -qF "feat(api)!: remove old endpoint"
    printf '%s\n' "$res" | grep -qF "BREAKING CHANGE: remove old endpoint"
    assert_conventional_commit_contract "$res"
}

@test "footer-only message separates header and footer by exactly one blank line" {
    local input=$'fix: resolve issue\n\nRefs: #12'
    local res
    res=$(enforce_conventional_commit "$input")
    assert_conventional_commit_contract "$res"
    local total_lines
    total_lines=$(printf '%s\n' "$res" | wc -l | tr -d ' ')
    [ "$total_lines" -eq 3 ]
    local line2
    line2=$(printf '%s\n' "$res" | sed -n '2p')
    [ -z "$line2" ]
}

@test "extract_conventional_commit preserves footer without blank line rather than joining into header" {
    local input=$'fix: resolve issue\nRefs: #12'
    local res
    res=$(extract_conventional_commit "$input")
    local header
    header=$(printf '%s\n' "$res" | head -n 1)
    [ "$header" = "fix: resolve issue" ]
    printf '%s\n' "$res" | grep -qF "Refs: #12"
    assert_conventional_commit_contract "$res"
}

@test "multi-paragraph body plus bullets plus footers preserves order with single blank separators" {
    local input=$'feat: add feature\n\nFirst paragraph of explanation.\n\nSecond paragraph of explanation.\n\n- bullet 1\n- bullet 2\n\nSigned-off-by: Dev <dev@example.com>\nRefs: #42'
    local res
    res=$(enforce_conventional_commit "$input")
    assert_conventional_commit_contract "$res"
    printf '%s\n' "$res" | grep -qF "First paragraph"
    printf '%s\n' "$res" | grep -qF "Second paragraph"
    printf '%s\n' "$res" | grep -qF -- "- bullet 1"
    printf '%s\n' "$res" | grep -qF "Signed-off-by:"
    printf '%s\n' "$res" | grep -qF "Refs: #42"
}

@test "extract_conventional_commit repairs word-wrap stutter fragments and keeps header within 72" {
    local input="feat(aicommit): implement logical context grouping and multi-commit
split c

confirmation

- introduce AI-driven context analyzer to group staged files by
  feature/fun
feature/functionality instead of directory structure
- add user prompt template for intelligent file clustering into atomic
  comm
commit contexts
- update split confirmation UI to display grouped file previews with
  dynami
dynamic width alignment
- add unit and integration tests for context grouping logic, output
  formatt
formatting, and abort handling
- disable live AI grouping in test environment to ensure deterministic
  unit
unit test behavior"

    local result
    result=$(extract_conventional_commit "$input")
    local header
    header=$(printf '%s\n' "$result" | head -n 1)
    [ "${#header}" -le 72 ]
    ! printf '%s\n' "$result" | grep -qF "split c"
    printf '%s\n' "$result" | grep -qF "confirmation"
    printf '%s\n' "$result" | grep -qF "feature/functionality instead of directory structure"
    printf '%s\n' "$result" | grep -qF "commit contexts"
    printf '%s\n' "$result" | grep -qF "dynamic width alignment"
    printf '%s\n' "$result" | grep -qF "formatting, and abort handling"
    printf '%s\n' "$result" | grep -qF "unit test behavior"
    assert_conventional_commit_contract "$result"
}
