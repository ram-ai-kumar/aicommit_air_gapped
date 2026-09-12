#!/usr/bin/env bats
# Unit Tests — lib/output-formatter.sh (5 functions)

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── display_setup_info ───────────────────────────────────────────────────────

@test "display_setup_info exits 0" {
    run display_setup_info "2" "app.js, app.py"
    [ "$status" -eq 0 ]
}

@test "display_setup_info includes file count" {
    run display_setup_info "3" "a.js, b.py, c.sh"
    assert_output_contains "3 files"
}

@test "display_setup_info includes file list" {
    run display_setup_info "1" "app.js"
    assert_output_contains "app.js"
}

@test "display_setup_info mentions Ollama status" {
    run display_setup_info "1" "app.js"
    assert_output_contains "Ollama running"
}

@test "display_setup_info shows formatted git status output when changes are staged" {
    echo "test content" > test_file.txt
    git add test_file.txt
    run display_setup_info "1" "test_file.txt"
    assert_output_contains "new file:   test_file.txt"
    git reset test_file.txt >/dev/null 2>&1 || true
    rm -f test_file.txt
}

# ─── display_commit_message ───────────────────────────────────────────────────

@test "display_commit_message exits 0" {
    run display_commit_message "feat: add login"
    [ "$status" -eq 0 ]
}

@test "display_commit_message shows commit message text" {
    run display_commit_message "feat: add login"
    assert_output_contains "feat: add login"
}

@test "display_commit_message shows Suggested Commit header without brain icon" {
    run display_commit_message "fix: handle null"
    assert_output_contains "Suggested Commit:"
    refute_output_contains "🧠"
}

@test "display_commit_message wraps in a box" {
    run display_commit_message "chore: update deps"
    assert_output_contains "┌"
    assert_output_contains "└"
}

@test "display_commit_message wraps lines on word boundaries without cutting words" {
    local long_msg="feat: update eslint configuration to use defineConfig and add packages and dependencies"
    run display_commit_message "$long_msg"
    [ "$status" -eq 0 ]
    assert_output_contains "defineConfig and add"
    assert_output_contains "and dependencies"
}

@test "display_commit_message supports 72 content characters width" {
    local line_72="123456789012345678901234567890123456789012345678901234567890123456789012"
    run display_commit_message "$line_72"
    [ "$status" -eq 0 ]
    assert_output_contains "│ $line_72 │"
}

@test "display_commit_message wraps bullets with hanging indent" {
    local bullet_msg="- update eslint configuration to use defineConfig and add @eslint/js and sharp dependencies"
    run display_commit_message "$bullet_msg"
    [ "$status" -eq 0 ]
    assert_output_contains "│   and sharp dependencies"
}

@test "display_split_confirmation shows count and scope names" {
    run display_split_confirmation "3" "config, scripts, seo"
    [ "$status" -eq 0 ]
    assert_output_contains "3 distinct scopes"
    assert_output_contains "config, scripts, seo"
}

@test "display_split_progress shows current and total with scope" {
    run display_split_progress "1" "3" "config"
    [ "$status" -eq 0 ]
    assert_output_contains "commit 1 of 3 (scope: config)"
}

# ─── display_error ────────────────────────────────────────────────────────────

@test "display_error shows error icon" {
    run display_error "connection refused"
    assert_output_contains "❌"
}

@test "display_error shows the message" {
    run display_error "model not found"
    assert_output_contains "model not found"
}

@test "display_error with debug info shows debug line" {
    run display_error "LLM failed" "check /tmp/error.log"
    assert_output_contains "check /tmp/error.log"
}

@test "display_error without debug info omits debug line" {
    run display_error "simple error"
    refute_output_contains "Debug:"
}

# ─── display_success ─────────────────────────────────────────────────────────

@test "display_success exits 0" {
    run display_success
    [ "$status" -eq 0 ]
}

@test "display_success shows checkmark" {
    run display_success
    assert_output_contains "✅"
}

@test "display_success shows Committed" {
    run display_success
    assert_output_contains "Committed"
}

# ─── display_commit_confirmation ─────────────────────────────────────────────

@test "display_commit_confirmation exits 0" {
    run display_commit_confirmation
    [ "$status" -eq 0 ]
}

@test "display_commit_confirmation shows y/n/e prompt" {
    run display_commit_confirmation
    assert_output_contains "[Y]/n/e"
}
