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

@test "get_aicommit_tmp_dir returns a path under .git/aicommit/runs" {
    local d
    d=$(get_aicommit_tmp_dir)
    [[ "$d" == "$(git rev-parse --absolute-git-dir)/aicommit/runs/"* ]]
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

# ─── init_aicommit_run / dead-run purge / secure-dir checks ──────────────────

@test "init_aicommit_run creates a unique run dir under .git/aicommit/runs" {
    init_aicommit_run
    [ -n "$_AICOMMIT_RUN_DIR" ]
    [ -d "$_AICOMMIT_RUN_DIR" ]
    [[ "$_AICOMMIT_RUN_DIR" == "$(git rev-parse --absolute-git-dir)/aicommit/runs/"* ]]
}

@test "init_aicommit_run purges run dirs owned by dead PIDs" {
    init_aicommit_run
    local base
    base=$(get_aicommit_base_dir)
    mkdir -p "${base}/runs/99999999.dead"
    init_aicommit_run
    [ ! -d "${base}/runs/99999999.dead" ]
    [ -d "$_AICOMMIT_RUN_DIR" ]
}

@test "init_aicommit_run leaves run dirs owned by live PIDs alone" {
    init_aicommit_run
    local base
    base=$(get_aicommit_base_dir)
    sleep 60 &
    local sleeper=$!
    mkdir -p "${base}/runs/${sleeper}.live"
    init_aicommit_run
    [ -d "${base}/runs/${sleeper}.live" ]
    kill "$sleeper" 2>/dev/null || true
    wait "$sleeper" 2>/dev/null || true
}

@test "init_aicommit_run succeeds in zsh with empty runs directory" {
    which zsh >/dev/null 2>&1 || skip "zsh not installed"
    run zsh -c "
        export AICOMMIT_DIR='$AICOMMIT_DIR'
        source '$AICOMMIT_DIR/aicommit.sh'
        init_aicommit_run
    "
    [ "$status" -eq 0 ]
}

@test "init_aicommit_run aborts on insecure base directory" {
    local base
    base=$(get_aicommit_base_dir)
    mkdir -m 700 -p "$base"
    chmod 755 "$base"
    run init_aicommit_run
    [ "$status" -eq 1 ]
    assert_output_contains "insecure"
}

@test "init_aicommit_run aborts on symlinked base directory" {
    local base
    base="$(git rev-parse --absolute-git-dir)/aicommit"
    rm -rf "$base"
    mkdir -p "$TEST_TEMP_DIR/evil"
    ln -s "$TEST_TEMP_DIR/evil" "$base"
    run init_aicommit_run
    [ "$status" -eq 1 ]
}

# ─── aicommit_acquire_lock / aicommit_release_lock ───────────────────────────

@test "aicommit_acquire_lock serializes and releases the commit lock" {
    init_aicommit_run
    aicommit_acquire_lock
    [ -n "$_AICOMMIT_LOCK_DIR" ]
    [ -d "$_AICOMMIT_LOCK_DIR" ]
    aicommit_release_lock
    [ -z "$_AICOMMIT_LOCK_DIR" ]
    [ ! -d "$(get_aicommit_base_dir)/lock" ]
}

@test "aicommit_acquire_lock reclaims a lock owned by a dead PID" {
    init_aicommit_run
    local base
    base=$(get_aicommit_base_dir)
    mkdir -p "${base}/lock"
    printf '99999999' > "${base}/lock/pid"
    aicommit_acquire_lock
    [ -n "$_AICOMMIT_LOCK_DIR" ]
    aicommit_release_lock
}

# ─── state dir ───────────────────────────────────────────────────────────────

@test "get_aicommit_state_dir returns .git/aicommit/state" {
    local d
    d=$(get_aicommit_state_dir)
    [ -d "$d" ]
    [[ "$d" == "$(git rev-parse --absolute-git-dir)/aicommit/state" ]]
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
    get_aicommit_tmp_dir > /dev/null
    local d="$_AICOMMIT_RUN_DIR"
    touch "${d}/CHANGES_CONTEXT"
    cleanup_aicommit_ephemeral
    [ ! -f "${d}/CHANGES_CONTEXT" ]
}

@test "cleanup_aicommit_ephemeral removes FILE_CONTEXT" {
    get_aicommit_tmp_dir > /dev/null
    local d="$_AICOMMIT_RUN_DIR"
    touch "${d}/FILE_CONTEXT"
    cleanup_aicommit_ephemeral
    [ ! -f "${d}/FILE_CONTEXT" ]
}

@test "cleanup_aicommit_ephemeral removes FILE_COUNT" {
    get_aicommit_tmp_dir > /dev/null
    local d="$_AICOMMIT_RUN_DIR"
    touch "${d}/FILE_COUNT"
    cleanup_aicommit_ephemeral
    [ ! -f "${d}/FILE_COUNT" ]
}

@test "cleanup_aicommit_ephemeral removes the whole run dir but preserves state files" {
    get_aicommit_tmp_dir > /dev/null
    local d="$_AICOMMIT_RUN_DIR" s
    s=$(get_aicommit_state_dir)
    touch "${s}/FULL_PROMPT" "${d}/CHANGES_CONTEXT"
    cleanup_aicommit_ephemeral
    [ ! -d "$d" ]
    [ -f "${s}/FULL_PROMPT" ]
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

@test "_assemble_commit_message strips Thinking Process without open tag and extracts commit" {
    # Exact scenario reported by the user: Thinking Process without open
    # <think> tag, ending in </think>, with docs: appearing twice
    local rf="$TEST_TEMP_DIR/response.txt"
    cat << 'EOF' > "$rf"
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
    run _assemble_commit_message "$rf" "$TEST_TEMP_DIR"
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

@test "cleanup_aicommit_all removes FULL_PROMPT from state dir" {
    local s
    s=$(get_aicommit_state_dir)
    touch "${s}/FULL_PROMPT"
    cleanup_aicommit_all
    [ ! -f "${s}/FULL_PROMPT" ]
}

@test "cleanup_aicommit_all removes all ephemeral files" {
    get_aicommit_tmp_dir > /dev/null
    local d="$_AICOMMIT_RUN_DIR" s
    s=$(get_aicommit_state_dir)
    touch "${d}/CHANGES_CONTEXT" "${d}/FILE_CONTEXT" "${d}/FILE_COUNT" "${s}/FULL_PROMPT"
    cleanup_aicommit_all
    [ ! -d "$d" ]
    [ ! -f "${s}/FULL_PROMPT" ]
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

@test "extract_conventional_commit resolves terminal cursor backspaces and line wraps" {
    local input
    input="feat(aicommit): implement logical context grouping and multi-commit split c"$'\x1b[?25l\x1b[?25h\x1b[7D\x1b[K\n'"confirmation

- introduce AI-driven context analyzer to group staged files by
  feature/fun"$'\x1b[11D\x1b[K\n'"feature/functionality instead of directory structure"

    local result
    result=$(extract_conventional_commit "$input")
    echo "$result" | grep -qF "feat(aicommit): implement logical context grouping and multi-commit confirmation"
    echo "$result" | grep -qF "feature/functionality instead of directory structure"
    ! echo "$result" | grep -qF "feature/fun"
    ! echo "$result" | grep -qF "split c"
}

@test "extract_conventional_commit repairs word-wrap stutter fragments and joins wrapped headers" {
    local input
    input="feat(aicommit): implement logical context grouping and multi-commit
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
    echo "$result" | grep -qF "feat(aicommit): implement logical context grouping and multi-commit split confirmation"
    echo "$result" | grep -qF "feature/functionality instead of directory structure"
    echo "$result" | grep -qF "commit contexts"
    echo "$result" | grep -qF "dynamic width alignment"
    echo "$result" | grep -qF "formatting, and abort handling"
    echo "$result" | grep -qF "unit test behavior"
    ! echo "$result" | grep -qF "feature/fun"
    ! echo "$result" | grep -qF "split c"
    ! echo "$result" | grep -qE '^confirmation$'
}


# ─── build_ai_context facts/types/scopes ─────────────────────────────────────

@test "build_ai_context writes FACTS, ALLOWED_TYPES, SCOPE_CANDIDATES" {
    printf 'def added_function():\n    pass\n' > app.py
    git add app.py
    local changes staged numstat
    changes=$(git diff --staged)
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)
    build_ai_context "$changes" "$staged" "$numstat"
    local d
    d=$(get_aicommit_tmp_dir)
    [ -f "${d}/FACTS" ]
    [ -f "${d}/ALLOWED_TYPES" ]
    [ -f "${d}/SCOPE_CANDIDATES" ]
    grep -q "=== FACTS ===" "${d}/FACTS"
    grep -q "Definitions added" "${d}/FACTS"
    grep -q "added_function" "${d}/FACTS"
}

@test "build_ai_context writes run files STAGED_DIFF, STAGED_NAMES, NUMSTAT" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    local d
    d=$(get_aicommit_tmp_dir)
    [ -s "${d}/STAGED_DIFF" ]
    [ -s "${d}/STAGED_NAMES" ]
    [ -s "${d}/NUMSTAT" ]
}

@test "build_facts detects added and deleted files" {
    local diff_text
    diff_text=$'diff --git a/new.txt b/new.txt\nnew file mode 100644\n+content\ndiff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n-old\n'
    local result
    result=$(printf '%s' "$diff_text" | build_facts)
    echo "$result" | grep -qF "Files added: new.txt"
    echo "$result" | grep -qF "Files deleted: gone.txt"
}

@test "infer_allowed_types narrows docs-only change sets" {
    local result
    result=$(printf 'README.md\ndocs/guide.md\n' | infer_allowed_types)
    [ "$result" = "docs" ]
}

@test "infer_allowed_types narrows test-only change sets" {
    local result
    result=$(printf 'test/unit/test_core.bats\ntest/unit/test_other.bats\n' | infer_allowed_types)
    [ "$result" = "test" ]
}

@test "infer_allowed_types gives the full enum for mixed changes" {
    local result
    result=$(printf 'lib/core.sh\nREADME.md\n' | infer_allowed_types)
    echo "$result" | grep -qx "feat"
    echo "$result" | grep -qx "chore"
}

# ─── validate_commit_grounding ───────────────────────────────────────────────

@test "validate_commit_grounding accepts a grounded message" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    local d
    d=$(get_aicommit_tmp_dir)
    run validate_commit_grounding "feat(app): add app.js" "$d"
    [ "$status" -eq 0 ]
}

@test "validate_commit_grounding rejects hallucinated file paths" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    local d
    d=$(get_aicommit_tmp_dir)
    run validate_commit_grounding "feat: update src/nonexistent.js" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "not in the diff"
}

