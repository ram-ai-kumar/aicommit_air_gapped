#!/usr/bin/env bash
# aicommit — Output Formatter
# Display helpers for commit messages, errors, and status.

# Display staged file list with count and churn summary.
# Args: $1=staged_files (newline-separated), $2=numstat_data
display_staged_files() {
    local staged_files="$1" numstat_data="$2"
    local name_status=""
    if command -v git &>/dev/null; then
        name_status=$(agit diff --staged --name-status 2>/dev/null)
    fi
    [ -z "$name_status" ] && return 0

    local file_count adds dels plural git_status file rest
    file_count=$(printf '%s\n' "$staged_files" | grep -c '.')
    adds=$(printf '%s\n' "$numstat_data" | awk '{a += $1} END {print a + 0}')
    dels=$(printf '%s\n' "$numstat_data" | awk '{d += $2} END {print d + 0}')
    plural="s"
    [ "$file_count" -eq 1 ] && plural=""

    echo ""
    printf 'Staged changes (%s file%s, +%s -%s):\n' "$file_count" "$plural" "$adds" "$dels"
    # Variable deliberately NOT named `status`: aicommit.sh is sourced directly into
    # the user's interactive shell (per the file header), and some zsh setups (e.g. a
    # prompt theme caching git state) declare a global `readonly status=...`. zsh,
    # unlike bash, refuses to `local`-shadow a readonly global, so `local status`
    # aborts this function with "read-only variable: status" in exactly that setup —
    # this is what broke `aicx`/`aiccx` for a user whose shell does that.
    printf '%s\n' "$name_status" | while IFS=$'\t' read -r git_status file rest; do
        case "$git_status" in
            M*)  printf '        modified:   %s\n' "$file" ;;
            A*)  printf '        new file:   %s\n' "$file" ;;
            D*)  printf '        deleted:    %s\n' "$file" ;;
            R*)  printf '        renamed:    %s -> %s\n' "$file" "$rest" ;;
            C*)  printf '        copied:     %s -> %s\n' "$file" "$rest" ;;
            T*)  printf '        typechange: %s\n' "$file" ;;
            *)   printf '        %s: %s\n' "$git_status" "$file" ;;
        esac
    done
    echo ""
}

display_setup_info() {
    echo "💡 Backend: ${AI_BACKEND:-ollama} · Model: ${AI_MODEL:-$DEFAULT_AI_MODEL}"
}

display_commit_message() {
    local commit_msg="$1"
    local title="${2:-Suggested Commit:}"
    local box_width=72
    local border_line="" raw_line="" prefix="" rest="" indent="  " first=1
    local wrapped_line="" indented_line="" sub_line=""
    border_line=$(printf '─%.0s' {1..74})

    echo ""
    echo "$title"
    echo "┌${border_line}┐"

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        if [ -z "$raw_line" ]; then
            printf "│ %-${box_width}s │\n" ""
            continue
        fi

        # Check if line is a bullet item to preserve hanging indent on wrap
        if printf '%s\n' "$raw_line" | grep -qE '^[[:space:]]*[-*+][[:space:]]'; then
            prefix=$(printf '%s\n' "$raw_line" | sed -E -n 's/^([[:space:]]*[-*+][[:space:]])(.*)/\1/p')
            rest=$(printf '%s\n' "$raw_line" | sed -E -n 's/^([[:space:]]*[-*+][[:space:]])(.*)/\2/p')
            first=1

            echo "${prefix}${rest}" | fold -s -w "$box_width" | while IFS= read -r wrapped_line || [ -n "$wrapped_line" ]; do
                if [ $first -eq 1 ]; then
                    printf "│ %-${box_width}s │\n" "$wrapped_line"
                    first=0
                else
                    # Prepend indent for continuation if not already indented
                    indented_line="$wrapped_line"
                    if [[ "$indented_line" != "  "* ]]; then
                        indented_line="${indent}${wrapped_line}"
                    fi
                    echo "$indented_line" | fold -s -w "$box_width" | while IFS= read -r sub_line || [ -n "$sub_line" ]; do
                        printf "│ %-${box_width}s │\n" "$sub_line"
                    done
                fi
            done
        else
            echo "$raw_line" | fold -s -w "$box_width" | while IFS= read -r wrapped_line || [ -n "$wrapped_line" ]; do
                printf "│ %-${box_width}s │\n" "$wrapped_line"
            done
        fi
    done <<< "$commit_msg"

    echo "└${border_line}┘"
    echo ""
}

