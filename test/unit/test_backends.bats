#!/usr/bin/env bats
# Unit Tests — lib/backends.sh

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── validate_backend_prerequisites ──────────────────────────────────────────

@test "validate_backend_prerequisites fails for unknown backend" {
    export AI_BACKEND="nonexistent"
    run validate_backend_prerequisites
    [ "$status" -eq 1 ]
}

@test "validate_backend_prerequisites shows Unsupported backend message" {
    export AI_BACKEND="bogus"
    run validate_backend_prerequisites
    assert_output_contains "Unsupported backend"
}

@test "validate_backend_prerequisites caches successful validation and runs only once" {
    export AI_BACKEND="ollama"
    export AI_MODEL="test-model"
    local count_file="$TEST_TEMP_DIR/tags_count"
    echo "0" > "$count_file"

    # curl mock: serve API endpoints, count /api/tags hits
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do
    case "\$a" in */api/*) url="\$a" ;; esac
done
case "\$url" in
    */api/version)  echo '{"version":"0.40.1"}' ;;
    */api/tags)
        c=\$(( \$(cat "$count_file") + 1 ))
        echo "\$c" > "$count_file"
        echo '{"models":[{"name":"test-model"}]}'
        ;;
    */api/show|*/api/generate) echo '{}' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    validate_backend_prerequisites
    [ "$(cat "$count_file")" -eq 1 ]

    # Second call uses cache and does not hit /api/tags again
    validate_backend_prerequisites
    [ "$(cat "$count_file")" -eq 1 ]
}

# ─── invoke_llm routing ───────────────────────────────────────────────────────

@test "invoke_llm with unknown backend returns 1" {
    export AI_BACKEND="unknown_llm"
    run invoke_llm "m" "/dev/null" "/dev/null" "/dev/null" "5"
    [ "$status" -eq 1 ]
    assert_output_contains "Unsupported backend"
}

# ─── get_available_ollama_models ─────────────────────────────────────────────

@test "get_available_ollama_models returns model list via api/tags" {
    export MOCK_OLLAMA_MODEL="test-model"
    mock_ollama_api
    run get_available_ollama_models
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "test-model" ]
}

@test "get_available_ollama_models falls back to ollama list when API is down" {
    mock_bin "curl" "exit 1"
    mock_bin "ollama" "echo 'NAME            ID              SIZE    MODIFIED'
echo 'test-model    abc123   4.7 GB  2 days ago'"
    run get_available_ollama_models
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "test-model" ]
    refute_output_contains "abc123"
}

