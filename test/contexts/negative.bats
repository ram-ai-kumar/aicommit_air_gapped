#!/usr/bin/env bats
# Negative Tests — failure paths and rejection of invalid input.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── aicommit entry point ────────────────────────────────────────────────────

@test "aicommit --dry-run fails with no staged changes" {
    run aicommit --dry-run
    [ "$status" -eq 1 ]
    assert_output_contains "No staged changes"
}

@test "aicommit fails with an unknown option" {
    run aicommit --not-a-real-flag
    [ "$status" -eq 1 ]
}

@test "aicommit unknown option shows helpful message" {
    run aicommit --not-a-real-flag
    assert_output_contains "Unknown option"
}

# ─── aic entry point ─────────────────────────────────────────────────────────

@test "aic fails with no staged changes" {
    run aic
    [ "$status" -eq 1 ]
    assert_output_contains "No staged changes"
}

# ─── validate_backend_prerequisites ──────────────────────────────────────────

@test "validate_backend_prerequisites rejects unknown backend" {
    export AI_BACKEND="totally_bogus"
    run validate_backend_prerequisites
    [ "$status" -eq 1 ]
}

# ─── generate_commit_message ─────────────────────────────────────────────────

@test "generate_commit_message --dry-run fails when CHANGES_CONTEXT is missing" {
    local d
    d=$(get_aicommit_tmp_dir)
    rm -f "${d}/CHANGES_CONTEXT"
    run generate_commit_message --dry-run
    [ "$status" -eq 1 ]
}

@test "generate_commit_message --dry-run fails when CHANGES_CONTEXT is empty" {
    local d
    d=$(get_aicommit_tmp_dir)
    : > "${d}/CHANGES_CONTEXT"   # create but empty
    run generate_commit_message --dry-run
    [ "$status" -eq 1 ]
}

# ─── build_ai_context ────────────────────────────────────────────────────────

@test "build_ai_context returns 1 when staged_files is empty" {
    run build_ai_context "" "" ""
    [ "$status" -eq 1 ]
}

@test "build_ai_context shows No staged files error" {
    run build_ai_context "" "" ""
    assert_output_contains "No staged files"
}

# ─── validate_ollama_prerequisites ───────────────────────────────────────────

@test "validate_ollama_prerequisites fails when the API is down" {
    mock_bin "curl" "exit 1"
    run validate_ollama_prerequisites "$(get_default_ai_model)"
    [ "$status" -eq 1 ]
    assert_output_contains "not running"
}

@test "validate_ollama_prerequisites fails when the model metadata cannot load" {
    mock_ollama_api
    cat > "$TEST_TEMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in */api/*) url="$a" ;; esac; done
case "$url" in
    */api/version)  echo '{"version":"0.40.1"}' ;;
    */api/tags)     echo '{"models":[{"name":"test-model"}]}' ;;
    */api/show)     exit 1 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    run validate_ollama_prerequisites "test-model"
    [ "$status" -eq 1 ]
}

@test "validate_ollama_prerequisites fails when model not found" {
    mock_ollama_api
    export MOCK_OLLAMA_MODEL="other-model:latest"
    run validate_ollama_prerequisites "missing-model"
    [ "$status" -eq 1 ]
    assert_output_contains "Model 'missing-model' not found"
}

# ─── Conventional Commits contract ───────────────────────────────────────────

@test "validate_commit_grounding rejects header over 72 chars" {
    local d
    d=$(get_aicommit_tmp_dir)
    printf 'feat\n' > "${d}/ALLOWED_TYPES"
    run validate_commit_grounding "feat: $(printf 'a%.0s' {1..68})" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "header exceeds 72 chars"
}

@test "validate_commit_grounding rejects missing blank line 2" {
    local d
    d=$(get_aicommit_tmp_dir)
    printf 'feat\n' > "${d}/ALLOWED_TYPES"
    local msg="feat: update feature
line directly after header without blank line"
    run validate_commit_grounding "$msg" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "line 2 must be blank"
}

@test "validate_commit_grounding rejects missing space after colon" {
    local d
    d=$(get_aicommit_tmp_dir)
    printf 'feat\n' > "${d}/ALLOWED_TYPES"
    run validate_commit_grounding "feat:x" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "header is not a conventional commit"
}

