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
        test/*|tests/*|spec/*|__tests__/*|*.test.*|*.spec.*)
            echo "test" ;;
        docs/*|*.md|*.rst|README*|CHANGELOG*|CONTRIBUTING*)
            echo "docs" ;;
        templates/*)
            echo "templates" ;;
        src/components/*|components/*)
            local comp_sub
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
            local mod
            mod=$(echo "$file" | awk -F/ '{print $2}')
            mod="${mod%.*}"
            echo "${mod:-core}" ;;
        *)
            local dir
            dir=$(dirname "$file")
            if [ "$dir" != "." ] && [ -n "$dir" ]; then
                echo "$(basename "$dir")"
            else
                local base
                base=$(basename "$file")
                echo "${base%.*}"
            fi
            ;;
    esac
}

# Group staged files into scopes.
# Outputs lines in format: "<scope>|<file1>,<file2>,..."
group_staged_files_by_scope() {
    local staged_files="$1"
    [ -z "$staged_files" ] && return 0

    local tmp_scope_dir
    tmp_scope_dir=$(mktemp -d "/tmp/.aicommit_scopes_XXXXXX")

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local s
        s=$(infer_file_scope "$f")
        echo "$f" >> "${tmp_scope_dir}/${s}"
    done <<< "$staged_files"

    for scope_file in "$tmp_scope_dir"/*; do
        [ -e "$scope_file" ] || continue
        local s
        s=$(basename "$scope_file")
        local files
        files=$(tr '\n' ',' < "$scope_file" | sed 's/,$//')
        echo "${s}|${files}"
    done
    rm -rf "$tmp_scope_dir"
}

# Returns count of unique scopes
count_staged_scopes() {
    local staged_files="$1"
    group_staged_files_by_scope "$staged_files" | grep -c '.' || echo "0"
}
