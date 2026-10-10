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
    export AI_REFLECTION_PROMPT_FILE="$AICOMMIT_DIR/templates/reflection-prompt.txt"

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
data_file=""
data_raw=""
prev=""
for a in "$@"; do
    case "$a" in */api/*) url="$a" ;; esac
    if [ "$prev" = "-d" ] || [ "$prev" = "--data" ] || [ "$prev" = "--data-binary" ]; then
        if [ "$a" = "@-" ] || [ "$a" = "-" ]; then
            data_raw=$(cat)
        elif [[ "$a" == @* ]]; then
            data_file="${a#@}"
        else
            data_raw="$a"
        fi
    fi
    prev="$a"
done
case "$url" in
    */api/version)   echo '{"version":"0.40.1"}' ;;
    */api/tags)      printf '{"models":[{"name":"%s"}]}' "${MOCK_OLLAMA_MODEL:-${AI_MODEL:-${DEFAULT_AI_MODEL:-test-model}}}" ;;
    */api/show)      echo '{}' ;;
    */api/generate)  echo '{}' ;;
    */api/chat)
        if [ -n "$TEST_TEMP_DIR" ]; then
            if [ -n "$data_file" ] && [ -f "$data_file" ]; then
                jq -c . "$data_file" 2>/dev/null >> "$TEST_TEMP_DIR/chat_calls.jsonl" || cat "$data_file" >> "$TEST_TEMP_DIR/chat_calls.jsonl"
            elif [ -n "$data_raw" ]; then
                printf '%s' "$data_raw" | jq -c . 2>/dev/null >> "$TEST_TEMP_DIR/chat_calls.jsonl" || printf '%s\n' "$data_raw" >> "$TEST_TEMP_DIR/chat_calls.jsonl"
            fi
        fi
        cat "$TEST_TEMP_DIR/mock_chat.json"
        ;;
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

# Return 0 if the message satisfies the Conventional Commits v1.0.0 contract
# and git 72-char limit across the full message.
assert_conventional_commit_contract() {
    local msg="$1"
    [ -z "$msg" ] && return 1

    # Rule 1 & 2: Header format and length
    local line1
    line1=$(printf '%s\n' "$msg" | head -n 1)

    # Header length must not exceed 72 characters
    [ "${#line1}" -le 72 ] || return 1

    # Header must not have a trailing dot
    [[ "$line1" != *\. ]] || return 1

    # Line 1 must match conventional commit format with lowercase type and single space after colon
    printf '%s' "$line1" | grep -qE \
        "^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: \S" || return 1

    # Scope must have no -N dedup suffix (e.g. core-2) and contain no spaces
    if printf '%s' "$line1" | grep -qE '\([a-z0-9._/-]*-[0-9]+\)'; then
        return 1
    fi

    # Total lines
    local total_lines
    total_lines=$(printf '%s\n' "$msg" | wc -l | tr -d ' ')

    # Rule 3: when there is more than one line, line 2 must be empty
    if [ "$total_lines" -gt 1 ]; then
        local line2
        line2=$(printf '%s\n' "$msg" | sed -n '2p')
        [ -z "$line2" ] || return 1
    fi

    # Rule 4: no two consecutive blank lines, and no trailing blank line
    local last_line
    last_line=$(printf '%s\n' "$msg" | tail -n 1)
    [ -n "$last_line" ] || return 1

    local has_consec
    has_consec=$(printf '%s\n' "$msg" | awk '
        BEGIN { prev_b = 0; bad = 0 }
        /^[[:space:]]*$/ {
            if (prev_b) bad = 1
            prev_b = 1
            next
        }
        { prev_b = 0 }
        END { print bad }
    ')
    [ "$has_consec" -eq 0 ] || return 1

    # Rule 5: footer lines form one trailing block with one blank line before it,
    # and BREAKING CHANGE must be uppercase
    local footer_err
    footer_err=$(printf '%s\n' "$msg" | awk '
        BEGIN { n = 0 }
        { lines[n++] = $0 }
        END {
            if (n <= 2) exit 0
            f_start = n
            for (i = n - 1; i >= 2; i--) {
                l = lines[i]
                if (l ~ /^[[:space:]]*$/) break
                if (l ~ /^[[:space:]]*breaking[ -]change(: | #)/) {
                    print "LOWERCASE_BREAKING"
                    exit 1
                }
                if (l ~ /^[[:space:]]*(BREAKING[ -]CHANGE|[A-Za-z-]+)(: | #)/) {
                    f_start = i
                } else {
                    break
                }
            }
            if (f_start < n) {
                if (f_start == 0 || lines[f_start - 1] !~ /^[[:space:]]*$/) {
                    print "NO_BLANK_BEFORE_FOOTERS"
                    exit 1
                }
                for (i = 2; i < f_start - 1; i++) {
                    if (lines[i] ~ /^[[:space:]]*(BREAKING[ -]CHANGE|[A-Za-z-]+)(: | #)/) {
                        print "DISCONTINUOUS_FOOTERS"
                        exit 1
                    }
                }
            }
            exit 0
        }
    ')
    [ -z "$footer_err" ] || return 1

    # Rule 6: if header has ! or BREAKING CHANGE: footer exists, suggest_semver_bump returns major
    if declare -f suggest_semver_bump >/dev/null 2>&1; then
        local is_major=false
        if printf '%s' "$line1" | grep -qE '^[a-z]+(\([a-z0-9._/-]+\))?!:'; then
            is_major=true
        fi
        if printf '%s\n' "$msg" | grep -qE '^BREAKING[ -]CHANGE:'; then
            is_major=true
        fi
        if [ "$is_major" = true ]; then
            local bump
            bump=$(suggest_semver_bump "$msg")
            [ "$bump" = "major" ] || return 1
        fi
    fi

    return 0
}

# Alias for backwards compatibility with existing test callers
verify_conventional_commit() {
    assert_conventional_commit_contract "$@"
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
    export -f assert_conventional_commit_contract
    export -f verify_conventional_commit
    export -f get_default_ai_model
fi
