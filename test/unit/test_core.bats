#!/usr/bin/env bats
# Unit Tests — lib/core.sh (9 functions)

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── get_aicommit_tmp_dir ────────────────────────────────────────────────────

@test "get_aicommit_tmp_dir creates the directory" {
    local d
    d=$(get_aicommit_tmp_dir)
    [ -d "$d" ]
}

@test "get_aicommit_tmp_dir returns a path under /tmp/.aicommit" {
    local d
    d=$(get_aicommit_tmp_dir)
    [[ "$d" == /tmp/.aicommit/* ]]
}

@test "get_aicommit_tmp_dir sets directory permissions to 700" {
    local d perms
    d=$(get_aicommit_tmp_dir)
    perms=$(stat -f %A "$d" 2>/dev/null || stat -c %a "$d" 2>/dev/null)
    [ "$perms" = "700" ]
}

@test "get_aicommit_tmp_dir returns the same path on repeated calls" {
    local d1 d2
    d1=$(get_aicommit_tmp_dir)
    d2=$(get_aicommit_tmp_dir)
    [ "$d1" = "$d2" ]
}

# ─── build_file_context ──────────────────────────────────────────────────────

@test "build_file_context creates FILE_CONTEXT, CHANGE_STATS, FILE_COUNT" {
    echo "content" > app.js
    git add app.js
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)

    build_file_context "$staged" "$numstat"

    local d
    d=$(get_aicommit_tmp_dir)
    [ -f "${d}/FILE_CONTEXT" ]
    [ -f "${d}/CHANGE_STATS" ]
    [ -f "${d}/FILE_COUNT" ]
}

@test "build_file_context counts staged files correctly" {
    echo "a" > f1.js
    echo "b" > f2.py
    git add f1.js f2.py
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)

    build_file_context "$staged" "$numstat"

    local d count
    d=$(get_aicommit_tmp_dir)
    count=$(cat "${d}/FILE_COUNT")
    [ "$count" = "2" ]
}

@test "build_file_context excludes .env from CHANGE_STATS" {
    echo "SECRET=abc" > .env
    echo "content"   > app.js
    git add .env app.js
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)

    build_file_context "$staged" "$numstat"

    local d
    d=$(get_aicommit_tmp_dir)
    ! grep -qF ".env" "${d}/CHANGE_STATS"
}

@test "build_file_context classifies .js files as javascript/typescript" {
    echo "var x=1;" > app.js
    git add app.js
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)

    build_file_context "$staged" "$numstat"

    local d
    d=$(get_aicommit_tmp_dir)
    grep -q "javascript/typescript" "${d}/FILE_CONTEXT"
}

@test "build_file_context classifies .sh files as shell" {
    echo "echo hi" > run.sh
    git add run.sh
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)

    build_file_context "$staged" "$numstat"

    local d
    d=$(get_aicommit_tmp_dir)
    grep -q "shell" "${d}/FILE_CONTEXT"
}

# ─── filter_and_truncate_diff ────────────────────────────────────────────────

@test "filter_and_truncate_diff passes empty input without error" {
    local result
    result=$(printf '' | filter_and_truncate_diff)
    [ -z "$result" ]
}

@test "filter_and_truncate_diff excludes .env file diffs" {
    local result
    result=$(printf 'diff --git a/.env b/.env\n+SECRET_KEY=abc\n' \
             | filter_and_truncate_diff)
    ! echo "$result" | grep -qF "SECRET_KEY"
}

@test "filter_and_truncate_diff passes through source file diffs" {
    local result
    result=$(printf 'diff --git a/src/app.sh b/src/app.sh\n+echo hello\n' \
             | filter_and_truncate_diff)
    echo "$result" | grep -qF "echo hello"
}

@test "filter_and_truncate_diff excludes .lock file diffs" {
    local result
    result=$(printf 'diff --git a/package-lock.json b/package-lock.json\n+{"lockfileVersion":2}\n' \
             | filter_and_truncate_diff)
    ! echo "$result" | grep -qF "lockfileVersion"
}

@test "filter_and_truncate_diff caps markdown files at 20 lines" {
    # Build a diff with 30 content lines for a .md file
    local input
    input="diff --git a/README.md b/README.md"$'\n'
    for i in $(seq 1 30); do
        input="${input}+line ${i}"$'\n'
    done
    local result
    result=$(printf '%s' "$input" | filter_and_truncate_diff)
    local count
    count=$(echo "$result" | grep -c "^+line" || true)
    [ "$count" -le 20 ]
}

@test "filter_and_truncate_diff caps source files at 80 lines" {
    local input
    input="diff --git a/src/app.sh b/src/app.sh"$'\n'
    for i in $(seq 1 100); do
        input="${input}+line_${i}=true"$'\n'
    done
    local result
    result=$(printf '%s' "$input" | filter_and_truncate_diff)
    local count
    count=$(echo "$result" | grep -c "^+line_" || true)
    [ "$count" -le 80 ]
}

# ─── process_commit ──────────────────────────────────────────────────────────

@test "process_commit creates a git commit with the given message" {
    echo "content" > app.js
    git add app.js
    process_commit "feat: add app.js"
    local msg
    msg=$(git log --format="%s" -1)
    [ "$msg" = "feat: add app.js" ]
}

# ─── cleanup_aicommit_ephemeral ──────────────────────────────────────────────

@test "cleanup_aicommit_ephemeral removes CHANGES_CONTEXT" {
    local d
    d=$(get_aicommit_tmp_dir)
    touch "${d}/CHANGES_CONTEXT"
    cleanup_aicommit_ephemeral
    [ ! -f "${d}/CHANGES_CONTEXT" ]
}

@test "cleanup_aicommit_ephemeral removes FILE_CONTEXT" {
    local d
    d=$(get_aicommit_tmp_dir)
    touch "${d}/FILE_CONTEXT"
    cleanup_aicommit_ephemeral
    [ ! -f "${d}/FILE_CONTEXT" ]
}

@test "cleanup_aicommit_ephemeral removes FILE_COUNT" {
    local d
    d=$(get_aicommit_tmp_dir)
    touch "${d}/FILE_COUNT"
    cleanup_aicommit_ephemeral
    [ ! -f "${d}/FILE_COUNT" ]
}

@test "cleanup_aicommit_ephemeral preserves FULL_PROMPT" {
    local d
    d=$(get_aicommit_tmp_dir)
    touch "${d}/FULL_PROMPT" "${d}/CHANGES_CONTEXT"
    cleanup_aicommit_ephemeral
    [ -f "${d}/FULL_PROMPT" ]
}

# ─── generate_commit_message ─────────────────────────────────────────────────

@test "generate_commit_message strips thinking blocks and extracts @@@ delimiters" {
    echo "console.log('hello');" > app.js
    git add app.js
    local changes staged numstat
    changes=$(git diff --staged)
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)
    build_ai_context "$changes" "$staged" "$numstat"

    # Mock the LLM call to write a response with reasoning and @@@ delimiters
    invoke_llm() {
        local response_file="$3"
        {
            echo "<thinking>"
            echo "some reasoning"
            echo "</thinking>"
            echo "@@@"
            echo "feat(app): add app.js"
            echo "@@@"
        } > "$response_file"
        return 0
    }
    export -f invoke_llm

    run generate_commit_message
    [ "$status" -eq 0 ]
    assert_output_contains "feat(app): add app.js"
    refute_output_contains "<thinking>"
    refute_output_contains "some reasoning"
    refute_output_contains "@@@"
}

@test "generate_commit_message strips Thinking Process without open tag and extracts commit" {
    echo "console.log('hello');" > app.js
    git add app.js
    local changes staged numstat
    changes=$(git diff --staged)
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)
    build_ai_context "$changes" "$staged" "$numstat"

    # Mock the LLM call with the exact scenario reported by the user:
    # Thinking Process without open <think> tag, ending in </think>, with docs: appearing twice
    invoke_llm() {
        local response_file="$3"
        cat << 'EOF' > "$response_file"
Thinking Process:
1.  Analyze the Request:
    *   Input: A log of recent git commits and a prompt indicating "Stage 12".
    *   Task: Generate a commit message for the current action.
    Subject: docs: create improvements plan for identified optimizations
    Body:
    - Implements Stage 12 deliverable
    - Covers Performance, Security, Architecture, Ops
    Okay, I'll construct the final response.cw
</think>
docs: create improvements plan for identified optimizations

- Implements Stage 12 deliverable: docs/IMPROVEMENTS_PLAN.md
- Consolidates findings
EOF
        return 0
    }
    export -f invoke_llm

    run generate_commit_message
    [ "$status" -eq 0 ]
    assert_output_contains "docs: create improvements plan for identified optimizations"
    assert_output_contains "- Implements Stage 12 deliverable: docs/IMPROVEMENTS_PLAN.md"
    assert_output_contains "- Consolidates findings"
    refute_output_contains "Thinking Process"
    refute_output_contains "1.  Analyze the Request"
    refute_output_contains "</think>"
    refute_output_contains "construct the final response"
}

@test "extract_conventional_commit handles untagged thinking process with intermediate drafts" {
    local input
    input=$(cat << 'EOF'
Thinking Process:
1. Analyze the changes:
   Option 1:
   docs: intermediate draft that is incomplete
2. Better option:
docs(core): extract conventional commit cleanly from thinking

- strip thinking blocks before anchor discovery
- preserve body bullets
EOF
)
    local result
    result=$(extract_conventional_commit "$input")
    echo "$result" | grep -qF "docs(core): extract conventional commit cleanly from thinking"
    echo "$result" | grep -qF -- "- strip thinking blocks before anchor discovery"
    ! echo "$result" | grep -qF "Thinking Process"
    ! echo "$result" | grep -qF "intermediate draft"
}

@test "extract_conventional_commit preserves body bullets containing commit keywords" {
    local input
    input=$(cat << 'EOF'
docs(plans): add stage 12 planning documentation

- docs: add stage-12-identify-and-plan-overall-improvements.md
- fix: clean up old documentation
- test: verify all changes
EOF
)
    local result
    result=$(extract_conventional_commit "$input")
    echo "$result" | grep -qF "docs(plans): add stage 12 planning documentation"
    echo "$result" | grep -qF -- "- docs: add stage-12-identify-and-plan-overall-improvements.md"
    echo "$result" | grep -qF -- "- fix: clean up old documentation"
    echo "$result" | grep -qF -- "- test: verify all changes"
}

@test "extract_conventional_commit strips markdown fences and conversational preamble/postscript" {
    local input
    input=$(cat << 'EOF'
Here is the conventional commit message:
```
feat(auth): add OAuth2 login with Google provider

- integrate Google OAuth2 endpoint
- add user token verification
```
Hope this helps! Let me know if you need changes.
EOF
)
    local result
    result=$(extract_conventional_commit "$input")
    echo "$result" | grep -qF "feat(auth): add OAuth2 login with Google provider"
    echo "$result" | grep -qF -- "- integrate Google OAuth2 endpoint"
    ! echo "$result" | grep -qF "Here is the"
    ! echo "$result" | grep -qF "Hope this helps"
    ! echo "$result" | grep -qF '```'
}

# ─── cleanup_aicommit_all ────────────────────────────────────────────────────

@test "cleanup_aicommit_all removes FULL_PROMPT" {
    local d
    d=$(get_aicommit_tmp_dir)
    touch "${d}/FULL_PROMPT"
    cleanup_aicommit_all
    [ ! -f "${d}/FULL_PROMPT" ]
}

@test "cleanup_aicommit_all removes all ephemeral files" {
    local d
    d=$(get_aicommit_tmp_dir)
    touch "${d}/CHANGES_CONTEXT" "${d}/FILE_CONTEXT" "${d}/FILE_COUNT" "${d}/FULL_PROMPT"
    cleanup_aicommit_all
    [ ! -f "${d}/CHANGES_CONTEXT" ]
    [ ! -f "${d}/FILE_CONTEXT" ]
    [ ! -f "${d}/FULL_PROMPT" ]
}

# ─── Stutter Cleanup & Scope Retention ───────────────────────────────────────

@test "extract_conventional_commit retains compound scope" {
    local input
    input="@@@
feat(config, scripts, seo): update tooling and validation

- update configuration
@@@"
    local result
    result=$(extract_conventional_commit "$input")
    echo "$result" | grep -qF "feat(config, scripts, seo): update tooling and validation"
}

@test "extract_conventional_commit cleans duplicate token stutters" {
    local input
    input="@@@
refactor(validation): optimize error counting

- update eslint configuration to use defineConfig and add @eslint/js an and sharp dependencies
- refactor Markdown validation to remove unused file path parameters and op optimize error counting
- update build script and and check dependencies
@@@"
    local result
    result=$(extract_conventional_commit "$input")
    echo "$result" | grep -qF "add @eslint/js and sharp dependencies"
    echo "$result" | grep -qF "parameters and optimize error counting"
    echo "$result" | grep -qF "update build script and check dependencies"
    ! echo "$result" | grep -qF "an and"
    ! echo "$result" | grep -qF "op optimize"
    ! echo "$result" | grep -qF "and and"
}

# ─── commit_staged_subset ────────────────────────────────────────────────────

@test "commit_staged_subset commits only specified file leaving others staged" {
    echo "content1" > file1.txt
    echo "content2" > file2.txt
    git add file1.txt file2.txt

    run commit_staged_subset "feat(file1): add file1" "file1.txt"
    [ "$status" -eq 0 ]

    # Verify commit log
    local log_msg
    log_msg=$(git log -1 --pretty=%s)
    [ "$log_msg" = "feat(file1): add file1" ]

    # file2.txt should still be staged
    local remaining_staged
    remaining_staged=$(git diff --staged --name-only)
    [ "$remaining_staged" = "file2.txt" ]
}
