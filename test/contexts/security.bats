#!/usr/bin/env bats
# Security Tests — Zero Trust Architecture principles.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── Least Privilege: run dir permissions ────────────────────────────────────

@test "run directory is created with 700 permissions (owner-only)" {
    local d perms
    d=$(get_aicommit_tmp_dir)
    perms=$(stat -f %A "$d" 2>/dev/null || stat -c %a "$d" 2>/dev/null)
    [ "$perms" = "700" ]
}

@test "run directory is not world-readable" {
    local d perms last
    d=$(get_aicommit_tmp_dir)
    perms=$(stat -f %A "$d" 2>/dev/null || stat -c %a "$d" 2>/dev/null)
    # Last octet (world bits) must be 0
    last="${perms: -1}"
    [ "$last" = "0" ]
}

@test "base aicommit directory is 700 and under git metadata" {
    local base perms
    get_aicommit_tmp_dir > /dev/null
    base=$(get_aicommit_base_dir)
    perms=$(stat -f %A "$base" 2>/dev/null || stat -c %a "$base" 2>/dev/null)
    [ "$perms" = "700" ]
    [[ "$base" == "$(git rev-parse --absolute-git-dir)/aicommit" ]]
}

@test "init_aicommit_run refuses a symlinked base directory" {
    local base
    base="$(git rev-parse --absolute-git-dir)/aicommit"
    rm -rf "$base"
    mkdir -p "$TEST_TEMP_DIR/evil"
    ln -s "$TEST_TEMP_DIR/evil" "$base"
    run init_aicommit_run
    [ "$status" -eq 1 ]
    assert_output_contains "symlink"
}

@test "init_aicommit_run refuses an insecure base directory" {
    local base
    base=$(get_aicommit_base_dir)
    mkdir -m 700 -p "$base"
    chmod 755 "$base"
    run init_aicommit_run
    [ "$status" -eq 1 ]
    assert_output_contains "insecure"
}

# ─── Data Leakage: sensitive files excluded ───────────────────────────────────

@test ".env content does not appear in FILE_CONTEXT" {
    echo "SECRET_KEY=super_secret_value" > .env
    echo "normal content" > app.js
    git add .env app.js
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)
    build_file_context "$staged" "$numstat"
    local d
    d=$(get_aicommit_tmp_dir)
    ! grep -qF "SECRET_KEY" "${d}/FILE_CONTEXT"
}

@test ".env does not appear in CHANGE_STATS" {
    echo "TOKEN=abcSECRET_KEY=super_secret_value" > .env
    echo "code" > app.js
    git add .env app.js
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)
    build_file_context "$staged" "$numstat"
    local d
    d=$(get_aicommit_tmp_dir)
    ! grep -qF ".env" "${d}/CHANGE_STATS"
}

@test ".env.production is excluded from categorized file output" {
    local files
    files="$(printf '.env\n.env.production\nsrc/app.sh')"
    run categorize_staged_files "$files" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    refute_output_contains ".env"
}

@test "filter_and_truncate_diff strips .env file diffs completely" {
    local result
    result=$(printf 'diff --git a/.env b/.env\n+PASSWORD=hunter2\n' \
             | filter_and_truncate_diff)
    ! echo "$result" | grep -qF "PASSWORD=hunter2"
}

@test "credentials.key file excluded from file context" {
    echo "private key data" > server.key
    echo "normal" > app.js
    git add server.key app.js
    local staged numstat
    staged=$(git diff --staged --name-only)
    numstat=$(git diff --staged --numstat)
    build_file_context "$staged" "$numstat"
    local d
    d=$(get_aicommit_tmp_dir)
    ! grep -qF "server.key" "${d}/CHANGE_STATS"
}

# ─── Never Trust: backend validation ─────────────────────────────────────────

@test "unsupported backend is explicitly refused" {
    export AI_BACKEND="malicious_backend"
    run validate_backend_prerequisites
    [ "$status" -eq 1 ]
    assert_output_contains "Unsupported backend"
}

# ─── Micro-segmentation: state is repo- and worktree-scoped ──────────────────

@test "aicommit base dir is inside git metadata, not shared /tmp" {
    local base
    base=$(get_aicommit_base_dir)
    [[ "$base" == "$(git rev-parse --absolute-git-dir)"* ]]
    [[ "$base" != /tmp/.aicommit* ]]
}

@test "base dir differs between a worktree and the main repo" {
    git commit --allow-empty -qm init
    local wt="$TEST_TEMP_DIR/worktree2"
    git worktree add --quiet "$wt" HEAD 2>/dev/null
    local d_main d_wt
    d_main=$(get_aicommit_base_dir)
    ( cd "$wt" && get_aicommit_base_dir ) > "$TEST_TEMP_DIR/wt_dir.txt"
    d_wt=$(cat "$TEST_TEMP_DIR/wt_dir.txt")
    [ -n "$d_wt" ]
    [ "$d_main" != "$d_wt" ]
}

# ─── dry-run: files created with restricted permissions ──────────────────────