display_split_confirmation() {
    local count="$1"
    local scopes="$2"
    local scope_groups="$3"
    local group_line="" grp_scope="" grp_files="" file_count=0 count_str=""
    local f="" s=""

    # Filter and validate scope groups (TAB-delimited: scope<TAB>file<TAB>file...)
    # Only keep lines with a scope and at least one file, no variable assignments ('=')
    local -a valid_groups=()
    local -a valid_scopes=()
    if [ -n "$scope_groups" ]; then
        while IFS= read -r group_line; do
            [ -z "$group_line" ] && continue
            [[ "$group_line" == *$'\t'* ]] || continue

            grp_scope=$(cut -f1 <<< "$group_line" | sed -E 's/^[[:space:]*#-]+//; s/[[:space:]]+$//; s/`//g; s/\*\*//g')
            grp_files=$(cut -f2- <<< "$group_line")

            [ -z "$grp_scope" ] && continue
            [ -z "$grp_files" ] && continue
            echo "$grp_scope" | grep -q '=' && continue
            echo "$grp_scope" | grep -qiE '^(joined_files|staged_files|files|local |export )' && continue

            valid_groups+=("$(printf '%s\t%s' "$grp_scope" "$grp_files")")
            valid_scopes+=("$grp_scope")
        done <<< "$scope_groups"
    fi

    # Reconcile count and scopes from valid groups when available
    if [ ${#valid_groups[@]} -gt 0 ]; then
        count="${#valid_groups[@]}"
        local s_joined=""
        for s in "${valid_scopes[@]}"; do
            [ -n "$s_joined" ] && s_joined="${s_joined}, "
            s_joined="${s_joined}${s}"
        done
        scopes="$s_joined"
    fi

    echo "💡 Staged changes span $count distinct scopes: [$scopes]"

    if [ ${#valid_groups[@]} -gt 0 ]; then
        local total=${#valid_groups[@]}
        local idx=1
        for group_line in "${valid_groups[@]}"; do
            grp_scope=$(cut -f1 <<< "$group_line")
            grp_files=$(cut -f2- <<< "$group_line")

            file_count=$(printf '%s' "$grp_files" | tr '\t' '\n' | count_lines)
            count_str="($file_count files):"
            [ "$file_count" -eq 1 ] && count_str="($file_count file):"

            echo ""
            echo "  📁 Category $idx of $total: $grp_scope $count_str"
            local shown=0
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                if [ "$shown" -ge 5 ]; then
                    echo "      … and $((file_count - shown)) more"
                    break
                fi
                echo "      - $f"
                shown=$((shown + 1))
            done <<< "$(printf '%s' "$grp_files" | tr '\t' '\n')"
            idx=$((idx + 1))
        done
        echo ""
    fi

    echo "Make all-in-one commit? ([Y] all-in-one / [n] multi-commits / [x] abort)"
}

display_split_progress() {
    local current="$1"
    local total="$2"
    local scope="$3"
    echo "📦 Preparing commit $current of $total (scope: $scope)..."
}

display_error() {
    local error_msg="$1" debug_info="$2"

    echo "❌ $error_msg" >&2
    [ -n "$debug_info" ] && echo "🔍 Debug: $debug_info" >&2
}

display_success() {
    local sha
    sha=$(git rev-parse --short HEAD 2>/dev/null || true)
    if [ -n "$sha" ]; then
        echo "✅ Committed! ($sha)"
    else
        echo "✅ Committed!"
    fi
}

# One-line semver bump suggestion, shown after a successful commit.
# Args: $1=bump ("major"|"minor"|"patch"|"none")
display_semver_hint() {
    local bump="$1"
    case "$bump" in
        major) echo "🔺 Suggested version bump: MAJOR (breaking change)" ;;
        minor) echo "🔼 Suggested version bump: MINOR (new feature)" ;;
        patch) echo "🔧 Suggested version bump: PATCH (fix/perf)" ;;
        *) ;;
    esac
}

# Success line for one atomic commit in --split mode
display_scope_success() {
    local scope="$1" sha
    sha=$(git rev-parse --short HEAD 2>/dev/null || true)
    if [ -n "$sha" ]; then
        echo "✅ Committed scope '$scope' ($sha)"
    else
        echo "✅ Committed scope '$scope'"
    fi
}

# Display commit confirmation prompt
# Args: $1=bump_opt ("true" or "false"), $2=rec_summary (optional)
display_commit_confirmation() {
    local bump_opt="${1:-false}"
    local rec_summary="${2:-}"

    if [ "$bump_opt" = "true" ]; then
        echo "Use this message with SemVer? ([Y]/n/e to edit, c to change level, a for AI)"
    elif [ -n "$rec_summary" ]; then
        echo "Use this message? ([Y]/n/e to edit, s for SemVer bump [$rec_summary], a for AI)"
    else
        echo "Use this message? ([Y]/n/e to edit, s for SemVer, a for AI)"
    fi
}

# Display SemVer release evaluation summary
# Args: $1=current_ver, $2=bump, $3=next_ver, $4=tag_name, $5=files (newline-separated), $6=is_higher (optional)
display_semver_plan() {
    local cur="$1" bump="$2" next="$3" tag="$4" files="$5" is_higher="${6:-false}"
    local bump_label=""
    if [ "$is_higher" = "true" ] || [ "$bump" = "preserved" ]; then
        bump_label="PRESERVED (higher version in manifests)"
    else
        case "$bump" in
            major) bump_label="MAJOR (breaking change)" ;;
            minor) bump_label="MINOR (new feature)" ;;
            patch) bump_label="PATCH (fix/perf)" ;;
            *) bump_label="$bump" ;;
        esac
    fi

    echo "🏷️  SemVer Release Plan:"
    echo "   Current: $cur"
    echo "   Bump:    $bump_label"
    echo "   Target:  $next"
    [ -n "$tag" ] && echo "   Git tag: $tag"
    if [ -n "$files" ]; then
        local files_str
        files_str=$(printf '%s' "$files" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
        echo "   Files:   $files_str"
    else
        echo "   Files:   (none — tag only)"
    fi
}

