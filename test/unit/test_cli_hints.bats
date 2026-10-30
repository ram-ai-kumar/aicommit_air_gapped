#!/usr/bin/env bats
# Unit Tests — User Intent Hints & Multi-Commit Steering (Smoke, Negative, Edge, Exception, Security)

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── 1. Smoke Tests ──────────────────────────────────────────────────────────

@test "ST-01: aiccx parses multiple positional user hints into USER_HINTS" {
    echo "content" > test.txt
    git add test.txt

    # Run dry-run with two positional hints
    run aiccx "docs reorganized" "Export bug resolved"
    [ "$status" -eq 0 ]
    assert_output_contains "User hints: \"docs reorganized\", \"Export bug resolved\""
}

@test "ST-02: aiccx parses comma-separated hints into distinct entries" {
    echo "content" > test.txt
    git add test.txt

    run aiccx "docs reorganized, Export bug resolved, core refactor"
    [ "$status" -eq 0 ]
    assert_output_contains "User hints: \"docs reorganized\", \"Export bug resolved\", \"core refactor\""
}

@test "ST-03: aiccx accepts explicit --hint and --hints flags" {
    echo "content" > test.txt
    git add test.txt

    run aiccx --hint="docs reorganized" --hints="auth fix, billing retry"
    [ "$status" -eq 0 ]
    assert_output_contains "User hints: \"docs reorganized\", \"auth fix\", \"billing retry\""
}

@test "ST-04: context and prompt templates instruct model to synthesize formal header and body rather than using hint as is" {
    echo "content" > test.txt
    git add test.txt

    init_aicommit_run
    local run_dir
    run_dir=$(get_aicommit_tmp_dir)

    printf 'stages changes grouping enhanced\n' > "${run_dir}/USER_HINTS"
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)" "enhance multi-commit grouping" "$run_dir"

    [ -f "${run_dir}/CHANGES_CONTEXT" ]
    run grep -F "Directional guidance" "${run_dir}/CHANGES_CONTEXT"
    [ "$status" -eq 0 ]

    # Check commit message prompt template
    run grep -F "USER HINTS & INTENT" "$AICOMMIT_DIR/templates/prompt.txt"
    [ "$status" -eq 0 ]
    run grep -F "proper body section" "$AICOMMIT_DIR/templates/prompt.txt"
    [ "$status" -eq 0 ]
}

# ─── 2. Negative Tests ───────────────────────────────────────────────────────

@test "NT-01: conflicting options with hints exits non-zero" {
    echo "content" > test.txt
    git add test.txt

    run aicommit --split --no-split "docs reorganized"
    [ "$status" -eq 1 ]
    assert_output_contains "Conflicting options"
}

@test "NT-02: unknown flag mixed with hints is rejected" {
    echo "content" > test.txt
    git add test.txt

    run aiccs --bogus-flag-xyz "docs reorganized"
    [ "$status" -eq 1 ]
    assert_output_contains "Unknown option: --bogus-flag-xyz"
}

@test "NT-03: empty staged set with hints exits with error" {
    run aiccx "docs reorganized"
    [ "$status" -eq 1 ]
    assert_output_contains "No staged changes"
}

@test "NT-04: _split_sync_to_staged keeps only files still staged" {
    echo "base" > base.txt
    git add base.txt
    git commit -m "chore: initial" >/dev/null 2>&1

    echo "a" > a.txt
    echo "b" > b.txt
    git add a.txt b.txt

    # All group files staged → all kept
    grp_file_array=(a.txt b.txt)
    _split_sync_to_staged
    [ "${#grp_file_array[@]}" -eq 2 ]

    # Unstage b.txt externally → filtered out, a.txt kept
    git restore --staged b.txt
    grp_file_array=(a.txt b.txt)
    _split_sync_to_staged
    [ "${#grp_file_array[@]}" -eq 1 ]
    [ "${grp_file_array[0]}" = "a.txt" ]

    # Foreign staged file is never pulled into the group
    echo "foreign" > foreign.txt
    git add foreign.txt
    grp_file_array=(a.txt)
    _split_sync_to_staged
    [ "${#grp_file_array[@]}" -eq 1 ]
    [ "${grp_file_array[0]}" = "a.txt" ]
}

# ─── 3. Edge Cases ───────────────────────────────────────────────────────────

@test "EC-01: empty and whitespace-only hints are filtered out" {
    echo "content" > test.txt
    git add test.txt

    run aiccx "" "   " "  ,  ,  "
    [ "$status" -eq 0 ]
    refute_output_contains "User hints:"
}

