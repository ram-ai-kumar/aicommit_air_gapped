#!/usr/bin/env bash
# aicommit — Context Analyzer
# Analyzes staged changes to provide structural hints for commit message
# generation, and clusters staged files into atomic commit groups.

# Single shared sensitive-path rule (was: the same grep -E pattern repeated in
# three functions — the DRY-on-third-occurrence rule). Case glob, not grep, so
# it costs zero subprocesses inside loops.
_AICOMMIT_SENSITIVE_RE='\.env$|\.env\.|config\.ini|.*secrets.*|.*credentials.*|.*\.key|.*\.pem|.*\.p12'

is_sensitive_path() {
    case "$1" in
        *.env|*.env.*|*config.ini*|*secrets*|*credentials*|*.key*|*.pem*|*.p12*) return 0 ;;
        *) return 1 ;;
    esac
}

# Join arguments with ", " (avoids mutating IFS).
_aicommit_join_csv() {
    local s
    s=$(printf '%s, ' "$@")
    printf '%s' "${s%, }"
}

# Categorize staged files into structural layers.
# Outputs a FILE CATEGORIES block used as context and for diff filtering.
# Also writes asset filenames (newline-separated) to ${out_dir}/ASSET_FILES
# so build_ai_context can exclude their diffs.
categorize_staged_files() {
    local staged_files="$1"
    local out_dir="$2"

    local source_files=() config_files=() doc_files=() infra_files=() test_files=() asset_files=()

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        # Sensitive files are never categorized — they must not reach the prompt
        if is_sensitive_path "$file"; then
            continue
        fi
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
            # Config / environment / lock files
            *.yaml|*.yml|*.json|*.toml|*.conf|\
            config/*|.config/*|\
            *.lock|*lock.json|*lock.yaml)
                config_files+=("$file") ;;
            # Functional source — catch-all
            *)
                source_files+=("$file") ;;
        esac
    done <<< "$staged_files"

    # Write asset filenames for diff exclusion in build_ai_context
    if [ -n "$out_dir" ]; then
        printf '' > "${out_dir}/ASSET_FILES"
        for f in "${asset_files[@]}"; do
            printf '%s\n' "$f" >> "${out_dir}/ASSET_FILES"
        done
    fi

    local output="=== FILE CATEGORIES ==="
    [ ${#source_files[@]} -gt 0 ] && output="${output}\nFunctional Source:  $(_aicommit_join_csv "${source_files[@]}")"
    [ ${#config_files[@]} -gt 0 ] && output="${output}\nConfiguration:      $(_aicommit_join_csv "${config_files[@]}")"
    [ ${#doc_files[@]} -gt 0 ]    && output="${output}\nDocumentation:      $(_aicommit_join_csv "${doc_files[@]}")"
    [ ${#infra_files[@]} -gt 0 ]  && output="${output}\nInfrastructure/CI:  $(_aicommit_join_csv "${infra_files[@]}")"
    [ ${#test_files[@]} -gt 0 ]   && output="${output}\nTests:              $(_aicommit_join_csv "${test_files[@]}")"
    [ ${#asset_files[@]} -gt 0 ]  && output="${output}\nStatic Assets (diff excluded): $(_aicommit_join_csv "${asset_files[@]}")"

    printf '%b\n' "$output"
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

# Generic, project-agnostic context name for a file — used to name deterministic
# groups when the LLM is off (or as the single-file fast path). All previous
# domain-specific heuristics (apartment, devise, product/spare, navbar, bank)
# were from another project and are replaced by graph clustering.
infer_logical_file_context() {
    local file="$1"
    case "$file" in
        test/*|tests/*|spec/*|__tests__/*|*.test.*|*.spec.*|*_test.*|test_*.*|*.bats)
            echo "test" ;;
        *.md|*.rst|docs/*|doc/*|README*|CHANGELOG*|CONTRIBUTING*|LICENSE*|AGENTS*|*.txt)
            echo "docs" ;;
        .github/*|.gitlab-ci.yml|.circleci/*|Jenkinsfile|Dockerfile*|docker-compose*|k8s/*|kubernetes/*|terraform/*|helm/*)
            echo "ci" ;;
        db/migrate/*|migrations/*|alembic/*|db/schema*|db/seeds*|db/structure*)
            echo "db" ;;
        *)
            infer_file_scope "$file" ;;
    esac
}

# ─── Deterministic graph clustering ──────────────────────────────────────────
# Staged files become nodes in a graph; edges are structural facts, not guesses:
#   1. test↔subject stem pairing   test/unit/test_core.bats ↔ lib/core.sh
#   2. shared symbol               a definition changed in A's diff appears in B's
#   3. co-change history           files committed together ≥N times in git log -300
#   4. same leaf directory         weak edge, only attaches otherwise isolated files
# Groups are connected components (union-find), computed in one awk program —
# identical input always produces identical groups.

cluster_staged_files_deterministic() {
    local staged_files="$1"
    local diff_file="${2:-}"
    local cochange_file="${3:-}"

    printf '%s\n' "$staged_files" | LC_ALL=C sort | awk \
        -v diff_file="$diff_file" \
        -v cochange_file="$cochange_file" \
        -v cochange_min="${AI_COCHANGE_MIN:-2}" '
    function basename_of(p,   b) { b = p; sub(/^.*\//, "", b); return b }
    function dirname_of(p,   d) { d = p; return (sub(/\/[^\/]*$/, "", d) ? d : ".") }
    function norm_stem(b,   s) {
        s = b
        sub(/\.[^.\/]+$/, "", s)                                    # extension
        sub(/^(test|tests)_/, "", s)                               # test_ prefix
        sub(/(_test|_spec|\.test|\.spec|test_|spec_|-test|-spec)$/, "", s)
        return s
    }
    function is_test_path(p) {
        return p ~ /(^|\/)(tests?|spec|__tests__|testdata)\// || \
               p ~ /(_test|_spec|\.test|\.spec)\.[^.\/]+$/ || \
               p ~ /\.bats$/ || p ~ /(^|\/)test_[^\/]+$/
    }
    function find(x,   r, p2) {
        r = x
        while (parent[r] != r) r = parent[r]
        while (parent[x] != x) { p2 = parent[x]; parent[x] = r; x = p2 }
        return r
    }
    function union(a, b,   ra, rb) {
        ra = find(a); rb = find(b)
        if (ra != rb) { parent[rb] = ra; touched[a] = 1; touched[b] = 1 }
    }
    BEGIN {
        # Per-file hunk text + definitions changed, from the staged diff
        if (diff_file != "") {
            cur = ""
            while ((getline line < diff_file) > 0) {
                if (line ~ /^diff --git /) {
                    f = line
                    if (match(f, / b\/.*$/)) f = substr(f, RSTART + 3)
                    else { split(f, pp, " "); f = pp[3]; sub(/^b\//, "", f) }
                    cur = f
                    continue
                }
                if (cur == "") continue
                if (line ~ /^[+-]/ && line !~ /^[+-][+-][+-]/) {
                    hunk[cur] = hunk[cur] substr(line, 1, 300) "\n"
                    if (length(hunk[cur]) > 60000) hunk[cur] = substr(hunk[cur], 1, 60000)
                    sym = ""
                    if (match(line, /(^|[^A-Za-z0-9_])(def |function |func |class |interface |struct |enum )[A-Za-z_][A-Za-z0-9_]*/)) {
                        sym = substr(line, RSTART, RLENGTH); sub(/.* /, "", sym)
                    } else if (match(line, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\([^;{}]*\)[ \t]*\{/)) {
                        s = substr(line, RSTART, RLENGTH)
                        match(s, /^[A-Za-z_][A-Za-z0-9_]*/)
                        sym = substr(s, RSTART, RLENGTH)
                    }
                    if (sym != "" && length(sym) >= 5) defs[cur SUBSEP sym] = 1
                }
            }
            close(diff_file)
            for (k in defs) { split(k, a, SUBSEP); definer[a[2]] = definer[a[2]] " " a[1] }
        }
        # Co-change pairs; line 1 of the cache is the HEAD sha it was built at
        if (cochange_file != "") {
            getline _head < cochange_file
            while ((getline line < cochange_file) > 0) {
                n = split(line, p, "\t")
                if (n >= 3 && p[3] + 0 >= cochange_min) cpair[p[1] SUBSEP p[2]] = 1
            }
            close(cochange_file)
        }
    }
    { files[++nf] = $0; parent[$0] = $0 }
    END {
        # Edge 1 — test↔subject stem pairing
        for (i = 1; i <= nf; i++) {
            f = files[i]
            st = norm_stem(basename_of(f))
            stem_count[st]++
            stem_test[st] += (is_test_path(f) ? 1 : 0)
            stem_list[st] = stem_list[st] SUBSEP f
            if (!(st in stem_first)) stem_first[st] = f
        }
        for (st in stem_count) {
            if (stem_count[st] >= 2 && stem_test[st] >= 1 && stem_test[st] < stem_count[st]) {
                m = split(stem_list[st], sf, SUBSEP)
                for (j = 1; j <= m; j++) union(stem_first[st], sf[j])
            }
        }

        # Edge 2 — shared symbol: a definition changed in file A appears in
        # the hunks of file B (word-boundary match, not bare substring)
        for (sym in definer) {
            nd = split(definer[sym], dl, " ")
            first = ""
            for (j = 1; j <= nd; j++) { if (first == "") first = dl[j]; else union(first, dl[j]) }
            if (first == "") continue
            re = "(^|[^A-Za-z0-9_])" sym "([^A-Za-z0-9_]|$)"
            for (i = 1; i <= nf; i++) {
                f = files[i]
                if ((f SUBSEP sym) in defs) continue
                if (hunk[f] ~ re) union(first, f)
            }
        }

        # Edge 3 — co-change history (only when both files are staged)
        for (k in cpair) {
            split(k, a, SUBSEP)
            if ((a[1] in parent) && (a[2] in parent)) union(a[1], a[2])
        }

        # Edge 4 — same leaf directory, weak: only attaches files still
        # isolated after the strong edges. Existing components are preferred
        # attachment targets; leftover same-dir singletons bind together.
        for (i = 1; i <= nf; i++) {
            f = files[i]
            if (f in touched) dir_rep[dirname_of(f)] = find(f)
        }
        for (i = 1; i <= nf; i++) {
            f = files[i]
            if (f in touched) continue
            d = dirname_of(f)
            if (d == ".") continue
            if (d in dir_rep) union(dir_rep[d], f)
            else dir_rep[d] = f
        }

        # Emit components in first-appearance order — deterministic I/O
        ng = 0
        for (i = 1; i <= nf; i++) {
            r = find(files[i])
            if (!(r in seen)) { seen[r] = ++ng; order[ng] = r }
            members[r] = members[r] "\t" files[i]
        }
        for (g = 1; g <= ng; g++) printf "%d%s\n", g, members[order[g]]
    }
    '
}

