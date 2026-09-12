#!/usr/bin/env bash
# aicommit — Core Logic
# Orchestrates context building, prompt assembly, and LLM commit generation.

# Validate prerequisites using backend abstraction
validate_prerequisites() {
    validate_backend_prerequisites
    return 0
}

# Get temp directory scoped to current repo
get_aicommit_tmp_dir() {
    # Cache repo root to avoid repeated git calls
    if [ -z "$_AICOMMIT_REPO_NAME" ]; then
        export _AICOMMIT_REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")
    fi
    local tmp_dir="/tmp/.aicommit/${_AICOMMIT_REPO_NAME}"
    mkdir -m 700 -p "$tmp_dir" > /dev/null 2>&1
    echo "$tmp_dir"
}

# Build file context — writes FILE_CONTEXT, CHANGE_STATS, and FILE_COUNT to temp dir
# Args: $1=staged_files, $2=numstat_data
# Writes count to ${tmp_dir}/FILE_COUNT (avoids stdout pollution from zsh xtrace)
build_file_context() {
    local staged_files="$1"
    local numstat_data="$2"
    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir)

    # Restrict permissions for sensitive content
    umask 077

    # Zero-out owned files before writing — never use stale content
    : > "${tmp_dir}/FILE_CONTEXT"
    : > "${tmp_dir}/CHANGE_STATS"
    : > "${tmp_dir}/FILE_COUNT"

    local total_files=0
    local file_context=""
    local change_stats=""

    while IFS= read -r file; do
        # Use Bash internal trimming for significantly better performance than sed
        file="${file#"${file%%[![:space:]]*}"}"
        file="${file%"${file##*[![:space:]]}"}"
        # Remove carriage returns
        file="${file//$'\r'/}"
        [ -z "$file" ] && continue

        # Skip sensitive files from change statistics
        if echo "$file" | grep -qE "\.env$|\.env\.|config\.ini|.*secrets.*|.*credentials.*|.*\.key|.*\.pem|.*\.p12"; then
            total_files=$((total_files + 1))
            continue
        fi

        total_files=$((total_files + 1))

        local numstat_line lines_added lines_deleted file_ext file_type
        # Use grep for literal match to avoid awk field-splitting issues
        numstat_line=$(printf '%s\n' "$numstat_data" | grep -F $'\t'"${file}" | head -1)
        lines_added=$(printf '%s' "$numstat_line" | awk '{print $1}')
        lines_deleted=$(printf '%s' "$numstat_line" | awk '{print $2}')

        file_ext="${file##*.}"
        case "$file_ext" in
            js|ts|jsx|tsx) file_type="javascript/typescript" ;;
            py)            file_type="python" ;;
            sh|bash)       file_type="shell" ;;
            md|txt)        file_type="documentation" ;;
            json|yaml|yml) file_type="config" ;;
            html|css|scss) file_type="web" ;;
            rb)            file_type="ruby" ;;
            *)             file_type="$file_ext" ;;
        esac

        file_context="${file_context}
${file} (${file_type})"
        if [ -n "$lines_added" ] && [ -n "$lines_deleted" ]; then
            change_stats="${change_stats}
${file}: +${lines_added} -${lines_deleted} lines"
        fi
    done <<< "$staged_files"

    printf '%s' "$file_context" > "${tmp_dir}/FILE_CONTEXT"
    printf '%s' "$change_stats" > "${tmp_dir}/CHANGE_STATS"
    # Write count to file — avoids stdout pollution from zsh xtrace in subshell capture
    printf '%s' "$total_files" > "${tmp_dir}/FILE_COUNT"
}

