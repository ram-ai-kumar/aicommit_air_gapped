#!/usr/bin/env bash
# aicommit Test Helper
# Shared utilities: environment setup, mocking, and BATS assertion helpers.

# Note: no set -euo pipefail here — BATS manages error propagation, and set -u
# would propagate into sourced lib scripts that expect unset variables to be empty.

# ─── State ───────────────────────────────────────────────────────────────────

TEST_TEMP_DIR=""
TEST_REPO_DIR=""
ORIGINAL_DIR=""
ORIGINAL_HOME=""

# ─── Environment Setup ───────────────────────────────────────────────────────

setup_test_env() {
    ORIGINAL_DIR="$(cd "$(pwd)" && pwd)"
    ORIGINAL_HOME="${HOME:-}"
    TEST_TEMP_DIR="/tmp/aicommit-test-$RANDOM-$$"
    export TEST_TEMP_DIR
    mkdir -p "$TEST_TEMP_DIR"
    export HOME="$TEST_TEMP_DIR"
    TEST_REPO_DIR="$TEST_TEMP_DIR/test_repo"

    mkdir -p "$TEST_REPO_DIR"
    cd "$TEST_REPO_DIR"
    git init --quiet
    git config user.name "Test User"
    git config user.email "test@example.com"
    # Disable global/system gitignore so tests can add .env and other files freely
    git config core.excludesFile /dev/null
    # Disable global/system git hooks so tests do not run slow external linters/scanners
    git config core.hooksPath /dev/null

    # Isolate aicommit install from real ~/.aicommit
    export AICOMMIT_DIR="$TEST_TEMP_DIR/aicommit"
    mkdir -p "$AICOMMIT_DIR"/{lib,config,templates,bin}
    cp -r "$ORIGINAL_DIR/lib"       "$AICOMMIT_DIR/"
    cp -r "$ORIGINAL_DIR/config"    "$AICOMMIT_DIR/"
    cp -r "$ORIGINAL_DIR/templates" "$AICOMMIT_DIR/"
    cp -r "$ORIGINAL_DIR/bin"       "$AICOMMIT_DIR/"
    chmod 755 "$AICOMMIT_DIR/bin/"* 2>/dev/null || true
    export PATH="$AICOMMIT_DIR/bin:$PATH"
    cp    "$ORIGINAL_DIR/aicommit.sh" "$AICOMMIT_DIR/"

    # Reset caches that survive between tests (set to empty, not unset — avoids
    # "unbound variable" errors when the lib is sourced under set -u contexts)
    export _AICOMMIT_REPO_NAME=""
    export _AICOMMIT_PREREQS_CHECKED_MODEL=""
    export _AICOMMIT_RUN_DIR=""
    export _AICOMMIT_BASE_DIR=""
    export _AICOMMIT_BASE_DIR_PWD=""
    export _AICOMMIT_LOCK_DIR=""

    # aicommit.sh references $ZSH_VERSION; guard against set -u failures in bash
    export ZSH_VERSION="${ZSH_VERSION:-}"

    # Disable live AI grouping in tests so unit tests test deterministic heuristics
    export AI_DISABLE_GROUPING="true"

    # Global mock for timeout to respect internal mocked functions
    timeout() {
        shift
        "$@"
    }
    export -f timeout

    source "$AICOMMIT_DIR/aicommit.sh"
}

cleanup_test_env() {
    cd "$ORIGINAL_DIR" 2>/dev/null || true
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    if [ -n "$ORIGINAL_HOME" ]; then
        export HOME="$ORIGINAL_HOME"
    fi
    unset TEST_TEMP_DIR TEST_REPO_DIR ORIGINAL_DIR ORIGINAL_HOME _AICOMMIT_REPO_NAME \
        _AICOMMIT_RUN_DIR _AICOMMIT_BASE_DIR _AICOMMIT_BASE_DIR_PWD _AICOMMIT_LOCK_DIR
}

# ─── Mock Helpers ────────────────────────────────────────────────────────────