# Build/refresh the co-change pair cache: pairs of files committed together in
# the last 300 commits, with counts. Line 1 is the HEAD sha it was computed at;
# a different HEAD → rebuild.
# Args: $1=state_dir
build_cochange_cache() {
    local state_dir="$1"
    local head_sha
    head_sha=$(agit rev-parse HEAD 2>/dev/null) || return 1
    local cache="${state_dir}/COCHANGE"
    if [ -f "$cache" ] && [ "$(head -1 "$cache" 2>/dev/null)" = "$head_sha" ]; then
        return 0
    fi
    local tmp="${cache}.tmp"
    {
        printf '%s\n' "$head_sha"
        agit log -300 --pretty=format:'__aicommit_commit__' --name-only 2>/dev/null | awk '
            function flush(   i, j, a, b) {
                # Mass commits carry mostly noise — cap fan-out per commit
                if (n >= 2 && n <= 40)
                    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
                        a = f[i]; b = f[j]
                        pairs[(a < b ? a : b) SUBSEP (a < b ? b : a)]++
                    }
                n = 0; delete f
            }
            $0 == "__aicommit_commit__" { flush(); next }
            NF { f[++n] = $0 }
            END {
                flush()
                for (k in pairs) {
                    split(k, a, SUBSEP)
                    printf "%s\t%s\t%d\n", a[1], a[2], pairs[k]
                }
            }'
    } > "$tmp" && mv "$tmp" "$cache"
}

