#!/usr/bin/env bash
# aicommit — Phase Profiling Harness
# Usage: ./scripts/profile_phases.sh <sha> <single|split> [model]
# Evaluates latency, token counts, and flow execution times against historical commits
# in a throwaway clone with update-ref stubbed, writing TSV output.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AICOMMIT_DIR="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
export AICOMMIT_DIR

source "${AICOMMIT_DIR}/config/defaults.sh"

SHA="${1:-}"
FLOW="${2:-single}"
MODEL="${3:-${AI_MODEL:-$DEFAULT_AI_MODEL}}"

if [ -z "$SHA" ]; then
    echo "Usage: $0 <sha> [single|split] [model]" >&2
    echo "Example: $0 3e5a13e single qwen3.5:4b" >&2
    exit 1
fi

REPO_ROOT="$(git -C "$AICOMMIT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"

# Verify commit exists
if ! git -C "$REPO_ROOT" rev-parse --verify "${SHA}^{commit}" >/dev/null 2>&1; then
    echo "Error: Commit '${SHA}' not found in repository." >&2
    exit 1
fi
FULL_SHA=$(git -C "$REPO_ROOT" rev-parse "${SHA}^{commit}")

# Create throwaway clone
TMP_CLONE=$(mktemp -d "${TMPDIR:-/tmp}/aicommit_profile.XXXXXX")
trap 'rm -rf "$TMP_CLONE"' EXIT INT TERM

git clone -s -q "$REPO_ROOT" "$TMP_CLONE"

# Checkout parent and stage changes of target SHA
cd_and_stage() {
    (
        cd "$TMP_CLONE" || exit 1
        if git rev-parse --verify "${FULL_SHA}^" >/dev/null 2>&1; then
            git checkout -q "${FULL_SHA}^" 2>/dev/null
        else
            git checkout --orphan "orphan_profile" 2>/dev/null
            git rm -rf . >/dev/null 2>&1 || true
        fi
        git checkout -q "$FULL_SHA" -- . 2>/dev/null
        git add -A
    )
}

if ! cd_and_stage; then
    echo "Error: Failed to re-stage changes for ${SHA} in clone." >&2
    exit 1
fi

# Stub update-ref so refs are never advanced
STUB_BIN="${TMP_CLONE}/stub_bin"
mkdir -p "$STUB_BIN"
REAL_GIT=$(command -v git)
cat << EOF > "${STUB_BIN}/git"
#!/usr/bin/env bash
for arg in "\$@"; do
    if [ "\$arg" = "update-ref" ]; then
        exit 0
    fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "${STUB_BIN}/git"

# Prepare environment for run
export PATH="${STUB_BIN}:$PATH"
export AI_TRACE=true
export AI_MODEL="$MODEL"
export AICOMMIT_DIR="$AICOMMIT_DIR"

BASE_DIR="${TMP_CLONE}/.git/aicommit"
mkdir -m 700 -p "$BASE_DIR"
STATE_DIR="${BASE_DIR}/state"
mkdir -m 700 -p "$STATE_DIR"
rm -f "${STATE_DIR}/TRACE"

# Execute flow
START_TS=$(/usr/bin/python3 -c 'import time; print(time.time())' 2>/dev/null || perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s)

RUN_OUT="${TMP_CLONE}/run_output.log"
(
    cd "$TMP_CLONE" || exit 1
    if [ "$FLOW" = "split" ]; then
        bash "${AICOMMIT_DIR}/aicommit.sh" --yes --split --shortcut > "$RUN_OUT" 2>&1
    else
        bash "${AICOMMIT_DIR}/aicommit.sh" --yes --no-split --shortcut > "$RUN_OUT" 2>&1
    fi
)
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ] && [ -f "$RUN_OUT" ]; then
    cat "$RUN_OUT" >&2
fi

END_TS=$(/usr/bin/python3 -c 'import time; print(time.time())' 2>/dev/null || perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s)
TOTAL_WALL=$(awk "BEGIN {printf \"%.2f\", $END_TS - $START_TS}")

# Emit TSV
printf "SHA\tFLOW\tMODEL\tEXIT\tTOTAL_S\tACTION\tCALL_MS\tPROMPT_TOK\tPROMPT_EVAL_MS\tEVAL_TOK\tEVAL_MS\n"

if [ -f "${STATE_DIR}/TRACE" ] && [ -s "${STATE_DIR}/TRACE" ]; then
    while IFS=$'\t' read -r action wall_ms load p_cnt p_dur e_cnt e_dur; do
        [ -z "$action" ] && continue
        p_dur_ms=$(awk "BEGIN {printf \"%.1f\", $p_dur / 1000000}")
        e_dur_ms=$(awk "BEGIN {printf \"%.1f\", $e_dur / 1000000}")
        printf "%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "${SHA:0:7}" "$FLOW" "$MODEL" "$EXIT_CODE" "$TOTAL_WALL" \
            "$action" "$wall_ms" "$p_cnt" "$p_dur_ms" "$e_cnt" "$e_dur_ms"
    done < "${STATE_DIR}/TRACE"
else
    printf "%s\t%s\t%s\t%d\t%s\t%s\t-\t-\t-\t-\t-\n" \
        "${SHA:0:7}" "$FLOW" "$MODEL" "$EXIT_CODE" "$TOTAL_WALL" "total"
fi
