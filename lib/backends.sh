#!/usr/bin/env bash
# aicommit — LLM Backend Abstraction Layer
#
# Ollama transport goes through the HTTP API (POST /api/chat) instead of
# `ollama run`. The CLI cannot set sampling options, so model defaults apply
# (for qwen3.5 that is temperature 1 / top_k 20 / presence_penalty 1.5 — a
# different message every run). The API lets us pin temperature, seed, top_k,
# num_ctx and a JSON-schema `format`, which is what makes output deterministic
# and schema-valid. Static content goes in the system message so Ollama can
# reuse its KV prefix cache across calls.

# Global cache to ensure presence of Ollama + LLM is only verified once per session
_AICOMMIT_PREREQS_CHECKED_MODEL=""

# Generic system prompt for calls that don't supply their own rules file
# (semver evaluation, ad-hoc prompts).
_AICOMMIT_DEFAULT_SYSTEM='You are a precise software engineering assistant. Follow the requested output format exactly. No preamble, no explanation, no markdown fences.'

_ollama_host() {
    printf '%s' "${OLLAMA_HOST:-http://127.0.0.1:11434}"
}

# All API traffic goes through here so timeouts are uniform.
_ollama_curl() {
    curl -sS --max-time "${AI_NETWORK_TIMEOUT:-15}" "$@"
}

# Validate backend prerequisites and model availability (cached per session)
validate_backend_prerequisites() {
    local backend="${AI_BACKEND:-ollama}"
    local model="${AI_MODEL:-$DEFAULT_AI_MODEL}"

    if [ -n "$_AICOMMIT_PREREQS_CHECKED_MODEL" ] && [ "$_AICOMMIT_PREREQS_CHECKED_MODEL" = "${backend}:${model}" ]; then
        return 0
    fi

    case "$backend" in
        ollama)
            validate_ollama_prerequisites "$model" || return 1
            ;;
        *)
            display_error "Unsupported backend: $backend" "Supported backends: ollama"
            return 1
            ;;
    esac

    _AICOMMIT_PREREQS_CHECKED_MODEL="${backend}:${model}"
    return 0
}

# Invoke LLM with unified interface
# Args: model, request_file (built by build_ollama_request), response_file,
#       error_file, timeout_secs, action_label (optional)
invoke_llm() {
    local model="$1"
    local request_file="$2"
    local response_file="$3"
    local error_file="$4"
    local timeout_secs="$5"
    local action_label="${6:-Generating commit message}"

    local backend="${AI_BACKEND:-ollama}"

    case "$backend" in
        ollama)
            invoke_ollama "$model" "$request_file" "$response_file" "$error_file" "$timeout_secs" "$action_label"
            ;;
        *)
            display_error "Unsupported backend: $backend" "Supported backends: ollama"
            return 1
            ;;
    esac
}

# Extract and validate a JSON object from raw LLM output.
# If the model wrapped the JSON in markdown code blocks (```json ... ```) or conversational
# text, lifts the outermost {...} span. Returns the JSON object or original text on failure.
# Args: $1=raw_text
extract_json_object() {
    local raw="$1"
    [ -z "$raw" ] && return 0
    if printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '%s' "$raw"
        return 0
    fi
    if command -v perl >/dev/null 2>&1; then
        local extracted
        extracted=$(printf '%s' "$raw" | perl -0777 -ne 'print $1 if /(\{.*\})/s')
        if [ -n "$extracted" ] && printf '%s' "$extracted" | jq -e 'type == "object"' >/dev/null 2>&1; then
            printf '%s' "$extracted"
            return 0
        fi
    fi
    printf '%s' "$raw"
    return 1
}

