#!/usr/bin/env bats
# Regression Tests — verify historical regressions remain fixed across all generation paths.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

FIXTURES_DIR="$(dirname "$BATS_TEST_FILENAME")/../fixtures/commit-responses"

replay_fixture_through_all_paths() {
    local fixture_file="$1"
    local raw d
    raw=$(cat "$fixture_file")
    d=$(get_aicommit_tmp_dir)

    # Path 1: _assemble_commit_message (single, covers aic)
    local out1
    out1=$(_assemble_commit_message "$fixture_file" "$d")
    assert_conventional_commit_contract "$out1"

    # Path 2: extract_conventional_commit (fallback)
    local out2
    out2=$(extract_conventional_commit "$raw")
    assert_conventional_commit_contract "$out2"

    # Path 3: _commit_msg_from_json_obj (batched aicc)
    local out3
    out3=$(_commit_msg_from_json_obj "$raw" "$d")
    assert_conventional_commit_contract "$out3"
}

# ─── Conventional Commits contract ───────────────────────────────────────────

@test "regression_d1716ed_body_merged_into_subject" {
    replay_fixture_through_all_paths "${FIXTURES_DIR}/d1716ed-merged-body.txt"
    local raw out
    raw=$(cat "${FIXTURES_DIR}/d1716ed-merged-body.txt")
    out=$(extract_conventional_commit "$raw")
    ! printf '%s\n' "$out" | grep -qF "logic Add lib/semver.sh"
    printf '%s\n' "$out" | grep -qE '^Add lib/semver\.sh'
}

@test "regression_bee1e0d_body_merged_into_subject" {
    replay_fixture_through_all_paths "${FIXTURES_DIR}/bee1e0d-merged-body.txt"
    local raw out
    raw=$(cat "${FIXTURES_DIR}/bee1e0d-merged-body.txt")
    out=$(extract_conventional_commit "$raw")
    ! printf '%s\n' "$out" | grep -qF "logic Add lib/semver.sh"
    printf '%s\n' "$out" | grep -qE '^Add lib/semver\.sh'
}

@test "regression_566f0af_dedup_scope_core_2" {
    replay_fixture_through_all_paths "${FIXTURES_DIR}/scope-dedup-suffix.json"
}

@test "regression_594c31d_overlong_subject_falls_to_template" {
    replay_fixture_through_all_paths "${FIXTURES_DIR}/long-subject-sentence.json"
}

@test "all fixture responses satisfy conventional commit contract across all paths" {
    local fixture
    for fixture in "${FIXTURES_DIR}"/*; do
        [ -f "$fixture" ] || continue
        replay_fixture_through_all_paths "$fixture"
    done
}