@test "EC-02: hints with punctuation colons and quotes are preserved verbatim" {
    echo "content" > test.txt
    git add test.txt

    run aiccx "fix: (core) 'retry', timeout handling"
    [ "$status" -eq 0 ]
    assert_output_contains "User hints: \"fix: (core) 'retry'\", \"timeout handling\""
}

@test "EC-03: high hint volume is parsed cleanly" {
    echo "content" > test.txt
    git add test.txt

    run aiccx "h1" "h2" "h3" "h4" "h5" "h6" "h7" "h8" "h9" "h10" "h11" "h12"
    [ "$status" -eq 0 ]
    assert_output_contains '"h1"'
    assert_output_contains '"h12"'
}

@test "EC-04: regrouping after preview does not output warning message and continues" {
    echo "file 1" > file1.txt
    git add file1.txt

    run aiccx "hint A"
    [ "$status" -eq 0 ]

    # Change staged files to trigger regrouping
    echo "file 2" > file2.txt
    git add file2.txt

    run aiccx "hint B"
    [ "$status" -eq 0 ]
    refute_output_contains "Staged set changed since preview — regrouping"
}

# ─── 4. Exception & Resilience Tests ─────────────────────────────────────────

@test "ET-01: grouping is deterministic even with user hints present" {
    mkdir -p src lib
    echo "a" > src/a.js
    echo "b" > lib/b.js
    git add src/a.js lib/b.js

    init_aicommit_run
    local run_dir
    run_dir=$(get_aicommit_tmp_dir)
    printf 'docs update\n' > "${run_dir}/USER_HINTS"

    run group_staged_files_logically "$(printf 'src/a.js\nlib/b.js')"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    assert_output_contains "src/a.js"
    assert_output_contains "lib/b.js"
}

@test "ET-02: deterministic grouping keeps distinct contexts in separate groups" {
    mkdir -p src test/unit
    echo "src" > src/app.js
    echo "test" > test/unit/test_cli_hints.bats
    git add src/app.js test/unit/test_cli_hints.bats

    init_aicommit_run
    local run_dir
    run_dir=$(get_aicommit_tmp_dir)
    printf 'all changes\n' > "${run_dir}/USER_HINTS"

    run group_staged_files_logically "$(printf 'src/app.js\ntest/unit/test_cli_hints.bats')"
    [ "$status" -eq 0 ]
    local count
    count=$(printf '%s\n' "$output" | count_lines)
    # Must preserve at least 2 distinct groups, not collapse into 1
    [ "$count" -ge 2 ]
}

# ─── 5. Security Tests ───────────────────────────────────────────────────────

@test "SEC-01: shell metacharacters in user hints are treated strictly as literals" {
    echo "content" > test.txt
    git add test.txt

    # Dangerous payload: command substitution, semicolon, pipe, background
    local evil_payload='; touch /tmp/pwned_aicommit_test; echo "hacked" | cat; $(whoami)'
    run aiccx "$evil_payload"
    [ "$status" -eq 0 ]
    [ ! -f "/tmp/pwned_aicommit_test" ]
    assert_output_contains "touch /tmp/pwned_aicommit_test"
}