# Display Git tag and version update confirmation
# Args: $1=tag_name, $2=files (newline-separated)
display_tag_success() {
    local tag="$1" files="$2"
    if [ -n "$tag" ]; then
        echo "🏷️  Tagged release: $tag"
    fi
    if [ -n "$files" ]; then
        local files_str
        files_str=$(printf '%s' "$files" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
        echo "📝 Updated version in: $files_str"
    fi
}

# Summarize a list of files by type/extension in human-readable compact form.
# Outputs one summary row per category:
#   single file:    <file>
#   multiple files: <first_file> +<N-1> <type> files
# Args: files as positional arguments or newline-separated via stdin
format_group_files_compact() {
    local input=""
    if [ $# -gt 0 ]; then
        input=$(printf '%s\n' "$@")
    else
        input=$(cat)
    fi
    [ -z "$input" ] && return 0

    printf '%s\n' "$input" | awk '
function get_type(file,   base, ext) {
    base = file; sub(/^.*\//, "", base)
    if (base ~ /^\./ && base !~ /^[.][^.]+[.]/) {
        return "config file:config files"
    }
    if (base ~ /\./) {
        ext = base; sub(/^.*\./, "", ext); ext = tolower(ext)
        if (ext ~ /^(md|markdown)$/) return "markdown file:markdown files"
        if (ext ~ /^(sh|bash|zsh)$/) return "shell script:shell scripts"
        if (ext == "bats") return "test file:test files"
        if (ext ~ /^(js|mjs|cjs)$/) return "JavaScript file:JavaScript files"
        if (ext ~ /^(ts|tsx)$/) return "TypeScript file:TypeScript files"
        if (ext == "jsx") return "React file:React files"
        if (ext == "py") return "Python file:Python files"
        if (ext == "rb") return "Ruby file:Ruby files"
        if (ext == "go") return "Go file:Go files"
        if (ext == "rs") return "Rust file:Rust files"
        if (ext ~ /^(yaml|yml)$/) return "YAML file:YAML files"
        if (ext == "json") return "JSON file:JSON files"
        if (ext == "toml") return "TOML file:TOML files"
        if (ext == "txt") return "text file:text files"
        if (ext ~ /^(css|scss|sass|less)$/) return "CSS file:CSS files"
        if (ext ~ /^(html|htm)$/) return "HTML file:HTML files"
        if (ext == "sql") return "SQL file:SQL files"
        if (ext == "dart") return "Dart file:Dart files"
        return ext " file:" ext " files"
    }
    if (base ~ /^Dockerfile/) return "Dockerfile:Dockerfiles"
    if (base == "Makefile") return "Makefile:Makefiles"
    return "file:files"
}
NF {
    t_pair = get_type($0)
    split(t_pair, parts, ":")
    sing = parts[1]; plur = parts[2]
    cat_key = sing
    if (!(cat_key in seen)) {
        seen[cat_key] = 1
        order[n_cats++] = cat_key
        first_file[cat_key] = $0
        singular_name[cat_key] = sing
        plural_name[cat_key] = plur
    }
    count[cat_key]++
}
END {
    for (i = 0; i < n_cats; i++) {
        k = order[i]
        c = count[k]
        if (c == 1) {
            print first_file[k]
        } else if (c == 2) {
            print first_file[k] " +1 " singular_name[k]
        } else {
            print first_file[k] " +" (c - 1) " " plural_name[k]
        }
    }
}
'
}

# Display resolved or previewed atomic commit groups in clean, human-readable format.
# Single-item groups are printed on one row (`  • <scope> -> <summary>`).
# Multi-item groups are printed as indented bullet items (`  • <scope>:` followed by `      - <item>`).
# Args: $1=scope_groups, $2=bullet_char (default "•")
display_resolved_atomic_groups() {
    local scope_groups="$1"
    local bullet="${2:-•}"
    [ -z "$scope_groups" ] && return 0

    local group_line grp_scope summary_lines line_count item
    while IFS= read -r group_line; do
        [ -z "$group_line" ] && continue
        if command -v _aicommit_split_tab_line >/dev/null 2>&1; then
            _aicommit_split_tab_line "$group_line"
            [ -z "$_aicommit_split_scope" ] && continue
            grp_scope="$_aicommit_split_scope"
            [ ${#_aicommit_split_files[@]} -eq 0 ] && continue
            summary_lines=$(format_group_files_compact "${_aicommit_split_files[@]}")
        else
            grp_scope=$(cut -f1 <<< "$group_line")
            [ -z "$grp_scope" ] && continue
            local grp_raw_files
            grp_raw_files=$(cut -f2- <<< "$group_line" | tr '\t' '\n')
            [ -z "$grp_raw_files" ] && continue
            summary_lines=$(format_group_files_compact <<< "$grp_raw_files")
        fi

        line_count=$(printf '%s\n' "$summary_lines" | awk 'NF { c++ } END { print c + 0 }')

        if [ "$line_count" -le 1 ]; then
            echo "  $bullet $grp_scope -> $summary_lines"
        else
            echo "  $bullet $grp_scope:"
            while IFS= read -r item; do
                [ -z "$item" ] && continue
                echo "      - $item"
            done <<< "$summary_lines"
        fi
    done <<< "$scope_groups"
}