# Install a mock binary into $TEST_TEMP_DIR/bin and prepend it to PATH.
# Usage: mock_bin "pgrep" "exit 1"
mock_bin() {
    local name="$1"
    local body="$2"
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/usr/bin/env bash\n%s\n' "$body" > "$TEST_TEMP_DIR/bin/$name"
    chmod +x "$TEST_TEMP_DIR/bin/$name"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# Install a mock `curl` that emulates the Ollama HTTP API endpoints the backend
# uses: /api/version, /api/tags, /api/show, /api/generate (warm-up), /api/chat.
# Usage: mock_ollama_api '<chat content string>' ['<raw chat response json>']
# The model name served by /api/tags is
# ${MOCK_OLLAMA_MODEL:-${AI_MODEL:-${DEFAULT_AI_MODEL:-test-model}}}, read at
# request time — so export AI_MODEL before OR after this call. Set
# MOCK_OLLAMA_MODEL explicitly to pin a name (e.g. the /api/tags list tests).
# To simulate an API-level error, pass raw='{"error":"..."}'.
mock_ollama_api() {
    local content="${1:-}" raw="${2:-}"
    [ -z "$content" ] && content='{"type":"chore","scope":"none","scope_other":"","breaking":false,"subject":"mock commit","body":[]}'
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '%s' "$content" > "$TEST_TEMP_DIR/mock_content.txt"
    if [ -n "$raw" ]; then
        printf '%s' "$raw" > "$TEST_TEMP_DIR/mock_chat.json"
    else
        jq -n --rawfile c "$TEST_TEMP_DIR/mock_content.txt" \
            '{message:{role:"assistant",content:$c}}' > "$TEST_TEMP_DIR/mock_chat.json"
    fi
    cat > "$TEST_TEMP_DIR/bin/curl" <<'MOCK_EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do
    case "$a" in */api/*) url="$a" ;; esac
done
case "$url" in
    */api/version)   echo '{"version":"0.40.1"}' ;;
    */api/tags)      printf '{"models":[{"name":"%s"}]}' "${MOCK_OLLAMA_MODEL:-${AI_MODEL:-${DEFAULT_AI_MODEL:-test-model}}}" ;;
    */api/show)      echo '{}' ;;
    */api/generate)  echo '{}' ;;
    */api/chat)      cat "$TEST_TEMP_DIR/mock_chat.json" ;;
    *) echo "mock curl: unexpected url '$url'" >&2; exit 1 ;;
esac
MOCK_EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

# ─── File Fixtures ───────────────────────────────────────────────────────────

create_test_files() {
    local kind="${1:-normal}"
    case "$kind" in
        normal)
            echo "console.log('hello');" > app.js
            echo "def main(): pass"       > app.py
            echo "# readme"               > README.md
            ;;
        sensitive)
            echo "SECRET_KEY=abc123"   > .env
            echo "API_TOKEN=xyz789"    > .env.production
            echo "password = secret"   > config.ini
            ;;
        large)
            for i in $(seq 1 200); do
                echo "line $i — padding content to make the diff large" >> large_file.sh
            done
            ;;
        special)
            echo "test" > "file with spaces.txt"
            echo "test" > "file-with-dashes.txt"
            echo "test" > "file_with_underscores.txt"
            ;;
    esac
}

# ─── Assertion Helpers (used with BATS $output / $status) ────────────────────

# Succeed when $output contains the given literal string.
assert_output_contains() {
    local expected="$1"
    if ! printf '%s' "$output" | grep -qF -- "$expected"; then
        printf 'Expected output to contain: %s\nActual output:\n%s\n' \
               "$expected" "$output" >&2
        return 1
    fi
}

# Succeed when $output does NOT contain the given literal string.
refute_output_contains() {
    local pattern="$1"
    if printf '%s' "$output" | grep -qF -- "$pattern"; then
        printf 'Expected output NOT to contain: %s\nActual output:\n%s\n' \
               "$pattern" "$output" >&2
        return 1
    fi
}

# ─── Compliance Helpers ───────────────────────────────────────────────────────

# Return 0 if the message matches Conventional Commits format and the header
# is at most 72 characters, matching the rule in templates/prompt.txt.
verify_conventional_commit() {
    local msg="$1"
    local first_line
    first_line=$(printf '%s' "$msg" | head -n 1)

    # Header length must not exceed 72 characters
    if [ "${#first_line}" -gt 72 ]; then
        return 1
    fi

    printf '%s' "$first_line" | grep -qE \
        "^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)(\(.+\))?!?: .+"
}

# ─── Default Model Helper ────────────────────────────────────────────────────

# Return the configured default model name. Tests should use this instead of
# hardcoding the model name, so the project has a single source of truth.
get_default_ai_model() {
    source "$AICOMMIT_DIR/config/defaults.sh"
    printf '%s' "$DEFAULT_AI_MODEL"
}

# ─── Exports (when sourced from BATS) ────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    export -f setup_test_env cleanup_test_env mock_bin mock_ollama_api
    export -f create_test_files
    export -f assert_output_contains refute_output_contains
    export -f verify_conventional_commit
    export -f get_default_ai_model
fi
