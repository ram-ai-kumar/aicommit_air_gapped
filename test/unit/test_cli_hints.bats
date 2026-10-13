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

@test "ST-04: name_groups_with_ai injects USER INTENT HINTS into grouping prompt" {
    export AI_ENABLE_LLM_GROUPING="true"
    export AI_MODEL="test-model"
    init_aicommit_run
    local run_dir
    run_dir=$(get_aicommit_tmp_dir)
    printf 'docs reorganized\nExport bug resolved\n' > "${run_dir}/USER_HINTS"

    mock_ollama_api '{"groups":[{"name":"docs reorganized","type":"docs","files":["docs/guide.md"]},{"name":"export fix","type":"fix","files":["src/export.js"]}]}'

    run name_groups_with_ai "$(printf '1\tdocs/guide.md\n2\tsrc/export.js')" "$(printf 'docs/guide.md\nsrc/export.js')"
    [ "$status" -eq 0 ]
    [ -f "${run_dir}/GROUPING_USER" ]
    run grep -F "=== USER INTENT HINTS (HIGH PRIORITY) ===" "${run_dir}/GROUPING_USER"
    [ "$status" -eq 0 ]
    run grep -F "docs reorganized" "${run_dir}/GROUPING_USER"
    [ "$status" -eq 0 ]
    run grep -F "Export bug resolved" "${run_dir}/GROUPING_USER"
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

@test "NT-04: mid-run foreign staged file is detected by _split_guard_staged_set" {
    echo "a" > a.txt
    echo "b" > b.txt
    git add a.txt b.txt

    # Staged now matches original
    run _split_guard_staged_set "$(printf 'a.txt\nb.txt')" "a.txt"
    [ "$status" -eq 0 ]

    # Simulate foreign file staged by another process
    echo "foreign" > foreign.txt
    git add foreign.txt

    run _split_guard_staged_set "$(printf 'a.txt\nb.txt')" "a.txt"
    [ "$status" -eq 1 ]
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

@test "EC-03: zero-relevance hint does not crash and leaves changes intact" {
    mkdir -p docs
    echo "doc" > docs/readme.md
    git add docs/readme.md

    local raw='{"groups":[{"name":"database migrations","type":"chore","files":[]},{"name":"documentation","type":"docs","files":["docs/readme.md"]}]}'
    run reconcile_grouping_json "$raw" "docs/readme.md" "1\tdocs/readme.md"
    [ "$status" -eq 0 ]
    assert_output_contains $'documentation\tdocs/readme.md'
}

@test "EC-04: high hint volume is parsed cleanly" {
    echo "content" > test.txt
    git add test.txt

    run aiccx "h1" "h2" "h3" "h4" "h5" "h6" "h7" "h8" "h9" "h10" "h11" "h12"
    [ "$status" -eq 0 ]
    assert_output_contains '"h1"'
    assert_output_contains '"h12"'
}

@test "EC-05: single staged file with multiple hints assigns file once" {
    echo "content" > test.txt
    git add test.txt

    local raw='{"groups":[{"name":"hint 1","type":"feat","files":["test.txt"]},{"name":"hint 2","type":"chore","files":["test.txt"]}]}'
    run reconcile_grouping_json "$raw" "test.txt" "1\ttest.txt"
    [ "$status" -eq 0 ]
    # test.txt must only appear in the first matched group
    assert_output_contains $'hint 1\ttest.txt'
    refute_output_contains $'hint 2\ttest.txt'
}

# ─── 4. Exception & Resilience Tests ─────────────────────────────────────────

@test "ET-01: grouping_state_key changes when user hints change" {
    echo "content" > test.txt
    git add test.txt

    init_aicommit_run
    local run_dir
    run_dir=$(get_aicommit_tmp_dir)

    # Key without hints
    local k1 k2 k3
    k1=$(grouping_state_key)

    # Key with hint A
    printf 'hint A\n' > "${run_dir}/USER_HINTS"
    k2=$(grouping_state_key)
    [ "$k1" != "$k2" ]

    # Key with hint B
    printf 'hint B\n' > "${run_dir}/USER_HINTS"
    k3=$(grouping_state_key)
    [ "$k2" != "$k3" ]
}

@test "ET-02: LLM failure with hints falls back to deterministic components" {
    mkdir -p src lib
    echo "a" > src/a.js
    echo "b" > lib/b.js
    git add src/a.js lib/b.js

    init_aicommit_run
    local run_dir
    run_dir=$(get_aicommit_tmp_dir)
    printf 'docs update\n' > "${run_dir}/USER_HINTS"

    # Simulate invalid JSON response
    mock_ollama_api "I am sorry, I cannot format this as JSON."

    export AI_ENABLE_LLM_GROUPING="true"
    run group_staged_files_logically "$(printf 'src/a.js\nlib/b.js')"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    # Must fallback to deterministic component names
    assert_output_contains "src/a.js"
    assert_output_contains "lib/b.js"
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

@test "SEC-02: sensitive files are not leaked into grouping prompt even when named in hint" {
    export AI_ENABLE_LLM_GROUPING="true"
    export AI_MODEL="test-model"
    init_aicommit_run
    local run_dir
    run_dir=$(get_aicommit_tmp_dir)

    echo "SECRET=123" > .env
    mkdir -p src
    echo "normal" > src/app.js
    git add .env src/app.js

    printf 'update .env credentials\n' > "${run_dir}/USER_HINTS"
    mock_ollama_api '{"groups":[{"name":"app","type":"feat","files":["src/app.js"]}]}'

    run name_groups_with_ai "$(printf '1\t.env\n2\tsrc/app.js')" "$(printf '.env\nsrc/app.js')"
    [ "$status" -eq 0 ]
    [ -f "${run_dir}/GROUPING_USER" ]
    # .env must be filtered from the component listing
    run grep -F "GROUP 1: M:.env" "${run_dir}/GROUPING_USER"
    [ "$status" -eq 1 ]
}

@test "SEC-03: path traversal in model response is rejected by reconcile" {
    echo "content" > test.txt
    git add test.txt

    # Malicious LLM outputs external/traversal paths
    local raw='{"groups":[{"name":"hack","type":"chore","files":["../../../../etc/passwd","/etc/shadow","test.txt"]}]}'
    run reconcile_grouping_json "$raw" "test.txt" "1\ttest.txt"
    [ "$status" -eq 0 ]
    assert_output_contains $'hack\ttest.txt'
    refute_output_contains "etc/passwd"
    refute_output_contains "etc/shadow"
}

@test "SEC-04: run directories and USER_HINTS created with secure permissions" {
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
