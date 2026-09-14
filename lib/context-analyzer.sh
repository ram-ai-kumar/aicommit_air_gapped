#!/usr/bin/env bash
# aicommit — Context Analyzer
# Analyzes staged changes to provide structural hints for commit message generation.

# Detect project type from staged files and repo contents
detect_project_type() {
    local staged_files="$1"

    if [ -f "Gemfile" ] || echo "$staged_files" | grep -q "Gemfile"; then
        echo "rails/ruby"
    elif [ -f "package.json" ] || echo "$staged_files" | grep -q "package.json"; then
        echo "node/javascript"
    elif [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || echo "$staged_files" | grep -qE "(requirements\.txt|pyproject\.toml|setup\.py)"; then
        echo "python"
    elif [ -f "go.mod" ] || echo "$staged_files" | grep -q "go.mod"; then
        echo "go"
    elif [ -f "Cargo.toml" ] || echo "$staged_files" | grep -q "Cargo.toml"; then
        echo "rust"
    elif [ -f "pom.xml" ] || [ -f "build.gradle" ] || echo "$staged_files" | grep -qE "(pom\.xml|build\.gradle)"; then
        echo "java"
    else
        echo "unknown"
    fi
}

# Analyze change concentration across directories
analyze_change_concentration() {
    local staged_files="$1"
    local total_files
    total_files=$(echo "$staged_files" | grep -c '.')

    if [ "$total_files" -eq 0 ]; then
        echo "|0|0"
        return
    fi

    local top_dir_info
    top_dir_info=$(echo "$staged_files" | while IFS= read -r f; do
        [ -n "$f" ] && dirname "$f"
    done | sort | uniq -c | sort -rn | head -1)

    local max_count max_dir concentration
    max_count=$(echo "$top_dir_info" | awk '{print $1}')
    max_dir=$(echo "$top_dir_info" | awk '{print $2}')
    concentration=$((max_count * 100 / total_files))

    echo "${max_dir}|${max_count}|${concentration}"
}

# Detect new vs modified files ratio
detect_new_files_ratio() {
    local staged_files="$1"
    local total_files
    total_files=$(echo "$staged_files" | grep -c '.')
    local new_files
    new_files=$(git diff --staged --diff-filter=A --name-only 2>/dev/null | wc -l | tr -d ' ')

    if [ "$total_files" -gt 0 ]; then
        local new_ratio=$((new_files * 100 / total_files))
        echo "${new_files}|${total_files}|${new_ratio}"
    else
        echo "0|0|0"
    fi
}

# Detect dependency/framework upgrade pattern
detect_upgrade_pattern() {
    local staged_files="$1"
    local has_lockfile=false has_dep_file=false has_config_changes=false has_migration=false

    while IFS= read -r file; do
        case "$file" in
            *.lock|*lock.json|*-lock.yaml)
                has_lockfile=true ;;
            Gemfile|package.json|requirements.txt|go.mod|Cargo.toml|pyproject.toml)
                has_dep_file=true ;;
            config/*|*.yml|*.yaml|*.toml|*.cfg)
                has_config_changes=true ;;
            db/migrate/*|migrations/*|alembic/*)
                has_migration=true ;;
        esac
    done <<< "$staged_files"

    if $has_dep_file && $has_lockfile; then
        echo "dependency_upgrade"
    elif $has_dep_file && $has_config_changes; then
        echo "framework_upgrade"
    elif $has_migration; then
        echo "migration"
    else
        echo "none"
    fi
}

# Categorize staged files into structural layers.
# Outputs a FILE CATEGORIES block used as context and for diff filtering.
# Also writes asset filenames (newline-separated) to ${tmp_dir}/ASSET_FILES
# so build_ai_context can exclude their diffs.
categorize_staged_files() {
    local staged_files="$1"
    local tmp_dir="$2"

    local source_files=() config_files=() doc_files=() infra_files=() test_files=() asset_files=()

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        case "$file" in
            # Tests — matched before source to avoid false positives
            tests/*|test/*|spec/*|__tests__/*|\
            *.test.js|*.test.ts|*.spec.js|*.spec.ts|\
            test_*.py|*_test.py|*_test.go)
                test_files+=("$file") ;;
            # IaC / CI/CD / migrations
            *.tf|*.tfvars|\
            .github/workflows/*|.gitlab-ci.yml|.circleci/*|Jenkinsfile|\
            docker-compose*|Dockerfile*|\
            k8s/*|kubernetes/*|helm/*|\
            db/migrate/*|migrations/*|alembic/versions/*)
                infra_files+=("$file") ;;
            # Documentation
            *.md|*.rst|\
            docs/*|doc/*|\
            README*|CHANGELOG*|CONTRIBUTING*|LICENSE*)
                doc_files+=("$file") ;;
            # Static assets — binary/visual, diffs excluded
            *.svg|*.png|*.jpg|*.jpeg|*.gif|*.ico|*.fig|*.webp|\
            *.mp4|*.mp3|*.woff|*.woff2|*.ttf|\
            assets/*|static/*|public/images/*)
                asset_files+=("$file") ;;
            # Config / environment / lock files (exclude .env and sensitive configs from prompt)
            *.yaml|*.yml|*.json|*.toml|*.conf|\
            config/*|.config/*|\
            *.lock|*lock.json|*lock.yaml)
                config_files+=("$file") ;;
            # Sensitive files - exclude from prompt entirely
            *.env|*.env.*|\
            config.ini|*secrets.*|*credentials.*|*.key|*.pem|*.p12)
                # Don't add to any category - exclude from prompt
                ;;
            # Functional source — catch-all
            *)
                source_files+=("$file") ;;
        esac
    done <<< "$staged_files"

    # Write asset filenames for diff exclusion in build_ai_context
    if [ -n "$tmp_dir" ]; then
        printf '' > "${tmp_dir}/ASSET_FILES"
        for f in "${asset_files[@]}"; do
            printf '%s\n' "$f" >> "${tmp_dir}/ASSET_FILES"
        done
    fi

    local output="=== FILE CATEGORIES ==="
    [ ${#source_files[@]} -gt 0 ] && output="${output}\nFunctional Source:  $(IFS=', '; echo "${source_files[*]}")"
    [ ${#config_files[@]} -gt 0 ] && output="${output}\nConfiguration:      $(IFS=', '; echo "${config_files[*]}")"
    [ ${#doc_files[@]} -gt 0 ]    && output="${output}\nDocumentation:      $(IFS=', '; echo "${doc_files[*]}")"
    [ ${#infra_files[@]} -gt 0 ]  && output="${output}\nInfrastructure/CI:  $(IFS=', '; echo "${infra_files[*]}")"
    [ ${#test_files[@]} -gt 0 ]   && output="${output}\nTests:              $(IFS=', '; echo "${test_files[*]}")"
    [ ${#asset_files[@]} -gt 0 ]  && output="${output}\nStatic Assets (diff excluded): $(IFS=', '; echo "${asset_files[*]}")"

    printf '%b\n' "$output"
}

# Build enhanced context string from analysis results
build_enhanced_context() {
    local staged_files="$1"
    local changes="$2"

    local project_type concentration_info focus_dir focus_count concentration
    project_type=$(detect_project_type "$staged_files")
    concentration_info=$(analyze_change_concentration "$staged_files")
    focus_dir=$(echo "$concentration_info" | cut -d'|' -f1)
    focus_count=$(echo "$concentration_info" | cut -d'|' -f2)
    concentration=$(echo "$concentration_info" | cut -d'|' -f3)

    local ratio_info new_files total_files new_ratio
    ratio_info=$(detect_new_files_ratio "$staged_files")
    new_files=$(echo "$ratio_info" | cut -d'|' -f1)
    total_files=$(echo "$ratio_info" | cut -d'|' -f2)
    new_ratio=$(echo "$ratio_info" | cut -d'|' -f3)

    local upgrade_pattern
    upgrade_pattern=$(detect_upgrade_pattern "$staged_files")

    local enhanced_context="=== ENHANCED CONTEXT ===
Project Type: $project_type
Focus Directory: $focus_dir ($focus_count files, $concentration% concentration)
New Files: $new_files/$total_files ($new_ratio% new)"

    if [ "$upgrade_pattern" != "none" ]; then
        enhanced_context="${enhanced_context}
Upgrade Pattern: $upgrade_pattern"
    fi

    echo "$enhanced_context"
}

# Infer logical scope for a given file path
infer_file_scope() {
    local file="$1"
    case "$file" in
        *schema*|*seo*|*Schema*|*sitemap*|*robots.txt*|*acme-challenge*)
            echo "seo" ;;
        scripts/*|bin/*)
            echo "scripts" ;;
        *.config.*|.eslintrc*|pnpm-workspace*|*package.json|tsconfig*.json|*.toml|*.yaml|*.yml)
            echo "config" ;;
        .github/*|Dockerfile*|docker-compose*|k8s/*|terraform/*)
            echo "ci" ;;
        test/*|tests/*|spec/*|__tests__/*|*.test.*|*.spec.*|*.bats)
            echo "test" ;;
        docs/*|*.md|*.rst|README*|CHANGELOG*|CONTRIBUTING*)
            echo "docs" ;;
        templates/*|*prompt*)
            echo "prompt" ;;
        src/components/*|components/*)
            local comp_sub=""
            comp_sub=$(echo "$file" | sed -E 's|^(src/)?components/([^/]+).*|\2|')
            if [ -n "$comp_sub" ] && [ "$comp_sub" != "$file" ]; then
                if echo "$comp_sub" | grep -qi "schema"; then
                    echo "seo"
                else
                    echo "ui"
                fi
            else
                echo "ui"
            fi
            ;;
        lib/*|aicommit.sh|cli/*)
            echo "core" ;;
        src/*|app/*)
            local mod=""
            mod=$(echo "$file" | awk -F/ '{print $2}')
            mod="${mod%.*}"
            echo "${mod:-core}" ;;
        *)
            local dir=""
            dir=$(dirname "$file")
            if [ "$dir" != "." ] && [ -n "$dir" ]; then
                echo "$(basename "$dir")"
            else
                echo "core"
            fi
            ;;
    esac
}

# Infer logical, feature/context-specific scope for a given file path
infer_logical_file_context() {
    local file="$1"
    local all_staged="${2:-}"

    # 1. Multi-tenancy / Apartment / Tenant
    if echo "$file" | grep -qiE "(apartment|tenant)"; then
        echo "apartment multi-tenancy config & tests"
        return
    fi

    # 2. Authentication / Devise / OAuth / User account navigation
    if echo "$file" | grep -qiE "(devise|oauth|user_menu|google_auth)"; then
        echo "google oauth & devise authentication"
        return
    fi

    # 3. Product & Spare catalog
    if echo "$file" | grep -qiE "(models/(product|spare)|products?_controller|spares?_controller|factories/(product|spare))"; then
        echo "product & spare catalog"
        return
    fi

    # 4. Navigation & Layout UI
    if echo "$file" | grep -qiE "(navbar|layout|header|footer|sidebar)"; then
        echo "navigation UI updates"
        return
    fi

    # 5. Database schema & Seeds
    if echo "$file" | grep -qiE "(db/structure|db/schema|db/seeds|seeds_test|db/migrate|migrations/)"; then
        echo "database schema & seeds"
        return
    fi

    # 6. Documentation & Planning
    if echo "$file" | grep -qiE "(\.md$|\.rst$|^docs/|/docs/|^doc/|README|CHANGELOG|CONTRIBUTING|AGENTS)"; then
        echo "documentation & plans"
        return
    fi

    # 7. CI / CD & Deployment / Secrets / Containers
    if echo "$file" | grep -qiE "(\.github/|Dockerfile|docker-compose|podman|k8s|kubernetes|terraform|helm)"; then
        echo "infrastructure & container deployment"
        return
    fi

    # 8. SEO & Schema files
    if echo "$file" | grep -qiE "(schema|seo|sitemap|robots\.txt|acme-challenge)"; then
        echo "seo"
        return
    fi

    # 9. Scripts and developer tooling
    if echo "$file" | grep -qiE "^(scripts/|bin/)"; then
        echo "scripts"
        return
    fi

    # 10. Config and workspace dependencies
    if echo "$file" | grep -qiE "(\.config\.|^\.eslintrc|pnpm-workspace|\bpnpm-lock|\bpackage\.json|tsconfig.*\.json|\.toml$|\.ya?ml$)"; then
        echo "config"
        return
    fi

    # 11. Core CLI & templates
    case "$file" in
        lib/*|aicommit.sh|cli/*)
            echo "core"
            return ;;
        templates/*|*prompt*)
            echo "prompt"
            return ;;
    esac

    # 12. Specific domain entities matching other staged files
    if echo "$file" | grep -qi "bank"; then
        echo "banks feature & tests"
        return
    fi

    # 13. Test file subject correlation:
    if echo "$file" | grep -qiE "(test/|tests/|spec/|__tests__/|_test\.|\.test\.|\.spec\.|\.bats$)"; then
        # Check for model tests
        if echo "$file" | grep -qiE "(models/|model_test)"; then
            local model_name
            model_name=$(echo "$file" | sed -E 's|.*models?/([^/]+)_test\..*|\1|; s|.*models?/([^/]+)\..*|\1|')
            [ -n "$model_name" ] && [ "$model_name" != "$file" ] && echo "${model_name} model test coverage" && return
        fi
        # Check for controller tests
        if echo "$file" | grep -qiE "(controllers/|controller_test)"; then
            echo "controller test suite coverage"
            return
        fi
        # General test support or test suite
        if echo "$file" | grep -qiE "(support/|test_helper|spec_helper)"; then
            echo "test suite support & configuration"
            return
        fi
        echo "test"
        return
    fi

    # 14. Fallback to infer_file_scope
    infer_file_scope "$file"
}

# Group staged files using domain & semantic heuristics
group_staged_files_heuristically() {
    local staged_files="$1"
    [ -z "$staged_files" ] && return 0

    local tmp_scope_dir="" s="" f="" scope_file="" files=""
    tmp_scope_dir=$(mktemp -d "/tmp/.aicommit_scopes_XXXXXX")

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        s=$(infer_logical_file_context "$f" "$staged_files")
        echo "$f" >> "${tmp_scope_dir}/${s}"
    done <<< "$staged_files"

    for scope_file in "$tmp_scope_dir"/*; do
        [ -e "$scope_file" ] || continue
        s=$(basename "$scope_file")
        files=$(tr '\n' ',' < "$scope_file" | sed 's/,$//')
        [ -n "$s" ] && [ -n "$files" ] && echo "${s}|${files}"
    done
    rm -rf "$tmp_scope_dir"
}

# Parse and reconcile AI grouping output against actual staged files
validate_and_reconcile_contexts() {
    local raw_output="$1"
    local staged_files="$2"
    [ -z "$raw_output" ] && return 1

    # Step 1: Strip thinking blocks and cursor escape artifacts
    local cleaned
    cleaned=$(printf '%s\n' "$raw_output" | tr -d '\r')
    if command -v perl >/dev/null 2>&1; then
        cleaned=$(printf '%s\n' "$cleaned" | perl -0777 -pe '
            s/\x1b\[\?[0-9]+[hl]//g;
            s/\x1b\[[0-9;]*m//g;
            while (/(\x1b\[(\d+)D(?:\x1b\[[0-9;]*[a-zA-Z])?\n?)/) {
                my $len = $2;
                s/.{$len}\x1b\[${len}D(?:\x1b\[[0-9;]*[a-zA-Z])?\n?//s;
            }
            while (/.\x08/) { s/.\x08//g; }
        ')
    fi
    cleaned=$(printf '%s\n' "$cleaned" | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g')
    cleaned=$(printf '%s\n' "$cleaned" | awk '
        /<\/(think|thought|thinking|reasoning)>/ {
            sub(/.*<\/(think|thought|thinking|reasoning)>[[:space:]]*/, "")
            last_close_line = NR
            line_content = $0
        }
        { lines[NR] = $0 }
        END {
            if (last_close_line > 0) {
                if (line_content != "") print line_content
                for (i = last_close_line + 1; i <= NR; i++) print lines[i]
            } else {
                for (i = 1; i <= NR; i++) print lines[i]
            }
        }
    ')
    cleaned=$(printf '%s\n' "$cleaned" | awk '
        /<(think|thought|thinking|reasoning)>/ { in_block = 1; next }
        /<\/(think|thought|thinking|reasoning)>/ { in_block = 0; next }
        !in_block { print }
    ')

    # Step 2: Extract between @@@ delimiters if present
    local delimited
    delimited=$(printf '%s\n' "$cleaned" | awk '
        /^@@@([[:space:]]*)$/ { count++; next }
        count == 1 { print }
        count >= 2 { exit }
    ')
    [ -n "$(printf '%s' "$delimited" | tr -d '[:space:]')" ] && cleaned="$delimited"

    # Step 3: Parse and validate lines
    local line="" ctx="" file_csv="" f=""
    local -a valid_lines=()
    local -a seen_files=()
    local staged_array=()
    while IFS= read -r f; do
        f="${f#"${f%%[![:space:]]*}"}"
        f="${f%"${f##*[![:space:]]}"}"
        [ -n "$f" ] && staged_array+=("$f")
    done <<< "$(printf '%b\n' "$staged_files")"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line" | grep -q '|' || continue

        ctx=$(echo "$line" | cut -d'|' -f1 | sed -E 's/^[[:space:]*#-]+//; s/[[:space:]]+$//; s/`//g; s/\*\*//g')
        file_csv=$(echo "$line" | cut -d'|' -f2-)
        [ -z "$ctx" ] && continue

        # Reject malformed scope names (e.g. variable assignments like joined_files=..., comma-separated lists, overly long text, or code tokens)
        echo "$ctx" | grep -q '=' && continue
        echo "$ctx" | grep -q ',' && continue
        echo "$ctx" | grep -qE '^<(context[ _]name|scope|name)>' && continue
        echo "$ctx" | grep -qiE '^(joined_files|staged_files|files|local |export )' && continue
        [ "${#ctx}" -gt 60 ] && continue

        local valid_files_in_ctx=()
        while IFS= read -r f; do
            f=$(echo "$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/`//g; s/\*\*//g')
            [ -z "$f" ] && continue

            local is_staged=false
            for sf in "${staged_array[@]}"; do
                if [ "$sf" = "$f" ]; then
                    is_staged=true
                    break
                fi
            done
            [ "$is_staged" = false ] && continue

            local already_seen=false
            for seen in "${seen_files[@]}"; do
                if [ "$seen" = "$f" ]; then
                    already_seen=true
                    break
                fi
            done
            if [ "$already_seen" = false ]; then
                seen_files+=("$f")
                valid_files_in_ctx+=("$f")
            fi
        done <<< "$(echo "$file_csv" | tr ',' '\n')"

        if [ ${#valid_files_in_ctx[@]} -gt 0 ]; then
            local joined_files
            joined_files=$(IFS=','; echo "${valid_files_in_ctx[*]}")
            valid_lines+=("${ctx}|${joined_files}")
        fi
    done <<< "$cleaned"

    [ ${#valid_lines[@]} -eq 0 ] && return 1

    # Check for any missed staged files
    local missed_files=()
    for sf in "${staged_array[@]}"; do
        local found=false
        for seen in "${seen_files[@]}"; do
            if [ "$seen" = "$sf" ]; then
                found=true
                break
            fi
        done
        [ "$found" = false ] && missed_files+=("$sf")
    done

    if [ ${#missed_files[@]} -gt 0 ]; then
        local joined_missed
        joined_missed=$(IFS=','; echo "${missed_files[*]}")
        valid_lines+=("additional changes|${joined_missed}")
    fi

    for vl in "${valid_lines[@]}"; do
        echo "$vl"
    done
}

# Invoke AI to cluster staged files into logical contexts
cluster_staged_files_with_ai() {
    local staged_files="$1"
    local numstat_data="$2"
    local changes="$3"

    local model="${AI_MODEL:-$DEFAULT_AI_MODEL}"
    local prompt_template="${AI_GROUPING_PROMPT_FILE:-$AICOMMIT_DIR/templates/context-grouping-prompt.txt}"
    [ ! -f "$prompt_template" ] && return 1

    command -v invoke_llm >/dev/null 2>&1 || return 1

    local tmp_dir
    if command -v get_aicommit_tmp_dir >/dev/null 2>&1; then
        tmp_dir=$(get_aicommit_tmp_dir)
    else
        tmp_dir=$(mktemp -d "/tmp/.aicommit_grouping_XXXXXX")
    fi

    # Build lightweight summary of files and change stats
    local files_summary="" file="" stat_line="" adds="" dels=""
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        stat_line=$(printf '%s\n' "$numstat_data" | grep -F $'\t'"${file}" | head -1)
        adds=$(printf '%s' "$stat_line" | awk '{print $1}')
        dels=$(printf '%s' "$stat_line" | awk '{print $2}')
        if [ -n "$adds" ] && [ -n "$dels" ]; then
            files_summary="${files_summary}\n- ${file} (+${adds} -${dels})"
        else
            files_summary="${files_summary}\n- ${file}"
        fi
    done <<< "$staged_files"

    local prompt_file="${tmp_dir}/GROUPING_PROMPT"
    local response_file="${tmp_dir}/GROUPING_RESPONSE"
    local error_file="${tmp_dir}/GROUPING_ERROR"
    local context_file="${tmp_dir}/GROUPING_CONTEXT"

    umask 077
    : > "$prompt_file"
    : > "$response_file"
    : > "$error_file"
    printf '%b\n' "$files_summary" > "$context_file"

    awk '
    /\$\{STAGED_FILES_CONTEXT\}/ {
        while ((getline line < context_file) > 0) print line
        close(context_file)
        next
    }
    { print }
    ' context_file="$context_file" "$prompt_template" > "$prompt_file"
    rm -f "$context_file"

    local timeout_secs=30
    if invoke_llm "$model" "$prompt_file" "$response_file" "$error_file" "$timeout_secs" "Analyzing logical scopes" >/dev/null 2>&1; then
        cat "$response_file" 2>/dev/null
    fi
}

# Group staged files into logical contexts.
# Uses AI context grouping if LLM backend is available, falling back to semantic heuristic analysis.
# Outputs lines in format: "<scope>|<file1>,<file2>,..."
group_staged_files_logically() {
    local staged_files="$1"
    local changes="${2:-}"
    local numstat_data="${3:-}"

    [ -z "$staged_files" ] && return 0

    local file_count
    file_count=$(echo "$staged_files" | grep -c '.' || echo "0")
    if [ "$file_count" -le 1 ]; then
        local single_file
        single_file=$(echo "$staged_files" | tr -d '[:space:]')
        if [ -n "$single_file" ]; then
            local single_scope
            single_scope=$(infer_logical_file_context "$single_file" "$staged_files")
            echo "${single_scope}|${single_file}"
        fi
        return 0
    fi

    # Use AI model for logical scope grouping when LLM backend is available
    if [ "${AI_ENABLE_LLM_GROUPING:-true}" = "true" ] && [ "${AI_DISABLE_GROUPING:-false}" != "true" ] && validate_backend_prerequisites >/dev/null 2>&1; then
        local ai_result=""
        ai_result=$(cluster_staged_files_with_ai "$staged_files" "$numstat_data" "$changes")
        if [ -n "$ai_result" ]; then
            local validated_groups
            validated_groups=$(validate_and_reconcile_contexts "$ai_result" "$staged_files")
            if [ -n "$validated_groups" ]; then
                echo "$validated_groups"
                return 0
            fi
        fi
    fi

    # Fallback to intelligent domain & semantic heuristic
    group_staged_files_heuristically "$staged_files"
}

# Backward compatible aliases
group_staged_files_by_scope() {
    local staged_files="$1"
    local changes="${2:-}"
    local numstat_data="${3:-}"

    group_staged_files_logically "$staged_files" "$changes" "$numstat_data"
}

# Returns count of unique scopes/contexts
count_staged_scopes() {
    local staged_files="$1"
    local changes="${2:-}"
    local numstat_data="${3:-}"

    group_staged_files_logically "$staged_files" "$changes" "$numstat_data" | grep -c '|' || echo "0"
}