@test "SEC-02: run directories and USER_HINTS created with secure permissions" {
    echo "content" > test.txt
    git add test.txt

    run aiccx "test hint"
    [ "$status" -eq 0 ]

    local run_dirs=(.git/aicommit/runs/*)
    for rd in "${run_dirs[@]}"; do
        [ -d "$rd" ] || continue
        local perms
        perms=$(stat -f "%OLp" "$rd" 2>/dev/null || stat -c "%a" "$rd" 2>/dev/null || echo "")
        [ "$perms" = "700" ]
        if [ -f "${rd}/USER_HINTS" ]; then
            local fperms
            fperms=$(stat -f "%OLp" "${rd}/USER_HINTS" 2>/dev/null || stat -c "%a" "${rd}/USER_HINTS" 2>/dev/null || echo "")
            # Must be owner readable/writable only (600 or 700)
            [[ "$fperms" =~ ^(600|700)$ ]]
        fi
    done
}

# ─── 6. Multi-Commit Reliability Tests ────────────────────────────────────────

@test "MC-01: multi-commit split flow does not error in between groups with unbumped or private manifests" {
    printf '{\n  "name": "private-app",\n  "private": true\n}\n' > package.json
    echo "1.0.0" > VERSION
    echo "# Changelog" > CHANGELOG.md
    git add package.json VERSION CHANGELOG.md
    git commit -m "chore: initial" >/dev/null 2>&1
    git tag v1.0.0

    mkdir -p src test
    echo "function feature() {}" > src/feature.js
    echo "test feature" > test/feature_test.js
    git add src/feature.js test/feature_test.js

    export AI_MODEL="test-model"
    mock_ollama_api 'feat(feature): add new feature'

    run aiccs
    [ "$status" -eq 0 ]
    refute_output_contains "Staged set changed since grouping"
    assert_output_contains "All atomic commits completed!"
}

@test "MC-02: multi-commit gracefully handles changelog assigned to later group after earlier group commits it" {
    echo "1.0.0" > VERSION
    echo "# Changelog" > CHANGELOG.md
    git add VERSION CHANGELOG.md
    git commit -m "chore: initial" >/dev/null 2>&1
    git tag v1.0.0

    echo "code" > app.js
    echo "updated changelog" >> CHANGELOG.md
    git add app.js CHANGELOG.md

    export AI_MODEL="test-model"
    mock_ollama_api 'feat: add app feature'

    run aiccs
    [ "$status" -eq 0 ]
    refute_output_contains "Staged set changed since grouping"
    assert_output_contains "All atomic commits completed!"
}

@test "MC-03: aicc regroups currently staged files, ignoring stale preview artifacts" {
    echo "base" > base.txt
    git add base.txt
    git commit -m "chore: initial" >/dev/null 2>&1

    mkdir -p src docs
    echo "function f() {}" > src/f.js
    echo "# guide" > docs/guide.md
    git add src/f.js docs/guide.md

    # Seed stale preview artifacts from an older run — must be ignored
    local state_dir
    state_dir=$(get_aicommit_state_dir)
    printf 'stale\tghost.txt\n' > "${state_dir}/SCOPE_GROUPS"
    printf 'deadbeef\n' > "${state_dir}/STAGED_FINGERPRINT"

    export AI_MODEL="test-model"
    mock_ollama_api 'feat(f): add f'

    run aicc
    [ "$status" -eq 0 ]
    refute_output_contains "Reusing"
    refute_output_contains "Staged set changed since grouping"
    assert_output_contains "All atomic commits completed!"
    # Nothing may remain staged and the phantom file must never have been committed
    [ -z "$(git diff --staged --name-only)" ]
    ! git cat-file -e "HEAD:ghost.txt" 2>/dev/null
    git cat-file -e "HEAD:src/f.js"
    git cat-file -e "HEAD:docs/guide.md"
}

@test "MC-04: aicc regroups files staged after a dry-run preview" {
    echo "base" > base.txt
    git add base.txt
    git commit -m "chore: initial" >/dev/null 2>&1

    echo "one" > one.js
    git add one.js
    run aiccx
    [ "$status" -eq 0 ]

    # Stage another file after the preview — the real run must pick it up
    echo "two" > two.js
    git add two.js

    export AI_MODEL="test-model"
    mock_ollama_api 'feat: add files'

    run aicc
    [ "$status" -eq 0 ]
    assert_output_contains "All atomic commits completed!"
    [ -z "$(git diff --staged --name-only)" ]
    git cat-file -e "HEAD:one.js"
    git cat-file -e "HEAD:two.js"
}

@test "MC-05: externally staged file mid-run is left staged and never aborts the flow" {
    echo "base" > base.txt
    git add base.txt
    git commit -m "chore: initial" >/dev/null 2>&1

    echo "a" > a_one.js
    echo "b" > b_two.js
    git add a_one.js b_two.js
    echo "sneak" > sneak.js

    export AI_MODEL="test-model"
    mock_ollama_api 'feat: add files'

    # Simulate another terminal staging a file once the run is underway —
    # generate_commit_message runs once per group, so sneak.js lands in the
    # index mid-flight (after grouping, before commits).
    eval "_orig_generate_commit_message() $(declare -f generate_commit_message | tail -n +2)"
    generate_commit_message() {
        git add sneak.js 2>/dev/null || true
        _orig_generate_commit_message "$@"
    }

    run aicc
    [ "$status" -eq 0 ]
    refute_output_contains "Staged set changed since grouping"
    assert_output_contains "All atomic commits completed!"
    # Foreign file stays staged, grouped files were committed
    printf '%s\n' "$(git diff --staged --name-only)" | grep -qx "sneak.js"
    git cat-file -e "HEAD:a_one.js"
    git cat-file -e "HEAD:b_two.js"
}

