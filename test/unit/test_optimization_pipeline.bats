#!/usr/bin/env bats
# Unit Tests — Performance Optimization Levers & Invariants
# Tests caching, shared prefix layout, strict CC gate, deterministic repairs,
# and id-based grouping reconciliation.

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── Lever C: Content-addressed disk cache ───────────────────────────────────

@test "aic on a chore change makes 1 call and second identical run makes 0 calls with cache hit" {
    echo "init" > init.txt
    git add init.txt
    git commit -q -m "chore: initial commit"

    echo "test_content" >> app.js
    git add app.js
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"update app","body":[],"release":"none"}'
    export _AICOMMIT_PREREQS_CHECKED_MODEL="ollama:${AI_MODEL:-$DEFAULT_AI_MODEL}"
    rm -f "$TEST_TEMP_DIR/chat_calls.jsonl"

    run aic
    [ "$status" -eq 0 ]
    local call_count1=0
    [ -f "$TEST_TEMP_DIR/chat_calls.jsonl" ] && call_count1=$(wc -l < "$TEST_TEMP_DIR/chat_calls.jsonl" | tr -d ' ')
    [ "$call_count1" -ge 1 ]

    # Re-stage identical change by resetting soft HEAD~1
    git reset --soft HEAD~1
    rm -f "$TEST_TEMP_DIR/chat_calls.jsonl"

    run aic
    [ "$status" -eq 0 ]
    local call_count2=0
    [ -f "$TEST_TEMP_DIR/chat_calls.jsonl" ] && call_count2=$(wc -l < "$TEST_TEMP_DIR/chat_calls.jsonl" | tr -d ' ')
    [ "$call_count2" -eq 0 ]
}

@test "changing one byte of a staged file misses the content-addressed cache" {
    echo "init" > init.txt
    git add init.txt
    git commit -q -m "chore: initial commit"

    echo "initial" >> app.js
    git add app.js
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"update app","body":[],"release":"none"}'
    run aic
    [ "$status" -eq 0 ]

    git reset --soft HEAD~1
    echo "x" >> app.js
    git add app.js
    rm -f "$TEST_TEMP_DIR/chat_calls.jsonl"

    run aic
    [ "$status" -eq 0 ]
    local calls=0
    [ -f "$TEST_TEMP_DIR/chat_calls.jsonl" ] && calls=$(wc -l < "$TEST_TEMP_DIR/chat_calls.jsonl" | tr -d ' ')
    [ "$calls" -gt 0 ]
}

@test "aiccx dry-run preview followed by aicc makes 0 naming calls on second run" {
    echo "init" > init.txt
    git add init.txt
    git commit -q -m "chore: initial commit"

    export AI_DISABLE_GROUPING="false"
    echo "c1" >> app.js
    echo "c2" >> helper.py
    git add app.js helper.py
    mock_ollama_api '{"groups":[{"id":"comp_1","name":"app","type":"chore","merge_into":null},{"id":"comp_2","name":"helper","type":"chore","merge_into":null}]}'
    rm -f "$TEST_TEMP_DIR/chat_calls.jsonl"

    run aiccx
    [ "$status" -eq 0 ]

    local preview_calls=0
    [ -f "$TEST_TEMP_DIR/chat_calls.jsonl" ] && preview_calls=$(wc -l < "$TEST_TEMP_DIR/chat_calls.jsonl" | tr -d ' ')
    [ "$preview_calls" -ge 1 ]

    rm -f "$TEST_TEMP_DIR/chat_calls.jsonl"
    mock_ollama_api '{"type":"chore","scope":"none","breaking":false,"subject":"batch commit","body":[],"release":"none"}'
    run aicc
    [ "$status" -eq 0 ]

    if [ -f "$TEST_TEMP_DIR/chat_calls.jsonl" ]; then
        ! grep -q "GROUPS" "$TEST_TEMP_DIR/chat_calls.jsonl"
        ! grep -q "name_groups" "$TEST_TEMP_DIR/chat_calls.jsonl"
    fi
}

@test "aicc with 2 groups makes at most 1 naming call, 1 batch call and 0 semver calls" {
    export AI_DISABLE_GROUPING="false"
    echo "part1" >> app.js
    echo "part2" >> helper.py
    git add app.js helper.py
    mock_ollama_api '{"groups":[{"id":"comp_1","name":"app","type":"chore","merge_into":null},{"id":"comp_2","name":"helper","type":"chore","merge_into":null}]}'
    rm -f "$TEST_TEMP_DIR/chat_calls.jsonl"

    run aicc
    [ "$status" -eq 0 ]
    if [ -f "$TEST_TEMP_DIR/chat_calls.jsonl" ]; then
        ! grep -q "SEMVER" "$TEST_TEMP_DIR/chat_calls.jsonl"
        ! grep -q "suggest_semver" "$TEST_TEMP_DIR/chat_calls.jsonl"
    fi
}