# Name deterministic components with infer_logical_file_context of the first
# file; colliding names get a numeric suffix (input order is sorted → stable).
# Args: $1=comp_lines ("i\tf1\tf2" per line)
_name_component_lines() {
    local comp_lines="$1"
    local line first_file name base n used_names=" " files_tab=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        _aicommit_split_tab_line "$line"
        [ ${#_aicommit_split_files[@]} -eq 0 ] && continue
        first_file=$(printf '%s' "$line" | cut -f2)
        name=$(infer_logical_file_context "$first_file")
        [ -z "$name" ] && name="core"
        base="$name"; n=1
        while [[ "$used_names" == *" ${name} "* ]]; do
            n=$((n + 1)); name="${base}-${n}"
        done
        used_names="${used_names}${name} "
        files_tab=$(printf '%s\t' "${_aicommit_split_files[@]}")
        printf '%s\t%s\n' "$name" "${files_tab%$'\t'}"
    done <<< "$comp_lines"
}

# Heuristic grouping = deterministic clustering + deterministic naming.
# (Kept under its old name — the callers and fallback path are unchanged.)
group_staged_files_heuristically() {
    local staged_files="$1"
    local diff_file="${2:-}"
    local cochange_file="${3:-}"
    [ -z "$staged_files" ] && return 0
    local comp_lines
    comp_lines=$(cluster_staged_files_deterministic "$staged_files" "$diff_file" "$cochange_file")
    _name_component_lines "$comp_lines"
}

# Ask the LLM to NAME the deterministic groups (and optionally merge them).
# Schema uses component ids instead of re-listing every file path.
# Args: $1=comp_lines, $2=staged_files
name_groups_with_ai() {
    local comp_lines="$1" staged_files="$2"
    local prompt_template="${AI_GROUPING_PROMPT_FILE:-$AICOMMIT_DIR/templates/context-grouping-prompt.txt}"
    [ ! -f "$prompt_template" ] && return 1
    command -v invoke_llm >/dev/null 2>&1 || return 1
    command -v build_ollama_request >/dev/null 2>&1 || return 1

    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir) || return 1
    local user_file="${tmp_dir}/GROUPING_USER" schema_file="${tmp_dir}/GROUPING_SCHEMA.json"
    local req="${tmp_dir}/GROUPING_REQUEST.json" resp="${tmp_dir}/GROUPING_RESPONSE" err="${tmp_dir}/GROUPING_ERROR"

    umask 077
    {
        printf 'Deterministic groups to name (rename each by id; merge only if they serve the same change):\n'
        printf '%s\n' "$comp_lines" | awk -F'\t' '{ printf "GROUP %s (id: \"%s\"): ", NR, $1; for (i = 2; i <= NF; i++) printf "%s%s", (i>2?", ":""), $i; printf "\n" }'
    } > "$user_file"

    local comp_ids
    comp_ids=$(printf '%s\n' "$comp_lines" | awk -F'\t' 'NF>=1 && $1!="" {print $1}' | jq -R . | jq -sc 'unique')

    jq -n --argjson ids "$comp_ids" \
        '{type: "object", additionalProperties: false,
          properties: {groups: {type: "array", items: {
            type: "object", additionalProperties: false,
            properties: {
                id:         {type: "string", enum: $ids},
                name:       {type: "string", maxLength: 40},
                type:       {type: "string", enum: ["feat","fix","docs","style","refactor","perf","test","build","ci","chore","revert"]},
                merge_into: {type: "string"}
            },
            required: ["id", "name"]}}},
          required: ["groups"]}' > "$schema_file" || return 1

    if ! build_ollama_request "$req" "${AI_MODEL:-$DEFAULT_AI_MODEL}" "$user_file" "$prompt_template" "$schema_file"; then
        return 1
    fi

    : > "$resp"; : > "$err"
    if invoke_llm "${AI_MODEL:-$DEFAULT_AI_MODEL}" "$req" "$resp" "$err" "30" "Naming commit groups" >/dev/null 2>&1; then
        cat "$resp" 2>/dev/null
    else
        return 1
    fi
}