# Filter diff by tier and truncate per-file. Reads from stdin, writes to stdout.
# Tier 1 (stat only)  — generated/binary/sensitive files: diff entirely excluded
# Tier 2 (20-line cap) — low-signal files: tests, docs, markdown
# Tier 3 (80-line cap) — full-signal files: source, config, migrations
filter_and_truncate_diff() {
    local sensitive_pattern='\.env$|\.env\.|config\.ini|.*secrets.*|.*credentials.*|.*\.key|.*\.pem|.*\.p12'

    awk -v sensitive="$sensitive_pattern" '
    BEGIN { tier = 3; max_lines = 80; file_lines = 0 }
    /^diff --git/ {
        if (file_lines > max_lines && max_lines > 0)
            printf "    ... (%d lines truncated)\n", (file_lines - max_lines)
        file = $NF; sub(/^b\//, "", file)
        file_lines = 0

        # Skip sensitive files entirely
        if (file ~ sensitive) {
            tier = 1; max_lines = 0
        }
        # Tier 1 — stat only
        if (file ~ /\.(lock|snap|pyc|class|map)$/ ||
            file ~ /lock\.(json|yaml|toml)$/ ||
            file ~ /\.(svg|png|jpg|jpeg|gif|ico|fig|webp|mp4|mp3|woff2?|ttf)$/ ||
            file ~ /\.min\.(js|css)$/ ||
            file ~ /_pb2\.py$/ || file ~ /\.pb\.go$/ ||
            file ~ /^dist\// || file ~ /\/dist\// ||
            file ~ /^build\// || file ~ /\/build\// ||
            file ~ /^out\// || file ~ /\/out\// ||
            file ~ /^\.next\// ||
            file ~ /^coverage\// || file ~ /\/coverage\// ||
            file ~ /^\.nyc_output\// ||
            file ~ /\.env$/ || file ~ /\.env\./) {
            tier = 1; max_lines = 0
        }
        # Tier 2 — low-signal, 20-line cap
        else if (file ~ /^tests?\// || file ~ /\/tests?\// ||
                 file ~ /^spec\// || file ~ /\/spec\// ||
                 file ~ /^__tests__\// ||
                 file ~ /\.(test|spec)\.(js|ts)$/ ||
                 file ~ /test_.*\.py$/ ||
                 file ~ /_test\.(py|go)$/ ||
                 file ~ /^docs?\// || file ~ /\/docs?\// ||
                 file ~ /\.(md|rst)$/ ||
                 file ~ /^README/ || file ~ /^CHANGELOG/ || file ~ /^CONTRIBUTING/) {
            tier = 2; max_lines = 20
        }
        # Tier 3 — full signal, 80-line cap
        else {
            tier = 3; max_lines = 80
        }
        if (tier >= 2) print
        next
    }
    {
        file_lines++
        if (tier >= 2 && file_lines <= max_lines) print
    }
    END {
        if (file_lines > max_lines && max_lines > 0)
            printf "    ... (%d lines truncated)\n", (file_lines - max_lines)
    }
    '
}

# Build AI context — writes CHANGES_CONTEXT to temp dir
# Args: $1=diff, $2=staged_files, $3=numstat_data
build_ai_context() {
    local changes="$1"
    local staged_files="$2"
    local numstat_data="$3"
    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir)

    # Restrict permissions for sensitive content
    umask 077

    # Zero-out owned file before writing — never use stale content
    : > "${tmp_dir}/CHANGES_CONTEXT"

    # Run build_file_context; read count from temp file to avoid xtrace stdout pollution
    build_file_context "$staged_files" "$numstat_data" > /dev/null 2>&1
    local total_files
    tmp_dir=$(get_aicommit_tmp_dir)
    total_files=$(cat "${tmp_dir}/FILE_COUNT" 2>/dev/null || echo "0")

    if [ "$total_files" -eq 0 ] 2>/dev/null || ! [ "$total_files" -gt 0 ] 2>/dev/null; then
        display_error "No staged files found"
        return 1
    fi

    # Filter out sensitive files from staged_files before processing
    local filtered_staged_files=""
    while IFS= read -r file; do
        if ! echo "$file" | grep -qE "\.env$|\.env\.|config\.ini|.*secrets.*|.*credentials.*|.*\.key|.*\.pem|.*\.p12"; then
            filtered_staged_files="${filtered_staged_files}${file}\n"
        fi
    done <<< "$staged_files"

    local file_context change_stats enhanced_context categories_context
    file_context=$(cat "${tmp_dir}/FILE_CONTEXT")
    change_stats=$(cat "${tmp_dir}/CHANGE_STATS")
    enhanced_context=$(build_enhanced_context "$filtered_staged_files" "$changes")
    categories_context=$(categorize_staged_files "$filtered_staged_files" "$tmp_dir")

    # Tier 1 patterns (stat only): generated, binary, sensitive — matches filter_and_truncate_diff tier 1
    local stat_only_ext='\.lock$|lock\.(json|yaml|toml)$|\.snap$|\.pyc$|\.class$|\.map$|_pb2\.py$|\.pb\.go$'
    local stat_only_assets='\.svg$|\.png$|\.jpg$|\.jpeg$|\.gif$|\.ico$|\.fig$|\.webp$|\.mp4$|\.mp3$|\.woff2?$|\.ttf$|\.min\.(js|css)$'
    local stat_only_dirs='^(dist|build|out|\.next|coverage|\.nyc_output)/|/(dist|build|coverage)/'
    local stat_only_env='\.env$|\.env\.|config\.ini|.*secrets.*|.*credentials.*|.*\.key|.*\.pem|.*\.p12'
    local stat_only_patterns="${stat_only_ext}|${stat_only_assets}|${stat_only_env}"
    local stat_only_files=""

    while IFS= read -r file; do
        if [ -n "$file" ] && { echo "$file" | grep -qE "$stat_only_patterns" || echo "$file" | grep -qE "$stat_only_dirs"; }; then
            stat_only_files="${stat_only_files}${file}\n"
        fi
    done <<< "$staged_files"

    # Single-pass tiered filter: excludes tier-1 diffs, caps tier-2 at 20 lines, tier-3 at 80 lines
    local changes_summary
    changes_summary=$(echo "$changes" | filter_and_truncate_diff)

    # Stat summary for tier-1 files (lets LLM infer dependency/asset changes without reading diff)
    local stat_only_stat=""
    if [ -n "$stat_only_files" ]; then
        stat_only_stat=$(printf '%b' "$stat_only_files" | sed '/^$/d' | while IFS= read -r sf; do
            local stat_line
            stat_line=$(echo "$numstat_data" | awk -v f="$sf" '$3 == f {printf "%s | +%s -%s\n", $3, $1, $2}')
            [ -n "$stat_line" ] && echo "$stat_line"
        done)
    fi

    local repo_name
    repo_name="${_AICOMMIT_REPO_NAME:-unknown}"

    local changes_context="=== REPOSITORY ===
${repo_name}

${categories_context}

=== CHANGE STATISTICS ===
${change_stats}

${enhanced_context}

=== CHANGES ===
${changes_summary}"

    if [ -n "$stat_only_stat" ]; then
        changes_context="${changes_context}

=== OMITTED DIFFS — stat only (generated/binary/sensitive) ===
${stat_only_stat}"
    fi

    # Add recent commit history for scope consistency (ignore new repos with no commits)
    local commit_history
    commit_history=$(git log --oneline -10 2>/dev/null) || true
    if [ -n "$commit_history" ]; then
        changes_context="${changes_context}

=== RECENT COMMITS (STYLE AND SCOPE REFERENCE ONLY - DO NOT DESCRIBE IN COMMIT) ===
${commit_history}"
    fi

    printf '%s' "$changes_context" > "${tmp_dir}/CHANGES_CONTEXT"
}

