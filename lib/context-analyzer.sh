#!/usr/bin/env bash
# aicommit — Context Analyzer
# Analyzes staged changes to provide structural hints for commit message
# generation, and clusters staged files into atomic commit groups.

# Single shared sensitive-path rule (was: the same grep -E pattern repeated in
# three functions — the DRY-on-third-occurrence rule). Case glob, not grep, so
# it costs zero subprocesses inside loops.
_AICOMMIT_SENSITIVE_RE='\.env$|\.env\.|config\.ini|.*secrets.*|.*credentials.*|.*\.key|.*\.pem|.*\.p12'

# Structural/layer/infra directory names that carry no feature signal when
# they appear as path segments — tree roots (app/src/lib/…), layer dirs
# (models/controllers/tests/… via is_domain_keyword plus mailers/jobs/…),
# API plumbing (routes/api/endpoints/…), asset/config/i18n dirs, junk
# drawers (utils/shared/misc/…), and platform/build dirs. Passed to awk as a
# dynamic regex (-v pathkw_re) so both clustering and naming share one copy.
_AICOMMIT_PATH_KW_EXCL_RE='^(routes?|routers?|urls|endpoints?|v[0-9]+|api|apis|graphql|rest|rpc|grpc|websocket|websockets|ws|socket|sockets|realtime|stream|streams|events?|listeners?|subscribers?|views?|screens?|widgets?|pages?|components?|app|lib|src|internal|pkg|backend|frontend|server|web|mobile|packages?|apps?|desktop|native|hybrid|cross|platform|features?|modules?|db|database|data|migrate|migrations|alembic|seeds?|structure|dumps?|backups?|snapshots?|archives?|assets?|static|public|private|vendor|node_modules|bower_components|jspm_packages|__pycache__|venv|env|virtualenv|site-packages|dist-packages|eggs?|wheels?|cargo|target|dist|build|out|bin|obj|debug|release|x64|x86|arm|arm64|universal|macos|linux|windows|darwin|ios|android|coverage|logs?|log|tmp|temp|cache|caches|storage|uploads?|downloads?|exports?|imports?|locales?|i18n|lang|translations?|messages?|emails?|cron|tasks?|batch|cmd|cli|utils?|shared|misc|stuff|general|integration|requests?|routing|channels?|policies|serializers?|units?|functional|system|acceptance|mailers?|presenters?|factories|support|concerns?|interactors?|commands?|queries?|forms?|validators?|decorators?|entities|aggregates?|domain|infrastructure|interface|interfaces|adapters?|daos?|dtos?|schemas?|types?|abstract|settings|initializers?|autoload|eager_load|middleware|kernels?|console|javascript|stylesheets|images|fonts?|img|css|scss|sass|less|third_party|external|examples?|samples?|demos?|tutorials?|guides?|snippets?|mocks?|stubs?|fakes?|doubles?|jobs?|managers?|builders?|parsers?|formatters?|encoders?|decoders?|mappers?|converters?|transformers?|strategies?|engines?|drivers?|plugins?|extensions?|elements?|blocks?|sections?|panels?|modals?|dialogs?|inputs?|outputs?|labels?|buttons?|links?|icons?|logos?|sidebars?|menus?|nav|navigation|tabs?|tooltips?|dropdowns?|selects?|checkboxes?|radios?|switches?|sliders?|progress|spinners?|loaders?|skeletons?|placeholders?|avatars?|badges?|tags?|chips?|alerts?|toasts?|notifications?|banners?|cards?|grids?|tables?|rows?|columns?|cells?|titles?|subtitles?|descriptions?|texts?|contents?|media|values?|roles?|permissions?|abilities?|scopes?|contexts?|states?|reducers?|actions?|effects?|selectors?|sagas?|thunks?|stores?|layouts?|templates?|themes?|skins?|styles?|bundles?|chunks?|vendors?|polyfills?|shims?|wrappers?|mixins?|libs?|frameworks?|toolkits?|sdks?|clients?|servers?|providers?|consumers?|producers?|publishers?|brokers?|exchanges?|topics?|bindings?|operations?|mutations?|resolvers?|models?|roots?|leaves?|nodes?|edges?|graphs?|trees?|forests?|hierarchies?|structures?|organizational|departmental|divisional|branch|branches|office|offices|team|teams|squad|squads|crew|crews|unit|units|battalion|battalions|regiment|regiments|brigade|brigades|division|divisions|corps|armies|fleet|fleets|navy|armada|squadron|squadrons|wing|wings|group|groups|cluster|clusters|node|nodes|instance|instances|replica|replicas|shard|shards|partition|partitions|fragment|fragments|slice|slices|chunk|chunks|frame|frames|window|windows|pane|panes|viewport|viewports|display|displays|monitor|monitors|terminal|terminals|consoles?|shells?|prompt|prompts|tui|gui|ui|ux|sdk|ide|editor|editors|daemon|daemons|process|processes|thread|threads|fiber|fibers|coroutine|coroutines|agent|agents|bot|bots|robot|robots|automation|automations|program|programs|application|applications|software|infrastructure|architecture|design|pattern|patterns|presenter|presenters|bridge|bridges|composite|composites|facade|facades|flyweight|flyweights|proxy|proxies|singleton|singletons|prototype|prototypes|observer|observers|mediator|mediators|memento|mementos|iterator|iterators|visitor|visitors|chain|chains|responsibility|specification|specifications)$'

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
    local contents_dir="${4:-}"
    local mtimes_file="${5:-}"
    local framework_patterns_file="${AI_FRAMEWORK_PATTERNS_FILE:-$AICOMMIT_DIR/config/framework-patterns.json}"

    printf '%s\n' "$staged_files" | LC_ALL=C sort | LC_ALL=C awk \
        -v diff_file="$diff_file" \
        -v cochange_file="$cochange_file" \
        -v cochange_min="${AI_COCHANGE_MIN:-2}" \
        -v sym_max="${AI_SYMBOL_MAX_FILES:-4}" \
        -v tgroup_max="${AI_MAX_GROUP_SIZE:-14}" \
        -v dbg="${AICOMMIT_GROUP_DEBUG:-}" \
        -v patterns_file="$framework_patterns_file" \
        -v contents_dir="$contents_dir" \
        -v pk_max="${AI_PATH_KEYWORD_MAX:-10}" \
        -v ckw_max="${AI_CONTENT_KEYWORD_MAX:-10}" \
        -v pathkw_re="$_AICOMMIT_PATH_KW_EXCL_RE" \
        -v path_kw_off="${AI_DISABLE_PATH_KEYWORDS:-false}" \
        -v content_kw_off="${AI_DISABLE_CONTENT_KEYWORDS:-false}" \
        -v mtimes_file="$mtimes_file" \
        -v time_win="$(( ${AI_GROUP_TIME_WINDOW_MIN:-60} * 60 ))" \
        -v time_off="${AI_DISABLE_TIME_GROUPING:-false}" '
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
    # Canonical keyword form for one path/content token: lowercase,
    # singularized with the same rules feature_of applies to dir segments,
    # separators removed so `user-profile` ≡ `user_profile` ≡ `userprofile`.
    # Returns "" when the token cannot be a keyword (symbols, dots, empties).
    function canon_seg(s,   t) {
        t = tolower(s)
        if (t ~ /ies$/) sub(/ies$/, "y", t)
        else if (t ~ /(sses|shes|ches|xes|zes)$/) sub(/es$/, "", t)
        else if (t ~ /[^s]s$/ && length(t) > 3) sub(/s$/, "", t)
        gsub(/[-_]/, "", t)
        if (t ~ /^[a-z0-9]+$/) return t
        return ""
    }
    # Domain keyword that may legitimately name a feature when found in a
    # path: passes is_domain_keyword and is not a structural tree root, layer
    # dir, or infra/junk-drawer name. models/controllers/tests/config etc. are
    # already excluded by is_domain_keyword; this adds the rest.
    function is_path_keyword(s) {
        return is_domain_keyword(s) && s !~ pathkw_re
    }
    # Register file f under path keyword kw (once per file+kw pair).
    # is_stem=1 marks f as an owner of the name (its own filename stem).
    function pkw_add(f, kw, is_stem,   k) {
        k = f SUBSEP kw
        if (k in pkw_all) return
        pkw_all[k] = 1
        pk_mem[kw] = (kw in pk_mem ? pk_mem[kw] SUBSEP f : f)
        if (is_stem) {
            pk_owner[kw] = (kw in pk_owner ? pk_owner[kw] SUBSEP f : f)
            file_stemkw[f] = kw
        }
    }
    # English function words, language keywords, and ultra-generic nouns that
    # must never become content keywords (the anchor rule is the real guard —
    # this just trims obvious prose noise).
    function ck_stopword(s) {
        return s ~ /^(a|an|the|and|or|but|nor|for|yet|so|if|then|else|when|while|where|why|how|what|which|who|whom|whose|that|this|these|those|there|here|it|its|he|she|they|them|their|we|us|our|you|your|i|me|my|mine|anyone|everyone|someone|nobody|somebody|anybody|everybody|nothing|something|anything|everything|none|all|some|any|each|every|either|neither|both|few|several|many|much|more|most|less|least|little|lot|lots|plenty|about|above|below|under|over|after|before|between|among|through|during|within|without|against|along|around|across|behind|beyond|beside|toward|towards|per|via|vs|etc|ie|eg|cf|as|at|by|in|of|on|to|up|down|out|off|from|into|onto|upon|is|are|was|were|be|been|being|am|do|does|did|have|has|had|can|could|will|would|shall|should|may|might|must|ought|need|dare|used|not|no|yes|very|too|enough|almost|nearly|just|only|quite|rather|fairly|pretty|really|actually|basically|generally|usually|normally|typically|often|sometimes|occasionally|rarely|seldom|hardly|scarcely|barely|merely|simply|also|either|neither|indeed|perhaps|maybe|probably|possibly|certainly|surely|however|therefore|thus|hence|moreover|furthermore|nevertheless|nonetheless|otherwise|instead|meanwhile|afterward|afterwards|beforehand|besides|still|yet|already|always|never|ever|once|twice|thrice|again|now|soon|later|early|late|today|tomorrow|yesterday|currently|presently|recently|formerly|previously|originally|initially|finally|eventually|ultimately|lastly|firstly|secondly|thirdly|next|last|first|second|third|one|two|three|four|five|six|seven|eight|nine|ten|new|old|good|bad|better|best|worse|worst|big|small|large|little|great|huge|tiny|long|short|high|low|tall|deep|shallow|wide|narrow|broad|thick|thin|heavy|light|strong|weak|hard|soft|easy|difficult|simple|complex|clear|obvious|important|significant|major|minor|main|secondary|primary|final|initial|original|actual|possible|impossible|likely|unlikely|certain|uncertain|sure|true|false|real|correct|incorrect|right|wrong|valid|invalid|public|private|personal|common|rare|usual|normal|regular|standard|typical|average|excellent|poor|perfect|complete|incomplete|whole|partial|entire|total|full|empty|blank|plain|basic|advanced|modern|ancient|young|recent|latest|earliest|previous|following|subsequent|prior|former|latter|current|present|past|future|temporary|permanent|brief|quick|rapid|swift|slow|gradual|sudden|sharp|dull|bright|dark|dense|sparse|tight|loose|firm|solid|flexible|stiff|tough|delicate|fragile|sturdy|robust|powerful|gentle|mild|harsh|rough|smooth|coarse|fine|raw|natural|artificial|living|dead|awake|asleep|tired|weary|energetic|lively|active|inactive|passive|dynamic|static|mobile|fixed|portable|travel|journey|trip|voyage|flight|drive|ride|walk|run|sprint|race|chase|hunt|search|seek|find|locate|discover|detect|notice|observe|watch|view|see|look|glance|stare|gaze|peek|scan|browse|skim|read|peruse|study|examine|inspect|check|verify|validate|confirm|prove|demonstrate|show|display|exhibit|present|offer|provide|supply|furnish|deliver|send|ship|transport|carry|bear|bring|take|fetch|get|obtain|acquire|gain|earn|win|achieve|attain|reach|arrive|come|go|leave|depart|exit|enter|join|connect|link|attach|bind|tie|fasten|secure|fix|repair|mend|patch|restore|renew|refresh|upgrade|downgrade|improve|enhance|boost|increase|raise|lift|elevate|move|shift|transfer|convey|support|hold|keep|retain|maintain|preserve|conserve|save|store|stock|accumulate|collect|gather|assemble|compile|compose|construct|build|make|create|produce|generate|manufacture|fabricate|forge|cast|mold|shape|form|fashion|design|plan|scheme|plot|map|chart|graph|diagram|sketch|draw|paint|depict|portray|illustrate|represent|symbolize|signify|mean|denote|indicate|suggest|imply|hint|intimate|infer|deduce|conclude|reason|think|believe|suppose|assume|presume|expect|anticipate|await|hope|wish|desire|want|need|require|demand|request|ask|beg|plead|implore|urge|press|force|compel|oblige|order|command|direct|instruct|guide|lead|steer|navigate|fly|sail|swim|dive|plunge|jump|leap|hop|skip|bounce|spring|bound|vault|clear|pass|cross|traverse|ford|bridge|tunnel|span|cover|extend|stretch|accomplish|complete|finish|end|terminate|cease|stop|halt|pause|rest|break|interrupt|suspend|delay|postpone|defer|procrastinate|wait|linger|tarry|remain|stay|abide|dwell|reside|live|inhabit|occupy|populate|settle|develop|evolve|grow|expand|spread|propagate|multiply|decrease|diminish|reduce|lessen|lower|drop|fall|decline|sink|descend|crash|collapse|fail|flop|miss|lose|forfeit|surrender|yield|cede|relinquish|abandon|desert|forsake|quit|withdraw|retreat|recede|ebb|wane|fade|weaken|falter|flag|lag|trail|follow|pursue|track|trace|shadow|tail|stalk|dog|hound|badger|pester|plague|torment|torture|harass|harry|raid|attack|assault|strike|hit|beat|pound|thrash|whip|flog|lash|smite|slap|smack|punch|jab|poke|prod|nudge|elbow|shoulder|shove|push|thrust|drive|propel|impel|spur|goad|prompt|cue|signal|sign|gesture|wave|beckon|summon|call|invite|bid|entreat|beseech|supplicate|pray|petition|appeal|apply|submit|tender|proffer|extend|give|grant|bestow|confer|award|present|donate|contribute|equip|outfit|arm|prepare|ready|get|set|arrange|organize|marshal|deploy|station|post|position|place|put|lay|lie|stand|sit|seat|perch|roost|nest|alight|land|approach|near|draw|advance|proceed|progress|move|go|travel|journey|trek|hike|march|step|stride|stroll|saunter|amble|wander|roam|rove|range|stray|drift|meander|zigzag|wind|twist|turn|curve|bend|fold|loop|coil|spiral|circle|orbit|revolve|rotate|spin|twirl|whirl|swirl|wheel|roll|pivot|swivel|swing|sway|rock|oscillate|vibrate|quiver|tremble|shake|shiver|shudder|quake|wobble|teeter|totter|stagger|reel|lurch|stumble|trip|slip|slide|glide|skid|slither|crawl|creep|sneak|skulk|prowl|tiptoe|slink|edge|inch|worm|wriggle|squirm|wiggle|jiggle|jostle|jolt|jar|jerk|twitch|spasm|convulse|os|sys|io|re|json|yaml|yml|xml|html|css|sql|db|api|url|uri|http|https|www|com|org|net|edu|gov|int|localhost|example|sample|demo|testing|mock|mocks|stub|stubs|fake|fakes|fixture|fixtures|seed|seeds|factory|factories|path|paths|file|files|dir|dirs|directory|folder|name|names|time|times|date|dates|datetime|timedelta|timezone|calendar|typing|collections|functools|itertools|operator|math|cmath|decimal|fractions|numbers|numeric|statistics|random|secrets|hashlib|hmac|base64|binascii|struct|codecs|encodings|pickle|shelve|dbm|sqlite3|zlib|gzip|bz2|lzma|tarfile|zipfile|shutil|tempfile|filecmp|fileinput|stat|subprocess|shlex|signal|socket|ssl|select|selectors|asyncio|threading|multiprocessing|concurrent|queue|sched|contextlib|contextvars|atexit|traceback|warnings|logging|unittest|pytest|doctest|pdb|profile|cProfile|timeit|trace|tracemalloc|gc|inspect|ast|dis|importlib|pkgutil|modulefinder|runpy|sysconfig|platform|errno|ctypes|curses|termios|tty|pty|fcntl|resource|syslog|mmap|readline|rlcompleter|cmd|site|builtins|__future__|types|copy|weakref|enum|dataclasses|reprlib|graphlib|heapq|bisect|array|memoryview|bytearray|string|stringprep|stringparser|textwrap|unicodedata|codepoint|locale|gettext|argparse|getopt|getpass|react|reactdom|vue|angular|svelte|next|nuxt|express|koa|fastify|hapi|lodash|underscore|axios|moment|dayjs|rxjs|redux|mobx|zustand|jotai|recoil|formik|yup|zod|joi|ajv|sequelize|typeorm|prisma|mongoose|knex|objection|drizzle|kysely|postgres|mysql|mongodb|redis|elasticsearch|kafka|rabbitmq|grpc|protobuf|graphql|apollo|trpc|socketio|cors|helmet|morgan|parser|cookie|passport|jsonwebtoken|bcrypt|crypto|util|utils|helpers|core|common|shared|base|abstract|interface|trait|mixin|concern|interactor|command|query|handler|controller|model|service|repository|factory|builder|strategy|policy|validator|serializer|presenter|decorator|listener|subscriber|provider|registrar|bootstrap|kernel|middleware|pipeline|guard|interceptor|pipe|filter|resolver|gateway|adapter|client|driver|transport|protocol|codec|encoder|decoder|parser|lexer|tokenizer|scanner|compiler|interpreter|runtime|vm|engine|framework|library|package|module|component|widget|element|block|section|panel|modal|dialog|input|output|field|label|button|link|image|icon|logo|header|footer|sidebar|menu|nav|tab|tooltip|dropdown|select|checkbox|radio|switch|slider|spinner|loader|skeleton|placeholder|avatar|badge|tag|chip|alert|toast|notification|banner|card|grid|table|row|column|cell|title|subtitle|description|text|content|media|asset|static|public|private|vendor|build|out|release|version|versions|env|environment|production|development|staging|local|remote|internal|external|shared|dynamic|async|sync|single|multi|batch|bulk|time|times|way|ways|thing|things|stuff|info|details|specific|various|several|others|another|kind|sort|type|types|part|parts|piece|pieces|bit|bits|segment|segments|portion|portions|share|shares|half|halves|quarter|quarters|third|thirds|side|sides|end|ends|edge|edges|corner|corners|top|bottom|left|right|center|middle|front|back|inside|outside|beginning|start|starts|finish|finishes|point|points|place|places|spot|spots|site|sites|location|locations|position|positions|area|areas|region|regions|zone|zones|territory|territories|domain|domains|realm|realms|field|fields|sphere|spheres|world|worlds|universe|universes|space|spaces|void|voids|emptiness|nothingness|todo|fixme|xxx|note|notes|change|changes|update|updates|add|adds|added|remove|removes|removed|fix|bug|bugs)$/
    }
    # Bare single-segment module specifiers (import os, require("react")) hit
    # stdlib/framework noise far more often than local modules — filter those
    # harder. Dotted/relative paths keep every segment.
    function ck_mod_stopword(s) {
        return s ~ /^(abc|os|sys|io|re|json|yaml|yml|xml|html|css|sql|db|api|url|uri|http|https|www|com|org|net|edu|gov|int|localhost|example|sample|demo|test|testing|mock|mocks|stub|stubs|fake|fakes|fixture|fixtures|seed|seeds|factory|factories|path|paths|file|files|dir|dirs|directory|folder|name|names|time|times|date|dates|datetime|timedelta|timezone|calendar|typing|collections|functools|itertools|operator|math|cmath|decimal|fractions|numbers|numeric|statistics|random|secrets|hashlib|hmac|base64|binascii|struct|codecs|encodings|pickle|shelve|dbm|sqlite3|zlib|gzip|bz2|lzma|tarfile|zipfile|shutil|tempfile|filecmp|fileinput|stat|subprocess|shlex|signal|socket|ssl|select|selectors|asyncio|threading|multiprocessing|concurrent|queue|sched|contextlib|contextvars|atexit|traceback|warnings|logging|unittest|pytest|doctest|pdb|profile|cProfile|timeit|trace|tracemalloc|gc|inspect|ast|dis|importlib|pkgutil|modulefinder|runpy|sysconfig|platform|errno|ctypes|curses|termios|tty|pty|fcntl|resource|syslog|mmap|readline|rlcompleter|cmd|site|builtins|__future__|types|copy|weakref|enum|dataclasses|reprlib|graphlib|heapq|bisect|array|memoryview|bytearray|string|stringprep|stringparser|textwrap|unicodedata|codepoint|locale|gettext|argparse|getopt|getpass|xdrlib|plistlib|netrc|configparser|csv|react|reactdom|vue|angular|svelte|next|nuxt|express|koa|fastify|hapi|lodash|underscore|axios|moment|dayjs|date-fns|rxjs|redux|mobx|zustand|jotai|recoil|formik|yup|zod|joi|ajv|sequelize|typeorm|prisma|mongoose|knex|objection|drizzle|kysely|postgres|mysql|mongodb|redis|elasticsearch|kafka|rabbitmq|grpc|protobuf|graphql|apollo|trpc|socketio|cors|helmet|morgan|body-parser|cookie-parser|cookie-session|passport|jsonwebtoken|bcrypt|bcryptjs|crypto-js|node-forge|util|utils|helpers|core-js|core|common|shared|base|abstract|interface|trait|mixin|concern|interactor|command|query|handler|controller|model|service|repository|factory|builder|strategy|policy|validator|serializer|presenter|decorator|listener|subscriber|provider|registrar|bootstrap|kernel|middleware|pipeline|guard|interceptor|pipe|filter|resolver|gateway|adapter|client|driver|transport|protocol|codec|encoder|decoder|parser|lexer|tokenizer|scanner|compiler|interpreter|runtime|vm|engine|framework|library|package|module|component|widget|element|block|section|panel|modal|dialog|input|output|field|label|button|link|image|icon|logo|header|footer|sidebar|menu|nav|tab|tooltip|dropdown|select|checkbox|radio|switch|slider|progress|spinner|loader|skeleton|placeholder|avatar|badge|tag|chip|alert|toast|notification|banner|card|grid|table|row|column|cell|title|subtitle|description|text|content|media|asset|static|public|private|vendor|build|out|release|version|versions|env|environment|production|development|staging|local|remote|internal|external|shared|dynamic|async|sync|single|multi|batch|bulk)$/
    }
    # Emit one content keyword for file f at weight w (2=strong, 1=weak).
    # ckseen dedups the (file,kw) pair; ckw keeps the max weight seen.
    function emit_ck(f, kw, w,   k) {
        if (kw == "") return
        k = f SUBSEP kw
        if (!(k in ckseen)) {
            if ((f in ckcount) && ckcount[f] >= 80) return
            ckseen[k] = 1
            ckcount[f]++
            cklist[f] = (f in cklist ? cklist[f] SUBSEP kw : kw)
        }
        if (w > ckw[k]) ckw[k] = w
    }
    # Tokenize an identifier into keyword candidates: snake_case subtokens,
    # camelCase boundaries, plus the joined form (process_payment →
    # processpayment so it can match a process-payment/ dir keyword).
    function emit_ident_kws(f, ident, w,   toks, nt, j, t, kw, joined) {
        if (ident !~ /^[A-Za-z_][A-Za-z0-9_]*$/) return
        toks = ident_tokens(ident)
        nt = split(toks, ta, " ")
        for (j = 1; j <= nt; j++) {
            t = ta[j]
            if (length(t) < 3) continue
            kw = canon_seg(t)
            if (kw != "" && is_path_keyword(kw) && !ck_stopword(kw)) emit_ck(f, kw, w)
        }
        joined = tolower(ident); gsub(/[-_]/, "", joined)
        kw = canon_seg(joined)
        if (kw != "" && is_path_keyword(kw) && !ck_stopword(kw)) emit_ck(f, kw, w)
    }
    # Split identifier on _ and camel boundaries; returns space-joined tokens
    # in original case (caller canonicalizes).
    function ident_tokens(ident,   out, np, j, s, i, c, cur, prev) {
        out = ""
        np = split(ident, parts, "_")
        for (j = 1; j <= np; j++) {
            s = parts[j]
            if (s == "") continue
            cur = ""; prev = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c ~ /[A-Z]/ && cur != "" && prev ~ /[a-z0-9]/) {
                    out = out " " cur; cur = ""
                }
                cur = cur c; prev = c
            }
            if (cur != "") out = out " " cur
        }
        sub(/^ /, "", out)
        return out
    }
    # Emit keywords from a module/import path (models.abc, ../x/y, @/f/a,
    # crate::b). ns<=1 means a bare specifier → apply the heavier module
    # stopword list; dotted/relative paths keep every segment.
    function emit_module_kws(f, mod, w,   segs, ns, j, kw, single) {
        gsub(/::/, ".", mod)
        gsub(/\/+/, ".", mod)
        ns = split(mod, segs, ".")
        single = (ns <= 1)
        for (j = 1; j <= ns; j++) {
            kw = canon_seg(segs[j])
            if (kw == "" || !is_path_keyword(kw) || ck_stopword(kw)) continue
            if (single && ck_mod_stopword(kw)) continue
            emit_ck(f, kw, w)
        }
    }
    # Split comment/prose/path text into candidate keywords. Path-like tokens
    # (contain / or \ or a file extension or start with .) yield strong kws
    # from every segment; plain words yield weak kws.
    function emit_text_kws(f, txt, w,   n, lines, li, ln, segs, ns, j, kw, ispath, path_re, tok, nw, words) {
        n = split(txt, lines, "\n")
        # string-built ERE: / inside bracket expressions breaks BSD awk regex
        # literals, so path tokens are matched via a dynamic pattern instead
        path_re = "[A-Za-z0-9_~.@-]*[/\\\\][A-Za-z0-9_~.@/-]+|[A-Za-z0-9_~@-]+[.][A-Za-z][A-Za-z0-9]{0,5}"
        for (li = 1; li <= n; li++) {
            ln = lines[li]
            # path-like token: contains a slash, backslash, or file extension
            while (match(ln, path_re)) {
                tok = substr(ln, RSTART, RLENGTH)
                ln = substr(ln, 1, RSTART - 1) " " substr(ln, RSTART + RLENGTH)
                gsub(/::/, ".", tok); gsub(/\/+/, ".", tok)
                # drop leading ./ ../ @ ./ etc and trailing punctuation
                sub(/^\.*\//, "", tok); sub(/^@\//, "", tok); sub(/[),.;:!?"-]+$/, "", tok)
                ns = split(tok, segs, ".")
                ispath = 0
                for (j = 1; j <= ns; j++) {
                    if (segs[j] ~ /[\/\\]/) ispath = 1
                    kw = canon_seg(segs[j])
                    if (kw != "" && is_path_keyword(kw) && !ck_stopword(kw)) {
                        emit_ck(f, kw, 2)
                    }
                }
            }
            # plain words → weak kws (skip tokens already consumed is fine —
            # words inside path tokens also appear here; dedup handles it)
            nw = split(ln, words, /[^A-Za-z0-9_]+/)
            for (j = 1; j <= nw; j++) {
                if (length(words[j]) < 3) continue
                kw = canon_seg(words[j])
                if (kw != "" && is_path_keyword(kw) && !ck_stopword(kw)) emit_ck(f, kw, w)
            }
        }
    }
    # Extract the comment part of a line. Returns "" when there is none.
    # Handles whole-line comments and trailing # / // comments; skips
    # shebangs and C-preprocessor lines.
    function line_comment(ln,   p, comm) {
        if (ln ~ /^[ \t]*#!/) return ""
        if (ln ~ /^[ \t]*#[ \t]*(include|import|define|undef|if|ifdef|ifndef|elif|else|endif|pragma|error|warning|line)/) return ""
        if (ln ~ /^[ \t]*#/) { comm = ln; sub(/^[ \t]*#[ \t]?/, "", comm); return comm }
        if (ln ~ /^[ \t]*\/\//) { comm = ln; sub(/^[ \t]*\/\/[ \t]?/, "", comm); return comm }
        if (ln ~ /^[ \t]*\/\*/) { comm = ln; sub(/^[ \t]*\/\*[ \t]?/, "", comm); sub(/\*\/[ \t]*$/, "", comm); return comm }
        if (ln ~ /^[ \t]*\*/) { comm = ln; sub(/^[ \t]*\*[ \t]?/, "", comm); return comm }
        if (ln ~ /^[ \t]*--/) { comm = ln; sub(/^[ \t]*--[ \t]?/, "", comm); return comm }
        if (ln ~ /^[ \t]*%/) { comm = ln; sub(/^[ \t]*%[ \t]?/, "", comm); return comm }
        if (ln ~ /^[ \t]*;/) { comm = ln; sub(/^[ \t]*;[ \t]?/, "", comm); return comm }
        if (ln ~ /^[ \t]*<!--/) { comm = ln; sub(/^[ \t]*<!--[ \t]?/, "", comm); sub(/-->[ \t]*$/, "", comm); return comm }
        # trailing comments — require whitespace before the marker
        p = index(ln, " #")
        if (p > 0) return substr(ln, p + 2)
        p = index(ln, " //")
        if (p > 0) return substr(ln, p + 3)
        if (match(ln, /[ \t]\/\*/)) {
            comm = substr(ln, RSTART + RLENGTH)
            sub(/\*\/[ \t]*$/, "", comm)
            return comm
        }
        return ""
    }
    # Scan one staged file text (full blob or diff hunk) for content
    # keywords. isfull=1 means raw file text; isfull=0 means hunk lines that
    # each start with a + or - diff marker to strip first.
    function collect_content_kws(f, i,    txt, isfull, n, lines, li, ln, code, comm, m, mods, nmod, j, defnames, ndef, k, tmp, ndoc, ndq, nds, p, nm, mod, in_doc, imp_re, qre, wre, sq, sq3) {
        txt = hunk[f]
        isfull = 0
        if ((i in full) && full[i] != "") { txt = full[i]; isfull = 1 }
        if (txt == "") return
        n = split(txt, lines, "\n")
        ndoc = 0; ndq = 0; nds = 0
        sq = sprintf("%c", 39); sq3 = sq sq sq   # quote chars via sprintf
        imp_re = "(from|import|require|require_relative|include|using|source|load|use)[ \t]+[" sq "\"<]?([A-Za-z_][A-Za-z0-9_]*([.:/][A-Za-z0-9_.:/@-]*)?)"
        qre = "[" sq "\"](\\.{1,2}/|@/|[A-Za-z0-9_.-]+/)[A-Za-z0-9_./@-]+[" sq "\"]"
        wre = "^[ \\t]*[" sq "\"][A-Za-z0-9_./@-]+[" sq "\"][ \\t]*,?[ \\t]*$"
        for (li = 1; li <= n; li++) {
            ln = lines[li]
            if (!isfull) ln = substr(ln, 2)   # strip leading +/- diff marker
            # python docstring state (triple-double and triple-single quotes)
            tmp = ln; ndq += gsub(/"""/, "", tmp)
            tmp = ln; nds += gsub(sq3, "", tmp)
            in_doc = (ndq % 2 == 1 || nds % 2 == 1)
            comm = line_comment(ln)
            if (in_doc) comm = (comm == "" ? ln : comm " " ln)
            # code part = line minus the comment tail
            code = ln
            if (comm != "") {
                # crude strip: remove the comment substring occurrence
                p = index(ln, comm)
                if (p > 0) code = substr(ln, 1, p - 1)
            }
            # module/import statements → strong kws
            while (match(code, imp_re)) {
                mod = substr(code, RSTART, RLENGTH)
                sub("^[A-Za-z_]+[ \t]+[" sq "\"<]?", "", mod)
                sub("[" sq "\")`,;]+$", "", mod)
                code = substr(code, 1, RSTART - 1) " " substr(code, RSTART + RLENGTH)
                emit_module_kws(f, mod, 2)
            }
            # quoted path strings → strong kws
            while (match(code, qre)) {
                mod = substr(code, RSTART, RLENGTH)
                gsub("[" sq "\"]", "", mod)
                code = substr(code, 1, RSTART - 1) " " substr(code, RSTART + RLENGTH)
                emit_module_kws(f, mod, 2)
            }
            # whole-line quoted path (Go-style import block members)
            if (code ~ wre) {
                mod = code; gsub("[" "\"" sq ", \\t]", "", mod)
                emit_module_kws(f, mod, 2)
            }
            # def/class/function/etc names → strong kws
            while (match(code, /(def|class|function|func|fn|interface|struct|enum|module|trait|mixin|type|record|object|namespace)[ \t]+([A-Za-z_][A-Za-z0-9_]*)/)) {
                nm = substr(code, RSTART, RLENGTH)
                sub(/^[A-Za-z_]+[ \t]+/, "", nm)
                code = substr(code, 1, RSTART - 1) " " substr(code, RSTART + RLENGTH)
                emit_ident_kws(f, nm, 2)
            }
            # remaining identifiers → weak kws (cap via ckcap)
            while (match(code, /[A-Za-z_][A-Za-z0-9_]*/)) {
                nm = substr(code, RSTART, RLENGTH)
                code = substr(code, 1, RSTART - 1) " " substr(code, RSTART + RLENGTH)
                if (length(nm) >= 5) emit_ident_kws(f, nm, 1)
            }
            # comment text → path tokens strong + prose words weak
            if (comm != "") emit_text_kws(f, comm, 1)
        }
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
        # Path keyword index — every domain keyword in the full path (dir
        # segments + filename stem), canonicalized like stem_key so
        # `user-profile/` matches `user_profile.py`.
        if (path_kw_off != "true") {
            for (i = 1; i <= nf; i++) {
                f = files[i]
                if (basename_of(f) !~ /^(__init__|__main__|conftest)\./) {
                    sk = stem_key(f)
                    if (is_path_keyword(sk)) pkw_add(f, sk, 1)
                }
                d = dirname_of(f)
                if (d != ".") {
                    nd = split(d, dseg, "/")
                    # skip the outermost segment on multi-level paths — it is
                    # the repo/project root (src-tauri, my-app), not a feature
                    for (di = (nd > 1 ? 2 : 1); di <= nd; di++) {
                        kw = canon_seg(dseg[di])
                        if (kw != "" && is_path_keyword(kw)) pkw_add(f, kw, 0)
                    }
                }
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

        cyc = "1.7"
        # Cycle 1.7 — Full-path keyword pairing: files sharing a domain
        # keyword anywhere in their path union. A keyword owned by a staged
        # the file own stem anchors the group and may bridge trees; test files
        # may attach cross-tree to the anchor (test↔subject mirroring, e.g.
        # tests/models/abc/this.py ↔ models/abc.py); other dir-derived members
        # keep Cycle-1 dir1/dir2 containment so unrelated trees never bridge.
        if (path_kw_off != "true") {
            for (kw in pk_mem) {
                m = split(pk_mem[kw], pmem, SUBSEP)
                if (m < 2 || m > pk_max + 0) continue
                if (kw in pk_owner) { split(pk_owner[kw], ow, SUBSEP); anchor = ow[1] }
                else anchor = pmem[1]
                delete d2k_anchor
                for (j = 1; j <= m; j++) {
                    f = pmem[j]
                    if (f == "" || f == anchor) continue
                    if (dir1(f) == dir1(anchor) || file_stemkw[f] == kw || istest[f]) {
                        union(anchor, f)
                    } else {
                        d2 = dir2(f)
                        if (d2 in d2k_anchor) union(d2k_anchor[d2], f)
                        else d2k_anchor[d2] = f
                    }
                }
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

        # Full staged blobs for the fallback pass — contents_dir/NNNN holds
        # the index blob of the file at sorted position N (written by
        # group_staged_files_logically for pass-1 singletons only).
        if (contents_dir != "" && content_kw_off != "true") {
            for (i = 1; i <= nf; i++) {
                cpath = contents_dir "/" sprintf("%04d", i)
                btxt = ""
                while ((getline cline < cpath) > 0) {
                    btxt = btxt cline "\n"
                    if (length(btxt) > 200000) { btxt = substr(btxt, 1, 200000); break }
                }
                close(cpath)
                if (btxt != "") full[i] = btxt
            }
        }

        # Index mtimes (path<TAB>epoch) for the temporal tiebreak — files
        # absent from the file keep mtime 0 and are skipped in comparisons.
        if (mtimes_file != "" && time_off != "true") {
            while ((getline mline < mtimes_file) > 0) {
                split(mline, mf, "\t")
                if (mf[1] != "" && mf[2] + 0 > 0) mtime[mf[1]] = mf[2] + 0
            }
            close(mtimes_file)
        }

        cyc = "3.7"
        # Cycle 3.7 — Content-keyword rescue: files untouched by every
        # structural edge may still belong to a feature group — their diff
        # hunks (or full blobs) name modules, classes, and comments that
        # coincide with staged path keywords. Each untouched file scores
        # against the components owning those keywords and joins only a
        # UNIQUE best root (score>=2: one strong or two weak kws), so it can
        # never bridge two existing groups.
        if (content_kw_off != "true") {
            for (i = 1; i <= nf; i++) {
                f = files[i]
                if (f in touched) continue
                if (!(f in cklist)) collect_content_kws(f, i)
                if (!(f in cklist)) continue
                delete cscore; delete ckroot
                nc = split(cklist[f], cks, SUBSEP)
                for (ci = 1; ci <= nc; ci++) {
                    ck = cks[ci]
                    if (!(ck in pk_mem)) continue
                    nmembers = split(pk_mem[ck], pmem2, SUBSEP)
                    if (nmembers > ckw_max + 0) continue
                    w = ckw[f SUBSEP ck]
                    for (oi = 1; oi <= nmembers; oi++) {
                        g = pmem2[oi]
                        if (g == f) continue
                        r = find(g)
                        k2 = r SUBSEP ck
                        if (!(k2 in ckroot)) { ckroot[k2] = 1; cscore[r] += w }
                    }
                }
                best = ""; bestscore = 1; nties = 0; delete tb_ties
                for (r in cscore) {
                    if (cscore[r] > bestscore) { bestscore = cscore[r]; best = r; nties = 1; delete tb_ties; tb_ties[1] = r }
                    else if (cscore[r] == bestscore) { nties++; tb_ties[nties] = r }
                }
                if (best != "" && nties == 1) {
                    for (oi = 1; oi <= nf; oi++) {
                        if (find(files[oi]) == best) { union(f, files[oi]); break }
                    }
                } else if (best != "" && nties > 1 && time_off != "true" && mtime[f] > 0) {
                    # Temporal tiebreak: among equally-scored candidates pick the
                    # component whose members were modified closest to f — only
                    # when the minimum delta is unique and inside the window.
                    tb_bestd = -1; tb_ndel = 0; tb_brest = ""
                    for (ti = 1; ti <= nties; ti++) {
                        tb_rt = tb_ties[ti]
                        tb_dmin = -1
                        for (oi = 1; oi <= nf; oi++) {
                            tb_mm = files[oi]
                            if (find(tb_mm) != tb_rt || mtime[tb_mm] == 0) continue
                            tb_dd = mtime[tb_mm] - mtime[f]; if (tb_dd < 0) tb_dd = -tb_dd
                            if (tb_dmin < 0 || tb_dd < tb_dmin) tb_dmin = tb_dd
                        }
                        if (tb_dmin < 0) continue
                        if (tb_bestd < 0 || tb_dmin < tb_bestd) { tb_bestd = tb_dmin; tb_brest = tb_rt; tb_ndel = 1 }
                        else if (tb_dmin == tb_bestd) tb_ndel++
                    }
                    if (tb_brest != "" && tb_ndel == 1 && tb_bestd <= time_win + 0) {
                        for (oi = 1; oi <= nf; oi++) {
                            if (find(files[oi]) == tb_brest) { union(f, files[oi]); break }
                        }
                    }
                }
            }
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
        dom_feat=$(printf '%s\n' "${_aicommit_split_files[@]}" | LC_ALL=C awk \
        -v pathkw_re="$_AICOMMIT_PATH_KW_EXCL_RE" '
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
        function canon_seg(s,   t) {
            t = tolower(s)
            if (t ~ /ies$/) sub(/ies$/, "y", t)
            else if (t ~ /(sses|shes|ches|xes|zes)$/) sub(/es$/, "", t)
            else if (t ~ /[^s]s$/ && length(t) > 3) sub(/s$/, "", t)
            gsub(/[-_]/, "", t)
            if (t ~ /^[a-z0-9]+$/) return t
            return ""
        }
        function is_path_keyword(s) {
            return is_domain_keyword(s) && s !~ pathkw_re
        }
        {
            st = feature_of($0)
            if (is_domain_keyword(st)) counts[st]++
            # Directory-segment path keywords vote too — a merged component
            # like models/abc.py + tests/models/abc/{this,that}.py names `abc`
            # instead of falling back to a generic test/docs scope. Dedup per
            # file+kw so repeated segments cannot inflate a count.
            delete nkw
            d = dirname_of($0)
            if (d != ".") {
                nd = split(d, dseg, "/")
                for (di = (nd > 1 ? 2 : 1); di <= nd; di++) {
                    kw = canon_seg(dseg[di])
                    if (kw != "" && is_path_keyword(kw) && !(kw in nkw)) {
                        nkw[kw] = 1
                        counts[kw]++
                    }
                }
            }
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
    local mtimes_file="${tmp_dir}/MTIMES"
    _aicommit_group_mtimes "$tmp_dir"

    local comp_lines contents_dir=""
    comp_lines=$(cluster_staged_files_deterministic "$staged_files" "$diff_file" "$cochange_file" "" "$mtimes_file")

    # Full-content fallback: pass-1 singletons may have unchanged imports or
    # comments outside the diff hunks — read their staged blobs (bounded) and
    # re-cluster once so Cycle 3.7 sees the whole file.
    if [ "${AI_DISABLE_CONTENT_KEYWORDS:-false}" != "true" ] && [ "${AI_CONTENT_FALLBACK_MAX:-20}" -gt 0 ] 2>/dev/null; then
        contents_dir=$(_aicommit_group_content_fallback "$staged_files" "$comp_lines" "$tmp_dir")
        if [ -n "$contents_dir" ]; then
            comp_lines=$(cluster_staged_files_deterministic "$staged_files" "$diff_file" "$cochange_file" "$contents_dir" "$mtimes_file")
        fi
    fi

    local result
    result=$(_name_component_lines "$comp_lines")
    _write_grouping_source "deterministic"

    printf '%s\n' "$result"
}

# Index mtimes for staged files: `git ls-files --debug` emits path lines
# followed by indented stat fields; the mtime field carries epoch:nsec of the
# worktree file as last recorded by the index. Writes path<TAB>epoch rows to
# ${tmp_dir}/MTIMES for the clusterer's temporal tiebreak (files absent from
# the index — deletions — simply have no row).
# Args: $1=tmp_dir
_aicommit_group_mtimes() {
    local tmp_dir="$1"
    agit ls-files --debug 2>/dev/null | LC_ALL=C awk '
        /^[^ \t]/ { cur = $0; next }
        /mtime:/ { split($2, a, ":"); if (cur != "" && a[1] + 0 > 0) print cur "\t" a[1] }
    ' > "${tmp_dir}/MTIMES" 2>/dev/null || : > "${tmp_dir}/MTIMES"
}

# Pass-1 singleton rescue prep: for each staged file that landed alone in its
# component, extract its index blob (git show :path — the staged content, not
# the worktree) into ${tmp_dir}/group_contents/NNNN where NNNN is the file's
# position in LC_ALL=C sorted order (the same order cluster_staged_files_
# deterministic feeds awk). Prints the contents dir when at least one usable
# blob was written, nothing otherwise. Binaries/empties/deleted files are
# skipped via grep -I on the raw stream.
# Args: $1=staged_files, $2=comp_lines ("g\tf1\tf2..."), $3=tmp_dir
_aicommit_group_content_fallback() {
    local staged_files="$1" comp_lines="$2" tmp_dir="$3"
    local max="${AI_CONTENT_FALLBACK_MAX:-20}" cap="${AI_CONTENT_MAX_BYTES:-131072}"
    [ "$max" -gt 0 ] 2>/dev/null || return 0

    # comp lines with exactly one file member ("g\tfile")
    local singles
    singles=$(printf '%s\n' "$comp_lines" | LC_ALL=C awk -F'\t' 'NF==2 && $2!="" {print $2}')
    local n_single
    n_single=$(printf '%s\n' "$singles" | count_lines)
    [ "$n_single" -eq 0 ] || [ "$n_single" -gt "$max" ] && return 0

    # "idx<TAB>path" for each singleton, idx = position in sorted staged list
    local pairs idx f tmpf written=0
    local contents_dir="${tmp_dir}/group_contents"
    pairs=$(printf '%s\n' "$staged_files" | LC_ALL=C sort | LC_ALL=C awk \
        'NR==FNR { s[$0]=1; next } { if ($0 in s) print FNR "\t" $0 }' \
        <(printf '%s\n' "$singles") -)
    [ -z "$pairs" ] && return 0

    mkdir -m 700 -p "$contents_dir" 2>/dev/null || return 0
    while IFS=$'\t' read -r idx f; do
        [ -n "$idx" ] && [ -n "$f" ] || continue
        tmpf=$(mktemp "${TMPDIR:-/tmp}/aicommit-blob.XXXXXX" 2>/dev/null) || continue
        if agit show ":$f" 2>/dev/null | head -c "$cap" > "$tmpf" \
            && grep -Iq . "$tmpf" 2>/dev/null; then
            mv "$tmpf" "${contents_dir}/$(printf '%04d' "$idx")" 2>/dev/null && written=$((written + 1))
        else
            rm -f "$tmpf"
        fi
    done <<< "$pairs"

    [ "$written" -gt 0 ] && printf '%s' "$contents_dir"
    return 0
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