# Reconcile AI naming output against the staged set: files must be staged and
# assigned exactly once; anything the model dropped is re-attached to its
# deterministic component (named by first file). Supports id-based and legacy files schema.
# Args: $1=raw_json, $2=staged_files, $3=comp_lines
reconcile_grouping_json() {
    local raw="$1" staged_files="$2" comp_lines="${3:-}"

    if command -v extract_json_object >/dev/null 2>&1; then
        raw=$(extract_json_object "$raw" 2>/dev/null)
    fi

    printf '%s' "$raw" | jq -e '.groups | type == "array" and length > 0' >/dev/null 2>&1 || return 1

    local ngroups gi name id files f files_tab="" out="" used_names=" " seen=" "
    ngroups=$(printf '%s' "$raw" | jq '.groups | length' 2>/dev/null)

    # file -> component id map for re-attaching dropped files
    local comp_map_file comp_files_file
    comp_map_file=$(mktemp "${TMPDIR:-/tmp}/aicommit.compmap.XXXXXX") || return 1
    comp_files_file=$(mktemp "${TMPDIR:-/tmp}/aicommit.compfiles.XXXXXX") || return 1
    printf '%s\n' "$comp_lines" | awk -F'\t' '{ for (i = 2; i <= NF; i++) if ($i != "") printf "%s\t%s\n", $i, $1 }' > "$comp_map_file"
    printf '%s\n' "$comp_lines" | awk -F'\t' '{ printf "%s\t", $1; for (i = 2; i <= NF; i++) if ($i != "") printf "%s\t", $i; printf "\n" }' > "$comp_files_file"

    for ((gi = 0; gi < ngroups; gi++)); do
        name=$(printf '%s' "$raw" | jq -r ".groups[$gi].name // empty" 2>/dev/null \
            | sed -E 's/[=|`*]//g; s/^[[:space:]#-]+//; s/[[:space:]]+$//' | cut -c1-60)
        [ -z "$name" ] && name="changes"

        id=$(printf '%s' "$raw" | jq -r ".groups[$gi].id // empty" 2>/dev/null)
        if [ -n "$id" ]; then
            files=$(awk -F'\t' -v target="$id" '$1 == target { for (i = 2; i <= NF; i++) if ($i != "") print $i }' "$comp_files_file")
        else
            files=$(printf '%s' "$raw" | jq -r ".groups[$gi].files[]?" 2>/dev/null)
        fi

        files_tab=""
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            printf '%s\n' "$staged_files" | grep -qxF "$f" || continue   # must be staged
            [[ "$seen" == *" ${f} "* ]] && continue                     # once only
            seen="${seen}${f} "
            files_tab="${files_tab}${f}\t"
        done <<< "$files"
        [ -z "$files_tab" ] && continue

        local base="$name" n=1
        while [[ "$used_names" == *" ${name} "* ]]; do
            n=$((n + 1)); name="${base}-${n}"
        done
        used_names="${used_names}${name} "
        out="${out}${name}\t${files_tab%\\t}\n"
    done
    rm -f "$comp_files_file"

    # Leftover staged files → back into their deterministic components.
    # Build "comp_id\tfile" pairs, group in component order.
    local leftover_pairs
    leftover_pairs=$(while IFS= read -r f; do
        [ -z "$f" ] && continue
        [[ "$seen" == *" ${f} "* ]] && continue
        comp_id=$(awk -F'\t' -v f="$f" '$1 == f { print $2; exit }' "$comp_map_file")
        printf '%s\t%s\n' "${comp_id:-999}" "$f"
    done <<< "$staged_files" | sort -n)
    rm -f "$comp_map_file"

    if [ -n "$leftover_pairs" ]; then
        local cur_cid="" cur_files="" cid="" lf="" leftover_first=""
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            cid="${line%%$'\t'*}"
            lf="${line#*$'\t'}"
            if [ "$cid" != "$cur_cid" ]; then
                if [ -n "$cur_files" ]; then
                    leftover_first="${cur_files%%$'\t'*}"
                    name=$(infer_logical_file_context "$leftover_first")
                    [ -z "$name" ] && name="changes"
                    local base="$name" n=1
                    while [[ "$used_names" == *" ${name} "* ]]; do
                        n=$((n + 1)); name="${base}-${n}"
                    done
                    used_names="${used_names}${name} "
                    out="${out}${name}\t${cur_files}\n"
                fi
                cur_cid="$cid"; cur_files=""
            fi
            cur_files="${cur_files:+${cur_files}$'\t'}${lf}"
        done <<< "$leftover_pairs"
        if [ -n "$cur_files" ]; then
            leftover_first="${cur_files%%$'\t'*}"
            name=$(infer_logical_file_context "$leftover_first")
            [ -z "$name" ] && name="changes"
            local base="$name" n=1
            while [[ "$used_names" == *" ${name} "* ]]; do
                n=$((n + 1)); name="${base}-${n}"
            done
            used_names="${used_names}${name} "
            out="${out}${name}\t${cur_files}\n"
        fi
    fi

    [ -z "$out" ] && return 1
    printf '%b' "$out"
}