# Build a deterministic /api/chat request body with jq — no shell interpolation
# of prompt content.
# Args: out_file, model, user_content_file, system_file (optional),
#       format_schema_file (optional; constrains decoding to a JSON schema)
build_ollama_request() {
    local out_file="$1"
    local model="$2"
    local user_file="$3"
    local system_file="${4:-}"
    local format_file="${5:-}"

    [ -f "$user_file" ] || return 1
    command -v jq >/dev/null 2>&1 || {
        display_error "jq is required" "Install it with: brew install jq"
        return 1
    }

    local think=false
    [ "${AI_THINK:-false}" = "true" ] && think=true

    local system_json
    if [ -n "$system_file" ] && [ -f "$system_file" ]; then
        system_json=$(jq -n --rawfile s "$system_file" '$s')
    else
        system_json=$(jq -n --arg s "$_AICOMMIT_DEFAULT_SYSTEM" '$s')
    fi

    local format_json="null"
    if [ "${AI_NO_STRUCTURED_OUTPUT:-false}" != "true" ] && [ -n "$format_file" ] && [ -f "$format_file" ]; then
        format_json=$(cat "$format_file" 2>/dev/null || echo "null")
        # A malformed schema file must not produce a malformed request
        printf '%s' "$format_json" | jq -e 'type == "object"' >/dev/null 2>&1 || format_json="null"
    fi

    jq -n \
        --arg model "$model" \
        --argjson think "$think" \
        --argjson seed "${AI_SEED:-42}" \
        --argjson num_ctx "${AI_NUM_CTX:-16384}" \
        --argjson num_predict "${AI_NUM_PREDICT:-400}" \
        --argjson system "$system_json" \
        --argjson format "$format_json" \
        --rawfile user "$user_file" \
        '{
            model: $model,
            stream: false,
            think: $think,
            keep_alive: "15m",
            options: {
                temperature: 0,
                top_k: 1,
                top_p: 1,
                seed: $seed,
                presence_penalty: 0,
                repeat_penalty: 1,
                num_ctx: $num_ctx,
                num_predict: $num_predict
            },
            messages: [
                {role: "system", content: $system},
                {role: "user",   content: $user}
            ]
        } + (if $format != null then {format: $format} else {} end)' \
        > "$out_file"
}

# Ollama backend implementation

# Get list of available Ollama models via /api/tags, falling back to `ollama list`
get_available_ollama_models() {
    local names
    names=$(_ollama_curl "$(_ollama_host)/api/tags" 2>/dev/null | jq -r '.models[]?.name' 2>/dev/null)
    if [ -n "$names" ]; then
        printf '%s\n' "$names"
        return 0
    fi
    ollama list 2>/dev/null | awk 'NR>1 && NF>=2 {print $1}' || true
}

# Validate that the Ollama server is reachable and the model exists.
# Uses the HTTP API only — the installed client (0.33.x) is older than the
# server (0.40.x), so CLI flag/output detection is unreliable.
validate_ollama_prerequisites() {
    local model="$1"
    local host
    host=$(_ollama_host)

    if ! command -v jq >/dev/null 2>&1; then
        display_error "jq is required" "Install it with: brew install jq"
        return 1
    fi

    # Server reachable?
    if ! _ollama_curl "${host}/api/version" >/dev/null 2>&1; then
        display_error "Ollama is not running" "Start it with: ollama serve"
        return 1
    fi

    # Exact model-name match (no substring matching — 'foo' must not match 'foobar:latest').
    # A tagless name means ':latest' per Ollama convention.
    local tags
    tags=$(_ollama_curl "${host}/api/tags" 2>/dev/null)
    if ! printf '%s' "$tags" | jq -e --arg m "$model" \
        '.models[]? | select(.name == $m or .name == ($m + ":latest"))' >/dev/null 2>&1; then
        display_error "Model '$model' not found" "Pull it with: ollama pull $model"
        return 1
    fi

    # Metadata must parse — catches corrupt/partial model blobs.
    if ! jq -n --arg m "$model" '{model: $m}' | _ollama_curl \
            -X POST -H 'Content-Type: application/json' -d @- \
            "${host}/api/show" >/dev/null 2>&1; then
        display_error "Model '$model' metadata could not be loaded" "Try: ollama pull $model"
        return 1
    fi

    # Background warm-up: loads the model + keeps it resident for 15m while
    # git context is still being built, so the first real call skips load time.
    ( jq -n --arg m "$model" '{model: $m, prompt: "", keep_alive: "15m", stream: false, options: {num_predict: 1}}' \
        | _ollama_curl -X POST -H 'Content-Type: application/json' -d @- \
            "${host}/api/generate" >/dev/null 2>&1 & ) >/dev/null 2>&1 || true

    return 0
}

