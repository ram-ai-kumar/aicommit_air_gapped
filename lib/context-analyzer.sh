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
        -v cochange_min="${AI_COCHANGE_MIN:-2}" \
        -v sym_max="${AI_SYMBOL_MAX_FILES:-4}" '
    function basename_of(p,   b) { b = p; sub(/^.*\//, "", b); return b }
    function dirname_of(p,   d) { d = p; return (sub(/\/[^\/]*$/, "", d) ? d : ".") }
    function dir2(p,   d, a, n) {
        d = dirname_of(p)
        if (d == ".") return "."
        n = split(d, a, "/")
        return (n >= 2) ? a[1] "/" a[2] : a[1]
    }
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
                if (line ~ /^rename from /)   { old_path[cur] = substr(line, 12); continue }
                if (line ~ /^new file mode/)  { status[cur] = "A"; continue }
                if (line ~ /^deleted file mode/) { status[cur] = "D"; continue }
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
        # the hunks of file B (word-boundary match, not bare substring).
        # Guarded: skip symbols appearing in more than sym_max files.
        for (sym in definer) {
            nd = split(definer[sym], dl, " ")
            if (nd > sym_max) continue
            first = ""
            for (j = 1; j <= nd; j++) { if (first == "") first = dl[j]; else union(first, dl[j]) }
            if (first == "") continue
            re = "(^|[^A-Za-z0-9_])" sym "([^A-Za-z0-9_]|$)"
            m_cnt = 0
            for (i = 1; i <= nf; i++) {
                f = files[i]
                if ((f SUBSEP sym) in defs) continue
                if (hunk[f] ~ re) m_cnt++
            }
            if (nd + m_cnt > sym_max) continue
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

        # Edge 3.5 — relocation families: renames sharing an old->new parent-dir
        # transform signature bind together (e.g. docs/delivery/* -> docs/platform/*).
        # Deletes+adds with a basename unique on both sides are treated as one
        # relocation git could not pair below the similarity threshold.
        for (i = 1; i <= nf; i++) {
            f = files[i]
            if (f in old_path) {
                d_old = dir2(old_path[f]); d_new = dir2(f)
                if (d_old != d_new) pair_sig[f] = d_old SUBSEP d_new
            }
            else if ((f in status) && status[f] == "D") { bn = basename_of(f); del_f[bn] = f; del_cnt[bn]++ }
            else if ((f in status) && status[f] == "A") { bn = basename_of(f); add_f[bn] = f; add_cnt[bn]++ }
        }
        for (bn in del_cnt) {
            if (del_cnt[bn] == 1 && (bn in add_cnt) && add_cnt[bn] == 1) {
                s = dir2(del_f[bn]) SUBSEP dir2(add_f[bn])
                pair_sig[del_f[bn]] = s; pair_sig[add_f[bn]] = s
            }
        }
        for (f in pair_sig) {
            if (pair_sig[f] in sig_first) union(sig_first[pair_sig[f]], f)
            else sig_first[pair_sig[f]] = f
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

# Emit a normalized status map of the staged set: STATUS<TAB>path[<TAB>old_path]
# R/C rows carry the source path in field 3. One git call; statuses feed the
# grouping prompt and (via the diff headers) the relocation edge.
staged_status_map() {
    agit diff --staged --name-status -M 2>/dev/null | awk -F'\t' '{
        if ($1 == "") next
        st = $1
        if (st ~ /^[RC]/ && NF >= 3) printf "%s\t%s\t%s\n", substr(st, 1, 1), $3, $2
        else if (NF >= 2) printf "%s\t%s\n", substr(st, 1, 1), $2
    }'
}

# Canonical cache key for grouping artifacts — the exact staged-state identity
# plus every input that can change grouping output (grouping prompt, algorithm
# version, model/backend and all grouping-related knobs). Any difference in the
# staged set or these inputs produces a different key → cache miss → re-analyze.
grouping_state_key() {
    local ssk gprompt_hash run_dir uh_hash=""
    ssk=$(staged_state_key) || return 1
    gprompt_hash=$(shasum -a 256 "${AI_GROUPING_PROMPT_FILE:-/dev/null}" 2>/dev/null | awk '{print $1}')
    run_dir=$(get_aicommit_tmp_dir 2>/dev/null || echo "")
    if [ -n "$run_dir" ] && [ -s "${run_dir}/USER_HINTS" ]; then
        uh_hash=$(shasum -a 256 "${run_dir}/USER_HINTS" 2>/dev/null | awk '{print $1}')
    fi
    printf '%s\ngprompt:%s\nhints:%s\nalgo:%s\nbackend:%s\nmodel:%s\nseed:%s\nnum_ctx:%s\nnp:%s\nmaxpaths:%s\ndisable:%s\nenable:%s\nnso:%s\n' \
        "$ssk" "$gprompt_hash" "$uh_hash" "${AICOMMIT_GROUPING_ALGO_VERSION:-v3}" "${AI_BACKEND:-ollama}" \
        "${AI_MODEL:-$DEFAULT_AI_MODEL}" "${AI_SEED:-42}" "${AI_NUM_CTX:-16384}" \
        "${AI_GROUPING_NUM_PREDICT:-2048}" "${AI_GROUPING_MAX_PATHS:-1000}" \
        "${AI_DISABLE_GROUPING:-false}" "${AI_ENABLE_LLM_GROUPING:-true}" \
        "${AI_NO_STRUCTURED_OUTPUT:-false}" | shasum -a 256 | awk '{print $1}'
}

# Record how the current grouping was produced (ai / cache / single /
# deterministic / fallback:<reason>) for dry-run and --verbose display.
_write_grouping_source() {
    local run_dir
    run_dir=$(get_aicommit_tmp_dir 2>/dev/null || echo "")
    [ -n "$run_dir" ] || return 0
    printf '%s\n' "$1" > "${run_dir}/GROUPING_SOURCE" 2>/dev/null || true
}

# Name deterministic components with infer_logical_file_context of the first
# file; colliding names get a numeric suffix (input order is sorted → stable).
# Args: $1=comp_lines ("i\tf1\tf2" per line)
_name_component_lines() {
    local comp_lines="$1"
    local line first_file name base n used_names=" " files_tab=""
    local common_dir leaf
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        _aicommit_split_tab_line "$line"
        [ ${#_aicommit_split_files[@]} -eq 0 ] && continue
        first_file=$(printf '%s' "$line" | cut -f2)
        name=$(infer_logical_file_context "$first_file")
        # Generic bucket name + members sharing a deeper common leaf dir →
        # name the component by that leaf instead of "docs-12".
        case "$name" in
            docs|config|scripts|core)
                if [ ${#_aicommit_split_files[@]} -ge 2 ]; then
                    common_dir=$(printf '%s\n' "${_aicommit_split_files[@]}" | awk -F/ '
                        { n = split($0, a, "/")
                          if (NR == 1) { m = n - 1; for (i = 1; i <= m; i++) c[i] = a[i] }
                          else { for (i = 1; i <= m && i < n; i++) if (a[i] != c[i]) m = i - 1 }
                        }
                        END { s = ""; for (i = 1; i <= m; i++) s = (s == "" ? c[i] : s "/" c[i]); print s }')
                    leaf="${common_dir##*/}"
                    case "$leaf" in
                        docs|doc|src|lib|app|test|tests|"") ;;
                        *) [ "$common_dir" != "." ] && name="$leaf" ;;
                    esac
                fi
                ;;
        esac
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

# Ask the LLM to name/merge/split the deterministic components into
# intent-scoped commit groups. Input = component listing with per-file status
# tags (A/M/D/R:old=>new) — statuses and rename origins are what let the model
# infer relocation/restructure intent instead of naming by file type.
# Response = {"groups":[{"name","type","members":[ids],"files":[paths]}]}:
# members merges whole components, files splits or partitions path-by-path.
# Args: $1=comp_lines, $2=staged_files, $3=namestatus_file (optional)
name_groups_with_ai() {
    local comp_lines="$1" staged_files="$2" namestatus_file="${3:-}"
    local prompt_template="${AI_GROUPING_PROMPT_FILE:-$AICOMMIT_DIR/templates/context-grouping-prompt.txt}"
    [ ! -f "$prompt_template" ] && return 1
    command -v invoke_llm >/dev/null 2>&1 || return 1
    command -v build_ollama_request >/dev/null 2>&1 || return 1

    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir) || return 1
    local user_file="${tmp_dir}/GROUPING_USER" schema_file="${tmp_dir}/GROUPING_SCHEMA.json"
    local req="${tmp_dir}/GROUPING_REQUEST.json" resp="${tmp_dir}/GROUPING_RESPONSE" err="${tmp_dir}/GROUPING_ERROR"
    local comp_lines_file="${tmp_dir}/GROUPING_COMPS"

    umask 077
    printf '%s\n' "$comp_lines" > "$comp_lines_file"

    local comp_count maxpaths per_comp
    comp_count=$(printf '%s\n' "$comp_lines" | awk 'NF { c++ } END { print c + 0 }')
    maxpaths="${AI_GROUPING_MAX_PATHS:-1000}"
    per_comp=$(( maxpaths / (comp_count > 0 ? comp_count : 1) ))
    [ "$per_comp" -lt 5 ] && per_comp=5
    [ "$per_comp" -gt 40 ] && per_comp=40

    # Component listing with inline status tags and faceted distribution summaries
    {
        if [ -s "${tmp_dir}/USER_HINTS" ]; then
            printf '=== USER INTENT HINTS (HIGH PRIORITY) ===\n'
            while IFS= read -r uh; do
                [ -n "$uh" ] && printf -- '- %s\n' "$uh"
            done < "${tmp_dir}/USER_HINTS"
            printf '\n'
        fi
        printf 'Staged files were clustered into structural components. Each file is tagged A=added M=modified D=deleted R=renamed(old=>new).\n'
        awk -F'\t' -v status_file="$namestatus_file" -v per_comp="$per_comp" \
            -v sensitive="$_AICOMMIT_SENSITIVE_RE" '
        BEGIN {
            if (status_file != "") {
                while ((getline l < status_file) > 0) {
                    n = split(l, p, "\t")
                    if (n >= 3 && (p[1] == "R" || p[1] == "C")) st[p[2]] = p[1] ":" p[3] "=>"
                    else if (n >= 2) st[p[2]] = p[1] ":"
                }
                close(status_file)
            }
        }
        {
            total = 0; r_cnt = 0; m_cnt = 0; a_cnt = 0; d_cnt = 0
            for (i = 2; i <= NF; i++) {
                if ($i == "" || $i ~ sensitive) continue
                total++
                s = substr(st[$i], 1, 1)
                if (s == "R" || s == "C") r_cnt++
                else if (s == "M") m_cnt++
                else if (s == "A") a_cnt++
                else if (s == "D") d_cnt++
            }
            if (total == 0) next
            dist = ""
            if (r_cnt > 0) dist = dist (dist == "" ? "" : ", ") r_cnt " renamed"
            if (m_cnt > 0) dist = dist (dist == "" ? "" : ", ") m_cnt " modified"
            if (a_cnt > 0) dist = dist (dist == "" ? "" : ", ") a_cnt " added"
            if (d_cnt > 0) dist = dist (dist == "" ? "" : ", ") d_cnt " deleted"
            if (total > per_comp && dist != "") {
                printf "GROUP %s (%d files: %s):", $1, total, dist
            } else {
                printf "GROUP %s:", $1
            }
            shown = 0; rest = 0
            for (i = 2; i <= NF; i++) {
                if ($i == "" || $i ~ sensitive) continue
                if (shown < per_comp) {
                    printf "%s%s%s", (shown > 0 ? ", " : " "), st[$i], $i
                    shown++
                } else rest++
            }
            if (rest > 0) printf ", +%d more", rest
            printf "\n"
        }' "$comp_lines_file"
    } > "$user_file"

    local comp_ids staged_paths_json n_paths files_item
    comp_ids=$(printf '%s\n' "$comp_lines" | awk -F'\t' 'NF>=1 && $1!="" {print $1}' | jq -R . | jq -sc 'unique')
    staged_paths_json=$(printf '%s\n' "$staged_files" | jq -R . | jq -sc 'unique')
    n_paths=$(printf '%s' "$staged_paths_json" | jq 'length' 2>/dev/null || echo 0)
    files_item='{"type":"string"}'
    if [ "$n_paths" -gt 0 ] && [ "$n_paths" -le "${AI_GROUPING_MAX_ENUM_PATHS:-300}" ]; then
        files_item=$(jq -nc --argjson p "$staged_paths_json" '{type:"string", enum:$p}')
    fi

    local n_comp_ids min_groups=1
    n_comp_ids=$(printf '%s\n' "$comp_ids" | jq 'length' 2>/dev/null || echo 0)
    [ "$n_comp_ids" -ge 2 ] && min_groups=2

    jq -n --argjson ids "$comp_ids" --argjson files_item "$files_item" --argjson min_g "$min_groups" \
        '{type: "object", additionalProperties: false,
          properties: {groups: {type: "array", minItems: $min_g, items: {
            type: "object", additionalProperties: false,
            properties: {
                name:    {type: "string", maxLength: 60},
                type:    {type: "string", enum: ["feat","fix","docs","style","refactor","perf","test","build","ci","chore","revert"]},
                members: {type: "array", items: {type: "string", enum: $ids}},
                files:   {type: "array", items: $files_item}
            },
            required: ["name", "type"]}}},
          required: ["groups"]}' > "$schema_file" || return 1

    # The flat AI_NUM_PREDICT cap truncates the response on large group counts —
    # scale with component count, bounded by the grouping-specific knobs.
    local np
    np=$(( comp_count * 48 ))
    [ "$np" -lt "${AI_GROUPING_NUM_PREDICT:-2048}" ] && np="${AI_GROUPING_NUM_PREDICT:-2048}"
    [ "$np" -gt "${AI_GROUPING_NUM_PREDICT_MAX:-8192}" ] && np="${AI_GROUPING_NUM_PREDICT_MAX:-8192}"

    if ! build_ollama_request "$req" "${AI_MODEL:-$DEFAULT_AI_MODEL}" "$user_file" "$prompt_template" "$schema_file" "$np"; then
        return 1
    fi

    : > "$resp"; : > "$err"
    if invoke_llm "${AI_MODEL:-$DEFAULT_AI_MODEL}" "$req" "$resp" "$err" "${AI_GROUPING_TIMEOUT:-60}" "Naming commit groups"; then
        cat "$resp" 2>/dev/null
        return 0
    fi
    _write_grouping_source "fallback:llm-error"
    return 1
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

        # Hybrid contract: members[] expands component ids, files[] lists
        # explicit paths (split/partition), and legacy "id" aliases members:[id].
        # Union them, then the staged/exactly-once filter below does the rest.
        local grp_ids
        grp_ids=$(printf '%s' "$raw" | jq -r ".groups[$gi] | (.members // [])[], (.id // empty)" 2>/dev/null)
        files=""
        local cid cfiles
        while IFS= read -r cid; do
            [ -z "$cid" ] && continue
            cfiles=$(awk -F'\t' -v target="$cid" '$1 == target { for (i = 2; i <= NF; i++) if ($i != "") print $i }' "$comp_files_file")
            [ -n "$cfiles" ] && files="${files}${files:+$'\n'}${cfiles}"
        done <<< "$grp_ids"
        local efiles
        efiles=$(printf '%s' "$raw" | jq -r ".groups[$gi].files[]?" 2>/dev/null)
        [ -n "$efiles" ] && files="${files}${files:+$'\n'}${efiles}"

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
        _write_grouping_source "single"
        return 0
    fi

    # Grouping cache — keyed by the exact staged state plus all grouping inputs.
    # Any difference in staged files, statuses, content or grouping config
    # produces a different key → miss → re-analysis.
    local state_dir="" key="" cdir=""
    state_dir=$(get_aicommit_state_dir 2>/dev/null) || state_dir=""
    key=$(grouping_state_key 2>/dev/null || echo "")
    if [ -n "$state_dir" ] && [ -n "$key" ]; then
        cdir="${state_dir}/cache/${key}"
        if [ -s "${cdir}/GROUPS" ]; then
            cat "${cdir}/GROUPS"
            _write_grouping_source "cache"
            return 0
        fi
    fi
    if [ -n "$state_dir" ] && [ -n "$key" ] && [ -f "${state_dir}/GROUPS_KEY" ] \
        && [ "$(cat "${state_dir}/GROUPS_KEY" 2>/dev/null)" = "$key" ] \
        && [ -s "${state_dir}/GROUPS_CACHE" ]; then
        cat "${state_dir}/GROUPS_CACHE"
        _write_grouping_source "cache"
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
    rm -f "${tmp_dir}/GROUPING_SOURCE"
    # Per-file status map (A/M/D/R + rename origins) — feeds the grouping prompt
    staged_status_map > "${tmp_dir}/NAMESTATUS" 2>/dev/null || : > "${tmp_dir}/NAMESTATUS"
    if [ -n "$state_dir" ]; then
        build_cochange_cache "$state_dir" >/dev/null 2>&1 && cochange_file="${state_dir}/COCHANGE"
    fi

    local comp_lines result="" comp_count=0 provenance=""
    comp_lines=$(cluster_staged_files_deterministic "$staged_files" "$diff_file" "$cochange_file")
    comp_count=$(printf '%s\n' "$comp_lines" | awk 'NF' | wc -l | tr -d ' ')

    if [ "$comp_count" -gt 1 ]; then
        if [ "${AI_ENABLE_LLM_GROUPING:-true}" != "true" ] || [ "${AI_DISABLE_GROUPING:-false}" = "true" ]; then
            provenance="fallback:disabled"
        elif ! validate_backend_prerequisites >/dev/null 2>&1; then
            provenance="fallback:no-backend"
        else
            local ai_json
            ai_json=$(name_groups_with_ai "$comp_lines" "$staged_files" "${tmp_dir}/NAMESTATUS")
            if [ -n "$ai_json" ]; then
                result=$(reconcile_grouping_json "$ai_json" "$staged_files" "$comp_lines")
                if [ -n "$result" ]; then
                    local res_count
                    res_count=$(printf '%s\n' "$result" | count_lines)
                    if [ "$comp_count" -ge 2 ] && [ "$res_count" -lt 2 ]; then
                        result=$(_name_component_lines "$comp_lines")
                        provenance="fallback:collapsed-single"
                    else
                        provenance="ai"
                    fi
                else
                    provenance="fallback:invalid-json"
                fi
            else
                [ -s "${tmp_dir}/GROUPING_SOURCE" ] || provenance="fallback:llm-empty"
            fi
        fi
    fi

    if [ -z "$result" ]; then
        result=$(_name_component_lines "$comp_lines")
    fi
    # name_groups_with_ai may have already recorded a more specific reason
    # (e.g. fallback:llm-error) — only write when it hasn't.
    [ -s "${tmp_dir}/GROUPING_SOURCE" ] || _write_grouping_source "${provenance:-deterministic}"

    if [ -n "$state_dir" ] && [ -n "$result" ]; then
        if [ -n "$key" ]; then
            local cache_base="${state_dir}/cache"
            [ -d "$cache_base" ] || mkdir -m 700 -p "$cache_base" 2>/dev/null || true
            [ -d "$cdir" ] || mkdir -m 700 -p "$cdir" 2>/dev/null || true
            if [ -d "$cdir" ]; then
                printf '%s\n' "$result" > "${cdir}/GROUPS.tmp" && mv "${cdir}/GROUPS.tmp" "${cdir}/GROUPS"
            fi
            printf '%s' "$key" > "${state_dir}/GROUPS_KEY.tmp" && mv "${state_dir}/GROUPS_KEY.tmp" "${state_dir}/GROUPS_KEY"
            printf '%s\n' "$result" > "${state_dir}/GROUPS_CACHE.tmp" && mv "${state_dir}/GROUPS_CACHE.tmp" "${state_dir}/GROUPS_CACHE"
        fi
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
