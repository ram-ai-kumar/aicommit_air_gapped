#!/usr/bin/env bash
# aicommit — Output Formatter
# Display helpers for commit messages, errors, and status.

# Display staged file list with count and churn summary.
# Args: $1=staged_files (newline-separated), $2=numstat_data
display_staged_files() {
    local staged_files="$1" numstat_data="$2"
    local name_status=""
    if command -v git &>/dev/null; then
        name_status=$(git diff --staged --name-status 2>/dev/null)
    fi
    [ -z "$name_status" ] && return 0

    local file_count adds dels plural status file rest
    file_count=$(printf '%s\n' "$staged_files" | grep -c '.')
    adds=$(printf '%s\n' "$numstat_data" | awk '{a += $1} END {print a + 0}')
    dels=$(printf '%s\n' "$numstat_data" | awk '{d += $2} END {print d + 0}')
    plural="s"
    [ "$file_count" -eq 1 ] && plural=""

    echo ""
    printf 'Staged changes (%s file%s, +%s -%s):\n' "$file_count" "$plural" "$adds" "$dels"
    printf '%s\n' "$name_status" | while IFS=$'\t' read -r status file rest; do
        case "$status" in
            M*)  printf '        modified:   %s\n' "$file" ;;
            A*)  printf '        new file:   %s\n' "$file" ;;
            D*)  printf '        deleted:    %s\n' "$file" ;;
            R*)  printf '        renamed:    %s -> %s\n' "$file" "$rest" ;;
            C*)  printf '        copied:     %s -> %s\n' "$file" "$rest" ;;
            T*)  printf '        typechange: %s\n' "$file" ;;
            *)   printf '        %s: %s\n' "$status" "$file" ;;
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
    local f=""

    echo "💡 Staged changes span $count distinct scopes: [$scopes]"

    if [ -n "$scope_groups" ]; then
        while IFS= read -r group_line; do
            [ -z "$group_line" ] && continue
            grp_scope=$(echo "$group_line" | cut -d'|' -f1)
            grp_files=$(echo "$group_line" | cut -d'|' -f2)
            [ -z "$grp_scope" ] && continue

            file_count=$(echo "$grp_files" | tr ',' '\n' | grep -c '.' || echo "0")
            count_str="($file_count files):"
            [ "$file_count" -eq 1 ] && count_str="($file_count file):"

            echo "  • $grp_scope $count_str"
            local shown=0
            while IFS= read -r f; do
                f=$(echo "$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
                [ -z "$f" ] && continue
                if [ "$shown" -ge 5 ]; then
                    echo "      … and $((file_count - shown)) more"
                    break
                fi
                echo "      - $f"
                shown=$((shown + 1))
            done <<< "$(echo "$grp_files" | tr ',' '\n')"
        done <<< "$scope_groups"
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

display_commit_confirmation() {
    echo "Use this message? ([Y]/n/e to edit)"
}