# POST a pre-built request body to /api/chat and extract .message.content.
# Args: model, request_file, response_file, error_file, timeout_secs, action_label
invoke_ollama() {
    local model="$1"
    local request_file="$2"
    local response_file="$3"
    local error_file="$4"
    local timeout_secs="$5"
    local action_label="${6:-Generating commit message}"

    # Use the configured AI_MODEL
    local current_model="${AI_MODEL:-$model}"
    local host
    host=$(_ollama_host)
    local raw_file="${response_file}.raw.json"

    : > "$error_file"
    : > "$raw_file"

    if [ ! -f "$request_file" ]; then
        display_error "LLM request file not found" "$request_file"
        return 1
    fi

    # Run curl in background to allow timeout and elapsed-time display
    {
        curl -sS --max-time "$timeout_secs" \
            -H 'Content-Type: application/json' \
            --data-binary @"$request_file" \
            "${host}/api/chat" > "$raw_file" 2> "$error_file" &
    } 2>/dev/null
    local curl_pid=$!

    local progress_dev="/dev/null"
    if (: > /dev/tty) 2>/dev/null; then
        progress_dev="/dev/tty"
    fi

    local elapsed=0
    printf "=> %s using $current_model..." "$action_label" > "$progress_dev"
    while kill -0 "$curl_pid" 2>/dev/null; do
        sleep 0.5
        elapsed=$((elapsed + 5)) # We add .5 seconds each time
        # Only print every second to reduce terminal noise
        if (( elapsed % 10 == 0 )); then
            printf "\r=> %s using $current_model... (%ds)" "$action_label" "$((elapsed / 10))" > "$progress_dev"
        fi
        if [ "$elapsed" -ge $((timeout_secs * 10)) ]; then
            kill "$curl_pid" 2>/dev/null
            wait "$curl_pid" 2>/dev/null
            printf "\r\033[K" > "$progress_dev"

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
    wait "$curl_pid" && local exit_code=0 || local exit_code=$?
    printf "\r\033[K" > "$progress_dev"

    local error_content
    error_content=$(cat "$error_file" 2>/dev/null || echo "")

    if [ $exit_code -ne 0 ]; then
        if echo "$error_content" | grep -qi -E "(memory|gpu|cuda|out of memory|oom|cannot allocate|insufficient)"; then
            display_error "Ollama generation failed (insufficient memory)" \
                "Model '$current_model' is too large for available RAM/GPU" \
                "" \
                "💡 Try freeing up RAM and retrying:" \
                "aicommit"
        elif echo "$error_content" | grep -qi -E "(connection refused|couldn't connect|failed to connect|could not resolve)"; then
            display_error "Ollama is not reachable at $host" "Start it with: ollama serve"
        else
            display_error "Ollama generation failed (exit $exit_code)" "Check diagnostic log: $error_file"
        fi
        return 1
    fi

    # The API reports model-side failures in the response body's .error field
    local api_error
    api_error=$(jq -r '.error // empty' "$raw_file" 2>/dev/null)
    if [ -n "$api_error" ]; then
        if echo "$api_error" | grep -qi "structured output is unavailable"; then
            if jq -e 'has("format")' "$request_file" >/dev/null 2>&1; then
                export AI_NO_STRUCTURED_OUTPUT=true
                local noformat_req="${request_file}.noformat"
                if jq 'del(.format)' "$request_file" > "$noformat_req" 2>/dev/null && mv "$noformat_req" "$request_file"; then
                    invoke_ollama "$model" "$request_file" "$response_file" "$error_file" "$timeout_secs" "$action_label"
                    return $?
                fi
            fi
        fi
        printf '%s\n' "$api_error" >> "$error_file"
        if echo "$api_error" | grep -qi -E "(memory|out of memory|oom|cannot allocate|insufficient|requires more system memory)"; then
            display_error "Ollama generation failed (insufficient memory)" \
                "Model '$current_model' is too large for available RAM/GPU"
        else
            display_error "Ollama API error" "$api_error"
        fi
        return 1
    fi

    if ! jq -r '.message.content // empty' "$raw_file" > "$response_file" 2>/dev/null || [ ! -s "$response_file" ]; then
        display_error "Ollama returned an empty or malformed response" "Check diagnostic log: $error_file"
        printf 'malformed api response: %s\n' "$(head -c 500 "$raw_file" 2>/dev/null)" >> "$error_file"
        return 1
    fi

    return 0
}
