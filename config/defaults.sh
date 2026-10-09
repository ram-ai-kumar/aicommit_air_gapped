#!/usr/bin/env bash
# aicommit — Default Configuration
# User overrides via ~/.aicommitrc take precedence.

# LLM
# LLM backend to use for inference (ollama)
AI_BACKEND="${AI_BACKEND:-ollama}"

# Default LLM model (single source of truth for the project)
# Official tag with a proper chat template (the unsloth raw import has a bare
# {{ .Prompt }} template — no system/user turns, so think:false is unreliable).
# Exported so child processes (e.g. bin wrappers, test mocks) see the default.
DEFAULT_AI_MODEL="${DEFAULT_AI_MODEL:-qwen3.5:4b}"
export DEFAULT_AI_MODEL

# LLM model to use for commit message generation (must be available in selected backend)
AI_MODEL="${AI_MODEL:-$DEFAULT_AI_MODEL}"

# Ollama HTTP endpoint (never hardcode credentials or hosts — override in ~/.aicommitrc)
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"

# Deterministic sampling — the whole point of the HTTP transport.
AI_SEED="${AI_SEED:-42}"
AI_NUM_CTX="${AI_NUM_CTX:-16384}"
AI_NUM_PREDICT="${AI_NUM_PREDICT:-400}"
AI_THINK="${AI_THINK:-false}"

# Bypass JSON schema decoding constraint if the backend/model does not support it
# (auto-detected when Ollama returns "structured output is unavailable")
AI_NO_STRUCTURED_OUTPUT="${AI_NO_STRUCTURED_OUTPUT:-false}"
export AI_NO_STRUCTURED_OUTPUT

# Generate per-group commit messages in one batched LLM call when splitting
AI_BATCH_MESSAGES="${AI_BATCH_MESSAGES:-true}"

# How many co-changes in git history (last 300 commits) count as a grouping edge
AI_COCHANGE_MIN="${AI_COCHANGE_MIN:-2}"

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

# Semantic Versioning & Git Tagging
# Enable automatic semver bump evaluation and application (false by default)
AI_SEMVER_BUMP="${AI_SEMVER_BUMP:-false}"
# Create Git tag when semver bump is applied (true by default)
AI_SEMVER_TAG="${AI_SEMVER_TAG:-true}"
# Git tag prefix (e.g. "v" produces v1.2.3, "" produces 1.2.3)
AI_SEMVER_TAG_PREFIX="${AI_SEMVER_TAG_PREFIX:-v}"
# Fallback bump level for chore/docs/refactor when bump is opted in (patch)
AI_SEMVER_DEFAULT_BUMP="${AI_SEMVER_DEFAULT_BUMP:-patch}"
# Default initial version when repo has no existing version files or tags
DEFAULT_INITIAL_VERSION="${DEFAULT_INITIAL_VERSION:-0.1.0}"
# Path to prompt template for AI-driven SemVer evaluation
AI_SEMVER_PROMPT_FILE="${AI_SEMVER_PROMPT_FILE:-$AICOMMIT_DIR/templates/semver-prompt.txt}"
# Use AI/LLM to evaluate SemVer if needed (when conventional commit is ambiguous or on request)
AI_SEMVER_USE_AI="${AI_SEMVER_USE_AI:-true}"
# Automatically update or create changelog on version release (true by default)
AI_SEMVER_CHANGELOG="${AI_SEMVER_CHANGELOG:-true}"
# Default changelog filename if no existing changelog is detected
AI_SEMVER_CHANGELOG_FILE="${AI_SEMVER_CHANGELOG_FILE:-CHANGELOG.md}"