# Extract and sanitize clean conventional commit message from raw LLM output.
# Handles reasoning model thinking blocks (<think>...</think>, </think> without open tag,
# Thinking Process: preambles, duplicate keyword occurrences in draft vs final, etc.),
# delimiters (@@@, code fences), conventional commit anchor discovery, and normalization.
extract_conventional_commit() {
    local raw_input="$1"
    [ -z "$raw_input" ] && return 0

    # Step 1: Strip ANSI escape sequences and carriage returns
    local cleaned
    cleaned=$(printf '%s' "$raw_input" | tr -d '\r' | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g')

    # Step 2: Handle reasoning / thinking closing tags
    # If any closing tag (</think>, </thought>, </thinking>, </reasoning>) exists,
    # discard EVERYTHING up to and including the last closing tag.
    cleaned=$(printf '%s\n' "$cleaned" | awk '
        /<\/(think|thought|thinking|reasoning)>/ {
            sub(/.*<\/(think|thought|thinking|reasoning)>[[:space:]]*/, "")
            last_close_line = NR
            line_content = $0
        }
        {
            lines[NR] = $0
        }
        END {
            if (last_close_line > 0) {
                if (line_content != "") {
                    print line_content
                }
                for (i = last_close_line + 1; i <= NR; i++) {
                    print lines[i]
                }
            } else {
                for (i = 1; i <= NR; i++) {
                    print lines[i]
                }
            }
        }
    ')

    # Step 3: Remove any paired XML thinking blocks that might remain
    cleaned=$(printf '%s\n' "$cleaned" | awk '
        /<(think|thought|thinking|reasoning)>/ { in_block = 1; next }
        /<\/(think|thought|thinking|reasoning)>/ { in_block = 0; next }
        !in_block { print }
    ')

    # Step 4: Extract from @@@ delimiters if present
    local delimited
    delimited=$(printf '%s\n' "$cleaned" | awk '
        /^@@@([[:space:]]*)$/ {
            count++
            next
        }
        count == 1 {
            print
        }
        count >= 2 {
            exit
        }
    ')

    if [ -n "$(printf '%s' "$delimited" | tr -d '[:space:]')" ]; then
        cleaned="$delimited"
    else
        # Step 4b: Check for markdown code blocks (``` or ```commit or ```gitcommit)
        local code_block
        code_block=$(printf '%s\n' "$cleaned" | awk '
            /^```[a-zA-Z0-9_-]*[[:space:]]*$/ {
                count++
                next
            }
            count == 1 {
                print
            }
            count >= 2 {
                exit
            }
        ')
        if [ -n "$(printf '%s' "$code_block" | tr -d '[:space:]')" ]; then
            if printf '%s\n' "$code_block" | grep -qE '^[[:space:]]*(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)([(][^)]+[)])?!?: '; then
                cleaned="$code_block"
            fi
        fi
    fi

    # Step 5: Locate Conventional Commit header
    local commit_regex='^[[:space:]]*(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)([(][^)]+[)])?!?:[[:space:]].+'

    # Extract conventional commit block:
    # Handles multiple candidate headers (e.g. drafts in thinking) by tracking blocks.
    # Lines starting with bullet markers (- or * or +) are ALWAYS treated as body lines, never headers.
    local extracted
    extracted=$(printf '%s\n' "$cleaned" | awk -v pattern="$commit_regex" '
        BEGIN {
            header_count = 0
            curr_header = ""
            curr_body = ""
            in_body = 0
        }
        {
            line = $0
            trimmed = line
            sub(/^[[:space:]]+/, "", trimmed)

            # A bullet point line (- or * or +) is NEVER a commit header
            is_bullet = (trimmed ~ /^[-*+][[:space:]]/)

            candidate = trimmed
            sub(/^[Ss]ubject:[[:space:]]*/, "", candidate)

            # Check if this line is a conventional commit header candidate
            if (!is_bullet && candidate ~ pattern) {
                # Save previous block if any
                if (curr_header != "") {
                    headers[header_count] = curr_header
                    bodies[header_count] = curr_body
                    header_count++
                }
                curr_header = candidate
                curr_body = ""
                in_body = 1
                next
            }

            if (in_body) {
                # Stop if we hit trailing commentary or closing delimiters
                if (line ~ /^[[:space:]]*(@@@|```)/ ||
                    line ~ /^[[:space:]]*([Nn]ote|[Nn]otes|[Ee]xplanation|[Ss]ummary|[Cc]ommit [Mm]essage):/ ||
                    line ~ /^[[:space:]]*([Hh]ope this|[Tt]his commit|[Ll]et me know|[Ii] have generated)/) {
                    in_body = 0
                    next
                }
                curr_body = (curr_body == "") ? line : curr_body "\n" line
            }
        }
        END {
            if (curr_header != "") {
                headers[header_count] = curr_header
                bodies[header_count] = curr_body
                header_count++
            }

            if (header_count > 0) {
                # Use the last detected commit block (the final decided commit message)
                target = header_count - 1
                print headers[target]
                if (bodies[target] != "") {
                    print bodies[target]
                }
            }
        }
    ')

    if [ -n "$(printf '%s' "$extracted" | tr -d '[:space:]')" ]; then
        cleaned="$extracted"
    fi

    # Step 6: Post-processing & Normalization
    cleaned=$(printf '%s' "$cleaned" | sed 's/`//g; s/\*\*//g')

    # Remove immediate token stutters (e.g. "an and", "op optimize", "and and")
    if command -v perl >/dev/null 2>&1; then
        cleaned=$(printf '%s\n' "$cleaned" | perl -pe 's/\b([a-zA-Z]{2,})\s+\1\b/\1/g; s/\b([a-zA-Z]{2,})\s+\1([a-zA-Z]+)\b/\1\2/g')
    fi

    # Trim leading and trailing empty lines and normalize header-body separation
    printf '%s\n' "$cleaned" | awk '
        BEGIN { header = ""; body_count = 0; reading_body = 0 }
        {
            sub(/[[:space:]]+$/, "")
            if (header == "") {
                if ($0 != "") {
                    header = $0
                }
                next
            }
            if (!reading_body) {
                if ($0 == "") next
                reading_body = 1
            }
            body_lines[body_count++] = $0
        }
        END {
            if (header != "") {
                print header
                while (body_count > 0 && body_lines[body_count - 1] ~ /^[[:space:]]*$/) {
                    body_count--
                }
                if (body_count > 0) {
                    print ""
                    for (i = 0; i < body_count; i++) {
                        print body_lines[i]
                    }
                }
            }
        }
    '
}

# Generate commit message — assembles prompt and calls Ollama
# Args: --dry-run (optional)
generate_commit_message() {
    local dry_run=false
    [ "$1" = "--dry-run" ] && dry_run=true

    local model="${AI_MODEL:-$DEFAULT_AI_MODEL}"
    local prompt_file="${AI_PROMPT_FILE}"
    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir)

    # Restrict permissions for sensitive content
    umask 077

    local changes_file="${tmp_dir}/CHANGES_CONTEXT"
    local prompt_out="${tmp_dir}/FULL_PROMPT"

    # Zero-out owned files before writing — never use stale content
    : > "${tmp_dir}/FULL_PROMPT"
    : > "${tmp_dir}/RESPONSE"
    : > "${tmp_dir}/OLLAMA_ERROR"

    if [ ! -f "$changes_file" ] || [ ! -s "$changes_file" ]; then
        display_error "Context files not found or empty in $tmp_dir"
        return 1
    fi

    # Assemble prompt: substitute template placeholders with context files
    awk '
    /\$\{CHANGES_CONTEXT\}/ {
        while ((getline line < changes_file) > 0) print line
        close(changes_file)
        next
    }
    { print }
    ' changes_file="$changes_file" "$prompt_file" > "$prompt_out"

    if [ "$dry_run" = "true" ]; then
        return 0
    fi

    # Invoke LLM using backend abstraction
    local response_file="${tmp_dir}/RESPONSE"
    local error_file="${tmp_dir}/OLLAMA_ERROR"
    local timeout_secs=${AI_TIMEOUT:-120}

    if ! invoke_llm "$model" "$prompt_out" "$response_file" "$error_file" "$timeout_secs"; then
        return 1
    fi

    local raw_response commit_msg
    raw_response=$(cat "$response_file" 2>/dev/null)
    commit_msg=$(extract_conventional_commit "$raw_response")

    echo "$commit_msg"
}