# Group staged files into logical contexts.
# Deterministic clustering first; the LLM only names/merges components when
# enabled and available. Falls back to deterministic naming.
# Outputs TAB-delimited records: "<scope>\t<file1>\t<file2>\t..."
group_staged_files_logically() {
    local staged_files="$1"
    local changes="${2:-}"
    local numstat_data="${3:-}"

    [ -z "$staged_files" ] && return 0

    local file_count
    file_count=$(printf '%s\n' "$staged_files" | count_lines)
    if [ "$file_count" -le 1 ]; then
        local single_file="$staged_files"
        # Trim only leading/trailing whitespace — `tr -d '[:space:]'` (the prior
        # approach) strips ALL whitespace, corrupting any filename containing a
        # space, which is common in this vault ("Enterprise Architecture.md").
        single_file="${single_file#"${single_file%%[![:space:]]*}"}"
        single_file="${single_file%"${single_file##*[![:space:]]}"}"
        if [ -n "$single_file" ]; then
            local single_scope
            single_scope=$(infer_logical_file_context "$single_file")
            printf '%s\t%s\n' "$single_scope" "$single_file"
        fi
        return 0
    fi

    # Grouping cache — content-addressed by staged files and diff
    local state_dir="" key="" cdir=""
    state_dir=$(get_aicommit_state_dir 2>/dev/null) || state_dir=""
    if command -v get_aicommit_cache_key >/dev/null 2>&1; then
        key=$(get_aicommit_cache_key 2>/dev/null || echo "")
    else
        key=$(printf '%s\n' "$staged_files" | sort | shasum -a 256 | awk '{print $1}')
    fi
    if [ -n "$state_dir" ] && [ -n "$key" ]; then
        cdir="${state_dir}/cache/${key}"
        if [ -s "${cdir}/GROUPS" ]; then
            cat "${cdir}/GROUPS"
            return 0
        fi
    fi
    if [ -n "$state_dir" ] && [ -f "${state_dir}/GROUPS_KEY" ] \
        && [ "$(cat "${state_dir}/GROUPS_KEY" 2>/dev/null)" = "$key" ] \
        && [ -s "${state_dir}/GROUPS_CACHE" ]; then
        cat "${state_dir}/GROUPS_CACHE"
        return 0
    fi

    local tmp_dir diff_file cochange_file=""
    tmp_dir=$(get_aicommit_tmp_dir) || return 1
    diff_file="${tmp_dir}/GROUPING_DIFF"
    if [ -n "$changes" ]; then
        printf '%s' "$changes" > "$diff_file"
    elif [ -f "${tmp_dir}/STAGED_DIFF" ]; then
        diff_file="${tmp_dir}/STAGED_DIFF"
    else
        agit diff --staged > "$diff_file" 2>/dev/null || : > "$diff_file"
    fi
    if [ -n "$state_dir" ]; then
        build_cochange_cache "$state_dir" >/dev/null 2>&1 && cochange_file="${state_dir}/COCHANGE"
    fi

    local comp_lines result="" comp_count=0
    comp_lines=$(cluster_staged_files_deterministic "$staged_files" "$diff_file" "$cochange_file")
    comp_count=$(printf '%s\n' "$comp_lines" | awk 'NF' | wc -l | tr -d ' ')

    if [ "$comp_count" -gt 1 ] && [ "${AI_ENABLE_LLM_GROUPING:-true}" = "true" ] && [ "${AI_DISABLE_GROUPING:-false}" != "true" ] \
        && validate_backend_prerequisites >/dev/null 2>&1; then
        local ai_json
        ai_json=$(name_groups_with_ai "$comp_lines" "$staged_files")
        if [ -n "$ai_json" ]; then
            result=$(reconcile_grouping_json "$ai_json" "$staged_files" "$comp_lines")
        fi
    fi

    if [ -z "$result" ]; then
        result=$(_name_component_lines "$comp_lines")
    fi

    if [ -n "$state_dir" ] && [ -n "$result" ]; then
        if [ -n "$key" ]; then
            local cache_base="${state_dir}/cache"
            [ -d "$cache_base" ] || mkdir -m 700 -p "$cache_base" 2>/dev/null || true
            [ -d "$cdir" ] || mkdir -m 700 -p "$cdir" 2>/dev/null || true
            if [ -d "$cdir" ]; then
                printf '%s\n' "$result" > "${cdir}/GROUPS.tmp" && mv "${cdir}/GROUPS.tmp" "${cdir}/GROUPS"
            fi
        fi
        printf '%s' "$key" > "${state_dir}/GROUPS_KEY.tmp" && mv "${state_dir}/GROUPS_KEY.tmp" "${state_dir}/GROUPS_KEY"
        printf '%s\n' "$result" > "${state_dir}/GROUPS_CACHE.tmp" && mv "${state_dir}/GROUPS_CACHE.tmp" "${state_dir}/GROUPS_CACHE"
    fi

    printf '%s\n' "$result"
}

# Backward compatible aliases
group_staged_files_by_scope() {
    local staged_files="$1"
    local changes="${2:-}"
    local numstat_data="${3:-}"

    group_staged_files_logically "$staged_files" "$changes" "$numstat_data"
}

# Returns count of unique scopes/contexts (grouping is cached — this is cheap)
count_staged_scopes() {
    local staged_files="$1"
    local changes="${2:-}"
    local numstat_data="${3:-}"

    group_staged_files_logically "$staged_files" "$changes" "$numstat_data" | count_lines
}