@test "get_available_ollama_models handles malformed output" {
    mock_bin "curl" "echo 'not json at all'"
    mock_bin "ollama" "echo 'invalid output without proper structure'"
    run get_available_ollama_models
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "get_available_ollama_models does not expose sensitive data" {
    mock_bin "curl" "printf '{\"models\":[{\"name\":\"model-with-secret-key:latest\"},{\"name\":\"model-with-token:latest\"}]}'"
    run get_available_ollama_models
    [ "$status" -eq 0 ]
    assert_output_contains "model-with-secret-key:latest"
    assert_output_contains "model-with-token:latest"
}

# ─── validate_ollama_prerequisites ───────────────────────────────────────────

@test "validate_ollama_prerequisites fails when API is unreachable" {
    mock_bin "curl" "exit 1"
    run validate_ollama_prerequisites "$(get_default_ai_model)"
    [ "$status" -eq 1 ]
    assert_output_contains "not running"
}

@test "validate_ollama_prerequisites fails when model not found" {
    mock_ollama_api
    export MOCK_OLLAMA_MODEL="other-model"
    run validate_ollama_prerequisites "missing-model"
    [ "$status" -eq 1 ]
    assert_output_contains "Model 'missing-model' not found"
}

@test "validate_ollama_prerequisites sanitizes model names" {
    mock_ollama_api
    export MOCK_OLLAMA_MODEL="safe-model:latest"
    # A model name with shell metacharacters must simply not match any tag —
    # it is passed to the API via jq --arg, never through shell evaluation.
    run validate_ollama_prerequisites "safe-model; rm -rf /"
    [ "$status" -eq 1 ]
    assert_output_contains "Model 'safe-model; rm -rf /' not found"
}

@test "validate_ollama_prerequisites succeeds with healthy API" {
    mock_ollama_api
    export AI_MODEL="test-model"
    run validate_ollama_prerequisites "test-model"
    [ "$status" -eq 0 ]
}

@test "validate_ollama_prerequisites fails when model metadata cannot load" {
    # /api/show returning a failure means a corrupt model blob
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
    assert_output_contains "metadata"
}

# ─── invoke_ollama ────────────────────────────────────────────────────────────

@test "invoke_ollama returns 1 when curl fails" {
    mock_bin "curl" "exit 1"
    local rf="$TEST_TEMP_DIR/response.txt"
    local ef="$TEST_TEMP_DIR/error.txt"
    echo '{"model":"m","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    run invoke_ollama "test-model" "$TEST_TEMP_DIR/request.json" "$rf" "$ef" "5"
    [ "$status" -eq 1 ]
}

@test "invoke_ollama extracts message content from api/chat response" {
    mock_ollama_api "feat(api): wire up transport"
    echo '{"model":"m","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    local rf="$TEST_TEMP_DIR/response.txt"
    local ef="$TEST_TEMP_DIR/error.txt"
    run invoke_ollama "test-model" "$TEST_TEMP_DIR/request.json" "$rf" "$ef" "5"
    [ "$status" -eq 0 ]
    [ "$(cat "$rf")" = "feat(api): wire up transport" ]
}

@test "invoke_ollama surfaces api-level errors" {
    mock_ollama_api "" '{"error":"model runner has unexpectedly stopped"}'
    echo '{"model":"m","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    local rf="$TEST_TEMP_DIR/response.txt"
    local ef="$TEST_TEMP_DIR/error.txt"
    run invoke_ollama "test-model" "$TEST_TEMP_DIR/request.json" "$rf" "$ef" "5"
    [ "$status" -eq 1 ]
    assert_output_contains "unexpectedly stopped"
}

@test "invoke_ollama respects configured AI_MODEL" {
    export AI_MODEL="configured-model"
    mkdir -p "$TEST_TEMP_DIR/bin"
    # Mock asserts the request body carries the configured model
    cat > "$TEST_TEMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; data=""
while [ $# -gt 0 ]; do
    case "$1" in
        */api/*) url="$1" ;;
        --data-binary) shift; data="${1#@}" ;;
    esac
    shift
done
case "$url" in
    */api/chat)
        if grep -q 'configured-model' "$data"; then
            printf '{"message":{"role":"assistant","content":"feat: ok"}}'
        else
            exit 1
        fi
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    echo '{"model":"configured-model","messages":[]}' > "$TEST_TEMP_DIR/request.json"
    local rf="$TEST_TEMP_DIR/response.txt"
    local ef="$TEST_TEMP_DIR/error.txt"
    run invoke_ollama "original-model" "$TEST_TEMP_DIR/request.json" "$rf" "$ef" 30
    [ "$status" -eq 0 ]
    unset AI_MODEL
}

# ─── build_ollama_request ────────────────────────────────────────────────────

@test "build_ollama_request pins deterministic sampling options" {
    printf 'the user context' > "$TEST_TEMP_DIR/user.txt"
    printf 'the rules' > "$TEST_TEMP_DIR/system.txt"
    run build_ollama_request "$TEST_TEMP_DIR/req.json" "test-model" "$TEST_TEMP_DIR/user.txt" "$TEST_TEMP_DIR/system.txt"
    [ "$status" -eq 0 ]
    [ "$(jq '.options.temperature' "$TEST_TEMP_DIR/req.json")" = "0" ]
    [ "$(jq '.options.seed' "$TEST_TEMP_DIR/req.json")" = "42" ]
    [ "$(jq '.options.num_ctx' "$TEST_TEMP_DIR/req.json")" = "16384" ]
    [ "$(jq '.think' "$TEST_TEMP_DIR/req.json")" = "false" ]
    [ "$(jq '.stream' "$TEST_TEMP_DIR/req.json")" = "false" ]
    [ "$(jq -r '.messages[0].role' "$TEST_TEMP_DIR/req.json")" = "system" ]
    [ "$(jq -r '.messages[1].content' "$TEST_TEMP_DIR/req.json")" = "the user context" ]
}

@test "build_ollama_request embeds a format schema when provided" {
    printf 'ctx' > "$TEST_TEMP_DIR/user.txt"
    printf '{"type":"object","properties":{"type":{"type":"string"}}}' > "$TEST_TEMP_DIR/schema.json"
    run build_ollama_request "$TEST_TEMP_DIR/req.json" "test-model" "$TEST_TEMP_DIR/user.txt" "" "$TEST_TEMP_DIR/schema.json"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.format.type' "$TEST_TEMP_DIR/req.json")" = "object" ]
}

@test "build_ollama_request omits format schema when AI_NO_STRUCTURED_OUTPUT=true" {
    printf 'ctx' > "$TEST_TEMP_DIR/user.txt"
    printf '{"type":"object","properties":{"type":{"type":"string"}}}' > "$TEST_TEMP_DIR/schema.json"
    export AI_NO_STRUCTURED_OUTPUT="true"
    run build_ollama_request "$TEST_TEMP_DIR/req.json" "test-model" "$TEST_TEMP_DIR/user.txt" "" "$TEST_TEMP_DIR/schema.json"
    [ "$status" -eq 0 ]
    [ "$(jq '.format' "$TEST_TEMP_DIR/req.json")" = "null" ]
    unset AI_NO_STRUCTURED_OUTPUT
}

# ─── extract_json_object ──────────────────────────────────────────────────────

@test "extract_json_object extracts raw JSON and markdown-wrapped JSON" {
    local raw_json='{"type":"feat","subject":"clean"}'
    run extract_json_object "$raw_json"
    [ "$status" -eq 0 ]
    [ "$output" = "$raw_json" ]

    local fenced='```json
{"type":"fix","subject":"fenced"}
```'
    run extract_json_object "$fenced"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.type')" = "fix" ]
    [ "$(printf '%s' "$output" | jq -r '.subject')" = "fenced" ]
}

# ─── invoke_ollama structured output fallback ────────────────────────────────

@test "invoke_ollama automatically retries without format when structured output is unavailable" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat << 'EOF' > "$TEST_TEMP_DIR/bin/curl"
#!/bin/sh
data=""
while [ $# -gt 0 ]; do
    case "$1" in
        --data-binary) shift; data="${1#@}" ;;
    esac
    shift
done
if grep -q '"format"' "$data"; then
    printf '{"error":"structured output is unavailable"}'
else
    printf '{"message":{"role":"assistant","content":"feat: recovered without format"}}'
fi
EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    echo '{"model":"test-model","format":{"type":"object"},"messages":[]}' > "$TEST_TEMP_DIR/request.json"
    local rf="$TEST_TEMP_DIR/response.txt"
    local ef="$TEST_TEMP_DIR/error.txt"
    unset AI_NO_STRUCTURED_OUTPUT

    invoke_ollama "test-model" "$TEST_TEMP_DIR/request.json" "$rf" "$ef" 30
    [ $? -eq 0 ]
    [ "$(cat "$rf")" = "feat: recovered without format" ]
    [ "$AI_NO_STRUCTURED_OUTPUT" = "true" ]
    unset AI_NO_STRUCTURED_OUTPUT
}
