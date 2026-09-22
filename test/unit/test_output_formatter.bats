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
    run display_setup_info
    [ "$status" -eq 0 ]
}

@test "display_setup_info shows backend" {
    run display_setup_info
    assert_output_contains "Backend: ollama"
}

@test "display_setup_info shows configured model" {
    run display_setup_info
    assert_output_contains "Model: $(get_default_ai_model)"
}

@test "display_setup_info does not list staged files" {
    echo "test content" > test_file.txt
    git add test_file.txt
    run display_setup_info
    refute_output_contains "test_file.txt"
    refute_output_contains "Staged"
    git reset test_file.txt >/dev/null 2>&1 || true
    rm -f test_file.txt
}

# ─── display_staged_files ─────────────────────────────────────────────────────

@test "display_staged_files shows header with file count and churn" {
    echo "line" > app.js
    git add app.js
    run display_staged_files "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    [ "$status" -eq 0 ]
    assert_output_contains "Staged changes (1 file, +1 -0):"
}

@test "display_staged_files shows new file status word" {
    echo "x" > newfile.js
    git add newfile.js
    run display_staged_files "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    assert_output_contains "new file:   newfile.js"
}

@test "display_staged_files shows modified and renamed status words" {
    echo "a" > mod_me.txt
    echo "r" > orig.txt
    git add mod_me.txt orig.txt
    git commit -qm "init"
    echo "b" >> mod_me.txt
    git add mod_me.txt
    git mv orig.txt moved.txt
    run display_staged_files "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    assert_output_contains "Staged changes (2 files,"
    assert_output_contains "modified:   mod_me.txt"
    assert_output_contains "renamed:    orig.txt -> moved.txt"
}

@test "display_staged_files prints nothing when no staged changes" {
    run display_staged_files "" ""
    [ "$status" -eq 0 ]
    refute_output_contains "Staged changes"
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

@test "display_commit_message shows multi-bullet body without blank rows" {
    local bullet_msg="docs(build/Legal-Agreements): refactor MVP legal agreement documents

- remove 230 lines from NDA terms while adding 70 lines of updated content
- reduce SoW land clearance terms from 815 lines to 161 lines
- condense MSA content from 142 to 108 lines
- trim MVP checklist from 183 to 92 lines"
    run display_commit_message "$bullet_msg"
    [ "$status" -eq 0 ]
    assert_output_contains "remove 230 lines"
    assert_output_contains "reduce SoW land clearance"
    assert_output_contains "condense MSA content"
    assert_output_contains "trim MVP checklist"
    refute_output_contains "│   │"
}

@test "display_split_confirmation shows count and scope names" {
    run display_split_confirmation "3" "config, scripts, seo"
    [ "$status" -eq 0 ]
    assert_output_contains "3 distinct scopes"
    assert_output_contains "config, scripts, seo"
    assert_output_contains "Make all-in-one commit? ([Y] all-in-one / [n] multi-commits / [x] abort)"
}

@test "display_split_confirmation shows preview of file samples per scope" {
    local groups="core|aicommit.sh,lib/core.sh
prompt|templates/prompt.txt
test|test1.bats,test2.bats,test3.bats,test4.bats"
    run display_split_confirmation "3" "core, prompt, test" "$groups"
    [ "$status" -eq 0 ]
    assert_output_contains "core"
    assert_output_contains "(2 files):"
    assert_output_contains "- aicommit.sh"
    assert_output_contains "- lib/core.sh"
    assert_output_contains "prompt"
    assert_output_contains "(1 file):"
    assert_output_contains "- templates/prompt.txt"
    assert_output_contains "test"
    assert_output_contains "(4 files):"
    assert_output_contains "- test1.bats"
    assert_output_contains "- test4.bats"
}

@test "display_split_confirmation caps file list with overflow count" {
    local groups="big|f1.js,f2.js,f3.js,f4.js,f5.js,f6.js,f7.js"
    run display_split_confirmation "1" "big" "$groups"
    [ "$status" -eq 0 ]
    assert_output_contains "(7 files):"
    assert_output_contains "- f5.js"
    refute_output_contains "- f6.js"
    assert_output_contains "… and 2 more"
}

@test "display_split_confirmation formats categories with clear separation and category numbers" {
    local groups="core|aicommit.sh,lib/core.sh
prompt|templates/prompt.txt"
    run display_split_confirmation "2" "core, prompt" "$groups"
    [ "$status" -eq 0 ]
    assert_output_contains "📁 Category 1 of 2: core (2 files):"
    assert_output_contains "📁 Category 2 of 2: prompt (1 file):"
}

@test "display_split_confirmation rejects malformed scope lines and reconciles count" {
    local groups="joined_files=public/asset.svg,public/test.txt
static assets & certificate challenge|public/asset.svg,public/test.txt
layout updates|src/layouts/Layout.astro"
    run display_split_confirmation "3" "joined_files=..., static assets & certificate challenge, layout updates" "$groups"
    [ "$status" -eq 0 ]
    assert_output_contains "2 distinct scopes: [static assets & certificate challenge, layout updates]"
    assert_output_contains "📁 Category 1 of 2: static assets & certificate challenge (2 files):"
    assert_output_contains "📁 Category 2 of 2: layout updates (1 file):"
    refute_output_contains "joined_files"
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

@test "display_success shows short commit SHA when HEAD exists" {
    echo "x" > f.txt
    git add f.txt
    git commit -qm "init"
    local sha
    sha=$(git rev-parse --short HEAD)
    run display_success
    assert_output_contains "Committed! ($sha)"
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
