#!/usr/bin/env bash
# aicommit — Output Formatter
# Display helpers for commit messages, errors, and status.

display_setup_info() {
    local file_count="$1" file_list="$2"
    local staged_status=""

    if command -v git &>/dev/null; then
        staged_status=$(git status 2>/dev/null | awk '/Changes to be committed:/{flag=1; next} /^[A-Za-z]/{flag=0} flag' | grep -E '^\s*(modified|new file|deleted|renamed|typechange):' || true)
    fi

    echo "💡 Setup: Ollama running, model ready"
    if [ -n "$staged_status" ]; then
        echo "📁 Staged ($file_count files):"
        echo "$staged_status"
    elif [ -n "$file_list" ]; then
        echo "📁 Staged ($file_count files): $file_list"
    else
        echo "📁 Staged ($file_count files)"
    fi
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
        if [[ "$raw_line" =~ ^([[:space:]]*[-*+][[:space:]])(.*) ]]; then
            prefix="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
            first=1

            echo "${prefix}${rest}" | fold -s -w "$box_width" | while IFS= read -r wrapped_line || [ -n "$wrapped_line" ]; do
                if [ $first -eq 1 ]; then
                    printf "│ %-${box_width}s │\n" "$wrapped_line"
                    first=0
                else
                    # Prepend indent for continuation if not already indented
                    indented_line="$wrapped_line"
                    if [[ ! "$indented_line" =~ ^[[:space:]]{2} ]]; then
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
    local group_line="" grp_scope="" grp_files="" file_count=0 preview=""
    local first_three="" remaining=0 count_str=""

    echo "💡 Staged changes span $count distinct scopes: [$scopes]"

    if [ -n "$scope_groups" ]; then
        while IFS= read -r group_line; do
            [ -z "$group_line" ] && continue
            grp_scope=$(echo "$group_line" | cut -d'|' -f1)
            grp_files=$(echo "$group_line" | cut -d'|' -f2)
            [ -z "$grp_scope" ] && continue

            file_count=$(echo "$grp_files" | tr ',' '\n' | grep -c '.' || echo "0")

            if [ "$file_count" -gt 3 ]; then
                first_three=$(echo "$grp_files" | cut -d',' -f1-3 | sed 's/,/, /g')
                remaining=$((file_count - 3))
                preview="${first_three}, ... (+${remaining} more)"
            else
                preview=$(echo "$grp_files" | sed 's/,/, /g')
            fi

            count_str="($file_count files):"
            [ "$file_count" -eq 1 ] && count_str="($file_count file):"
            printf '  • %-10s %-11s %s\n' "$grp_scope" "$count_str" "$preview"
        done <<< "$scope_groups"
        echo ""
    fi

    echo "Split into $count atomic commits? ([Y]/n/all-in-one)"
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
    echo "✅ Committed!"
}

display_commit_confirmation() {
    echo "Use this message? ([Y]/n/e to edit)"
}
