#!/usr/bin/env bats
# Compliance Tests — Conventional Commits specification and audit trail.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── Standard commit types ────────────────────────────────────────────────────

@test "feat type is accepted" {
    verify_conventional_commit "feat: add OAuth2 support"
}

@test "fix type is accepted" {
    verify_conventional_commit "fix: resolve null pointer exception"
}

@test "docs type is accepted" {
    verify_conventional_commit "docs: update installation guide"
}

@test "style type is accepted" {
    verify_conventional_commit "style: apply prettier formatting"
}

@test "refactor type is accepted" {
    verify_conventional_commit "refactor: extract validation into helper"
}

@test "test type is accepted" {
    verify_conventional_commit "test: add unit tests for core module"
}

@test "chore type is accepted" {
    verify_conventional_commit "chore: update dependencies"
}

@test "perf type is accepted" {
    verify_conventional_commit "perf: cache db query results"
}

@test "ci type is accepted" {
    verify_conventional_commit "ci: add matrix strategy for multi-shell"
}

@test "build type is accepted" {
    verify_conventional_commit "build: migrate to esbuild"
}

@test "revert type is accepted" {
    verify_conventional_commit "revert: undo breaking auth change"
}

# ─── Scope syntax ─────────────────────────────────────────────────────────────

@test "scope in parentheses is accepted" {
    verify_conventional_commit "feat(auth): add session management"
}

@test "multi-word scope is accepted" {
    verify_conventional_commit "fix(user-profile): handle missing avatar"
}

@test "breaking change with ! is accepted" {
    verify_conventional_commit "feat(api)!: remove deprecated endpoint"
}

# ─── Invalid formats ─────────────────────────────────────────────────────────

@test "plain sentence without type is rejected" {
    run verify_conventional_commit "added new login feature"
    [ "$status" -eq 1 ]
}

@test "empty message is rejected" {
    run verify_conventional_commit ""
    [ "$status" -eq 1 ]
}

@test "uppercase type is rejected" {
    run verify_conventional_commit "FEAT: add something"
    [ "$status" -eq 1 ]
}

@test "type without description is rejected" {
    run verify_conventional_commit "feat:"
    [ "$status" -eq 1 ]
}

@test "type without colon is rejected" {
    run verify_conventional_commit "feat add something"
    [ "$status" -eq 1 ]
}

@test "unknown type is rejected" {
    run verify_conventional_commit "update: change some stuff"
    [ "$status" -eq 1 ]
}

# ─── Header length ───────────────────────────────────────────────────────────

@test "header at exactly 72 characters is accepted" {
    verify_conventional_commit "feat: $(printf 'a%.0s' {1..66})"
}

@test "header longer than 72 characters is rejected" {
    run verify_conventional_commit "feat: $(printf 'a%.0s' {1..67})"
    [ "$status" -eq 1 ]
}

# ─── Commit message generation audit ─────────────────────────────────────────

@test "process_commit records message verbatim in git log" {
    echo "code" > app.sh
    git add app.sh
    process_commit "feat(core): add shell support"
    local recorded
    recorded=$(git log --format="%s" -1)
    [ "$recorded" = "feat(core): add shell support" ]
}

@test "dry-run produces FULL_PROMPT audit file" {
    echo "code" > app.sh
    git add app.sh
    run aicommit --dry-run
    [ "$status" -eq 0 ]
    local s
    s=$(get_aicommit_state_dir)
    [ -f "${s}/FULL_PROMPT" ]
}

@test "FULL_PROMPT contains the changes context section" {
    echo "code" > app.sh
    git add app.sh
    run aicommit --dry-run
    [ "$status" -eq 0 ]
    local s
    s=$(get_aicommit_state_dir)
    grep -q "USER CONTEXT\|CHANGES" "${s}/FULL_PROMPT"
}