@test "validate_commit_grounding rejects a type outside the allowed enum" {
    echo "x" > README.md
    git add README.md
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    local d
    d=$(get_aicommit_tmp_dir)
    run validate_commit_grounding "feat: update docs" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "not allowed"
}

@test "validate_commit_grounding rejects headers over 72 chars" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    local d
    d=$(get_aicommit_tmp_dir)
    run validate_commit_grounding "feat: $(printf 'x%.0s' {1..80})" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "72"
}

# ─── _commit_msg_from_json_obj / _assemble_commit_message ────────────────────

@test "_commit_msg_from_json_obj assembles header and body" {
    local obj='{"type":"feat","scope":"auth","breaking":false,"subject":"add oauth login","body":["wire google provider"]}'
    run _commit_msg_from_json_obj "$obj"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "feat(auth): add oauth login" ]
    assert_output_contains "- wire google provider"
}

@test "_commit_msg_from_json_obj handles scope none and other" {
    run _commit_msg_from_json_obj '{"type":"chore","scope":"none","breaking":false,"subject":"update deps"}'
    [ "$output" = "chore: update deps" ]
    run _commit_msg_from_json_obj '{"type":"fix","scope":"other","scope_other":"Payments API","breaking":true,"subject":"handle timeouts"}'
    [ "${lines[0]}" = "fix(paymentsapi)!: handle timeouts" ]
}