@test "validate_commit_grounding rejects space before colon" {
    local d
    d=$(get_aicommit_tmp_dir)
    printf 'feat\n' > "${d}/ALLOWED_TYPES"
    run validate_commit_grounding "feat :x" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "header is not a conventional commit"
}

@test "validate_commit_grounding rejects message with no type" {
    local d
    d=$(get_aicommit_tmp_dir)
    printf 'feat\n' > "${d}/ALLOWED_TYPES"
    run validate_commit_grounding "just a random commit description" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "header is not a conventional commit"
}

@test "validate_commit_grounding rejects type outside ALLOWED_TYPES" {
    local d
    d=$(get_aicommit_tmp_dir)
    printf 'fix\n' > "${d}/ALLOWED_TYPES"
    run validate_commit_grounding "feat: add feature" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "type feat is not allowed"
}

@test "assert_conventional_commit_contract rejects literal d1716ed message" {
    local literal_d1716ed="feat(core): implement robust SemVer engine and comprehensive version comparison logic Add lib/semver.sh to support automatic detection of version strings across multiple ecosystems (Ruby, PHP, .NET, Java, Python) and integrate calculate_next_semver into the core workflow. This update enables automatic determination of Major, Minor, or Patch increments based on SemVer 2.0.0 rules by analyzing commit messages and diffs. Key additions include:

- semver_gt: A robust comparison function handling v prefixes, major.minor.patch structures, pre-release tags (e.g., -rc.1), and build metadata (e.g., +1). It correctly resolves precedence between core releases and pre-releases.
- Enhanced Changelog Integration: Updated logic to detect changelog files, manage updates, and restore previous states during semantic versioning operations.
- Release Bumping UI: Improved output formatting to clearly display the current version, the bump type, and the resulting label (e.g., \"MINOR (new feature)\").
- Test Coverage: Expanded unit tests in test/unit/test_semver.bats to validate version parsing, comparison logic, and the full release bumping lifecycle across different project types.

This change significantly improves the tool's ability to automate semantic versioning workflows for polyglot repositories."
    run assert_conventional_commit_contract "$literal_d1716ed"
    [ "$status" -eq 1 ]
}

@test "JSON with empty subject returns non-zero from assembly" {
    local d
    d=$(get_aicommit_tmp_dir)
    echo "test" > app.sh
    git add app.sh
    echo "app.sh" > "${d}/STAGED_NAMES"
    printf 'chore\n' > "${d}/ALLOWED_TYPES"
    local json='{"type":"chore","scope":"none","breaking":false,"subject":""}'
    run _commit_msg_from_json_obj "$json" "$d"
    [ "$status" -ne 0 ]

    local fallback
    fallback=$(template_commit_from_facts "$d")
    assert_conventional_commit_contract "$fallback"
}

@test "JSON with prefix-only subject returns non-zero from assembly" {
    local d
    d=$(get_aicommit_tmp_dir)
    echo "test" > app.sh
    git add app.sh
    echo "app.sh" > "${d}/STAGED_NAMES"
    printf 'feat\n' > "${d}/ALLOWED_TYPES"
    local json='{"type":"feat","scope":"none","breaking":false,"subject":"feat:"}'
    run _commit_msg_from_json_obj "$json" "$d"
    [ "$status" -ne 0 ]

    local fallback
    fallback=$(template_commit_from_facts "$d")
    assert_conventional_commit_contract "$fallback"
}

@test "hallucinated candidate message is corrected by reflection step" {
    echo "x" > app.js
    git add app.js
    local d
    d=$(get_aicommit_tmp_dir)
    build_ai_context "$(git diff --staged)" "$(git diff --staged --name-only)" "$(git diff --staged --numstat)" "" "$d"
    
    # Mock curl to return refined JSON on reflection
    mock_ollama_api '{"type":"feat","scope":"app","breaking":false,"subject":"add app.js","body":["initial app logic"]}'
    
    local refined
    run reflect_commit_message "feat: update nonexistent_file.js" "$d" "nonexistent_file.js is not in the diff"
    [ "$status" -eq 0 ]
    refined="$output"
    assert_conventional_commit_contract "$refined"
    run validate_commit_grounding "$refined" "$d"
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$refined" | grep -qF "nonexistent_file"
}