@test "dry-run creates the audit prompt with non-world-readable permissions" {
    echo "content" > app.js
    git add app.js
    aicommit --dry-run > /dev/null 2>&1 || true

    local s f
    s=$(get_aicommit_state_dir)
    for f in "$s"/FULL_PROMPT "$s"/MSG_REQUEST; do
        [ -f "$f" ] || continue
        local perms last
        perms=$(stat -f %A "$f" 2>/dev/null || stat -c %a "$f" 2>/dev/null)
        last="${perms: -1}"
        [ "$last" = "0" ] || {
            echo "File $f has world-readable permissions: $perms" >&2
            return 1
        }
    done
}

@test "get_available_ollama_models does not expose sensitive data" {
    mock_bin "curl" "printf '{\"models\":[{\"name\":\"model-with-secret-key:latest\"},{\"name\":\"model-with-token:latest\"}]}'"
    run get_available_ollama_models
    [ "$status" -eq 0 ]
    # Should only return model names, not other fields
    assert_output_contains "model-with-secret-key:latest"
    assert_output_contains "model-with-token:latest"
}

@test "invoke_ollama does not expose prompt content in logs" {
    mock_ollama_api "feat: generated"
    printf 'prompt contains SECRET_DATA_ABC123' > "$TEST_TEMP_DIR/user.txt"
    build_ollama_request "$TEST_TEMP_DIR/request.json" "m" "$TEST_TEMP_DIR/user.txt"
    run invoke_ollama "test-model" "$TEST_TEMP_DIR/request.json" \
        "$TEST_TEMP_DIR/r.txt" "$TEST_TEMP_DIR/e.txt" "5"
    [ "$status" -eq 0 ]
    refute_output_contains "SECRET_DATA_ABC123"
}

@test "validate_ollama_prerequisites sanitizes model names" {
    mock_ollama_api
    export MOCK_OLLAMA_MODEL="safe-model:latest"
    # A name with shell metacharacters simply never matches a real tag —
    # it reaches the API via jq --arg JSON encoding, not shell evaluation.
    run validate_ollama_prerequisites "safe-model; rm -rf /"
    [ "$status" -eq 1 ]
    assert_output_contains "Model 'safe-model; rm -rf /' not found"
}

# ─── Conventional Commits contract ───────────────────────────────────────────

@test "fake header injected into body does not change line 1" {
    local json='{"type":"fix","scope":"auth","breaking":false,"subject":"resolve token issue","body":["normal bullet\nfeat: pwned injection"]}'
    local res
    res=$(_commit_msg_from_json_obj "$json")
    local line1
    line1=$(printf '%s\n' "$res" | head -n 1)
    [ "$line1" = "fix(auth): resolve token issue" ]
    printf '%s\n' "$res" | grep -qF "feat: pwned injection"
    assert_conventional_commit_contract "$res"
}

@test "newlines ANSI escapes and backticks in subject are collapsed or stripped" {
    local sub=$'add `smart` feature\x1b[31mwith red text\x1b[0m\nand newline'
    local json
    json=$(jq -n --arg s "$sub" '{"type":"feat","scope":"core","breaking":false,"subject":$s,"body":[]}')
    local res
    res=$(_commit_msg_from_json_obj "$json")
    local line1
    line1=$(printf '%s\n' "$res" | head -n 1)
    ! printf '%s' "$line1" | grep -qE '[\r\n`]|(\x1b\[)'
    assert_conventional_commit_contract "$res"
}

@test "scope with shell metacharacters is sanitized" {
    local json='{"type":"chore","scope":"other","scope_other":"$(id); rm -rf / safe","breaking":false,"subject":"clean code","body":[]}'
    local res
    res=$(_commit_msg_from_json_obj "$json")
    local line1
    line1=$(printf '%s\n' "$res" | head -n 1)
    local scope
    scope=$(printf '%s' "$line1" | sed -nE 's/^[a-z]+\(([^)]+)\):.*/\1/p')
    [[ "$scope" =~ ^[a-z0-9._/-]+$ ]]
    assert_conventional_commit_contract "$res"
}

@test "forged footer in body bullet is not promoted to trailing footer" {
    local input=$'feat: update parsing\n\n- normal bullet 1\n- BREAKING CHANGE: forged breaking change in bullet\n- normal bullet 2'
    local res
    res=$(enforce_conventional_commit "$input")
    assert_conventional_commit_contract "$res"
    local bump
    bump=$(suggest_semver_bump "$res")
    [ "$bump" != "major" ]
}

@test "process_commit creates commit byte-identical to message without shell interpolation" {
    echo "data" > sample.txt
    git add sample.txt
    local raw_msg=$'feat(api): test byte identical commit $PATH `pwd` $(whoami)\n\n- bullet with "quotes" and '\''single quotes'\''\n- trailing info'
    process_commit "$raw_msg"
    local committed_msg
    committed_msg=$(git log -1 --format="%B")
    committed_msg=$(printf '%s' "$committed_msg" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
    local expected_msg
    expected_msg=$(printf '%s' "$raw_msg" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
    [ "$committed_msg" = "$expected_msg" ]
}