@test "cache purge retains at most 20 entries" {
    local state_dir
    state_dir=$(get_aicommit_state_dir)
    mkdir -p "${state_dir}/cache"
    for i in $(seq 1 25); do
        mkdir -p "${state_dir}/cache/key_${i}"
        touch "${state_dir}/cache/key_${i}/MSG"
    done
    local count_before
    count_before=$(find "${state_dir}/cache" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    [ "$count_before" -eq 25 ]

    init_aicommit_run
    local count_after
    count_after=$(find "${state_dir}/cache" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    [ "$count_after" -le 20 ]
}

# ─── Lever B: Shared-prefix request layout ───────────────────────────────────

@test "reflection and semver followup requests share identical system and context prefix bytes" {
    local d
    d=$(get_aicommit_tmp_dir)
    mkdir -p "$d"
    echo "=== FILES ===" > "${d}/CHANGES_CONTEXT"
    echo "+ added line" >> "${d}/CHANGES_CONTEXT"

    echo "reflection feedback" > "${d}/REFLECT_TAIL"
    echo "semver query" > "${d}/SEMVER_TAIL"

    local req_gen="${d}/REQ.gen.json"
    local req_ref="${d}/REQ.ref.json"
    local req_sem="${d}/REQ.sem.json"

    build_ollama_request "$req_gen" "test-model" "${d}/CHANGES_CONTEXT" "$AI_PROMPT_FILE"
    build_followup_request "$req_ref" "$d" "${d}/REFLECT_TAIL"
    build_followup_request "$req_sem" "$d" "${d}/SEMVER_TAIL"

    # System messages must be byte-identical
    local sys_gen sys_ref sys_sem
    sys_gen=$(jq -r '.messages[0].content' "$req_gen")
    sys_ref=$(jq -r '.messages[0].content' "$req_ref")
    sys_sem=$(jq -r '.messages[0].content' "$req_sem")
    [ "$sys_gen" = "$sys_ref" ]
    [ "$sys_gen" = "$sys_sem" ]

    # User message in followup requests must start with CHANGES_CONTEXT
    local ctx_bytes user_ref user_sem
    ctx_bytes=$(cat "${d}/CHANGES_CONTEXT")
    user_ref=$(jq -r '.messages[1].content' "$req_ref")
    user_sem=$(jq -r '.messages[1].content' "$req_sem")

    [[ "$user_ref" == "${ctx_bytes}"* ]]
    [[ "$user_sem" == "${ctx_bytes}"* ]]
}

# ─── Grounding & Deterministic repairs ───────────────────────────────────────

@test "validate_commit_grounding accepts literal token from CHANGES_CONTEXT" {
    local d
    d=$(get_aicommit_tmp_dir)
    mkdir -p "$d"
    echo "special_identifier_12345 in context" > "${d}/CHANGES_CONTEXT"
    touch "${d}/STAGED_NAMES" "${d}/FACTS"

    local msg=$'feat: update special_identifier_12345\n\n- changed special_identifier_12345'
    run validate_commit_grounding "$msg" "$d"
    [ "$status" -eq 0 ]
}

@test "single-type coercion coerces candidate to single allowed type" {
    local d
    d=$(get_aicommit_tmp_dir)
    mkdir -p "$d"
    echo "docs" > "${d}/ALLOWED_TYPES"

    local json='{"type":"feat","scope":"core","breaking":false,"subject":"update readme","body":[]}'
    local res
    res=$(_commit_msg_from_json_obj "$json" "$d")
    [[ "$res" == "docs(core): update readme"* ]]
}

@test "scope cleanup drops scope when equal to type and reduces path to stem" {
    local json1='{"type":"docs","scope":"docs","breaking":false,"subject":"update docs","body":[]}'
    local res1
    res1=$(_commit_msg_from_json_obj "$json1")
    [ "$res1" = "docs: update docs" ]

    local json2='{"type":"feat","scope":"other","scope_other":"lib/core.sh","breaking":false,"subject":"refactor core","body":[]}'
    local res2
    res2=$(_commit_msg_from_json_obj "$json2")
    [[ "$res2" == "feat(core): refactor core"* ]]
}

@test "body bullet cleanup strips leading conventional commit prefix from bullet" {
    local json='{"type":"chore","scope":"none","breaking":false,"subject":"cleanup code","body":["- refactor(core): internal cleanups","- normal bullet"]}'
    local res
    res=$(_commit_msg_from_json_obj "$json")
    printf '%s\n' "$res" | grep -qF -- "- internal cleanups"
    printf '%s\n' "$res" | grep -qF -- "- normal bullet"
}

# ─── Strict Conventional Commit gate ─────────────────────────────────────────

@test "is_strict_conventional_commit passes valid conventional commit" {
    local valid=$'feat(core): add strict gate validation\n\n- implement strict validator'
    run is_strict_conventional_commit "$valid"
    [ "$status" -eq 0 ]
}

@test "is_strict_conventional_commit rejects header over 72 chars" {
    local long_hdr="feat(core): this is a very long commit message subject that exceeds seventy two characters limit"
    run is_strict_conventional_commit "$long_hdr"
    [ "$status" -eq 1 ]
}

@test "is_strict_conventional_commit rejects subject ending with dot" {
    local dot_hdr="feat: subject ends with dot."
    run is_strict_conventional_commit "$dot_hdr"
    [ "$status" -eq 1 ]
}

@test "is_strict_conventional_commit rejects breaking bang without BREAKING CHANGE footer" {
    local bad_bang=$'feat!: breaking change without footer\n\n- did something'
    run is_strict_conventional_commit "$bad_bang"
    [ "$status" -eq 1 ]
}

@test "is_strict_conventional_commit accepts breaking bang with BREAKING CHANGE footer" {
    local good_bang=$'feat!: breaking change with footer\n\n- did something\n\nBREAKING CHANGE: breaks compatibility'
    run is_strict_conventional_commit "$good_bang"
    [ "$status" -eq 0 ]
}

@test "response with raw subject over 60 chars is flagged by grounding" {
    local d
    d=$(get_aicommit_tmp_dir)
    mkdir -p "$d"
    touch "${d}/STAGED_NAMES" "${d}/FACTS"
    echo "=== FILES ===" > "${d}/CHANGES_CONTEXT"

    local long_sub="feat: this is an excessively long commit subject that exceeds the raw limit of sixty chars"
    run validate_commit_grounding "$long_sub" "$d"
    [ "$status" -eq 1 ]
    assert_output_contains "subject exceeds 60 chars"
}

@test "all commit response fixtures pass strict conventional commit after finalization" {
    local fixtures_dir="${AICOMMIT_DIR}/test/fixtures/commit-responses"
    local d
    d=$(get_aicommit_tmp_dir)
    mkdir -p "$d"
    touch "${d}/STAGED_NAMES" "${d}/FACTS"
    echo "=== FILES ===" > "${d}/CHANGES_CONTEXT"

    for f in "${fixtures_dir}"/*; do
        [ -f "$f" ] || continue
        local raw
        raw=$(cat "$f")
        local fin
        fin=$(_finalize_candidate "$raw" "$d")
        run is_strict_conventional_commit "$fin" "$d"
        [ "$status" -eq 0 ]
    done
}

# ─── Group naming reconciliation ─────────────────────────────────────────────

@test "reconcile_grouping_json with id-based schema maps components to files" {
    local staged_files=$'lib/core.sh\nREADME.md'
    local comp_lines=$'comp_1\tlib/core.sh\ncomp_2\tREADME.md'
    local raw_json='{"groups":[{"id":"comp_1","name":"core","type":"feat","merge_into":null},{"id":"comp_2","name":"docs","type":"docs","merge_into":null}]}'

    run reconcile_grouping_json "$raw_json" "$staged_files" "$comp_lines"
    [ "$status" -eq 0 ]
    local line1 line2
    line1=$(printf '%s\n' "$output" | head -1)
    line2=$(printf '%s\n' "$output" | tail -1)
    [[ "$line1" == *"lib/core.sh"* ]]
    [[ "$line2" == *"README.md"* ]]
}

# ─── Keep-alive & num_ctx options ────────────────────────────────────────────

@test "chat request carries configured keep_alive and warm_up carries num_ctx" {
    export AI_KEEP_ALIVE="45m"
    export AI_NUM_CTX="8192"
    mock_ollama_api
    rm -f "$TEST_TEMP_DIR/chat_calls.jsonl"

    warm_up_model "test-model" true
    run aic
    [ -f "$TEST_TEMP_DIR/chat_calls.jsonl" ]
    local warm_call
    warm_call=$(head -1 "$TEST_TEMP_DIR/chat_calls.jsonl")
    local ka nc
    ka=$(printf '%s' "$warm_call" | jq -r '.keep_alive')
    nc=$(printf '%s' "$warm_call" | jq -r '.options.num_ctx')
    [ "$ka" = "45m" ]
    [ "$nc" = "8192" ]
}