@test "_commit_msg_from_json_obj strips embedded conventional prefix" {
    run _commit_msg_from_json_obj '{"type":"feat","scope":"none","breaking":false,"subject":"feat: add thing"}'
    [ "$output" = "feat: add thing" ]
}

@test "_assemble_commit_message parses schema JSON responses" {
    printf '{"type":"feat","scope":"none","breaking":false,"subject":"add transport"}' > "$TEST_TEMP_DIR/resp.txt"
    run _assemble_commit_message "$TEST_TEMP_DIR/resp.txt" "$TEST_TEMP_DIR"
    [ "$output" = "feat: add transport" ]
}

@test "template_commit_from_facts builds a deterministic fallback" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    local d
    d=$(get_aicommit_tmp_dir)
    run template_commit_from_facts "$d"
    [ "$status" -eq 0 ]
    assert_output_contains "app.js"
    verify_conventional_commit "$output"
}

# ─── generate_commit_message — schema, grounding, cache ─────────────────────

@test "generate_commit_message assembles a schema-conform JSON response" {
    echo "console.log('hello');" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    invoke_llm() {
        printf '%s' '{"type":"feat","scope":"app","breaking":false,"subject":"add app.js"}' > "$3"
        return 0
    }
    export -f invoke_llm
    run generate_commit_message
    [ "$status" -eq 0 ]
    [ "$output" = "feat(app): add app.js" ]
}

