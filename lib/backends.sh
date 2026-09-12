#!/usr/bin/env bash
# LLM Backend Abstraction Layer
# Provides unified interface for different LLM backends

# Validate backend prerequisites and model availability
validate_backend_prerequisites() {
    local backend="${AI_BACKEND:-ollama}"
    local model="${AI_MODEL:-$DEFAULT_AI_MODEL}"

    case "$backend" in
        ollama)
            validate_ollama_prerequisites "$model"
            ;;
        *)
            display_error "Unsupported backend: $backend" "Supported backends: ollama"
            return 1
            ;;
    esac
}

# Invoke LLM with unified interface
# Args: model, prompt_file, response_file, error_file, timeout_secs
invoke_llm() {
    local model="$1"
    local prompt_file="$2"
    local response_file="$3"
    local error_file="$4"
    local timeout_secs="$5"

    local backend="${AI_BACKEND:-ollama}"

    case "$backend" in
        ollama)
            invoke_ollama "$model" "$prompt_file" "$response_file" "$error_file" "$timeout_secs"
            ;;
        *)
            display_error "Unsupported backend: $backend" "Supported backends: ollama"
            return 1
            ;;
    esac
}

# Ollama backend implementation

# Get list of available Ollama models
get_available_ollama_models() {
    ollama list 2>/dev/null | awk 'NR>1 && NF>=2 {print $1}' || true
}

# Test if a model can be loaded successfully
test_model_loadability() {
    local model="$1"
    local test_prompt="Say 'OK'"
    local timeout=30

    # Try to run the model with a simple test prompt
    if echo "$test_prompt" | timeout "$timeout" ollama run "$model" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

validate_ollama_prerequisites() {
    local model="$1"

    if ! pgrep -f "ollama" > /dev/null; then
        display_error "Ollama is not running" "Start it with: ollama serve"
        return 1
    fi

    # Check if model exists in Ollama
    if ! ollama list 2>/dev/null | grep -qF "$model"; then
        display_error "Model '$model' not found" "Pull it with: ollama pull $model"
        return 1
    fi

    # Test if the preferred model can be loaded
    if ! test_model_loadability "$model"; then
        return 1
    fi

    return 0
}

invoke_ollama() {
    local model="$1"
    local prompt_file="$2"
    local response_file="$3"
    local error_file="$4"
    local timeout_secs="$5"

    # Use the configured AI_MODEL
    local current_model="${AI_MODEL:-$model}"

    # Suppress thinking generation by default for reasoning models if supported
    local -a extra_args=()
    local think_setting="${AI_THINK:-false}"
    if [ "$think_setting" = "false" ] && ollama run --help 2>&1 | grep -q -- "--think"; then
        extra_args+=("--think=false")
    fi

    # Run ollama in background to allow timeout and elapsed-time display
    ollama run "${extra_args[@]}" "$current_model" < "$prompt_file" > "$response_file" 2> "$error_file" &
    local ollama_pid=$!

    local progress_dev="/dev/null"
    if [ -w /dev/tty ] 2>/dev/null; then
        progress_dev="/dev/tty"
    fi

    local elapsed=0
    printf "🧠 Generating commit message using $current_model..." > "$progress_dev"
    while kill -0 "$ollama_pid" 2>/dev/null; do
        sleep 0.5
        elapsed=$((elapsed + 5)) # We add .5 seconds each time
        # Only print every second to reduce terminal noise
        if (( elapsed % 10 == 0 )); then
            printf "\r🧠 Generating commit message using $current_model... (%ds)" "$((elapsed / 10))" > "$progress_dev"
        fi
        if [ "$elapsed" -ge $((timeout_secs * 10)) ]; then
            kill "$ollama_pid" 2>/dev/null
            wait "$ollama_pid" 2>/dev/null
            printf "\r\033[K" > "$progress_dev"

            # Check if this might be a memory issue
            local error_content
            error_content=$(cat "$error_file" 2>/dev/null || echo "")
            if echo "$error_content" | grep -qi -E "(memory|gpu|cuda|out of memory|oom|cannot allocate|insufficient)"; then
                display_error "Ollama timed out after ${timeout_secs}s (likely insufficient memory)" \
                    "Model '$current_model' may be too large for available RAM/GPU" \
                    "" \
                    "💡 Try:" \
                    "1. Free up system RAM and retry" \
                    "2. Check available models: ollama list"
            else
                display_error "Ollama timed out after ${timeout_secs}s" "Model may be slow — try: ollama run $current_model"
            fi
            return 1
        fi
    done
    wait "$ollama_pid"
    local exit_code=$?
    printf "\n" > "$progress_dev"

    if [ $exit_code -ne 0 ]; then
        local error_content
        error_content=$(cat "$error_file" 2>/dev/null || echo "")

        # Check for memory-related errors
        if echo "$error_content" | grep -qi -E "(memory|gpu|cuda|out of memory|oom|cannot allocate|insufficient)"; then
            display_error "Ollama generation failed (insufficient memory)" \
                "Model '$current_model' is too large for available RAM/GPU" \
                "" \
                "💡 Try freeing up RAM and retrying:" \
                "aicommit"
        else
            display_error "Ollama generation failed (exit $exit_code)" "Check diagnostic log: $error_file"
        fi
        return 1
    fi
}
