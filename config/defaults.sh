#!/usr/bin/env bash
# aicommit — Default Configuration
# User overrides via ~/.aicommitrc take precedence.

# LLM
# LLM backend to use for inference (ollama)
AI_BACKEND="${AI_BACKEND:-ollama}"

# Default LLM model (single source of truth for the project)
DEFAULT_AI_MODEL="qwen3.5-9b-unsloth:latest"

# LLM model to use for commit message generation (must be available in selected backend)
AI_MODEL="${AI_MODEL:-$DEFAULT_AI_MODEL}"

# Path to custom prompt template for commit message generation
# Override in ~/.aicommitrc: AI_PROMPT_FILE="$HOME/.aicommit/templates/custom-prompt.txt"
AI_PROMPT_FILE="${AI_PROMPT_FILE:-$AICOMMIT_DIR/templates/prompt.txt}"

# Path to prompt template for logical context grouping
AI_GROUPING_PROMPT_FILE="${AI_GROUPING_PROMPT_FILE:-$AICOMMIT_DIR/templates/context-grouping-prompt.txt}"

# Enable AI model for logical scope grouping (true by default, falls back to heuristic)
AI_ENABLE_LLM_GROUPING="${AI_ENABLE_LLM_GROUPING:-true}"

# Timeout for LLM inference (seconds). Increase for large models or slow hardware.
# Override in ~/.aicommitrc: AI_TIMEOUT=240
AI_TIMEOUT="${AI_TIMEOUT:-120}"

# Circuit Breaker Timeouts (seconds)
AI_GIT_TIMEOUT="${AI_GIT_TIMEOUT:-30}"
AI_FILESYSTEM_TIMEOUT="${AI_FILESYSTEM_TIMEOUT:-10}"
AI_NETWORK_TIMEOUT="${AI_NETWORK_TIMEOUT:-15}"
AI_PROCESS_TIMEOUT="${AI_PROCESS_TIMEOUT:-5}"

# Circuit Breaker Thresholds
AI_LLM_FAILURE_THRESHOLD="${AI_LLM_FAILURE_THRESHOLD:-3}"
AI_CIRCUIT_RESET_TIME="${AI_CIRCUIT_RESET_TIME:-300}"

# Circuit Breaker Behavior
AI_ENABLE_CIRCUIT_BREAKERS="${AI_ENABLE_CIRCUIT_BREAKERS:-true}"
AI_GRACEFUL_DEGRADATION="${AI_GRACEFUL_DEGRADATION:-true}"
