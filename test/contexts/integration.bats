#!/usr/bin/env bats
# Integration Tests — end-to-end workflows.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── Help ────────────────────────────────────────────────────────────────────

@test "aicommit --help completes successfully" {
    run aicommit --help
    [ "$status" -eq 0 ]
}

@test "aicommit -h is equivalent to --help" {
    run aicommit -h
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit"
}

# ─── dry-run workflow ─────────────────────────────────────────────────────────

@test "dry-run exits 0 when files are staged" {
    echo "console.log('hello');" > app.js
    git add app.js
    run aicommit --dry-run
    [ "$status" -eq 0 ]
}

@test "dry-run --verbose shows staged files summary" {
    echo "function test() {}" > app.js
    git add app.js
    run aicommit --dry-run --verbose
    assert_output_contains "Staged"
}

@test "dry-run is quiet by default: no staged list or backend line" {
    echo "content" > app.js
    git add app.js
    run aicommit --dry-run
    refute_output_contains "Staged changes"
    refute_output_contains "Backend:"
}

@test "dry-run shows Dry run message" {
    echo "content" > app.js
    git add app.js
    run aicommit --dry-run
    assert_output_contains "Dry run"
}

@test "dry-run --verbose shows backend and model line" {
    echo "content" > app.js
    git add app.js
    run aicommit --dry-run --verbose
    assert_output_contains "Backend: ollama"
}

@test "dry-run does not repeat staged file list after staged summary" {
    echo "content" > app.js
    git add app.js
    run aicommit --dry-run
    refute_output_contains "📁 Staged"
}

@test "dry-run creates FULL_PROMPT file in the state dir" {
    echo "content" > app.js
    git add app.js
    run aicommit --dry-run
    local s
    s=$(get_aicommit_state_dir)
    [ -f "${s}/FULL_PROMPT" ]
}

@test "FULL_PROMPT is non-empty after dry-run" {
    echo "content" > app.js
    git add app.js
    run aicommit --dry-run
    [ "$status" -eq 0 ]
    local s
    s=$(get_aicommit_state_dir)
    [ -s "${s}/FULL_PROMPT" ]
}

# ─── verbose mode ─────────────────────────────────────────────────────────────

@test "dry-run --verbose shows run dir path" {
    echo "content" > app.js
    git add app.js
    run aicommit --dry-run --verbose
    [ "$status" -eq 0 ]
    assert_output_contains "Run dir"
}

@test "dry-run --verbose shows CHANGES_CONTEXT path" {
    echo "content" > app.js
    git add app.js
    run aicommit --dry-run --verbose
    assert_output_contains "CHANGES_CONTEXT"
}

# ─── failure modes ────────────────────────────────────────────────────────────

@test "aicommit fails cleanly with no staged changes" {
    run aicommit --dry-run
    [ "$status" -eq 1 ]
    assert_output_contains "No staged changes"
}

@test "aic fails cleanly with no staged changes" {
    run aic
    [ "$status" -eq 1 ]
    assert_output_contains "No staged changes"
}

@test "aicommit --regenerate fails when no cached prompt" {
    local s
    s=$(get_aicommit_state_dir)
    rm -f "${s}/MSG_REQUEST"
    run aicommit --regenerate
    [ "$status" -eq 1 ]
    assert_output_contains "No cached prompt"
}

# ─── multi-file staging ───────────────────────────────────────────────────────

@test "dry-run succeeds with multiple staged files" {
    echo "js code"     > app.js
    echo "python code" > app.py
    echo "shell code"  > run.sh
    git add app.js app.py run.sh
    run aicommit --dry-run
    [ "$status" -eq 0 ]
}

@test "dry-run --verbose file count reflects staged files" {
    echo "a" > f1.sh
    echo "b" > f2.sh
    git add f1.sh f2.sh
    run aicommit --dry-run --verbose
    assert_output_contains "2 files"
}

# ─── cleanup after dry-run ────────────────────────────────────────────────────

@test "aic commits a generated message end-to-end" {
    echo "console.log('hello');" > app.js
    git add app.js

    export AI_MODEL="test-model"
    mock_ollama_api '{"type":"feat","scope":"app","breaking":false,"subject":"add app.js"}'

    run aic
    [ "$status" -eq 0 ]

    local msg
    msg=$(git log --format="%s" -1)
    [ "$msg" = "feat(app): add app.js" ]
}

@test "ephemeral run dir is removed after dry-run" {
    echo "content" > app.js
    git add app.js
    # Run in a subshell so the EXIT trap fires
    ( aicommit --dry-run > /dev/null 2>&1 ) || true
    local base
    base=$(get_aicommit_base_dir)
    # No run directories may survive a finished session
    [ -z "$(find "${base}/runs" -mindepth 1 -maxdepth 1 2>/dev/null)" ]
    # But the state dir keeps the audit prompt
    [ -f "${base}/state/FULL_PROMPT" ]
}

