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
    local count_file="$TEST_TEMP_DIR/load_count"
    echo "0" > "$count_file"

    pgrep() { return 0; }
    ollama() {
        case "$1" in
            list) echo "NAME ID SIZE MODIFIED"; echo "test-model abc 1GB 1d ago" ;;
            run)
                local cur
                cur=$(cat "$count_file")
                echo $((cur + 1)) > "$count_file"
                return 0
                ;;
        esac
    }
    export -f pgrep ollama
    export AI_MODEL="test-model"

    # First call runs the checks and caches the result
    validate_backend_prerequisites
    [ "$(cat "$count_file")" -eq 1 ]

    # Second call uses cache and does not re-run test_model_loadability
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

@test "get_available_ollama_models returns model list" {
    local default_model
    default_model=$(get_default_ai_model)
    ollama() {
        echo "NAME            ID              SIZE    MODIFIED"
        echo "$default_model    abc123   4.7 GB  2 days ago"
    }
    export -f ollama

    run get_available_ollama_models
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$default_model" ]
}

@test "get_available_ollama_models handles malformed output" {
    ollama() {
        echo "invalid output without proper structure"
    }
    export -f ollama

    run get_available_ollama_models
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "get_available_ollama_models does not expose sensitive data" {
    ollama() {
        echo "NAME            ID              SIZE    MODIFIED"
        echo "model-with-secret-key:latest    secret123   4.7 GB  2 days ago"
        echo "model-with-token:latest       token456    2.3 GB  1 week ago"
    }
    export -f ollama

    run get_available_ollama_models
    [ "$status" -eq 0 ]
    assert_output_contains "model-with-secret-key:latest"
    assert_output_contains "model-with-token:latest"
    refute_output_contains "secret123"
    refute_output_contains "token456"
}

# ─── test_model_loadability ──────────────────────────────────────────────────

@test "test_model_loadability with successful model" {
    ollama() {
        if [ "$1" = "run" ] && [ "$2" = "test-model" ]; then
            echo "OK"
            return 0
        fi
        return 1
    }
    export -f ollama

    run test_model_loadability "test-model"
    [ "$status" -eq 0 ]
}

@test "test_model_loadability with failing model" {
    ollama() {
        if [ "$1" = "run" ] && [ "$2" = "test-model" ]; then
            return 1
        fi
    }
    export -f ollama

    run test_model_loadability "test-model"
    [ "$status" -eq 1 ]
}

@test "test_model_loadability handles timeout" {
    timeout() {
        return 124
    }
    export -f timeout

    run test_model_loadability "slow-model"
    [ "$status" -eq 1 ]
}

@test "test_model_loadability does not expose prompt content in logs" {
    ollama() {
        echo "Running model with prompt: 'secret data'" >&2
        echo "OK"
        return 0
    }
    export -f ollama

    run test_model_loadability "test-model"
    [ "$status" -eq 0 ]
    refute_output_contains "secret data"
}

# ─── validate_ollama_prerequisites ───────────────────────────────────────────

@test "validate_ollama_prerequisites fails when ollama process not found" {
    mock_bin "pgrep" "exit 1"
    run validate_ollama_prerequisites "$(get_default_ai_model)"
    [ "$status" -eq 1 ]
    assert_output_contains "not running"
}

@test "validate_ollama_prerequisites fails when model not in list" {
    mock_bin "pgrep" "echo 12345; exit 0"
    mock_bin "ollama" "echo 'NAME  ID  SIZE'; exit 0"
    run validate_ollama_prerequisites "missing-model:latest"
    [ "$status" -eq 1 ]
    assert_output_contains "not found"
}

@test "validate_ollama_prerequisites fails when model cannot be loaded" {
    pgrep() {
        return 0
    }
    ollama() {
        if [ "$1" = "list" ]; then
            echo "NAME            ID              SIZE    MODIFIED"
            echo "huge-model:latest   abc123   16 GB  2 days ago"
        elif [ "$1" = "run" ]; then
            return 1
        fi
    }
    export -f pgrep ollama

    run validate_ollama_prerequisites "huge-model:latest"
    [ "$status" -eq 1 ]
}

@test "validate_ollama_prerequisites sanitizes model names" {
    pgrep() {
        return 0
    }
    ollama() {
        if [ "$1" = "list" ]; then
            echo "NAME            ID              SIZE    MODIFIED"
            echo "safe-model:latest           abc123   2.3 GB  1 day ago"
        elif [ "$1" = "run" ]; then
            echo "OK"
            return 0
        fi
    }
    export -f pgrep ollama

    run validate_ollama_prerequisites "safe-model; rm -rf /"
    [ "$status" -eq 1 ]
    assert_output_contains "Model 'safe-model; rm -rf /' not found"
}

# ─── invoke_ollama ────────────────────────────────────────────────────────────

@test "invoke_ollama returns 1 when ollama command fails" {
    mock_bin "ollama" "exit 1"
    local pf="$TEST_TEMP_DIR/prompt.txt"
    local rf="$TEST_TEMP_DIR/response.txt"
    local ef="$TEST_TEMP_DIR/error.txt"
    echo "test prompt" > "$pf"
    run invoke_ollama "test-model" "$pf" "$rf" "$ef" "5"
    [ "$status" -eq 1 ]
}

@test "invoke_ollama respects configured AI_MODEL" {
    export AI_MODEL="configured-model"

    ollama() {
        if [ "$1" = "run" ] && [ "$2" = "configured-model" ]; then
            echo "Generated commit message"
            return 0
        else
            return 1
        fi
    }
    export -f ollama

    local prompt_file="$TEST_TEMP_DIR/prompt_$RANDOM.txt"
    local response_file="$TEST_TEMP_DIR/response_$RANDOM.txt"
    local error_file="$TEST_TEMP_DIR/error_$RANDOM.txt"

    echo "test prompt" > "$prompt_file"

    run invoke_ollama "original-model" "$prompt_file" "$response_file" "$error_file" 30
    [ "$status" -eq 0 ]

    rm -f "$prompt_file" "$response_file" "$error_file"
    unset AI_MODEL
}
