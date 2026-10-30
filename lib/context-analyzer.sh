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
        test/*|tests/*|spec/*|__tests__/*|*/test/*|*/tests/*|*/spec/*|*/__tests__/*|*.test.*|*.spec.*|*.bats)
            echo "test" ;;
        docs/*|*.md|*.rst|README*|CHANGELOG*|CONTRIBUTING*)
            echo "docs" ;;
        templates/*|*prompt*)
            echo "prompt" ;;
        src/components/*|components/*|*/src/components/*|*/components/*)
            local comp_sub=""
            comp_sub=$(echo "$file" | sed -E 's#^(.*/)?components/([^/]+).*#\2#')
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
        src/*|app/*|*/src/*|*/app/*)
            local mod=""
            # Segment right after the first src/ or app/ marker — root layouts
            # give the same answer as before; prefixed roots (frontend/src,
            # backend/app, packages/x/src) previously fell through to leaf dirs.
            mod=$(echo "$file" | sed -E 's#^(.*/)?(src|app)/([^/]+).*#\3#')
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
        test/*|tests/*|spec/*|__tests__/*|*/test/*|*/tests/*|*/spec/*|*/__tests__/*|*.test.*|*.spec.*|*_test.*|test_*.*|*.bats)
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
#   1. domain feature + test↔subject stem pairing (newly added tests pair with
#      a staged same-stem subject; unpaired ones consolidate by layer in
#      Cycle 5. Ambiguous `test_*` basenames outside test dirs classify by
#      staged-hunk test markers, so api/routes/test_personas.py is a subject)
#   2. shared symbol (non-test definers only) + replicated-edit signatures:
#      identical or receiver-masked added lines shared across files = one
#      replicated change (e.g. `foo&.bar` nil-safety added to many views)
#   3. co-change history           files committed together ≥N times in git log -300
#   4. same leaf directory         weak edge, only attaches otherwise isolated
#      files, and only when the rep's component lives entirely in that dir
#   5. unpaired test consolidation — untouched tests bucket by layer, capped
#      at AI_MAX_GROUP_SIZE (paired tests stay with their subject)
# Groups are connected components (union-find), computed in one awk program —
# identical input always produces identical groups. Set AICOMMIT_GROUP_DEBUG to
# a path (or /dev/stdout) to log every union edge tagged by cycle.

cluster_staged_files_deterministic() {
    local staged_files="$1"
    local diff_file="${2:-}"
    local cochange_file="${3:-}"
    local framework_patterns_file="${AI_FRAMEWORK_PATTERNS_FILE:-$AICOMMIT_DIR/config/framework-patterns.json}"

    printf '%s\n' "$staged_files" | LC_ALL=C sort | LC_ALL=C awk \
        -v diff_file="$diff_file" \
        -v cochange_file="$cochange_file" \
        -v cochange_min="${AI_COCHANGE_MIN:-2}" \
        -v sym_max="${AI_SYMBOL_MAX_FILES:-4}" \
        -v tgroup_max="${AI_MAX_GROUP_SIZE:-14}" \
        -v dbg="${AICOMMIT_GROUP_DEBUG:-}" \
        -v patterns_file="$framework_patterns_file" '
    function basename_of(p,   b) { b = p; sub(/^.*\//, "", b); return b }
    function dirname_of(p,   d) { d = p; return (sub(/\/[^\/]*$/, "", d) ? d : ".") }
    function dir2(p,   d, a, n) {
        d = dirname_of(p)
        if (d == ".") return "."
        n = split(d, a, "/")
        return (n >= 2) ? a[1] "/" a[2] : a[1]
    }
    function dir1(p,   a, n) {
        n = split(p, a, "/")
        return (n >= 2) ? a[1] : "."
    }
    function norm_stem(path,    b, s) {
        b = basename_of(path)
        if (b ~ /^use[A-Z]/) sub(/^use/, "", b)
        if (b ~ /^Test[A-Z]/) sub(/^Test/, "", b)
        if (b ~ /^Spec[A-Z]/) sub(/^Spec/, "", b)
        s = tolower(b)
        sub(/\.(g|freezed|mocks|part)\.dart$/, "", s)
        sub(/\.(module|spec|test)\.(css|scss|sass|less|ts|tsx|js|jsx)$/, "", s)
        sub(/\.html\.(erb|haml|slim)$/, "", s)
        sub(/\.[^.\/]+$/, "", s)
        sub(/^[0-9]+_/, "", s)
        while (sub(/^(test|tests|spec|specs)[_-]/, "", s)) { }
        sub(/(_test|_spec|\.test|\.spec|test_|spec_|-test|-spec|_tests|_specs)$/, "", s)
        sub(/^(create|add|update|remove|drop|alter|modify)_/, "", s)
        sub(/^use_/, "", s)
        sub(/(_controller|_controllers|_service|_services|_helper|_helpers|_serializer|_serializers|_router|_routers|_route|_routes|_routing|_model|_models|_schema|_schemas|_handler|_handlers|_client|_clients|_adapter|_adapters|_factory|_factories|_validator|_validators|_worker|_workers|_job|_jobs|_dto|_types|_screen|_screens|_widget|_widgets|_page|_pages|_view|_views|_bloc|_cubit|_event|_state|_notifier|_provider|_repository|_repositories|_datasource|_datasources)$/, "", s)
        if (s ~ /ies$/) sub(/ies$/, "y", s)
        else if (s ~ /(sses|shes|ches|xes|zes)$/) sub(/es$/, "", s)
        else if (s ~ /[^s]s$/ && length(s) > 3) sub(/s$/, "", s)
        return s
    }
    # Pairing key: separator-insensitive stem so `role-gate` ≡ `rolegate` and
    # `test-personas` ≡ `testpersonas`. Feature names keep the norm_stem form.
    function stem_key(path,   s) {
        s = norm_stem(path); gsub(/[-_]/, "", s); return s
    }
    function is_test_path(p) {
        return p ~ /(^|\/)(tests?|spec|__tests__|testdata)\// || \
               p ~ /(_test|_spec|\.test|\.spec)\.[^.\/]+$/ || \
               p ~ /\.bats$/ || p ~ /(^|\/)test_[^\/]+$/
    }
    # `test_*.py`-style basenames outside test dirs are ambiguous: pytest
    # collects them anywhere, but app code also names domain modules that way
    # (backend/app/api/routes/test_personas.py is an APIRouter module, not a
    # test). Resolve by sniffing the staged hunk for test markers.
    function is_ambiguous_test_name(p) {
        return p ~ /(^|\/)test_[^\/]+$/ && \
               p !~ /(^|\/)(tests?|spec|__tests__|testdata)\//
    }
    function hunk_is_test(f,   h) {
        h = hunk[f]
        return h ~ /(^|\n)[ \t+~-]*(import[ \t]+pytest|from[ \t]+pytest|import[ \t]+unittest|from[ \t]+unittest|def[ \t]+test_|class[ \t]+Test|TestClient|pytest\.|unittest\.)/ || \
               h ~ /(^|[^A-Za-z0-9_])(describe|it|test|expect)[ \t]*\(/
    }
    function is_test_file(f) {
        return is_test_path(f) && (!is_ambiguous_test_name(f) || hunk_is_test(f))
    }
    function test_bucket(p,   d, seg) {
        if (match(p, /(^|\/)(tests?|spec|__tests__)\/([^\/]+)/)) {
            seg = substr(p, RSTART, RLENGTH)
            sub(/^.*(tests?|spec|__tests__)\//, "", seg)
            if (seg ~ /^(controllers?|models?|mailers?|helpers?|views?|integration|requests?|routing|channels?|jobs?|policies?|serializers?|units?|functional)$/) return "cov:" seg
            return "infra"
        }
        d = dirname_of(p); return "dir:" d
    }
    # Sets _featdir=1 when the returned feature came from dir-walkback (weak
    # guess), 0 when it is the file stem itself or an explicit features/ dir
    # (authoritative). Cycle 1 uses this to keep dir-derived features from
    # bridging unrelated directory trees.
    function feature_of(path,    p, d, s, n, a, seg, idx) {
        _featdir = 0
        if (match(path, /(^|\/)(features?|modules?)\/([^\/]+)\//)) {
            seg = substr(path, RSTART, RLENGTH)
            sub(/^.*(features?|modules?)\//, "", seg)
            sub(/\/.*$/, "", seg)
            seg = tolower(seg)
            if (seg ~ /ies$/) sub(/ies$/, "y", seg)
            else if (seg ~ /(sses|shes|ches|xes|zes)$/) sub(/es$/, "", seg)
            else if (seg ~ /[^s]s$/ && length(seg) > 3) sub(/s$/, "", seg)
            if (is_domain_keyword(seg)) return seg
        }
        s = norm_stem(path)
        if (s ~ /^(index|show|edit|new|form|create|update|list|detail|details|page|view|mod|lib|main|app|route|routes|router|routers|urls|handler|handlers|service|services|repository|repositories|client|clients|worker|workers|model|models|schema|schemas|types|dto|dtos|adapter|adapters|dao|controller|controllers|__init__|__main__|conftest)$/) {
            d = dirname_of(path); n = split(d, a, "/")
            for (idx = n; idx >= 1; idx--) {
                seg = tolower(a[idx])
                if (seg ~ /ies$/) sub(/ies$/, "y", seg)
                else if (seg ~ /(sses|shes|ches|xes|zes)$/) sub(/es$/, "", seg)
                else if (seg ~ /[^s]s$/ && length(seg) > 3) sub(/s$/, "", seg)
                if (seg !~ /^(routes?|routers?|urls|views?|screens?|widgets?|pages?|components?|app|lib|src|internal|pkg|api|endpoints?|v[0-9]+|features?|backend|frontend|server|web|mobile|packages?|apps?)$/) {
                    s = seg
                    _featdir = 1
                    break
                }
            }
        }
        return s
    }
    function is_domain_keyword(s) {
        return (s != "" && s !~ /^(test|tests|spec|specs|model|models|controller|controllers|view|views|helper|helpers|service|services|migration|migrations|route|routes|config|common|core|base|main|index|app|lib|src|doc|docs|readme|changelog|license|fixture|fixtures|script|scripts|bin|tool|tools|handler|handlers|repository|repositories|schema|schemas|types|dto|dtos|adapter|adapters|dao|client|clients|worker|workers|component|components|ui|__init__|__main__|conftest)$/ && length(s) >= 3)
    }
    function find(x,   r, p2) {
        r = x
        while (parent[r] != r) r = parent[r]
        while (parent[x] != x) { p2 = parent[x]; parent[x] = r; x = p2 }
        return r
    }
    function union(a, b,   ra, rb) {
        if (a == "" || b == "" || a == b) return
        ra = find(a); rb = find(b)
        if (ra != rb) { parent[rb] = ra; touched[a] = 1; touched[b] = 1; if (dbg != "") printf "UNION[%s] %s <- %s\n", cyc, a, b > dbg }
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
                    # Replicated-edit signatures — the same change applied to
                    # many files is the strongest merge signal the diff carries
                    # (e.g. `foo&.bar` nil-safety added to 25 views). Added
                    # lines only; three signature granularities per line.
                    if (line ~ /^\+/ && (!is_test_path(cur) || is_ambiguous_test_name(cur))) {
                        sig_src = substr(line, 2)
                        gsub(/[ \t]+/, " ", sig_src)
                        sub(/^ /, "", sig_src); sub(/ $/, "", sig_src)
                        if (length(sig_src) >= 12 && sig_src ~ /[.(&=\/]/ && \
                            sig_src !~ /^(end|else|elsif|elif|fi|done|rescue|ensure|when|then|do)[ ,;}]?$/) {
                            fsig[cur SUBSEP "L:" sig_src] = 1
                            sig_v = sig_src
                            gsub(/@[A-Za-z_][A-Za-z0-9_]*/, "@V", sig_v)
                            if (sig_v != sig_src && sig_v ~ /&\.|\.[A-Za-z_][A-Za-z0-9_]*\./)
                                fsig[cur SUBSEP "V:" sig_v] = 1
                            # Chain-tail signatures: `receiver.foo&.bar` → `foo&.bar`
                            sig_tmp = sig_v
                            while (match(sig_tmp, /[A-Za-z_][A-Za-z0-9_]*((&\.|\.)[A-Za-z_][A-Za-z0-9_]*)+/)) {
                                chain = substr(sig_tmp, RSTART, RLENGTH)
                                sig_tmp = substr(sig_tmp, RSTART + RLENGTH)
                                if (chain ~ /&\./ || gsub(/\./, ".", chain) >= 2) {
                                    # safe-nav attr tail: `x&.name`/`x.y&.name`
                                    # both mean the same nil-safe display fix
                                    if (chain ~ /&\./ && match(chain, /[A-Za-z_][A-Za-z0-9_]*$/))
                                        fsig[cur SUBSEP "C:&." substr(chain, RSTART)] = 1
                                    sub(/^[A-Za-z_][A-Za-z0-9_]*(&\.|\.)/, "", chain)
                                    if (chain ~ /&\.|\./) fsig[cur SUBSEP "C:" chain] = 1
                                }
                            }
                        }
                    }
                    sym = ""
                    if (match(line, /(^|[^A-Za-z0-9_])(def |function |func |fn |class |interface |struct |enum |module |trait |mixin )[A-Za-z_][A-Za-z0-9_]*/)) {
                        sym = substr(line, RSTART, RLENGTH); sub(/.*[ \t]/, "", sym)
                    } else if (match(line, /(^|[^A-Za-z0-9_])(sealed|abstract|base|final)[ \t]+class[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
                        sym = substr(line, RSTART, RLENGTH); sub(/.*[ \t]/, "", sym)
                    } else if (match(line, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\([^;{}]*\)[ \t]*\{/)) {
                        s = substr(line, RSTART, RLENGTH)
                        match(s, /^[A-Za-z_][A-Za-z0-9_]*/)
                        sym = substr(s, RSTART, RLENGTH)
                    }
                    # Ubiquitous names carry no pairing signal — a deleted
                    # CRUD `def delete`/`update`/`commit` must not glue its
                    # file to every other diff calling .delete()/.update().
                    if (sym != "" && length(sym) >= 5 && sym !~ /^(constructor|toString|hashCode|build|dispose|initState|render|setup|teardown|all|one|list|count|create|update|delete|save|commit|refresh|rollback|close|open|read|write|find|add|remove|load|init|run|main|start|stop|new|make|call|fetch|send|parse|format|handle|process|execute|apply|reset|clear|copy|clone|dict|json|str|repr|len|enter|exit|done|check|ensure|exists|validate|serialize|to_dict|from_dict|to_json|from_json|dump|dumps|loads|encode|decode|verify|use|data|name|value|item|items|key|result|response|request|error|message|config|settings|options|params|args|kwargs|self|cls|obj|record|row|rows|user)$/ && (!is_test_path(cur) || is_ambiguous_test_name(cur))) {
                        defs[cur SUBSEP sym] = 1
                    }
                    if (match(line, /(resources|resource|create_table)[ \t]+:([A-Za-z0-9_]+)/)) {
                        res = substr(line, RSTART, RLENGTH)
                        sub(/.*:/, "", res)
                        res = tolower(res)
                        if (res ~ /ies$/) sub(/ies$/, "y", res)
                        else if (res ~ /[^s]s$/ && length(res) > 3) sub(/s$/, "", res)
                        if (length(res) >= 3) {
                            diff_features[cur SUBSEP res] = 1
                            diff_feat_count[cur SUBSEP res]++
                        }
                    }
                    if (match(line, /(prefix|path|route|get|post|put|delete|patch)[ \t]*(\([ \t]*|=[ \t]*)[^A-Za-z0-9_]*\/?[A-Za-z0-9_-]+/)) {
                        res = substr(line, RSTART, RLENGTH)
                        sub(/^.*(\/|[= \t(])[^A-Za-z0-9_]*/, "", res)
                        sub(/[^A-Za-z0-9_].*$/, "", res)
                        res = tolower(res)
                        if (res ~ /ies$/) sub(/ies$/, "y", res)
                        else if (res ~ /[^s]s$/ && length(res) > 3) sub(/s$/, "", res)
                        if (length(res) >= 3) {
                            diff_features[cur SUBSEP res] = 1
                            diff_feat_count[cur SUBSEP res]++
                        }
                    }
                    if (match(line, /include_router\([ \t]*([A-Za-z0-9_]+)/)) {
                        res = substr(line, RSTART, RLENGTH)
                        sub(/^.*include_router\([ \t]*/, "", res)
                        sub(/\..*$/, "", res)
                        res = tolower(res)
                        if (res ~ /ies$/) sub(/ies$/, "y", res)
                        else if (res ~ /[^s]s$/ && length(res) > 3) sub(/s$/, "", res)
                        if (length(res) >= 3) {
                            diff_features[cur SUBSEP res] = 1
                            diff_feat_count[cur SUBSEP res]++
                        }
                    }
                    if (match(line, /draw[ \t]+:([A-Za-z0-9_]+)/)) {
                        res = substr(line, RSTART, RLENGTH)
                        sub(/.*:/, "", res)
                        res = tolower(res)
                        if (res ~ /ies$/) sub(/ies$/, "y", res)
                        else if (res ~ /[^s]s$/ && length(res) > 3) sub(/s$/, "", res)
                        if (length(res) >= 3) {
                            diff_features[cur SUBSEP res] = 1
                            diff_feat_count[cur SUBSEP res]++
                        }
                    }
                    if (match(line, /(GoRoute|AutoRoute|<Route)[ \t]*\([^)]*path:[ \t]*[^A-Za-z0-9_]*\/?[A-Za-z0-9_-]+|<Route[ \t]+path=[^A-Za-z0-9_]*\/?[A-Za-z0-9_-]+/)) {
                        res = substr(line, RSTART, RLENGTH)
                        sub(/^.*\/+/, "", res)
                        sub(/[^A-Za-z0-9_].*$/, "", res)
                        res = tolower(res)
                        if (res ~ /ies$/) sub(/ies$/, "y", res)
                        else if (res ~ /[^s]s$/ && length(res) > 3) sub(/s$/, "", res)
                        if (length(res) >= 3) {
                            diff_features[cur SUBSEP res] = 1
                            diff_feat_count[cur SUBSEP res]++
                        }
                    }
                    if (match(line, /r\.(Route|Group|Get|Post|Put|Delete)\([^A-Za-z0-9_]*\/?[A-Za-z0-9_-]+/)) {
                        res = substr(line, RSTART, RLENGTH)
                        sub(/^.*\/+/, "", res)
                        sub(/[^A-Za-z0-9_].*$/, "", res)
                        res = tolower(res)
                        if (res ~ /ies$/) sub(/ies$/, "y", res)
                        else if (res ~ /[^s]s$/ && length(res) > 3) sub(/s$/, "", res)
                        if (length(res) >= 3) {
                            diff_features[cur SUBSEP res] = 1
                            diff_feat_count[cur SUBSEP res]++
                        }
                    }
                }
            }
            close(diff_file)
            for (k in defs) { split(k, a, SUBSEP); definer[a[2]] = definer[a[2]] " " a[1] }
            # Normalize extracted diff keywords through the same stem rules so
            # include_router(test_personas.router) reaches feature `persona`
            # and include_router(public_api_router) reaches `public_api`.
            for (k in diff_features) {
                split(k, a, SUBSEP)
                nr = norm_stem(a[2])
                if (nr != a[2]) {
                    delete diff_features[k]
                    diff_features[a[1] SUBSEP nr] = 1
                }
            }
            for (k in diff_feat_count) {
                split(k, a, SUBSEP)
                nr = norm_stem(a[2])
                if (nr != a[2]) {
                    c = diff_feat_count[k]
                    delete diff_feat_count[k]
                    diff_feat_count[a[1] SUBSEP nr] += c
                }
            }
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
        cyc = "1"
        # Cycle 1 — Primary Domain Feature Seed Formation & Companion Pairing
        # Final test classification first: path-shape test AND (unambiguous
        # location/suffix OR test markers in the staged hunk). An ambiguous
        # `test_*` basename outside test dirs (api/routes/test_personas.py is
        # an APIRouter module, not a pytest file) resolves by content.
        for (i = 1; i <= nf; i++) {
            f = files[i]
            istest[f] = is_test_file(f) ? 1 : 0
            newtest[f] = (istest[f] && status[f] == "A") ? 1 : 0
        }
        for (i = 1; i <= nf; i++) {
            f = files[i]
            # Stem bookkeeping covers every file — newly added tests included —
            # so a new test still pairs with its staged same-stem subject.
            # Package markers (__init__.py, conftest.py, __main__.py) never
            # pair: they share one stem across unrelated packages and
            # tests/*/__init__.py would count `init` as a tested stem,
            # gluing every staged __init__ into one component.
            if (basename_of(f) !~ /^(__init__|__main__|conftest)\./) {
                base_st = stem_key(f)
                stem_count[base_st]++
                stem_test[base_st] += istest[f]
                stem_list[base_st] = (base_st in stem_list ? stem_list[base_st] SUBSEP f : f)
                if (!(base_st in stem_first)) stem_first[base_st] = f
            }
            # Newly added tests still never seed feature components — bulk-
            # added coverage consolidates in Cycle 5 instead of voting on
            # feature names. M/D tests seed and pair as before.
            if (newtest[f]) continue
            st = feature_of(f)
            feat_dir[f] = _featdir
            if (st != "" && is_domain_keyword(st)) {
                feat_count[st]++
                feat_list[st] = (st in feat_list ? feat_list[st] SUBSEP f : f)
                if (!(st in feat_first)) feat_first[st] = f
            }
        }
        for (st in feat_count) {
            if (feat_count[st] >= 2) {
                m = split(feat_list[st], sf, SUBSEP)
                anchor = feat_first[st]
                delete d2_anchor
                d2_anchor[dir2(anchor)] = anchor
                for (j = 1; j <= m; j++) {
                    f = sf[j]
                    if (f == "" || f == anchor) continue
                    d = dir2(f)
                    # A dir-derived member (generic stem, name guessed from a
                    # parent dir) only unions inside its own top-level tree
                    # (dir1) — Rails spreads a feature across
                    # app/models|controllers|views legitimately, while
                    # backend/app ↔ frontend/src must not bridge. A
                    # stem-derived member owns the feature name itself and may
                    # bridge trees (auth.py ↔ useAuth.ts, route.ts ↔
                    # subscription.test.ts).
                    if (dir1(f) == dir1(anchor) || !feat_dir[f]) {
                        union(anchor, f)
                    } else if (d in d2_anchor) {
                        union(d2_anchor[d], f)
                    } else {
                        d2_anchor[d] = f
                    }
                }
            }
        }
        for (st in stem_count) {
            # Min stem length (same as is_domain_keyword): 1-2 char stems like
            # `a`/`db` are noise that pairs unrelated files.
            if (length(st) >= 3 && stem_count[st] >= 2 && stem_test[st] >= 1 && stem_test[st] < stem_count[st]) {
                m = split(stem_list[st], sf, SUBSEP)
                for (j = 1; j <= m; j++) {
                    if (sf[j] != "") union(stem_first[st], sf[j])
                }
            }
        }

        cyc = "1.5"
        # Cycle 1.5 — Dart & companion code-gen pairing (.g.dart, .freezed.dart, .mocks.dart)
        for (i = 1; i <= nf; i++) {
            f = files[i]
            if (f ~ /\.(g|freezed|mocks|part)\.dart$/) {
                base_f = f
                sub(/\.(g|freezed|mocks|part)\.dart$/, ".dart", base_f)
                if (base_f in parent) union(base_f, f)
            }
        }

        cyc = "2A"
        # Cycle 2A — Shared Files & Migrations diff-keyword matching
        # Dominant feature binding: if a shared file (e.g. routes.rb) touches multiple features,
        # bind it ONLY to the feature with the highest hunk match count so it never bridges
        # distinct features together into a single mega-group.
        for (f_idx = 1; f_idx <= nf; f_idx++) {
            sh_file = files[f_idx]
            if (sh_file in newtest && newtest[sh_file]) continue
            max_c = 0; best_feat = ""
            for (k in diff_feat_count) {
                split(k, a, SUBSEP)
                if (a[1] == sh_file) {
                    df_feat = a[2]
                    if (df_feat in feat_first) {
                        cnt = diff_feat_count[k]
                        if (cnt > max_c) {
                            max_c = cnt
                            best_feat = df_feat
                        }
                    }
                }
            }
            if (best_feat != "" && (best_feat in feat_first)) {
                union(feat_first[best_feat], sh_file)
            }
        }

        cyc = "2B"
        # Cycle 2B — Shared Symbol: a definition changed in file A appears in file B
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
                if (f in newtest && newtest[f]) continue
                if (hunk[f] ~ re) union(first, f)
            }
        }

        cyc = "2C"
        # Cycle 2C — Replicated-edit signatures: identical or receiver-masked
        # added lines shared across files → one replicated change, one group
        for (k in fsig) { split(k, a, SUBSEP); sf[a[2]] = sf[a[2]] " " a[1] }
        for (s in sf) {
            n2 = split(sf[s], dl, " ")
            if (n2 < 2) continue
            first = ""
            for (j = 1; j <= n2; j++) {
                if (dl[j] == "") continue
                if (first == "") first = dl[j]; else union(first, dl[j])
            }
        }

        cyc = "3"
        # Cycle 3 — Co-change history (only when both files are staged)
        for (k in cpair) {
            split(k, a, SUBSEP)
            if ((a[1] in parent) && (a[2] in parent)) union(a[1], a[2])
        }

        cyc = "3.5"
        # Cycle 3.5 — Relocation families: renames sharing parent-dir signature
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

        cyc = "4"
        # Cycle 4 — Same leaf directory (with strict ANTI-HORIZONTAL TEST GUARD)
        # A touched file may only rep its dir when its whole component lives in
        # that dir — otherwise a merged fix/feature component sweeps up every
        # unrelated leftover file in the directory (mega-sweep bug).
        for (i = 1; i <= nf; i++) cdirs[find(files[i]) SUBSEP dirname_of(files[i])] = 1
        for (k in cdirs) { split(k, a, SUBSEP); comp_ndirs[a[1]]++ }
        for (i = 1; i <= nf; i++) {
            f = files[i]
            if (f in touched) {
                if (!istest[f] && comp_ndirs[find(f)] <= 1) dir_rep[dirname_of(f)] = find(f)
            }
        }
        for (i = 1; i <= nf; i++) {
            f = files[i]
            if (f in touched) continue
            if (istest[f]) continue
            d = dirname_of(f)
            if (d == "." || d ~ /(^|\/)(tests?|spec|__tests__|testdata)($|\/)/) continue
            if (d in dir_rep) union(dir_rep[d], f)
            else dir_rep[d] = f
        }

        cyc = "5"
        # Cycle 5 — Unpaired test consolidation: tests untouched by every edge
        # above (new tests whose subjects are not staged) bucket by test layer
        # instead of each becoming a single-file commit. Capped at tgroup_max —
        # oversized buckets split into deterministic chunks. The anti-horizontal
        # guard still holds for *pairing*; this only sweeps leftovers.
        if (tgroup_max + 0 < 2) tgroup_max = 14
        for (i = 1; i <= nf; i++) {
            f = files[i]
            if (!istest[f]) continue
            # Any test already unioned (stem pair, symbol, co-change — A-status
            # included) stays with its subject; bucketing it would drag the
            # whole component into the coverage bucket. Only untouched tests
            # reach this point.
            if (f in touched) continue
            tb = test_bucket(f)
            tb_count[tb]++
            tb_list[tb] = (tb in tb_list ? tb_list[tb] SUBSEP f : f)
        }
        for (tb in tb_count) {
            m = split(tb_list[tb], sf2, SUBSEP)
            anchor = ""; pos = 0
            for (j = 1; j <= m; j++) {
                if (sf2[j] == "") continue
                if (pos % tgroup_max == 0) anchor = sf2[j]
                else union(anchor, sf2[j])
                pos++
            }
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
        agit log -300 --pretty=format:'__aicommit_commit__' --name-only 2>/dev/null | LC_ALL=C awk '
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

# Record how the current grouping was produced (single / deterministic)
# for dry-run and --verbose display.
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
    local common_dir leaf dom_feat
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        _aicommit_split_tab_line "$line"
        [ ${#_aicommit_split_files[@]} -eq 0 ] && continue

        # Identify dominant domain feature keyword among member files if present
        dom_feat=$(printf '%s\n' "${_aicommit_split_files[@]}" | LC_ALL=C awk '
        function basename_of(p,   b) { b = p; sub(/^.*\//, "", b); return b }
        function dirname_of(p,   d) { d = p; return (sub(/\/[^\/]*$/, "", d) ? d : ".") }
        function norm_stem(path,    b, s) {
            b = basename_of(path)
            if (b ~ /^use[A-Z]/) sub(/^use/, "", b)
            if (b ~ /^Test[A-Z]/) sub(/^Test/, "", b)
            if (b ~ /^Spec[A-Z]/) sub(/^Spec/, "", b)
            s = tolower(b)
            sub(/\.(g|freezed|mocks|part)\.dart$/, "", s)
            sub(/\.(module|spec|test)\.(css|scss|sass|less|ts|tsx|js|jsx)$/, "", s)
            sub(/\.html\.(erb|haml|slim)$/, "", s)
            sub(/\.[^.\/]+$/, "", s)
            sub(/^[0-9]+_/, "", s)
            while (sub(/^(test|tests|spec|specs)[_-]/, "", s)) { }
            sub(/(_test|_spec|\.test|\.spec|test_|spec_|-test|-spec|_tests|_specs)$/, "", s)
            sub(/^(create|add|update|remove|drop|alter|modify)_/, "", s)
            sub(/^use_/, "", s)
            sub(/(_controller|_controllers|_service|_services|_helper|_helpers|_serializer|_serializers|_router|_routers|_route|_routes|_routing|_model|_models|_schema|_schemas|_handler|_handlers|_client|_clients|_adapter|_adapters|_factory|_factories|_validator|_validators|_worker|_workers|_job|_jobs|_dto|_types|_screen|_screens|_widget|_widgets|_page|_pages|_view|_views|_bloc|_cubit|_event|_state|_notifier|_provider|_repository|_repositories|_datasource|_datasources)$/, "", s)
            if (s ~ /ies$/) sub(/ies$/, "y", s)
            else if (s ~ /(sses|shes|ches|xes|zes)$/) sub(/es$/, "", s)
            else if (s ~ /[^s]s$/ && length(s) > 3) sub(/s$/, "", s)
            return s
        }
        # Sets _featdir=1 when the feature came from dir-walkback (kept in sync
        # with the copy in cluster_staged_files_deterministic; unused here).
        function feature_of(path,    p, d, s, n, a, seg, idx) {
            _featdir = 0
            if (match(path, /(^|\/)(features?|modules?)\/([^\/]+)\//)) {
                seg = substr(path, RSTART, RLENGTH)
                sub(/^.*(features?|modules?)\//, "", seg)
                sub(/\/.*$/, "", seg)
                seg = tolower(seg)
                if (seg ~ /ies$/) sub(/ies$/, "y", seg)
                else if (seg ~ /(sses|shes|ches|xes|zes)$/) sub(/es$/, "", seg)
                else if (seg ~ /[^s]s$/ && length(seg) > 3) sub(/s$/, "", seg)
                if (is_domain_keyword(seg)) return seg
            }
            s = norm_stem(path)
            if (s ~ /^(index|show|edit|new|form|create|update|list|detail|details|page|view|mod|lib|main|app|route|routes|router|routers|urls|handler|handlers|service|services|repository|repositories|client|clients|worker|workers|model|models|schema|schemas|types|dto|dtos|adapter|adapters|dao|controller|controllers|__init__|__main__|conftest)$/) {
                d = dirname_of(path); n = split(d, a, "/")
                for (idx = n; idx >= 1; idx--) {
                    seg = tolower(a[idx])
                    if (seg ~ /ies$/) sub(/ies$/, "y", seg)
                    else if (seg ~ /(sses|shes|ches|xes|zes)$/) sub(/es$/, "", seg)
                    else if (seg ~ /[^s]s$/ && length(seg) > 3) sub(/s$/, "", seg)
                    if (seg !~ /^(routes?|routers?|urls|views?|screens?|widgets?|pages?|components?|app|lib|src|internal|pkg|api|endpoints?|v[0-9]+|features?|backend|frontend|server|web|mobile|packages?|apps?)$/) {
                        s = seg
                        _featdir = 1
                        break
                    }
                }
            }
            return s
        }
        function is_domain_keyword(s) {
            return (s != "" && s !~ /^(test|tests|spec|specs|model|models|controller|controllers|view|views|helper|helpers|service|services|migration|migrations|route|routes|config|common|core|base|main|index|app|lib|src|doc|docs|readme|changelog|license|fixture|fixtures|script|scripts|bin|tool|tools|handler|handlers|repository|repositories|schema|schemas|types|dto|dtos|adapter|adapters|dao|client|clients|worker|workers|component|components|ui|__init__|__main__|conftest)$/ && length(s) >= 3)
        }
        {
            st = feature_of($0)
            if (is_domain_keyword(st)) counts[st]++
            total_files++
        }
        END {
            max_c = 0; second_c = 0; best = ""; num_distinct = 0
            for (st in counts) {
                num_distinct++
                if (counts[st] > max_c) { second_c = max_c; max_c = counts[st]; best = st }
                else if (counts[st] > second_c) second_c = counts[st]
            }
            # dominant = covers ≥ half the members — keeps a large merged
            # component from being named after a minority feature in it.
            # Failing that, a repeated feature that is the strict plurality
            # (a tie can never qualify) still beats a generic dir-scope name.
            if (max_c >= 2 && max_c * 2 >= total_files) {
                print best
            } else if (max_c == 1 && num_distinct == 1 && total_files >= 2) {
                print best
            } else if (max_c >= 3 && max_c > second_c) {
                print best
            }
        }')

        if [ -n "$dom_feat" ]; then
            name="$dom_feat"
        else
            # All-member test component → name by layer bucket rather than a
            # numeric "test-N" (controller-tests, model-tests, test-infrastructure)
            name=$(printf '%s\n' "${_aicommit_split_files[@]}" | LC_ALL=C awk -F/ '
                function is_test_path(p) {
                    return p ~ /(^|\/)(tests?|spec|__tests__|testdata)\// || \
                           p ~ /(_test|_spec|\.test|\.spec)\.[^.\/]+$/ || \
                           p ~ /\.bats$/ || p ~ /(^|\/)test_[^\/]+$/
                }
                {
                    if (!is_test_path($0)) { mixed = 1; next }
                    if (match($0, /(^|\/)(tests?|spec|__tests__)\/([^\/]+)/)) {
                        s = substr($0, RSTART, RLENGTH)
                        sub(/^.*(tests?|spec|__tests__)\//, "", s)
                        segs[s] = 1; tot++
                    } else other = 1
                }
                END {
                    if (mixed || tot == 0) exit
                    n = 0; for (k in segs) n++
                    if (other || n != 1) { print "test-infrastructure"; exit }
                    for (k in segs) { sub(/s$/, "", k); print k "-tests" }
                }')
        fi
        if [ -z "$name" ]; then
            # Plurality context across members — a merged component keeps the
            # minority member's file from dictating the group name.
            name=$(for f in "${_aicommit_split_files[@]}"; do infer_logical_file_context "$f"; done \
                | LC_ALL=C awk '{ c[$0]++; if (!($0 in seen)) seen[$0] = NR }
                       END { bc = -1; bi = 999999; b = ""
                             for (k in c) if (c[k] > bc || (c[k] == bc && seen[k] < bi)) { bc = c[k]; b = k; bi = seen[k] }
                             print b }')
            first_file=$(printf '%s' "$line" | cut -f2)
            # Generic bucket name + members sharing a deeper common leaf dir →
            # name the component by that leaf instead of "docs-12".
            case "$name" in
                docs|config|scripts|core|ui|routes)
                    if [ ${#_aicommit_split_files[@]} -ge 1 ]; then
                        common_dir=$(printf '%s\n' "${_aicommit_split_files[@]}" | LC_ALL=C awk -F/ '
                            { n = split($0, a, "/")
                              if (NR == 1) { m = n - 1; for (i = 1; i <= m; i++) c[i] = a[i] }
                              else { for (i = 1; i <= m && i < n; i++) if (a[i] != c[i]) m = i - 1 }
                            }
                            END { s = ""; for (i = 1; i <= m; i++) s = (s == "" ? c[i] : s "/" c[i]); print s }')
                        leaf="${common_dir##*/}"
                        case "$leaf" in
                            docs|doc|src|lib|app|test|tests|"") ;;
                            _*|\$*|.\$*) ;; # pathless route markers (_layout, $id)
                            *) [ "$common_dir" != "." ] && name="$leaf" ;;
                        esac
                    fi
                    ;;
            esac
        fi
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

# Group staged files into logical contexts — purely deterministic clustering
# plus deterministic naming; the LLM is never consulted for grouping.
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

    local state_dir="" tmp_dir diff_file cochange_file=""
    state_dir=$(get_aicommit_state_dir 2>/dev/null) || state_dir=""
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
    if [ -n "$state_dir" ]; then
        build_cochange_cache "$state_dir" >/dev/null 2>&1 && cochange_file="${state_dir}/COCHANGE"
    fi

    local comp_lines
    comp_lines=$(cluster_staged_files_deterministic "$staged_files" "$diff_file" "$cochange_file")

    local result
    result=$(_name_component_lines "$comp_lines")
    _write_grouping_source "deterministic"

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