@test "aic commits all-in-one without logical grouping checks or prompts" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    echo "console.log('scripts');" > scripts/validate.js
    git add eslint.config.js scripts/validate.js

    export AI_MODEL="test-model"
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"quick all in one commit"}'

    run aic
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"
    refute_output_contains "distinct scopes"

    local commit_count
    commit_count=$(git rev-list --count HEAD)
    [ "$commit_count" -eq 1 ]

    local remaining
    remaining=$(git diff --staged --name-only)
    [ -z "$remaining" ]
}

@test "aic --split splits multi-scope staged changes into atomic commits" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    echo "console.log('scripts');" > scripts/validate.js
    git add eslint.config.js scripts/validate.js

    export AI_MODEL="test-model"
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"atomic split commit"}'

    run aic --split
    [ "$status" -eq 0 ]
    assert_output_contains "All atomic commits completed!"

    local commit_count
    commit_count=$(git rev-list --count HEAD)
    [ "$commit_count" -ge 2 ]

    local remaining
    remaining=$(git diff --staged --name-only)
    [ -z "$remaining" ]
}

@test "aicommit aborts commit when user selects 'x' option" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    echo "console.log('scripts');" > scripts/validate.js
    git add eslint.config.js scripts/validate.js

    export AI_MODEL="test-model"
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"irrelevant"}'

    # Simulate typing 'x'
    run aicommit <<< "x"
    [ "$status" -eq 0 ]
    assert_output_contains "Commit cancelled"

    # Files should still be staged
    local remaining
    remaining=$(git diff --staged --name-only)
    [ -n "$remaining" ]
}

@test "aicommit proceeds with all-in-one commit when user selects default/Y option" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    echo "console.log('scripts');" > scripts/validate.js
    git add eslint.config.js scripts/validate.js

    export AI_MODEL="test-model"
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"all in one commit"}'

    # Send Enter (default = Y) to select all-in-one, then 'y' to confirm the commit message
    run aicommit <<< $'\ny'
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"

    local commit_count
    commit_count=$(git rev-list --count HEAD)
    [ "$commit_count" -eq 1 ]

    local log_msg
    log_msg=$(git log -1 --pretty=%s)
    [ "$log_msg" = "chore: all in one commit" ]
}

@test "aicommit proceeds with multi-commits when user selects 'n' option" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    echo "console.log('scripts');" > scripts/validate.js
    git add eslint.config.js scripts/validate.js

    export AI_MODEL="test-model"
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"multi-commit split"}'

    # Send 'n' to select multi-commits, then confirm each commit
    run aicommit <<< $'n\ny\ny'
    [ "$status" -eq 0 ]
    assert_output_contains "All atomic commits completed!"

    local commit_count
    commit_count=$(git rev-list --count HEAD)
    [ "$commit_count" -ge 2 ]
}

@test "aicommit proceeds with all-in-one commit when user selects '1' option" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    echo "console.log('scripts');" > scripts/validate.js
    git add eslint.config.js scripts/validate.js

    export AI_MODEL="test-model"
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"all in one commit with 1"}'

    # Send '1' to select all-in-one, then 'y' to confirm the commit message
    run aicommit <<< $'1\ny'
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"

    local commit_count
    commit_count=$(git rev-list --count HEAD)
    [ "$commit_count" -eq 1 ]

    local log_msg
    log_msg=$(git log -1 --pretty=%s)
    [ "$log_msg" = "chore: all in one commit with 1" ]
}

@test "aicommit rejects conflicting --split and --no-split options" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    git add eslint.config.js

    run aicommit --split --no-split
    [ "$status" -eq 1 ]
    assert_output_contains "Conflicting options"
}

@test "aicommit --split --yes splits and auto-commits all scopes without prompts" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    echo "console.log('scripts');" > scripts/validate.js
    git add eslint.config.js scripts/validate.js

    export AI_MODEL="test-model"
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"split auto commit"}'

    run aicommit --split --yes
    [ "$status" -eq 0 ]
    assert_output_contains "All atomic commits completed!"

    local commit_count
    commit_count=$(git rev-list --count HEAD)
    [ "$commit_count" -ge 2 ]
}

@test "aicommit validates ollama presence upfront once before analysis" {
    mkdir -p scripts
    echo "console.log('config');" > eslint.config.js
    git add eslint.config.js

    mock_bin "curl" "exit 1"

    run aicommit
    [ "$status" -eq 1 ]
    assert_output_contains "Ollama is not running"
}