@test "generate_commit_message falls back to facts when grounding fails twice" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    invoke_llm() {
        printf '%s' '{"type":"feat","scope":"none","breaking":false,"subject":"rewrite src/totally-fake.js"}' > "$3"
        return 0
    }
    export -f invoke_llm
    run generate_commit_message
    [ "$status" -eq 0 ]
    # Fallback must be a valid conventional commit grounded in real files
    verify_conventional_commit "$output"
    refute_output_contains "totally-fake"
}

@test "generate_commit_message reuses cached response for identical request" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    echo "0" > "$TEST_TEMP_DIR/llm_count"
    invoke_llm() {
        c=$(( $(cat "$TEST_TEMP_DIR/llm_count") + 1 ))
        echo "$c" > "$TEST_TEMP_DIR/llm_count"
        printf '%s' '{"type":"feat","scope":"app","breaking":false,"subject":"add app.js"}' > "$3"
        return 0
    }
    export -f invoke_llm
    generate_commit_message > /dev/null
    [ "$(cat "$TEST_TEMP_DIR/llm_count")" -eq 1 ]
    local second
    second=$(generate_commit_message)
    [ "$(cat "$TEST_TEMP_DIR/llm_count")" -eq 1 ]
    [ "$second" = "feat(app): add app.js" ]
}

@test "regenerate_commit_message bumps the request seed" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    invoke_llm() {
        cp "$2" "$TEST_TEMP_DIR/req_seen.json"
        printf '%s' '{"type":"feat","scope":"app","breaking":false,"subject":"add app.js"}' > "$3"
        return 0
    }
    export -f invoke_llm
    generate_commit_message > /dev/null
    [ "$(jq '.options.seed' "$TEST_TEMP_DIR/req_seen.json")" = "42" ]
    regenerate_commit_message > /dev/null
    [ "$(jq '.options.seed' "$TEST_TEMP_DIR/req_seen.json")" = "43" ]
}

@test "generate_commit_message writes FULL_PROMPT into the state dir" {
    echo "x" > app.js
    git add app.js
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)"
    generate_commit_message --dry-run
    local s
    s=$(get_aicommit_state_dir)
    [ -s "${s}/FULL_PROMPT" ]
    grep -q "USER CONTEXT" "${s}/FULL_PROMPT"
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

# ─── suggest_semver_bump ─────────────────────────────────────────────────────