# Execute the git commit
# Args: $1=commit_msg
process_commit() {
    local commit_msg="$1"
    echo "$commit_msg" | git commit -F -
}

# Execute an atomic git commit for a specific subset of staged files
# using git plumbing so unstaged modifications and other staged files are preserved.
# Args: $1=commit_msg, $2=files_to_commit (comma-separated list of relative paths)
commit_staged_subset() {
    local commit_msg="$1"
    local files_to_commit="$2"

    local -a commit_files=()
    IFS=',' read -r -a commit_files <<< "$files_to_commit"

    local git_dir
    git_dir=$(git rev-parse --git-dir)
    local tmp_index="${git_dir}/index.aicommit.$$"
    cp "${git_dir}/index" "$tmp_index"

    local has_head=false
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        has_head=true
    fi

    # Find all staged files in real index
    local staged_files
    staged_files=$(git diff --staged --name-only)

    # For files staged in real index that are NOT in commit_files:
    # revert them in tmp_index to match HEAD (or remove if new file)
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local is_target=false
        for cf in "${commit_files[@]}"; do
            # Trim whitespace
            cf="${cf#"${cf%%[![:space:]]*}"}"
            cf="${cf%"${cf##*[![:space:]]}"}"
            if [ "$f" = "$cf" ]; then
                is_target=true
                break
            fi
        done
        if [ "$is_target" = false ]; then
            if [ "$has_head" = true ] && git ls-tree HEAD -- "$f" 2>/dev/null | grep -q .; then
                GIT_INDEX_FILE="$tmp_index" git restore --staged --source=HEAD -- "$f" >/dev/null 2>&1 || true
            else
                GIT_INDEX_FILE="$tmp_index" git rm --cached -q -- "$f" 2>/dev/null || true
            fi
        fi
    done <<< "$staged_files"

    local tree_sha
    tree_sha=$(GIT_INDEX_FILE="$tmp_index" git write-tree 2>/dev/null)
    rm -f "$tmp_index"

    if [ -z "$tree_sha" ]; then
        display_error "Failed to create git tree for subset commit"
        return 1
    fi

    local parent_args=()
    if [ "$has_head" = true ]; then
        parent_args=("-p" "$(git rev-parse HEAD)")
    fi

    local commit_sha
    commit_sha=$(printf '%s\n' "$commit_msg" | git commit-tree "$tree_sha" "${parent_args[@]}")
    if [ -z "$commit_sha" ]; then
        display_error "Failed to create git commit tree"
        return 1
    fi

    local current_ref
    current_ref=$(git symbolic-ref HEAD 2>/dev/null || git rev-parse HEAD)
    git update-ref "$current_ref" "$commit_sha"

    # Invoke post-commit hook if present
    if [ -x "${git_dir}/hooks/post-commit" ]; then
        "${git_dir}/hooks/post-commit" 2>/dev/null || true
    fi
}

# Cleanup ephemeral context files (keeps FULL_PROMPT for --regenerate)
cleanup_aicommit_ephemeral() {
    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir)
    rm -f "${tmp_dir}/CHANGES_CONTEXT" \
          "${tmp_dir}/FILE_CONTEXT" \
          "${tmp_dir}/CHANGE_STATS" \
          "${tmp_dir}/RESPONSE" \
          "${tmp_dir}/FILE_COUNT" \
          "${tmp_dir}/ASSET_FILES" \
          "${tmp_dir}/OLLAMA_ERROR" > /dev/null 2>&1
}

# Cleanup everything including the prompt
cleanup_aicommit_all() {
    cleanup_aicommit_ephemeral
    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir)
    rm -f "${tmp_dir}/FULL_PROMPT" > /dev/null 2>&1
}
