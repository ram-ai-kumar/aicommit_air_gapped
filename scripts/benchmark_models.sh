#!/usr/bin/env bash
# aicommit — Model Benchmark Script
# Evaluates Ollama models on commit diffs from repo history.
# Measures cold/warm latency, schema validity, grounding pass rate, and type accuracy.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AICOMMIT_DIR="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
export AICOMMIT_DIR

source "${AICOMMIT_DIR}/config/defaults.sh"
source "${AICOMMIT_DIR}/lib/backends.sh"
source "${AICOMMIT_DIR}/lib/core.sh"
source "${AICOMMIT_DIR}/lib/context-analyzer.sh"

MODELS=(
    "qwen3.5:4b"
    "qwen3.5:9b-q8_0"
    "qwen2.5-coder:14b"
    "qwen2.5-coder:latest"
)

# Allow models override via CLI args
if [ $# -gt 0 ]; then
    MODELS=("$@")
fi

# Select 5 fixture commits from history
SHAS=($(git log -n 5 --pretty=format:"%H"))
if [ ${#SHAS[@]} -eq 0 ]; then
    echo "Error: No git history found in current repository."
    exit 1
fi

echo "================================================================="
echo " aicommit Model Benchmark"
echo " Evaluating models: ${MODELS[*]}"
echo " Over 5 commit fixtures from history: ${SHAS[*]}"
echo "================================================================="
printf "\n"

printf "%-22s | %-8s | %-8s | %-9s | %-9s | %-10s | %-9s | %-7s | %-9s | %-8s\n" \
    "Model" "Cold(s)" "Warm(s)" "Schema OK" "Ground OK" "Type Match" "Strict OK" "Repairs" "Fallbacks" "Total(s)"
echo "-----------------------------------------------------------------------------------------------------------------"

for model in "${MODELS[@]}"; do
    (
        export AI_MODEL="$model"
        # Check if model is available in Ollama
        if ! validate_ollama_prerequisites "$model" >/dev/null 2>&1; then
            printf "%-22s | %-80s\n" "$model" "[SKIPPED: model not pulled or Ollama down]"
            exit 0
        fi

        cold_time="-"
        total_warm_time=0
        warm_count=0
        schema_ok_count=0
        ground_ok_count=0
        type_match_count=0
        strict_ok_count=0
        repair_calls=0
        fallback_count=0
        total_e2e_time=0
        idx=0

        for sha in "${SHAS[@]}"; do
            idx=$((idx + 1))
            orig_msg=$(git log -1 --pretty=format:"%s" "$sha")
            orig_type=$(printf '%s\n' "$orig_msg" | sed -nE 's/^([a-z]+)(\([^)]*\))?!?: .*/\1/p')

            # Prepare diff and file list in temporary test directory
            bench_dir=$(mktemp -d "${TMPDIR:-/tmp}/aicommit_bench.XXXXXX")
            diff_content=$(git show --format="" "$sha")
            staged_names=$(git show --name-only --format="" "$sha" | awk 'NF')
            numstat_data=$(git show --numstat --format="" "$sha" | awk 'NF')

            build_ai_context "$diff_content" "$staged_names" "$numstat_data" "" "$bench_dir" >/dev/null 2>&1

            schema_file="${bench_dir}/SCHEMA.json"
            req_file="${bench_dir}/REQUEST.json"
            resp_file="${bench_dir}/RESPONSE.json"
            err_file="${bench_dir}/ERROR.txt"

            _build_commit_schema "$schema_file" "$bench_dir"
            build_ollama_request "$req_file" "$model" "${bench_dir}/CHANGES_CONTEXT" "$AI_PROMPT_FILE" "$schema_file"

            # Time inference
            start_ts=$(/usr/bin/python3 -c 'import time; print(time.time())' 2>/dev/null || perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s)
            inv_ok=true
            invoke_ollama "$model" "$req_file" "$resp_file" "$err_file" 180 "Benchmark $model" >/dev/null 2>&1 || inv_ok=false
            infer_end_ts=$(/usr/bin/python3 -c 'import time; print(time.time())' 2>/dev/null || perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s)
            elapsed=$(awk "BEGIN {printf \"%.2f\", $infer_end_ts - $start_ts}")

            if [ "$idx" -eq 1 ]; then
                cold_time="$elapsed"
            else
                total_warm_time=$(awk "BEGIN {print $total_warm_time + $elapsed}")
                warm_count=$((warm_count + 1))
            fi

            if [ "$inv_ok" = true ] && [ -s "$resp_file" ]; then
                raw_resp=$(cat "$resp_file")
                # Verify schema
                if printf '%s' "$raw_resp" | jq -e 'type == "object" and has("type") and has("subject")' >/dev/null 2>&1; then
                    schema_ok_count=$((schema_ok_count + 1))
                fi

                # Assemble and check initial grounding
                assembled_msg=$(_assemble_commit_message "$resp_file" "$bench_dir")
                if validate_commit_grounding "$assembled_msg" "$bench_dir" >/dev/null 2>&1; then
                    ground_ok_count=$((ground_ok_count + 1))
                fi

                # Run through candidate finalizer for strict check, repairs, and fallback tracking
                final_msg=$(_finalize_candidate "$raw_resp" "$bench_dir")

                if [ -f "${bench_dir}/REPAIR_COUNT" ]; then
                    rep_c=$(cat "${bench_dir}/REPAIR_COUNT" 2>/dev/null || echo 0)
                    repair_calls=$((repair_calls + rep_c))
                fi

                if [ -f "${bench_dir}/TEMPLATE_FALLBACK" ]; then
                    fallback_count=$((fallback_count + 1))
                fi

                if is_strict_conventional_commit "$final_msg" "$bench_dir" >/dev/null 2>&1; then
                    strict_ok_count=$((strict_ok_count + 1))
                fi

                gen_type=$(printf '%s\n' "$final_msg" | head -1 | sed -nE 's/^([a-z]+)(\([^)]*\))?!?: .*/\1/p')
                if [ -n "$orig_type" ] && [ "$gen_type" = "$orig_type" ]; then
                    type_match_count=$((type_match_count + 1))
                fi
            fi

            fixture_end_ts=$(/usr/bin/python3 -c 'import time; print(time.time())' 2>/dev/null || perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s)
            fixture_elapsed=$(awk "BEGIN {printf \"%.2f\", $fixture_end_ts - $start_ts}")
            total_e2e_time=$(awk "BEGIN {print $total_e2e_time + $fixture_elapsed}")

            rm -rf "$bench_dir"
        done

        avg_warm="-"
        if [ "$warm_count" -gt 0 ]; then
            avg_warm=$(awk "BEGIN {printf \"%.2f\", $total_warm_time / $warm_count}")
        fi
        total_e2e_fmt=$(awk "BEGIN {printf \"%.2f\", $total_e2e_time}")

        printf "%-22s | %-8s | %-8s | %-9s | %-9s | %-10s | %-9s | %-7s | %-9s | %-8s\n" \
            "$model" \
            "${cold_time}s" \
            "${avg_warm}s" \
            "${schema_ok_count}/5" \
            "${ground_ok_count}/5" \
            "${type_match_count}/5" \
            "${strict_ok_count}/5" \
            "${repair_calls}" \
            "${fallback_count}/5" \
            "${total_e2e_fmt}s"
    )
done

echo "================================================================="