@test "suggest_semver_bump returns major for bang-marked header" {
    run suggest_semver_bump "feat!: drop legacy config format"
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "suggest_semver_bump returns major for scoped bang-marked header" {
    run suggest_semver_bump "fix(api)!: remove deprecated endpoint"
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "suggest_semver_bump returns major for BREAKING CHANGE footer" {
    local msg
    msg=$(printf 'feat: add new config loader\n\nBREAKING CHANGE: old config keys are no longer read')
    run suggest_semver_bump "$msg"
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "suggest_semver_bump returns minor for feat header" {
    run suggest_semver_bump "feat(auth): add OAuth login"
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "suggest_semver_bump returns patch for fix header" {
    run suggest_semver_bump "fix: correct off-by-one in pagination"
    [ "$status" -eq 0 ]
    [ "$output" = "patch" ]
}

@test "suggest_semver_bump returns patch for perf header" {
    run suggest_semver_bump "perf: cache parsed templates"
    [ "$status" -eq 0 ]
    [ "$output" = "patch" ]
}

@test "suggest_semver_bump returns none for chore header" {
    run suggest_semver_bump "chore: bump dependency versions"
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "suggest_semver_bump returns none for docs header" {
    run suggest_semver_bump "docs: clarify install steps"
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "suggest_semver_bump returns none for test header" {
    run suggest_semver_bump "test: add coverage for edge case"
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

# ─── agit & git helpers ──────────────────────────────────────────────────────

@test "agit runs git commands with quotePath=false" {
    echo "test" > "file with spaces.txt"
    agit add "file with spaces.txt"
    run agit status --short
    [ "$status" -eq 0 ]
    assert_output_contains "file with spaces.txt"
}

@test "to_pathspec formats path with top and literal specifier" {
    run to_pathspec "src/lib/app.js"
    [ "$status" -eq 0 ]
    [ "$output" = ":(top,literal)src/lib/app.js" ]
}

@test "staged_fingerprint produces deterministic sha256 of staged files" {
    echo "a" > a.txt
    echo "b" > b.txt
    agit add a.txt b.txt
    local fp1 fp2
    fp1=$(staged_fingerprint)
    fp2=$(staged_fingerprint)
    [ -n "$fp1" ]
    [ "$fp1" = "$fp2" ]
    echo "c" > c.txt
    agit add c.txt
    local fp3
    fp3=$(staged_fingerprint)
    [ "$fp1" != "$fp3" ]
}

@test "_aicommit_split_tab_line splits tab-delimited scope and files" {
    local line="core	aicommit.sh	lib/core.sh"
    _aicommit_split_tab_line "$line"
    [ "$_aicommit_split_scope" = "core" ]
    [ "${#_aicommit_split_files[@]}" -eq 2 ]
    [ "${_aicommit_split_files[0]}" = "aicommit.sh" ]
    [ "${_aicommit_split_files[1]}" = "lib/core.sh" ]
}

@test "_aicommit_split_tab_line handles empty and single-field lines" {
    _aicommit_split_tab_line ""
    [ "$_aicommit_split_scope" = "" ]
    [ "${#_aicommit_split_files[@]}" -eq 0 ]

    _aicommit_split_tab_line "docs"
    [ "$_aicommit_split_scope" = "docs" ]
    [ "${#_aicommit_split_files[@]}" -eq 0 ]
}

# ─── _aicommit_has_split_flag & shortcut functions ───────────────────────────

@test "_aicommit_has_split_flag detects split and no-split flags" {
    run _aicommit_has_split_flag "--split"
    [ "$status" -eq 0 ]

    run _aicommit_has_split_flag "-s"
    [ "$status" -eq 0 ]

    run _aicommit_has_split_flag "--no-split"
    [ "$status" -eq 0 ]

    run _aicommit_has_split_flag "--all"
    [ "$status" -eq 0 ]

    run _aicommit_has_split_flag "--bump" "--yes"
    [ "$status" -eq 1 ]

    run _aicommit_has_split_flag
    [ "$status" -eq 1 ]
}

@test "aic function executes all-in-one non-interactive dry-run" {
    echo "foo" > foo.txt
    git add foo.txt
    run aic --dry-run
    [ "$status" -eq 0 ]
    assert_output_contains "Dry run"
}

@test "aicc function executes split non-interactive dry-run" {
    echo "foo" > foo.txt
    git add foo.txt
    run aicc --dry-run
    [ "$status" -eq 0 ]
    assert_output_contains "Dry run"
}

@test "aicx function executes verbose dry-run without commit" {
    echo "foo" > foo.txt
    git add foo.txt
    run aicx
    [ "$status" -eq 0 ]
    assert_output_contains "Dry run"
}

@test "aiccx function executes verbose split dry-run" {
    echo "foo" > foo.txt
    git add foo.txt
    run aiccx
    [ "$status" -eq 0 ]
    assert_output_contains "Dry run"
}

@test "aics function executes semver all-in-one dry-run" {
    printf '{\n  "name": "pkg",\n  "version": "1.0.0"\n}\n' > package.json
    echo "foo" > foo.txt
    git add package.json foo.txt
    run aics --dry-run
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Plan"
}

@test "aiccs function executes semver split dry-run" {
    printf '{\n  "name": "pkg",\n  "version": "1.0.0"\n}\n' > package.json
    echo "foo" > foo.txt
    git add package.json foo.txt
    run aiccs --dry-run
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Plan"
}

@test "aicsx function executes verbose semver dry-run" {
    printf '{\n  "name": "pkg",\n  "version": "1.0.0"\n}\n' > package.json
    echo "foo" > foo.txt
    git add package.json foo.txt
    run aicsx
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Plan"
}

@test "aiccsx function executes verbose semver split dry-run" {
    printf '{\n  "name": "pkg",\n  "version": "1.0.0"\n}\n' > package.json
    echo "foo" > foo.txt
    git add package.json foo.txt
    run aiccsx
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Plan"
}

@test "aicommit preserves caller INT and TERM traps in bash and zsh" {
    # Verify in bash
    run bash -c "
        trap 'echo old_int' INT
        trap 'echo old_term' TERM
        export AICOMMIT_DIR='$AICOMMIT_DIR'
        source '$AICOMMIT_DIR/aicommit.sh'
        aicommit --help >/dev/null
        trap -p INT
        trap -p TERM
    "
    [ "$status" -eq 0 ]
    assert_output_contains "old_int"
    assert_output_contains "old_term"

    # Verify in zsh if available
    if which zsh >/dev/null 2>&1; then
        run zsh -c "
            trap 'echo old_int' INT
            trap 'echo old_term' TERM
            export AICOMMIT_DIR='$AICOMMIT_DIR'
            source '$AICOMMIT_DIR/aicommit.sh'
            aicommit --help >/dev/null
            trap
        "
        [ "$status" -eq 0 ]
        assert_output_contains "trap -- 'echo old_int' INT"
        assert_output_contains "trap -- 'echo old_term' TERM"
    fi
}

@test "_generate_group_messages_batched builds valid batch JSON schema" {
    local tmp_dir="$TEST_TEMP_DIR/batch_test"
    mkdir -p "${tmp_dir}/groups/1" "${tmp_dir}/groups/2"
    echo "feat" > "${tmp_dir}/groups/1/ALLOWED_TYPES"
    echo "core" > "${tmp_dir}/groups/1/SCOPE_CANDIDATES"
    echo "fix" > "${tmp_dir}/groups/2/ALLOWED_TYPES"
    echo "ui" > "${tmp_dir}/groups/2/SCOPE_CANDIDATES"
    touch "${tmp_dir}/groups/1/CHANGES_CONTEXT"
    touch "${tmp_dir}/groups/2/CHANGES_CONTEXT"
    echo "prompt" > "${AICOMMIT_DIR}/templates/prompt.txt"
    export AI_PROMPT_FILE="${AICOMMIT_DIR}/templates/prompt.txt"

    # Mock ollama request and invoke_llm to succeed with valid json response
    build_ollama_request() { return 0; }
    invoke_llm() {
        printf '{"commits":[{"type":"feat","scope":"core","breaking":false,"subject":"one","body":[]},{"type":"fix","scope":"ui","breaking":false,"subject":"two","body":[]}]}' > "$3"
        return 0
    }

    run _generate_group_messages_batched 2 "$tmp_dir"
    [ "$status" -eq 0 ]
    [ -f "${tmp_dir}/BATCH_SCHEMA.json" ]
    run jq . "${tmp_dir}/BATCH_SCHEMA.json"
    [ "$status" -eq 0 ]
    refute_output_contains "syntax error"
}

@test "aicommit entry points suppress interactive shell background job noise" {
    if which zsh >/dev/null 2>&1; then
        run zsh -f -i -c "
            export AICOMMIT_DIR='$AICOMMIT_DIR'
            source '$AICOMMIT_DIR/aicommit.sh'
            aicommit --help >/dev/null
        "
        [ "$status" -eq 0 ]
        refute_output_contains "done       "
        refute_output_contains "[1]"
    fi
}

@test "_generate_group_messages_batched parses fenced JSON response from model" {
    local tmp_dir="$TEST_TEMP_DIR/batch_fenced_test"
    mkdir -p "${tmp_dir}/groups/1" "${tmp_dir}/groups/2"
    echo "feat" > "${tmp_dir}/groups/1/ALLOWED_TYPES"
    echo "core" > "${tmp_dir}/groups/1/SCOPE_CANDIDATES"
    echo "fix" > "${tmp_dir}/groups/2/ALLOWED_TYPES"
    echo "ui" > "${tmp_dir}/groups/2/SCOPE_CANDIDATES"
    touch "${tmp_dir}/groups/1/CHANGES_CONTEXT"
    touch "${tmp_dir}/groups/2/CHANGES_CONTEXT"
    echo "prompt" > "${AICOMMIT_DIR}/templates/prompt.txt"
    export AI_PROMPT_FILE="${AICOMMIT_DIR}/templates/prompt.txt"

    build_ollama_request() { return 0; }
    invoke_llm() {
        cat << 'EOF' > "$3"
```json
{
  "commits": [
    {"type": "feat", "scope": "core", "breaking": false, "subject": "one", "body": []},
    {"type": "fix", "scope": "ui", "breaking": false, "subject": "two", "body": []}
  ]
}
```
EOF
        return 0
    }

    _AICOMMIT_GRP_MSGS=()
    _generate_group_messages_batched 2 "$tmp_dir"
    [ $? -eq 0 ]
    [ "${_AICOMMIT_GRP_MSGS[1]}" = "feat(core): one" ]
    [ "${_AICOMMIT_GRP_MSGS[2]}" = "fix(ui): two" ]
}




