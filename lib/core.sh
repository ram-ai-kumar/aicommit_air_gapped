#!/usr/bin/env bash
# aicommit — Core Logic
# Orchestrates context building, prompt assembly, and LLM commit generation.

# ─── Working-directory layout ────────────────────────────────────────────────
# All aicommit working files live inside the repository's own git dir:
#
#   $(git rev-parse --absolute-git-dir)/aicommit/
#     state/                  shared between runs, every file keyed by a
#       SCOPE_GROUPS          fingerprint or hash and written tmp+mv
#       STAGED_FINGERPRINT
#       FULL_PROMPT           audit artifact (system rules + user context)
#       MSG_KEY/MSG_CACHE/    last request hash + assembled message
#       MSG_REQUEST/SEED_OFFSET
#       GROUPS_KEY/GROUPS_CACHE  grouping cache (sha of sorted staged list)
#       COCHANGE              co-change pairs, HEAD sha on line 1
#     runs/<pid>.XXXXXX/      private to one invocation — two terminals never
#       STAGED_DIFF           share files; removed on exit
#       STAGED_NAMES NUMSTAT FACTS CHANGES_CONTEXT REQUEST.json RESPONSE
#       groups/<i>/{DIFF,NUMSTAT,CHANGES_CONTEXT,...}
#     lock/                   mkdir mutex (macOS has no flock) around
#                             index/ref mutation
#
# The git dir is never tracked, needs no .gitignore, is isolated per project
# AND per worktree (each worktree has its own git dir), and is deleted with
# the repo. It adds no new exposure: the same content already sits in the
# working tree and the object store.

# Repo-scoped base dir (<git-dir>/aicommit). Empty outside a git repo.
get_aicommit_base_dir() {
    if [ -n "$_AICOMMIT_BASE_DIR" ] && [ "$_AICOMMIT_BASE_DIR_PWD" = "$PWD" ]; then
        printf '%s' "$_AICOMMIT_BASE_DIR"
        return 0
    fi
    local git_dir
    git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
    _AICOMMIT_BASE_DIR="${git_dir}/aicommit"
    _AICOMMIT_BASE_DIR_PWD="$PWD"
    printf '%s' "$_AICOMMIT_BASE_DIR"
}

# Check a directory is ours and private: not a symlink, owned by $UID, mode 700.
# Returns: 0 = secure, 1 = exists but insecure, 2 = missing.
_aicommit_dir_check() {
    local d="$1" owner perms
    [ -L "$d" ] && return 1
    [ -d "$d" ] || return 2
    owner=$(stat -f %u "$d" 2>/dev/null || stat -c %u "$d" 2>/dev/null) || return 1
    [ "$owner" = "$(id -u)" ] || return 1
    perms=$(stat -f %A "$d" 2>/dev/null || stat -c %a "$d" 2>/dev/null) || return 1
    [ "$perms" = "700" ] || return 1
    return 0
}

# Ensure <base>/aicommit plus runs/ and state/ exist and are secure.
# Returns: 0 ok, 1 exists-but-insecure (caller must abort), 2 cannot create.
_init_base_layout() {
    local base="$1" rc sub
    # Guarded call — a nonzero result must never hit the shell's ERR trap
    # (bats runs tests with `set -E`; a simple failing command would abort).
    _aicommit_dir_check "$base" && rc=0 || rc=$?
    [ $rc -eq 1 ] && return 1
    if [ $rc -eq 2 ]; then
        mkdir -m 700 -p "$base" 2>/dev/null || return 2
        _aicommit_dir_check "$base" >/dev/null 2>&1 || return 2
    fi
    for sub in runs state; do
        _aicommit_dir_check "${base}/${sub}" && rc=0 || rc=$?
        [ $rc -eq 1 ] && return 1
        if [ $rc -eq 2 ]; then
            mkdir -m 700 "${base}/${sub}" 2>/dev/null || return 2
        fi
    done
    return 0
}

# Per-invocation working dir. Lazily resolves to <base>/runs/$$ (deterministic,
# so subshells that call this before the parent ever did still agree on the
# path). init_aicommit_run overrides it with a unique mktemp dir per aicommit
# invocation.
get_aicommit_tmp_dir() {
    if [ -n "$_AICOMMIT_RUN_DIR" ] && [ -d "$_AICOMMIT_RUN_DIR" ]; then
        printf '%s' "$_AICOMMIT_RUN_DIR"
        return 0
    fi
    local base rc
    base=$(get_aicommit_base_dir 2>/dev/null) || base=""
    if [ -n "$base" ]; then
        _init_base_layout "$base" >/dev/null 2>&1 && rc=0 || rc=$?
        if [ $rc -eq 1 ]; then
            display_error "Refusing insecure aicommit directory: ${base}" \
                "Must not be a symlink, must be owned by you, mode 700"
            return 1
        fi
        if [ $rc -eq 0 ]; then
            _AICOMMIT_RUN_DIR="${base}/runs/$$"
            _aicommit_dir_check "$_AICOMMIT_RUN_DIR" && rc=0 || rc=$?
            [ $rc -eq 1 ] && { display_error "Refusing insecure run directory: ${_AICOMMIT_RUN_DIR}"; return 1; }
            [ $rc -eq 2 ] && { mkdir -m 700 "$_AICOMMIT_RUN_DIR" 2>/dev/null || return 1; }
            printf '%s' "$_AICOMMIT_RUN_DIR"
            return 0
        fi
        # rc == 2 → git dir not writable → private TMPDIR fallback
    fi
    _AICOMMIT_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aicommit.XXXXXXXX" 2>/dev/null) || return 1
    printf '%s' "$_AICOMMIT_RUN_DIR"
}

# Shared cross-run state dir (SCOPE_GROUPS, message cache, co-change cache…).
get_aicommit_state_dir() {
    local base rc
    base=$(get_aicommit_base_dir 2>/dev/null) || base=""
    if [ -n "$base" ]; then
        _init_base_layout "$base" >/dev/null 2>&1 && rc=0 || rc=$?
        if [ $rc -eq 0 ]; then
            printf '%s' "${base}/state"
            return 0
        fi
        [ $rc -eq 1 ] && return 1
    fi
    # Fallback: state lives inside the run dir when there is no usable git dir
    local rd
    rd=$(get_aicommit_tmp_dir) || return 1
    mkdir -m 700 -p "${rd}/state" 2>/dev/null || return 1
    printf '%s' "${rd}/state"
}

# Called once per aicommit() invocation: fresh private run dir + dead-run purge.
init_aicommit_run() {
    _AICOMMIT_RUN_DIR=""
    local base rc
    base=$(get_aicommit_base_dir 2>/dev/null) || base=""
    if [ -n "$base" ]; then
        _init_base_layout "$base" >/dev/null 2>&1 && rc=0 || rc=$?
        if [ $rc -eq 1 ]; then
            display_error "Refusing insecure aicommit directory: ${base}" \
                "Must not be a symlink, must be owned by you, mode 700"
            return 1
        fi
        if [ $rc -eq 0 ]; then
            aicommit_purge_dead_runs "$base"
            _aicommit_purge_cache "$base"
            _AICOMMIT_RUN_DIR=$(mktemp -d "${base}/runs/$$.XXXXXXXX" 2>/dev/null) || rc=2
            if [ $rc -eq 0 ]; then
                # Reset the regenerate seed offset for this invocation
                printf '0' > "${base}/state/SEED_OFFSET.tmp" && mv "${base}/state/SEED_OFFSET.tmp" "${base}/state/SEED_OFFSET" 2>/dev/null || true
                return 0
            fi
        fi
        # rc == 2 → git dir not writable → private TMPDIR fallback
    fi
    _AICOMMIT_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aicommit.XXXXXXXX" 2>/dev/null) || return 1
    return 0
}

# Purge cache entries: retain 20 newest, remove entries older than 7 days.
_aicommit_purge_cache() {
    local base="$1"
    local cache_dir="${base}/state/cache"
    [ -d "$cache_dir" ] || return 0

    # Purge entries older than 7 days
    find "$cache_dir" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

    # Retain newest 20 entries
    local entries=()
    while IFS= read -r dir_path; do
        [ -n "$dir_path" ] && [ -d "$dir_path" ] && entries+=("$dir_path")
    done < <(ls -td "${cache_dir}"/*/ 2>/dev/null)

    local count=${#entries[@]}
    if [ "$count" -gt 20 ]; then
        local i
        for ((i = 20; i < count; i++)); do
            rm -rf "${entries[$i]}" 2>/dev/null || true
        done
    fi
}

# Remove run dirs whose owning PID is dead, and same-shell leftovers from
# previous invocations (a shell function runs sequentially per PID, so any
# runs/$$* dir other than the current one is stale). A dir whose PID is alive
# and different belongs to a concurrent run in another terminal — untouched.
aicommit_purge_dead_runs() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions nonomatch typesetsilent
    local base="$1" d pid
    [ -d "${base}/runs" ] || return 0
    for d in "${base}"/runs/*; do
        [ -e "$d" ] || continue
        [ "$d" = "$_AICOMMIT_RUN_DIR" ] && continue
        pid="${d##*/}"; pid="${pid%%.*}"
        if [ "$pid" = "$$" ] || ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$d"
        fi
    done
}

aicommit_cleanup_run_dir() {
    if [ -n "${_AICOMMIT_BG_PID:-}" ]; then
        kill "$_AICOMMIT_BG_PID" 2>/dev/null || true
        _AICOMMIT_BG_PID=""
    fi
    if [ -n "$_AICOMMIT_RUN_DIR" ] && [ -d "$_AICOMMIT_RUN_DIR" ]; then
        rm -rf "$_AICOMMIT_RUN_DIR" 2>/dev/null || true
    fi
    _AICOMMIT_RUN_DIR=""
}

# mkdir-based mutex around index/ref mutation so two terminals can't interleave
# `git commit`/`update-ref` in the same repo. The holder's PID is recorded; a
# dead holder's lock is reclaimed. Returns 0 unlocked when there is no git dir
# (nothing to serialize then) and 1 on wait timeout.
aicommit_acquire_lock() {
    local base lockdir holder tries=0 mtime now
    base=$(get_aicommit_base_dir 2>/dev/null) || return 0
    _init_base_layout "$base" >/dev/null 2>&1 || return 0
    lockdir="${base}/lock"
    while ! mkdir "$lockdir" 2>/dev/null; do
        holder=$(cat "${lockdir}/pid" 2>/dev/null || true)
        if [ -n "$holder" ]; then
            if ! kill -0 "$holder" 2>/dev/null; then
                rm -rf "$lockdir" 2>/dev/null
                continue
            fi
        else
            # No pid yet — holder is mid-acquisition or died before writing it.
            # Reclaim once the dir is clearly stale.
            mtime=$(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0)
            now=$(date +%s)
            if [ $((now - mtime)) -gt 15 ]; then
                rm -rf "$lockdir" 2>/dev/null
                continue
            fi
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 120 ]; then
            display_error "Timed out waiting for the aicommit commit lock" \
                "Another aicommit run holds ${lockdir}"
            return 1
        fi
        sleep 0.5
    done
    printf '%s' "$$" > "${lockdir}/pid" 2>/dev/null || true
    _AICOMMIT_LOCK_DIR="$lockdir"
    return 0
}

aicommit_release_lock() {
    if [ -n "$_AICOMMIT_LOCK_DIR" ]; then
        rm -rf "$_AICOMMIT_LOCK_DIR" 2>/dev/null || true
        _AICOMMIT_LOCK_DIR=""
    fi
}

# aicommit --clean-cache: remove the repo-local .git/aicommit working tree.
aicommit_clean_cache() {
    local base
    base=$(get_aicommit_base_dir) || {
        echo "Not inside a git repository — nothing to clean."
        return 0
    }
    case "$base" in
        */aicommit)
            rm -rf "$base" && echo "🧹 Removed ${base}"
            ;;
        *)
            display_error "Refusing to remove unexpected path" "$base"
            return 1
            ;;
    esac
}

# Validate prerequisites using backend abstraction
validate_prerequisites() {
    validate_backend_prerequisites
}

# All git reads/writes touching paths go through this: disables path quoting/octal
# escaping (core.quotePath) so non-ASCII filenames round-trip as raw UTF-8 instead
# of "quoted\342\204\242strings" that never match anything downstream.
agit() {
    git -c core.quotePath=false "$@"
}

# Convert a repo-root-relative path into a pathspec that resolves the same way
# regardless of the caller's CWD. Without this, `git diff -- <path>` silently
# matches nothing when run from any subdirectory of the repo (pathspecs are
# CWD-relative; `git diff --name-only` output is always repo-root-relative).
to_pathspec() {
    printf ':(top,literal)%s' "$1"
}

# Stable fingerprint of the current staged file set — used to detect whether
# staging changed between a dry-run preview and a later split-commit execution.
staged_fingerprint() {
    agit diff --staged -z --name-only | shasum -a 256 | awk '{print $1}'
}

# Split a TAB-delimited "scope<TAB>file<TAB>file..." line into
# `_aicommit_split_scope` (scalar) and `_aicommit_split_files` (array), without
# declaring either local here (so the assignment lands on the caller's scope via
# ordinary dynamic scoping — verified to work identically in bash and zsh).
#
# This exists because aicommit.sh is `source`d directly into the caller's
# interactive shell (see its file header), so it must work under both bash and
# zsh, and two incompatibilities rule out the obvious approaches:
#   - `read -a` (bash's "read into array" flag) vs `read -A` (zsh's) — no
#     spelling is valid in both interpreters, so plain `read -r line` is used
#     and splitting is done separately, in this helper.
#   - zsh arrays are 1-indexed by default; bash arrays are 0-indexed. Code that
#     reads `${arr[0]}` for "the first field" and `${arr[@]:1}` for "the rest"
#     silently gets nothing under zsh (index 0 doesn't exist there) instead of
#     an error — this is what broke `aiccx`/`aicc` group parsing under zsh even
#     after the read -a/-A fix. Returning the scope and the files as two
#     separate variables sidesteps numeric indexing entirely, so there is no
#     0-vs-1 convention to get wrong.
_aicommit_split_tab_line() {
    local line="$1"
    _aicommit_split_scope=""
    _aicommit_split_files=()
    [ -z "$line" ] && return 0
    local rest="$line" field more=true is_first=true
    while $more; do
        if [[ "$rest" == *$'\t'* ]]; then
            field="${rest%%$'\t'*}"
            rest="${rest#*$'\t'}"
        else
            field="$rest"
            more=false
        fi
        if $is_first; then
            _aicommit_split_scope="$field"
            is_first=false
        else
            _aicommit_split_files+=("$field")
        fi
    done
}

# Count non-empty lines from stdin. Deliberately NOT `grep -c ... || echo "0"`:
# on zero matches, `grep -c` still prints "0" to stdout AND exits 1, so a
# `|| echo "0"` fallback appends a second "0" line and callers that expect a
# single integer (e.g. `[ "$n" -ge 2 ]`) blow up with "integer expression expected".
count_lines() {
    awk '$0 != "" { c++ } END { print c + 0 }'
}

# Build file context — writes FILE_CONTEXT, CHANGE_STATS, and FILE_COUNT.
# Single awk pass (was: per-file grep + awk subshell per line).
# Args: $1=staged_files, $2=numstat_data, $3=out_dir (optional, default run dir)
# Writes count to ${out_dir}/FILE_COUNT (avoids stdout pollution from zsh xtrace)
build_file_context() {
    local staged_files="$1"
    local numstat_data="$2"
    local out_dir="${3:-}"
    if [ -z "$out_dir" ]; then
        out_dir=$(get_aicommit_tmp_dir) || return 1
    fi
    mkdir -m 700 -p "$out_dir" 2>/dev/null || return 1

    # Restrict permissions for sensitive content
    umask 077

    # numstat travels via file, not -v: BSD awk rejects literal newlines in -v
    printf '%s' "$numstat_data" > "${out_dir}/NUMSTAT"

    printf '%s\n' "$staged_files" | awk \
        -v numstat_file="${out_dir}/NUMSTAT" \
        -v out="$out_dir" \
        -v sensitive="$_AICOMMIT_SENSITIVE_RE" '
    BEGIN {
        while ((getline row < numstat_file) > 0) {
            c = split(row, f, "\t")
            if (c >= 3) { add[f[3]] = f[1]; del[f[3]] = f[2] }
        }
        close(numstat_file)
        file_ctx = ""; stats = ""; total = 0
    }
    {
        line = $0
        gsub(/^[ \t]+/, "", line)
        gsub(/[ \t\r]+$/, "", line)
        if (line == "") next
        total++
        if (line ~ sensitive) next
        ext = line
        if (ext !~ /\./) ext = ""; else sub(/.*\./, "", ext)
        if      (ext ~ /^(js|ts|jsx|tsx)$/)  t = "javascript/typescript"
        else if (ext == "py")                t = "python"
        else if (ext ~ /^(sh|bash)$/)        t = "shell"
        else if (ext ~ /^(md|txt)$/)         t = "documentation"
        else if (ext ~ /^(json|yaml|yml)$/)  t = "config"
        else if (ext ~ /^(html|css|scss)$/)  t = "web"
        else if (ext == "rb")                t = "ruby"
        else                                 t = ext
        file_ctx = file_ctx "\n" line " (" t ")"
        if (add[line] != "" && del[line] != "")
            stats = stats "\n" line ": +" add[line] " -" del[line] " lines"
    }
    END {
        # BSD awk needs the redirected filename parenthesized
        printf "%s", file_ctx > (out "/FILE_CONTEXT")
        printf "%s", stats    > (out "/CHANGE_STATS")
        printf "%s", total    > (out "/FILE_COUNT")
    }
    '
}

# Filter diff by tier and truncate per-file. Reads from stdin, writes to stdout.
# Tier 1 (stat only)     — generated/binary/sensitive files: diff entirely excluded
# Tier 2 (tier2 cap)     — low-signal files: tests, docs, markdown (default 20)
# Tier 3 (tier3 cap)     — full-signal files: source, config, migrations (default 80)
# Args: $1=tier2 cap, $2=tier3 cap — a cap of 0 makes the tier stat-only.
filter_and_truncate_diff() {
    local tier2_cap="${1:-20}"
    local tier3_cap="${2:-80}"

    awk -v sensitive="$_AICOMMIT_SENSITIVE_RE" \
        -v cap2="$tier2_cap" -v cap3="$tier3_cap" '
    BEGIN { tier = 3; max_lines = cap3; file_lines = 0 }
    /^diff --git/ {
        if (file_lines > max_lines && max_lines >= 0 && tier >= 2)
            printf "    ... (%d lines truncated)\n", (file_lines - max_lines)
        # Filenames containing spaces break a naive $NF split (it grabs only
        # the last word). Match the " b/<path>" suffix instead — reliable for
        # any path except one that literally contains the substring " b/".
        if (match($0, / b\/.*$/)) {
            file = substr($0, RSTART + 3)
        } else {
            file = $NF; sub(/^b\//, "", file)
        }
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
        # Tier 2 — low-signal
        else if (file ~ /^tests?\// || file ~ /\/tests?\// ||
                 file ~ /^spec\// || file ~ /\/spec\// ||
                 file ~ /^__tests__\// ||
                 file ~ /\.(test|spec)\.(js|ts)$/ ||
                 file ~ /test_.*\.py$/ ||
                 file ~ /_test\.(py|go)$/ ||
                 file ~ /^docs?\// || file ~ /\/docs?\// ||
                 file ~ /\.(md|rst)$/ ||
                 file ~ /^README/ || file ~ /^CHANGELOG/ || file ~ /^CONTRIBUTING/) {
            tier = 2; max_lines = cap2 + 0
        }
        # Tier 3 — full signal
        else {
            tier = 3; max_lines = cap3 + 0
        }
        if (tier >= 2) print
        next
    }
    {
        file_lines++
        if (tier >= 2 && file_lines <= max_lines) print
    }
    END {
        if (file_lines > max_lines && max_lines >= 0 && tier >= 2)
            printf "    ... (%d lines truncated)\n", (file_lines - max_lines)
    }
    '
}

# Deterministic facts extracted from the staged diff — one awk pass.
# The model is told to describe THESE facts instead of guessing. Reads diff
# text on stdin.
build_facts() {
    awk '
    /^diff --git / {
        file = $0
        if (match(file, / b\/.*$/)) file = substr(file, RSTART + 3)
        else { split(file, p, " "); file = p[3]; sub(/^b\//, "", file) }
        cur = file
        next
    }
    /^new file mode/     { added[cur] = 1;   next }
    /^deleted file mode/ { deleted[cur] = 1; next }
    /^rename to /        {
        rn = $0; sub(/^rename to /, "", rn)
        renamed[cur] = rn; next
    }
    /^@@ / {
        ctx = $0
        sub(/^.*@@/, "", ctx)
        gsub(/^[ \t]+|[ \t]+$/, "", ctx)
        if (ctx != "") symbols[ctx] = 1
        next
    }
    /^[+-]/ && !/^[+-][+-][+-]/ {
        line = $0
        sym = ""
        if (match(line, /(^|[^A-Za-z0-9_])(def |function |func |class |interface |struct |enum )[A-Za-z_][A-Za-z0-9_]*/)) {
            sym = substr(line, RSTART, RLENGTH)
            sub(/.* /, "", sym)
        } else if (match(line, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\([^;{}]*\)[ \t]*\{/)) {
            s = substr(line, RSTART, RLENGTH)
            match(s, /^[A-Za-z_][A-Za-z0-9_]*/)
            sym = substr(s, RSTART, RLENGTH)
        }
        if (sym != "") {
            if (line ~ /^\+/) defs_add[sym] = 1; else defs_del[sym] = 1
        }
        next
    }
    END {
        print "=== FACTS ==="
        first = 1; out = ""
        for (f in added)   { out = out (first ? "" : ", ") f; first = 0 }
        if (out != "") print "Files added: " out
        first = 1; out = ""
        for (f in deleted) { out = out (first ? "" : ", ") f; first = 0 }
        if (out != "") print "Files deleted: " out
        for (f in renamed) print "File renamed: " f " -> " renamed[f]
        first = 1; out = ""
        for (s in symbols) { out = out (first ? "" : ", ") s; first = 0 }
        if (out != "") print "Symbols touched (hunk context): " out
        first = 1; out = ""
        for (s in defs_add) { out = out (first ? "" : ", ") s; first = 0 }
        if (out != "") print "Definitions added: " out
        first = 1; out = ""
        for (s in defs_del) { out = out (first ? "" : ", ") s; first = 0 }
        if (out != "") print "Definitions removed: " out
    }
    '
}

# Narrow the conventional-commit type enum from the staged file list (stdin).
# Emits one allowed type per line. The schema enum makes a wrong type
# unrepresentable instead of merely discouraged.
infer_allowed_types() {
    awk '
    {
        if ($0 == "") next
        n++
        is_docs = ($0 ~ /(^|\/)(docs?|documentation)\// || $0 ~ /\.(md|rst|txt|adoc)$/ || \
                   $0 ~ /(^|\/)(README|CHANGELOG|CONTRIBUTING|LICENSE|NOTICE|AGENTS|AUTHORS)(\.[^.\/]+)?$/)
        is_test = ($0 ~ /(^|\/)(tests?|spec|__tests__|testdata)\// || \
                   $0 ~ /(_test|_spec|\.test|\.spec)\.[^.\/]+$/ || $0 ~ /\.bats$/ || \
                   $0 ~ /(^|\/)test_[^\/]+$/)
        is_ci   = ($0 ~ /^\.(github|gitlab|circleci)\// || $0 ~ /(^|\/)(Jenkinsfile|azure-pipelines\.yml|\.gitlab-ci\.yml)$/ || \
                   $0 ~ /(^|\/)Dockerfile[^\/]*$/ || $0 ~ /(^|\/)(docker-compose[^\/]*|compose\.ya?ml)$/)
        is_dep  = ($0 ~ /(^|\/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Gemfile\.lock|go\.sum|Cargo\.lock|poetry\.lock|composer\.lock|Pipfile\.lock|mix\.lock|bun\.lockb)$/ || \
                   $0 ~ /(^|\/)(package\.json|Gemfile|go\.mod|Cargo\.toml|pyproject\.toml|requirements[^\/]*\.txt|pom\.xml|build\.gradle[^\/]*|composer\.json|pubspec\.yaml|setup\.py|setup\.cfg|[^\/]*\.csproj|[^\/]*\.fsproj)$/)
        if (!is_docs) all_docs = 0
        if (!is_test) all_test = 0
        if (!is_ci)   all_ci   = 0
        if (!is_dep)  all_dep  = 0
    }
    BEGIN { all_docs = all_test = all_ci = all_dep = 1 }
    END {
        if (n == 0) { print "chore"; exit }
        if (all_docs) print "docs"
        else if (all_test) print "test"
        else if (all_ci)   print "ci"
        else if (all_dep)  print "build\nchore"
        else print "feat\nfix\ndocs\nstyle\nrefactor\nperf\ntest\nbuild\nci\nchore\nrevert"
    }
    '
}

# Scope candidates: deterministic scopes from staged paths plus scopes actually
# used in this repo's recent history (style reference, not shown to the model).
# Args: $1=staged_files
collect_scope_candidates() {
    local staged_files="$1" f s
    {
        while IFS= read -r f; do
            [ -n "$f" ] && infer_file_scope "$f"
        done <<< "$staged_files"
        agit log -200 --format=%s 2>/dev/null \
            | sed -nE 's/^[a-z]+\(([a-zA-Z0-9_.,\/ -]+)\)!?: .+/\1/p' \
            | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/-/g'
    } | awk 'NF' | sort -u | head -20
}

# Build AI context — writes run-dir files consumed by the prompt pipeline.
# Args: $1=diff, $2=staged_files, $3=numstat_data, $4=logical_scope (optional),
#       $5=out_dir (optional, default run dir), $6=tier2 cap, $7=tier3 cap
build_ai_context() {
    local changes="$1"
    local staged_files="$2"
    local numstat_data="$3"
    local logical_scope="${4:-}"
    local out_dir="${5:-}"
    local tier2_cap="${6:-20}"
    local tier3_cap="${7:-80}"
    local tmp_dir
    tmp_dir=$(get_aicommit_tmp_dir) || return 1
    [ -z "$out_dir" ] && out_dir="$tmp_dir"
    mkdir -m 700 -p "$out_dir" 2>/dev/null || return 1

    # Restrict permissions for sensitive content
    umask 077

    # Persist raw inputs: facts/schema/grounding consumers and the token-budget
    # rebuilder read these files instead of re-running git or big shell strings.
    printf '%s' "$changes"      > "${out_dir}/STAGED_DIFF"
    printf '%s' "$staged_files" > "${out_dir}/STAGED_NAMES"
    printf '%s' "$numstat_data" > "${out_dir}/NUMSTAT"
    printf '%s' "$logical_scope" > "${out_dir}/LOGICAL_SCOPE"
    : > "${out_dir}/CHANGES_CONTEXT"

    build_file_context "$staged_files" "$numstat_data" "$out_dir" > /dev/null 2>&1
    local total_files
    total_files=$(cat "${out_dir}/FILE_COUNT" 2>/dev/null || echo "0")

    if [ "$total_files" -eq 0 ] 2>/dev/null || ! [ "$total_files" -gt 0 ] 2>/dev/null; then
        display_error "No staged files found"
        return 1
    fi

    # Deterministic facts, allowed types and scope candidates — the grounding
    # inputs the model is held accountable to.
    printf '%s' "$changes" | build_facts > "${out_dir}/FACTS"
    printf '%s\n' "$staged_files" | infer_allowed_types > "${out_dir}/ALLOWED_TYPES"
    collect_scope_candidates "$staged_files" > "${out_dir}/SCOPE_CANDIDATES"

    # Filter out sensitive files before any downstream processing (one grep pass)
    local filtered_staged_files
    filtered_staged_files=$(printf '%s\n' "$staged_files" | grep -vE "$_AICOMMIT_SENSITIVE_RE" || true)

    local file_context change_stats categories_context
    file_context=$(cat "${out_dir}/FILE_CONTEXT")
    change_stats=$(cat "${out_dir}/CHANGE_STATS")
    categories_context=$(categorize_staged_files "$filtered_staged_files" "$out_dir")

    # Tier 1 stat-only files (generated, binary, sensitive) — one grep pass
    local stat_only_ext='\.lock$|lock\.(json|yaml|toml)$|\.snap$|\.pyc$|\.class$|\.map$|_pb2\.py$|\.pb\.go$'
    local stat_only_assets='\.svg$|\.png$|\.jpg$|\.jpeg$|\.gif$|\.ico$|\.fig$|\.webp$|\.mp4$|\.mp3$|\.woff2?$|\.ttf$|\.min\.(js|css)$'
    local stat_only_dirs='^(dist|build|out|\.next|coverage|\.nyc_output)/|/(dist|build|coverage)/'
    local stat_only_patterns="${stat_only_ext}|${stat_only_assets}|${stat_only_dirs}|${_AICOMMIT_SENSITIVE_RE}"
    local stat_only_files
    stat_only_files=$(printf '%s\n' "$staged_files" | grep -E "$stat_only_patterns" || true)

    # Single-pass tiered filter: excludes tier-1 diffs, caps tier-2/3 diffs
    local changes_summary
    changes_summary=$(printf '%s' "$changes" | filter_and_truncate_diff "$tier2_cap" "$tier3_cap")

    # Stat summary for tier-1 files (lets the model infer dependency/asset
    # changes without reading their diffs) — one awk join, not per-file grep
    local stat_only_stat=""
    if [ -n "$stat_only_files" ]; then
        stat_only_stat=$(printf '%s\n' "$numstat_data" | awk -v list="$stat_only_files" '
            BEGIN { n = split(list, f, "\n"); for (i = 1; i <= n; i++) keep[f[i]] = 1 }
            $3 in keep { printf "%s | +%s -%s\n", $3, $1, $2 }
        ')
    fi

    local repo_name
    repo_name=$(basename "$(agit rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")

    local changes_context="=== REPOSITORY ===
${repo_name}

=== FILES ===
${categories_context#=== FILE CATEGORIES ===$'\n'}

Change statistics:
${change_stats}

$(cat "${out_dir}/FACTS")

=== CHANGES ===
${changes_summary}"

    if [ -n "$stat_only_stat" ]; then
        changes_context="${changes_context}

=== OMITTED DIFFS — stat only (generated/binary/sensitive) ===
${stat_only_stat}"
    fi

    if [ -n "$logical_scope" ]; then
        local clean_scope
        clean_scope=$(printf '%s' "$logical_scope" | sed -E 's/-[0-9]+$//')
        local should_inject=true
        if [ -f "${out_dir}/SCOPE_CANDIDATES" ]; then
            grep -qxF "$clean_scope" "${out_dir}/SCOPE_CANDIDATES" 2>/dev/null || should_inject=false
        fi
        if [ "$should_inject" = "true" ]; then
            changes_context="${changes_context}

=== LOGICAL COMMIT SCOPE & FEATURE ===
This atomic commit is scoped specifically to: ${clean_scope}.
Generate the commit message type, scope, and description focused on this logical concern."
        fi
    fi

    printf '%s' "$changes_context" > "${out_dir}/CHANGES_CONTEXT"
}

# Spec enforcer: guarantee that any commit message satisfies the
# Conventional Commits v1.0.0 specification and git 72-char convention.
# Every generation path terminates in this function.
# Accepts message via $1 or stdin.
enforce_conventional_commit() {
    local raw_input
    if [ $# -gt 0 ]; then
        raw_input="$1"
    else
        raw_input="$(cat)"
    fi

    [ -z "$raw_input" ] && return 0

    # Strip carriage returns
    raw_input=$(printf '%s' "$raw_input" | tr -d '\r')

    # If completely blank, return empty
    if [ -z "$(printf '%s' "$raw_input" | tr -d '[:space:]')" ]; then
        return 0
    fi

    # Run the core enforcement engine in awk
    printf '%s\n' "$raw_input" | awk '
        BEGIN {
            line_count = 0
        }
        {
            lines[line_count++] = $0
        }
        END {
            # 1. Locate the first non-empty line as header candidate
            first_idx = -1
            for (i = 0; i < line_count; i++) {
                if (lines[i] ~ /[^[:space:]]/) {
                    first_idx = i
                    break
                }
            }
            if (first_idx == -1) exit 0

            header_raw = lines[first_idx]
            sub(/^[[:space:]]+/, "", header_raw)
            sub(/[[:space:]]+$/, "", header_raw)

            # Match conventional commit header:
            # ^([A-Za-z]+)(\([^)]*\))?(!)?:[[:space:]]*(.*)$
            if (header_raw !~ /^([A-Za-z]+)(\([^)]*\))?(!)?:[[:space:]]*(.*)$/) {
                # Not a conventional commit header candidate.
                # Output input lines verbatim without trailing blank lines.
                last_idx = line_count - 1
                while (last_idx >= 0 && lines[last_idx] ~ /^[[:space:]]*$/) last_idx--
                for (i = first_idx; i <= last_idx; i++) {
                    print lines[i]
                }
                exit 0
            }

            # Parse header parts
            colon_idx = index(header_raw, ":")
            prefix_part = substr(header_raw, 1, colon_idx - 1)
            raw_desc = substr(header_raw, colon_idx + 1)
            sub(/^[[:space:]]+/, "", raw_desc)
            sub(/[[:space:]]+$/, "", raw_desc)
            # Strip trailing period(s) from description
            sub(/\.+$/, "", raw_desc)

            # Parse prefix_part into type, scope, bang
            has_bang = 0
            if (substr(prefix_part, length(prefix_part), 1) == "!") {
                has_bang = 1
                prefix_part = substr(prefix_part, 1, length(prefix_part) - 1)
            }

            scope_str = ""
            open_paren = index(prefix_part, "(")
            close_paren = index(prefix_part, ")")
            if (open_paren > 0 && close_paren > open_paren) {
                type_str = substr(prefix_part, 1, open_paren - 1)
                scope_content = substr(prefix_part, open_paren + 1, close_paren - open_paren - 1)
                # Lowercase and strip dedup suffix -N (e.g. -2, -123)
                scope_content = tolower(scope_content)
                sub(/-[0-9]+$/, "", scope_content)
                if (scope_content != "") {
                    scope_str = "(" scope_content ")"
                }
            } else {
                type_str = prefix_part
            }

            type_str = tolower(type_str)
            gsub(/[^a-z]/, "", type_str)

            bang_str = (has_bang ? "!" : "")
            final_prefix = type_str scope_str bang_str ": "
            p_len = length(final_prefix)

            # Check header length limit (72 chars)
            overflow_desc = ""
            head_desc = raw_desc
            total_h_len = p_len + length(head_desc)

            if (total_h_len > 72) {
                max_d = 72 - p_len
                if (max_d < 1) max_d = 1

                # Find boundary in raw_desc that keeps header <= 72.
                # Boundaries in priority order: ". ", "; ", " — ", " - "
                split_found = 0
                split_pos = 0
                delim_len = 0

                delims[1] = ". "
                delims[2] = "; "
                delims[3] = " — "
                delims[4] = " - "

                for (d_idx = 1; d_idx <= 4; d_idx++) {
                    d = delims[d_idx]
                    d_len = length(d)
                    p = index(raw_desc, d)
                    if (p > 0) {
                        if ((p - 1) <= max_d && (p - 1) >= 1) {
                            split_found = 1
                            split_pos = p
                            delim_len = d_len
                            break
                        }
                    }
                }

                if (split_found) {
                    head_desc = substr(raw_desc, 1, split_pos - 1)
                    sub(/\.+$/, "", head_desc)
                    sub(/[[:space:]]+$/, "", head_desc)
                    overflow_desc = substr(raw_desc, split_pos + delim_len)
                    sub(/^[[:space:]]+/, "", overflow_desc)
                } else {
                    # No boundary fits: cut at last word boundary (space) within max_d
                    target_sub = substr(raw_desc, 1, max_d)
                    last_space = 0
                    for (c = length(target_sub); c >= 1; c--) {
                        if (substr(target_sub, c, 1) ~ /[[:space:]]/) {
                            last_space = c
                            break
                        }
                    }
                    if (last_space > 1) {
                        head_desc = substr(raw_desc, 1, last_space - 1)
                        sub(/\.+$/, "", head_desc)
                        sub(/[[:space:]]+$/, "", head_desc)
                        overflow_desc = substr(raw_desc, last_space + 1)
                        sub(/^[[:space:]]+/, "", overflow_desc)
                    } else {
                        # Single long token (> 72 chars, no spaces) -> hard cut at max_d
                        head_desc = substr(raw_desc, 1, max_d)
                        sub(/\.+$/, "", head_desc)
                        overflow_desc = substr(raw_desc, max_d + 1)
                        sub(/^[[:space:]]+/, "", overflow_desc)
                    }
                }
            }

            final_header = final_prefix head_desc

            # 2. Extract Footers and Body from remaining lines
            rem_count = 0
            for (i = first_idx + 1; i < line_count; i++) {
                rem_lines[rem_count++] = lines[i]
            }

            rem_last = rem_count - 1
            while (rem_last >= 0 && rem_lines[rem_last] ~ /^[[:space:]]*$/) {
                rem_last--
            }

            # Scan backwards from rem_last to find contiguous trailing footer lines:
            # Pattern: ^[[:space:]]*(BREAKING[ -]CHANGE|[A-Za-z][A-Za-z-]*)(: | #)
            footer_start = rem_last + 1
            for (i = rem_last; i >= 0; i--) {
                line = rem_lines[i]
                if (line ~ /^[[:space:]]*$/) {
                    break
                }
                if (line ~ /^[[:space:]]*([Bb][Rr][Ee][Aa][Kk][Ii][Nn][Gg][ -][Cc][Hh][Aa][Nn][Gg][Ee]|[A-Za-z][A-Za-z-]*)(: | #)/) {
                    footer_start = i
                } else {
                    break
                }
            }

            footer_count = 0
            if (footer_start <= rem_last) {
                for (i = footer_start; i <= rem_last; i++) {
                    f_line = rem_lines[i]
                    sub(/^[[:space:]]+/, "", f_line)
                    sub(/[[:space:]]+$/, "", f_line)
                    if (f_line ~ /^[Bb][Rr][Ee][Aa][Kk][Ii][Nn][Gg][ -][Cc][Hh][Aa][Nn][Gg][Ee]:/) {
                        sub(/^[Bb][Rr][Ee][Aa][Kk][Ii][Nn][Gg][ -][Cc][Hh][Aa][Nn][Gg][Ee]:[[:space:]]*/, "BREAKING CHANGE: ", f_line)
                    }
                    final_footers[footer_count++] = f_line
                }
            }

            body_end = footer_start - 1
            while (body_end >= 0 && rem_lines[body_end] ~ /^[[:space:]]*$/) {
                body_end--
            }

            body_start = 0
            while (body_start <= body_end && rem_lines[body_start] ~ /^[[:space:]]*$/) {
                body_start++
            }

            raw_body_count = 0
            prev_blank = 0
            for (i = body_start; i <= body_end; i++) {
                b_line = rem_lines[i]
                sub(/[[:space:]]+$/, "", b_line)
                if (b_line ~ /^[[:space:]]*$/) {
                    if (!prev_blank && raw_body_count > 0) {
                        clean_body[raw_body_count++] = ""
                        prev_blank = 1
                    }
                } else {
                    clean_body[raw_body_count++] = b_line
                    prev_blank = 0
                }
            }
            while (raw_body_count > 0 && clean_body[raw_body_count - 1] == "") {
                raw_body_count--
            }

            total_body_count = 0
            if (overflow_desc != "") {
                final_body[total_body_count++] = overflow_desc
                if (raw_body_count > 0) {
                    final_body[total_body_count++] = ""
                }
            }
            for (i = 0; i < raw_body_count; i++) {
                final_body[total_body_count++] = clean_body[i]
            }

            # 3. Output the assembled message
            print final_header

            if (total_body_count > 0) {
                print ""
                for (i = 0; i < total_body_count; i++) {
                    print final_body[i]
                }
            }

            if (footer_count > 0) {
                print ""
                for (i = 0; i < footer_count; i++) {
                    print final_footers[i]
                }
            }
        }
    '
}

# Extract and sanitize clean conventional commit message from raw LLM output.
# Handles reasoning model thinking blocks (<think>...</think>, </think> without open tag,
# Thinking Process: preambles, duplicate keyword occurrences in draft vs final, etc.),
# delimiters (@@@, code fences), conventional commit anchor discovery, and normalization.
# Kept as the fallback parser when the model does not return schema JSON.
extract_conventional_commit() {
    local raw_input="$1"
    [ -z "$raw_input" ] && return 0

    # Step 1: Strip carriage returns and resolve terminal cursor backspaces
    local cleaned
    cleaned=$(printf '%s' "$raw_input" | tr -d '\r')

    # If input contains a schema-conforming JSON object, delegate to json assembler
    local json_cand
    if command -v extract_json_object >/dev/null 2>&1; then
        json_cand=$(extract_json_object "$cleaned" 2>/dev/null)
    elif command -v perl >/dev/null 2>&1; then
        json_cand=$(printf '%s\n' "$cleaned" | perl -0777 -ne 'print $1 if /(\{.*\})/s' | head -c 8192)
    else
        json_cand="$cleaned"
    fi
    if printf '%s' "$json_cand" | jq -e 'type == "object" and has("type") and has("subject")' >/dev/null 2>&1; then
        _commit_msg_from_json_obj "$json_cand"
        return
    fi

    # Resolve terminal cursor backspaces and line clears (\x1b[<N>D\x1b[K) emitted by terminal word-wrappers
    if command -v perl >/dev/null 2>&1; then
        local perl_cleaned
        if perl_cleaned=$(printf '%s\n' "$cleaned" | perl -0777 -pe '
            # Strip non-destructive ANSI escapes (cursor show/hide, colors) first
            s/\x1b\[\?[0-9]+[hl]//g;
            s/\x1b\[[0-9;]*m//g;

            # Resolve terminal cursor backspaces (\x1b[<N>D) with optional erase and newline
            while (/(\x1b\[(\d+)D(?:\x1b\[[0-9;]*[a-zA-Z])?\n?)/) {
                my $len = $2;
                s/.{$len}\x1b\[${len}D(?:\x1b\[[0-9;]*[a-zA-Z])?\n?//s;
            }

            # Resolve ASCII backspaces (\b)
            while (/.\x08/) {
                s/.\x08//g;
            }
        ' 2>/dev/null) && [ -n "$perl_cleaned" ]; then
            cleaned="$perl_cleaned"
        fi
    fi

    # Strip remaining ANSI escape sequences
    cleaned=$(printf '%s\n' "$cleaned" | sed -E $'s/\x1B\\[[0-9;]*[a-zA-Z]//g')

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
            if printf '%s\n' "$code_block" | grep -qiE '^[[:space:]]*(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)([(][^)]+[)])?!?: '; then
                cleaned="$code_block"
            fi
        fi
    fi

    # Step 5: Locate Conventional Commit header (case-insensitive for type, rule 15)
    local commit_regex='^[[:space:]]*([Ff][Ee][Aa][Tt]|[Ff][Ii][Xx]|[Dd][Oo][Cc][Ss]|[Ss][Tt][Yy][Ll][Ee]|[Rr][Ee][Ff][Aa][Cc][Tt][Oo][Rr]|[Pp][Ee][Rr][Ff]|[Tt][Ee][Ss][Tt]|[Bb][Uu][Ii][Ll][Dd]|[Cc][Ii]|[Cc][Hh][Oo][Rr][Ee]|[Rr][Ee][Vv][Ee][Rr][Tt])([(][^)]+[)])?!?:[[:space:]].+'

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

    # Remove immediate token stutters and terminal word-wrap fragment stutters
    if command -v perl >/dev/null 2>&1; then
        local perl_stutter
        if perl_stutter=$(printf '%s\n' "$cleaned" | perl -0777 -pe '
            # Remove word-wrap fragment stutters where line N ends with a prefix of line N+1 leading word
            # e.g. "feature/fun\nfeature/functionality" -> "feature/functionality"
            s/(?:^[ \t]*|[ \t]+)([a-zA-Z0-9_\/\-\.]+)[ \t]*\n+[ \t]*(?=\1[a-zA-Z0-9_\/\-\.]*)/ /mg;

            # Remove token duplication stutters (e.g. "an and", "and and")
            s/\b([a-zA-Z]{2,})\s+\1\b/\1/g;
            s/\b([a-zA-Z]{2,})\s+\1([a-zA-Z]+)\b/\1\2/g;
        ' 2>/dev/null) && [ -n "$perl_stutter" ]; then
            cleaned="$perl_stutter"
        fi
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
                # A non-blank, non-bullet, non-footer line directly after the header is joined
                # only when the joined header stays within 72 chars. Otherwise the line starts the body.
                is_bullet = ($0 ~ /^[[:space:]]*[-*+]/)
                is_footer = ($0 ~ /^[[:space:]]*(BREAKING[ -]CHANGE|[A-Za-z][A-Za-z-]*)(: | #)/)
                if ($0 != "" && !is_bullet && !is_footer) {
                    if (length(header " " $0) <= 72) {
                        header = header " " $0
                        next
                    }
                }
                if ($0 == "") {
                    reading_body = 1
                    next
                }
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
    ' | enforce_conventional_commit
}

# Classify a Conventional Commit message into a semver bump suggestion.
# Args: $1=commit_msg (full message, header + body/footers)
# Echoes one of: major | minor | patch | none
suggest_semver_bump() {
    local commit_msg="$1"
    local header
    header=$(printf '%s\n' "$commit_msg" | head -n1)

    if printf '%s\n' "$commit_msg" | grep -qE '^BREAKING[ -]CHANGE:'; then
        echo "major"; return
    fi
    if printf '%s\n' "$header" | grep -qE '^[[:space:]]*[a-z]+(\([^)]+\))?!:'; then
        echo "major"; return
    fi

    case "$header" in
        feat*) echo "minor" ;;
        fix*|perf*) echo "patch" ;;
        *) echo "none" ;;
    esac
}

# ─── Structured commit generation ────────────────────────────────────────────

# JSON schema for the commit object, with enum constraints built from the
# context dir's ALLOWED_TYPES and SCOPE_CANDIDATES.
# Args: $1=out_file, $2=ctx_dir, $3=mode ("single"|"batch"), $4=batch_size
_build_commit_schema() {
    local out_file="$1" d="$2" mode="${3:-single}" batch_size="${4:-0}"
    jq -n \
        --argjson types "$(awk 'NF' "${d}/ALLOWED_TYPES" 2>/dev/null | jq -R . | jq -sc 'unique')" \
        --argjson scopes "$({ cat "${d}/SCOPE_CANDIDATES" 2>/dev/null; printf 'none\nother\n'; } | awk 'NF' | jq -R . | jq -sc 'unique')" \
        --argjson mode "$([ "$mode" = "batch" ] && echo 1 || echo 0)" \
        --argjson n "$batch_size" \
        'def commit_obj: {
            type: "object",
            additionalProperties: false,
            properties: {
                type:            {type: "string", enum: $types},
                scope:           {type: "string", enum: $scopes},
                scope_other:     {type: "string", maxLength: 24},
                breaking:        {type: "boolean"},
                breaking_change: {type: "string"},
                subject:         {type: "string", maxLength: 60},
                body:            {type: "array", items: {type: "string"}, maxItems: 6},
                release:         {type: "string", enum: ["major", "minor", "patch", "none"]}
            },
            required: ["type", "scope", "breaking", "subject"]
        };
        if $mode == 1 then {
            type: "object",
            additionalProperties: false,
            properties: {
                commits: {type: "array", items: commit_obj, minItems: $n, maxItems: $n}
            },
            required: ["commits"]
        } else commit_obj end' > "$out_file"
}

# Keep the request inside num_ctx: if the estimated prompt size blows the
# budget, rebuild CHANGES_CONTEXT with progressively smaller per-file caps
# (tier3 80→40→20→stat-only) instead of letting Ollama silently drop the head
# of the prompt — which is where the rules live.
# Args: $1=ctx_dir
_enforce_token_budget() {
    local d="$1"
    [ -f "${d}/CHANGES_CONTEXT" ] || return 0
    local budget est
    budget=$(( ${AI_NUM_CTX:-16384} - ${AI_NUM_PREDICT:-400} - 512 ))
    est=$(( ( $(wc -c < "$AI_PROMPT_FILE" 2>/dev/null | tr -d ' ') + $(wc -c < "${d}/CHANGES_CONTEXT" | tr -d ' ') ) * 10 / 35 ))
    [ "$est" -le "$budget" ] && return 0

    local t2 t3
    for caps in "10 40" "5 20" "0 0"; do
        t2="${caps%% *}"; t3="${caps##* }"
        build_ai_context \
            "$(cat "${d}/STAGED_DIFF" 2>/dev/null)" \
            "$(cat "${d}/STAGED_NAMES" 2>/dev/null)" \
            "$(cat "${d}/NUMSTAT" 2>/dev/null)" \
            "$(cat "${d}/LOGICAL_SCOPE" 2>/dev/null)" \
            "$d" "$t2" "$t3" || return 0
        est=$(( ( $(wc -c < "$AI_PROMPT_FILE" 2>/dev/null | tr -d ' ') + $(wc -c < "${d}/CHANGES_CONTEXT" | tr -d ' ') ) * 10 / 35 ))
        [ "$est" -le "$budget" ] && return 0
    done
    return 0
}

# Assemble a conventional commit message (header + bullet body) from a
# schema-shaped JSON object. The 72-char rule is enforced downstream by
# validate_commit_grounding; we deliberately assemble in shell so the format
# is guaranteed.
# Args: $1=json object, $2=ctx_dir (optional)
_commit_msg_from_json_obj() {
    local obj="$1" ctx_dir="${2:-}"
    if ! printf '%s' "$obj" | jq -e 'type == "object"' >/dev/null 2>&1; then
        extract_conventional_commit "$obj"
        return
    fi

    local d_hint="$ctx_dir"
    [ -z "$d_hint" ] && command -v get_aicommit_tmp_dir >/dev/null 2>&1 && d_hint=$(get_aicommit_tmp_dir 2>/dev/null)

    # Extract and write RELEASE_HINT (Phase 1)
    local rel
    rel=$(printf '%s' "$obj" | jq -r '.release // empty' 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z')
    case "$rel" in
        major|minor|patch|none) ;;
        *) rel="none" ;;
    esac
    if [ -n "$d_hint" ] && [ -d "$d_hint" ]; then
        printf '%s\n' "$rel" > "${d_hint}/RELEASE_HINT"
    fi

    local type scope scope_other breaking breaking_change subject body
    type=$(printf '%s' "$obj" | jq -r '.type // empty' 2>/dev/null)
    subject=$(printf '%s' "$obj" | jq -r '.subject // empty' 2>/dev/null)
    [ -n "$type" ] && [ -n "$subject" ] || return 1

    # Deterministic repair: Single-type coercion if type not in ALLOWED_TYPES and exactly 1 type allowed (Phase 4)
    if [ -n "$d_hint" ] && [ -f "${d_hint}/ALLOWED_TYPES" ]; then
        local allowed_count
        allowed_count=$(awk 'NF' "${d_hint}/ALLOWED_TYPES" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$allowed_count" -eq 1 ]; then
            local single_type
            single_type=$(awk 'NF' "${d_hint}/ALLOWED_TYPES" 2>/dev/null | head -1)
            if [ -n "$single_type" ] && [ "$type" != "$single_type" ]; then
                type="$single_type"
            fi
        fi
    fi

    scope=$(printf '%s' "$obj" | jq -r '.scope // "none"' 2>/dev/null)
    breaking=$(printf '%s' "$obj" | jq -r '.breaking // false' 2>/dev/null)
    breaking_change=$(printf '%s' "$obj" | jq -r '.breaking_change // empty' 2>/dev/null)
    if [ "$scope" = "other" ]; then
        scope_other=$(printf '%s' "$obj" | jq -r '.scope_other // ""' 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9._/-' | sed -E 's/-[0-9]+$//' | cut -c1-24)
        scope="$scope_other"
    fi
    case "$scope" in
        ""|none|null|other) scope="" ;;
        *)
            scope=$(printf '%s' "$scope" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9._/-' | sed -E 's/-[0-9]+$//' | cut -c1-24)
            # Scope cleanup: reduce path/file scope to stem (e.g. lib/core.sh -> core, aicommit.sh -> aicommit)
            scope="${scope##*/}"
            scope="${scope%.*}"
            # Scope cleanup: drop scope if it equals type (e.g. docs(docs) -> docs)
            if [ "$scope" = "$type" ] || [ -z "$scope" ]; then
                scope=""
            else
                scope="($scope)"
            fi
            ;;
    esac

    # A conventional prefix embedded in the subject is stripped — the schema
    # tells the model to return only the description, but don't trust it.
    subject=$(printf '%s' "$subject" | sed -E 's/^[a-zA-Z]+(\([^)]*\))?!?:[[:space:]]*//' \
        | tr -s '[:space:]' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/\.$//')
    [ -z "$subject" ] && return 1

    local bang=""
    [ "$breaking" = "true" ] && bang="!"
    local msg
    msg="${type}${scope}${bang}: ${subject}"

    body=$(printf '%s' "$obj" | jq -r '(.body // [])[] | select(type == "string" and length > 0)' 2>/dev/null)
    if [ -n "$body" ]; then
        local clean_body="" line clean_line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Strip leading conventional commit prefix from body bullets (e.g. "- refactor(x): ..." -> "- ...")
            if printf '%s' "$line" | grep -qE '^[[:space:]]*[-*][[:space:]]+(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?:[[:space:]]*'; then
                clean_line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*][[:space:]]+(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?:[[:space:]]*//')
            else
                clean_line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*][[:space:]]*//')
            fi
            if [ -z "$clean_body" ]; then
                clean_body="- ${clean_line}"
            else
                clean_body="${clean_body}"$'\n'"- ${clean_line}"
            fi
        done <<< "$body"
        [ -n "$clean_body" ] && msg="${msg}"$'\n\n'"${clean_body}"
    fi

    if [ "$breaking" = "true" ]; then
        local bc_desc="${breaking_change:-$subject}"
        msg="${msg}"$'\n\n'"BREAKING CHANGE: ${bc_desc}"
    fi

    printf '%s\n' "$msg" | enforce_conventional_commit
}

# Parse a raw model response into a commit message: schema JSON first, the
# legacy free-text extractor as fallback.
# Args: $1=response_file, $2=ctx_dir
_assemble_commit_message() {
    local response_file="$1" d="$2"
    local raw obj=""
    raw=$(cat "$response_file" 2>/dev/null)

    local cleaned
    if command -v extract_json_object >/dev/null 2>&1; then
        cleaned=$(extract_json_object "$raw" 2>/dev/null)
    else
        cleaned="$raw"
    fi

    if printf '%s' "$cleaned" | jq -e 'type == "object" and has("type") and has("subject")' >/dev/null 2>&1; then
        obj="$cleaned"
    elif command -v perl >/dev/null 2>&1; then
        # Model wrapped the JSON in prose/fences — lift the outermost {…} span
        local extracted
        extracted=$(printf '%s' "$raw" | perl -0777 -ne 'print $1 if /(\{.*\})/s' | head -c 8192)
        if printf '%s' "$extracted" | jq -e 'type == "object" and has("type") and has("subject")' >/dev/null 2>&1; then
            obj="$extracted"
        fi
    fi

    if [ -n "$obj" ]; then
        _commit_msg_from_json_obj "$obj" "$d"
        return
    fi
    extract_conventional_commit "$raw"
}

# One LLM round-trip: invoke, then assemble the response into a commit message.
# Args: $1=request_file, $2=ctx_dir, $3=action_label (optional)
_llm_commit_once() {
    local request_file="$1" d="$2" action_label="${3:-Generating commit message}"
    local resp="${d}/RESPONSE" err="${d}/OLLAMA_ERROR"
    : > "$resp"; : > "$err"
    if ! invoke_llm "${AI_MODEL:-$DEFAULT_AI_MODEL}" "$request_file" "$resp" "$err" "${AI_TIMEOUT:-120}" "$action_label"; then
        return 1
    fi
    _assemble_commit_message "$resp" "$d"
}

# Post-validation gate — checks the assembled message is grounded in the diff.
# Emits one feedback line per violation (consumed by the retry prompt).
# Args: $1=commit_msg, $2=ctx_dir
validate_commit_grounding() {
    local msg="$1" d="${2:-}"
    [ -z "$d" ] && d=$(get_aicommit_tmp_dir)
    local ok=true header type tok

    header=$(printf '%s\n' "$msg" | head -1)
    if [ -z "$header" ]; then
        echo "empty commit header"
        return 1
    fi
    if [ "${#header}" -gt 72 ]; then
        printf 'header exceeds 72 chars (%d)\n' "${#header}"
        ok=false
    fi

    local subj
    subj=$(printf '%s' "$header" | sed -nE 's/^[a-zA-Z]+(\([^)]*\))?!?:[[:space:]]*(.*)/\2/p')
    if [ "${#subj}" -gt 60 ]; then
        printf 'subject exceeds 60 chars (%d)\n' "${#subj}"
        ok=false
    fi

    local line_count
    line_count=$(printf '%s\n' "$msg" | wc -l | tr -d ' ')
    if [ "$line_count" -gt 1 ]; then
        local line2
        line2=$(printf '%s\n' "$msg" | sed -n '2p')
        if [ -n "$line2" ]; then
            echo "line 2 must be blank"
            ok=false
        fi
    fi

    type=$(printf '%s' "$header" | sed -nE 's/^([a-zA-Z]+)(\([^)]*\))?!?: .*/\1/p' | tr 'A-Z' 'a-z')
    if [ -z "$type" ]; then
        echo "header is not a conventional commit"
        ok=false
    elif [ -f "${d}/ALLOWED_TYPES" ] && ! grep -qxF "$type" "${d}/ALLOWED_TYPES" 2>/dev/null; then
        printf 'type %s is not allowed for these changes\n' "$type"
        ok=false
    fi

    # Every file path or identifier mentioned must exist in the staged set or
    # in the extracted facts or literally in CHANGES_CONTEXT.
    local candidates
    candidates=$(printf '%s\n' "$msg" | grep -oE '`[^`]+`|[A-Za-z0-9_.~+-]+/[A-Za-z0-9_./~+-]+|[A-Za-z0-9_+-]+\.[A-Za-z0-9]{1,8}\b' \
        | tr -d '`' | sort -u)
    while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        printf '%s' "$tok" | grep -qE '^[0-9]+([.][0-9]+)*$' && continue
        if [ -f "${d}/STAGED_NAMES" ]; then
            grep -qxF "$tok" "${d}/STAGED_NAMES" 2>/dev/null && continue
            grep -qF "/${tok}" "${d}/STAGED_NAMES" 2>/dev/null && continue
        fi
        [ -f "${d}/FACTS" ] && grep -qF "$tok" "${d}/FACTS" 2>/dev/null && continue
        [ -f "${d}/CHANGES_CONTEXT" ] && grep -qF "$tok" "${d}/CHANGES_CONTEXT" 2>/dev/null && continue
        printf '%s is not in the diff\n' "$tok"
        ok=false
    done <<< "$candidates"

    $ok
}

# Last-resort commit message built purely from extracted facts — used when the
# model fails the grounding gate twice.
# Args: $1=ctx_dir
template_commit_from_facts() {
    local d="$1" type scope first_file count subject
    if [ -f "${d}/ALLOWED_TYPES" ]; then
        local first_allowed
        first_allowed=$(awk 'NF' "${d}/ALLOWED_TYPES" 2>/dev/null | head -1)
        [ -n "$first_allowed" ] && type="$first_allowed"
    fi
    type="${type:-chore}"

    first_file=$(head -1 "${d}/STAGED_NAMES" 2>/dev/null)
    count=$(count_lines < "${d}/STAGED_NAMES" 2>/dev/null || echo 1)
    scope=$(infer_file_scope "$first_file" 2>/dev/null || echo "")
    case "$scope" in ""|none|other) scope="" ;; esac
    scope="${scope##*/}"
    scope="${scope%.*}"
    [ "$scope" = "$type" ] && scope=""

    subject="update ${first_file:-files}"
    if [ "$count" -gt 1 ]; then
        subject="update ${first_file:-files} and $((count - 1)) other files"
    fi
    subject=$(printf '%s' "$subject" | sed -E 's/\.$//')

    local header="${type}${scope:+(${scope})}: ${subject}"
    # Keep the fallback itself inside the 72-char contract
    if [ "${#header}" -gt 72 ]; then
        header="${type}: update ${first_file:-files}"
        [ "${#header}" -gt 72 ] && header="${type}: update staged changes"
    fi
    printf '%s\n' "$header"
}

# Reflection step — critique a candidate commit message against the staged diff
# and facts block, removing hallucinations and enforcing Conventional Commits.
# Args: $1=candidate_msg, $2=ctx_dir (optional), $3=feedback (optional)
reflect_commit_message() {
    local candidate_msg="$1" ctx_dir="${2:-}" feedback="${3:-}"
    [ "${AI_ENABLE_REFLECTION:-true}" != "true" ] && return 1

    if [ -z "$ctx_dir" ]; then
        ctx_dir=$(get_aicommit_tmp_dir) || return 1
    fi
    local changes_file="${ctx_dir}/CHANGES_CONTEXT"
    if [ ! -f "$changes_file" ] || [ ! -s "$changes_file" ]; then
        return 1
    fi

    local prompt_file="${AI_REFLECTION_PROMPT_FILE:-$AICOMMIT_DIR/templates/reflection-prompt.txt}"
    if [ ! -f "$prompt_file" ]; then
        display_error "Reflection prompt template not found: $prompt_file"
        return 1
    fi

    local model="${AI_MODEL:-$DEFAULT_AI_MODEL}"
    local schema_file="${ctx_dir}/SCHEMA.json"
    [ -f "$schema_file" ] || _build_commit_schema "$schema_file" "$ctx_dir"

    local reflect_tail_file="${ctx_dir}/REFLECTION_TAIL"
    {
        printf '=== REFLECTION TASK ===\n'
        printf 'Reflect on the draft commit message below against the actual changes and facts above.\n'
        printf 'Critique it, remove any hallucinations or ungrounded tokens, and return a corrected JSON object.\n\n'
        printf '=== DRAFT COMMIT MESSAGE CANDIDATE ===\n%s\n\n' "$candidate_msg"
        printf '=== DETECTED VIOLATIONS / CORRECTIONS REQUIRED ===\n'
        if [ -n "$feedback" ]; then
            printf '%s\n\n' "$feedback"
        else
            printf 'Ensure candidate strictly conforms to Conventional Commits and contains only grounded facts.\n\n'
        fi
        if [ -f "$prompt_file" ]; then
            printf '=== REFLECTION CHECKLIST & RULES ===\n'
            cat "$prompt_file"
            printf '\n'
        fi
    } > "$reflect_tail_file"

    local reflect_req="${ctx_dir}/REQUEST.reflect.json"
    if ! build_followup_request "$reflect_req" "$ctx_dir" "$reflect_tail_file" "$schema_file"; then
        return 1
    fi

    local refined_msg
    if ! refined_msg=$(_llm_commit_once "$reflect_req" "$ctx_dir" "Reflecting on commit message"); then
        return 1
    fi
    echo "$refined_msg"
}

# Strict conventional commit format gate.
# Args: $1=commit_msg, $2=ctx_dir (optional)
is_strict_conventional_commit() {
    local msg="$1" d="${2:-}"
    [ -z "$msg" ] && return 1
    [ -z "$d" ] && command -v get_aicommit_tmp_dir >/dev/null 2>&1 && d=$(get_aicommit_tmp_dir 2>/dev/null)

    local header
    header=$(printf '%s\n' "$msg" | head -1)
    [ -n "$header" ] || return 1
    [ "${#header}" -le 72 ] || return 1

    # Header regex: type(scope)!?: subject (starts with non-space, ends with non-dot, non-empty)
    if ! printf '%s\n' "$header" | grep -qE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: \S.*[^.]$'; then
        return 1
    fi

    # Line 2 must be blank if there are multiple lines
    local line_count
    line_count=$(printf '%s\n' "$msg" | wc -l | tr -d ' ')
    if [ "$line_count" -gt 1 ]; then
        local line2
        line2=$(printf '%s\n' "$msg" | sed -n '2p')
        [ -z "$line2" ] || return 1
    fi

    # Breaking change consistency: ! in header iff BREAKING CHANGE: in body/footer
    local has_bang=false has_breaking_footer=false
    if printf '%s\n' "$header" | grep -qE '^[^:]*!: '; then
        has_bang=true
    fi
    if printf '%s\n' "$msg" | grep -qE '^BREAKING CHANGE:[[:space:]]*\S'; then
        has_breaking_footer=true
    fi
    if [ "$has_bang" = "true" ] && [ "$has_breaking_footer" != "true" ]; then
        return 1
    fi
    if [ "$has_bang" != "true" ] && [ "$has_breaking_footer" = "true" ]; then
        return 1
    fi

    # Type must be in ALLOWED_TYPES if ALLOWED_TYPES file exists
    if [ -n "$d" ] && [ -f "${d}/ALLOWED_TYPES" ]; then
        local type
        type=$(printf '%s\n' "$header" | sed -nE 's/^([a-z]+)(\([^)]*\))?!?: .*/\1/p')
        grep -qxF "$type" "${d}/ALLOWED_TYPES" 2>/dev/null || return 1
    fi

    return 0
}

# Salvage commit message: keep model's header and grounded body bullets.
# Args: $1=msg, $2=ctx_dir
salvage_commit_message() {
    local msg="$1" d="${2:-}"
    [ -z "$d" ] && command -v get_aicommit_tmp_dir >/dev/null 2>&1 && d=$(get_aicommit_tmp_dir 2>/dev/null)
    local header
    header=$(printf '%s\n' "$msg" | head -1)
    [ -n "$header" ] || return 1

    # Header itself must pass grounding
    validate_commit_grounding "$header" "$d" >/dev/null 2>&1 || return 1

    local has_breaking=false bc_line=""
    if printf '%s\n' "$header" | grep -qE '^[^:]*!: '; then
        has_breaking=true
        bc_line=$(printf '%s\n' "$msg" | grep -E '^BREAKING CHANGE:' | head -1)
        [ -z "$bc_line" ] && bc_line="BREAKING CHANGE: compatibility break"
    fi

    local in_body=false line candidate_bullet clean_bullets=()
    while IFS= read -r line; do
        if [ "$in_body" = "false" ]; then
            [ -z "$line" ] && in_body=true
            continue
        fi
        [ -z "$line" ] && continue
        printf '%s\n' "$line" | grep -qE '^BREAKING CHANGE:' && continue
        if validate_commit_grounding "${header}"$'\n\n'"${line}" "$d" >/dev/null 2>&1; then
            clean_bullets+=("$line")
        fi
    done <<< "$msg"

    local result="$header"
    if [ ${#clean_bullets[@]} -gt 0 ]; then
        local bullets_joined
        bullets_joined=$(printf '%s\n' "${clean_bullets[@]}")
        result="${result}"$'\n\n'"${bullets_joined}"
    fi
    if [ "$has_breaking" = "true" ] && [ -n "$bc_line" ]; then
        result="${result}"$'\n\n'"${bc_line}"
    fi

    printf '%s\n' "$result" | enforce_conventional_commit
}

# Shared candidate finalizer across single, regenerate, and batched flows.
# Integrates deterministic repair, grounding validation, reflection repairs,
# salvage, and strict format gating.
# Args: $1=candidate_raw_or_obj, $2=ctx_dir
_finalize_candidate() {
    local raw_input="$1" ctx_dir="${2:-}"
    [ -z "$ctx_dir" ] && command -v get_aicommit_tmp_dir >/dev/null 2>&1 && ctx_dir=$(get_aicommit_tmp_dir 2>/dev/null)

    local candidate_msg=""
    if printf '%s' "$raw_input" | jq -e 'type == "object" and has("type") and has("subject")' >/dev/null 2>&1; then
        candidate_msg=$(_commit_msg_from_json_obj "$raw_input" "$ctx_dir") || candidate_msg=""
    elif command -v extract_json_object >/dev/null 2>&1 \
        && cleaned=$(extract_json_object "$raw_input" 2>/dev/null) \
        && printf '%s' "$cleaned" | jq -e 'type == "object" and has("type") and has("subject")' >/dev/null 2>&1; then
        candidate_msg=$(_commit_msg_from_json_obj "$cleaned" "$ctx_dir") || candidate_msg=""
    else
        candidate_msg=$(extract_conventional_commit "$raw_input")
    fi

    [ -z "$candidate_msg" ] && candidate_msg=$(template_commit_from_facts "$ctx_dir")

    # Unconditional reflection if AI_REFLECTION_MODE is 'always'
    if [ "${AI_ENABLE_REFLECTION:-true}" = "true" ] && [ "${AI_REFLECTION_MODE:-on-failure}" = "always" ]; then
        local feedback_always="" reflected_always=""
        feedback_always=$(validate_commit_grounding "$candidate_msg" "$ctx_dir" 2>&1 || true)
        if reflected_always=$(reflect_commit_message "$candidate_msg" "$ctx_dir" "$feedback_always") && [ -n "$reflected_always" ]; then
            candidate_msg="$reflected_always"
        fi
    fi

    # Grounding gate: verify, reflect up to AI_MAX_REPAIRS (default 1), else salvage or fallback
    local feedback=""
    if ! feedback=$(validate_commit_grounding "$candidate_msg" "$ctx_dir"); then
        local max_rep="${AI_MAX_REPAIRS:-1}" rep_count=0 rep_msg=""
        while [ "$rep_count" -lt "$max_rep" ]; do
            rep_count=$((rep_count + 1))
            [ -n "$ctx_dir" ] && printf '%s\n' "$rep_count" > "${ctx_dir}/REPAIR_COUNT"
            if [ "${AI_ENABLE_REFLECTION:-true}" = "true" ]; then
                if rep_msg=$(reflect_commit_message "$candidate_msg" "$ctx_dir" "$feedback") && [ -n "$rep_msg" ]; then
                    candidate_msg="$rep_msg"
                    if feedback=$(validate_commit_grounding "$candidate_msg" "$ctx_dir"); then
                        break
                    fi
                fi
            fi
        done

        # If still failing grounding: salvage before template
        if ! validate_commit_grounding "$candidate_msg" "$ctx_dir" >/dev/null 2>&1; then
            local salvaged=""
            if salvaged=$(salvage_commit_message "$candidate_msg" "$ctx_dir") \
                && [ -n "$salvaged" ] \
                && validate_commit_grounding "$salvaged" "$ctx_dir" >/dev/null 2>&1; then
                candidate_msg="$salvaged"
            else
                [ -n "$ctx_dir" ] && touch "${ctx_dir}/TEMPLATE_FALLBACK"
                candidate_msg=$(template_commit_from_facts "$ctx_dir")
            fi
        fi
    fi

    candidate_msg=$(printf '%s\n' "$candidate_msg" | enforce_conventional_commit)

    # Strict final gate
    if ! is_strict_conventional_commit "$candidate_msg" "$ctx_dir"; then
        [ -n "$ctx_dir" ] && touch "${ctx_dir}/TEMPLATE_FALLBACK"
        candidate_msg=$(template_commit_from_facts "$ctx_dir")
        candidate_msg=$(printf '%s\n' "$candidate_msg" | enforce_conventional_commit)
    fi

    printf '%s\n' "$candidate_msg"
}

# Compute content-addressed cache key for staged changes and configuration.
# Args: $1=raw_diff_or_files (optional, for per-group caching)
get_aicommit_cache_key() {
    local raw_input="${1:-}"
    local staged_raw=""
    if [ -n "$raw_input" ] && [ -f "$raw_input" ]; then
        staged_raw=$(cat "$raw_input" 2>/dev/null)
    elif [ -n "$raw_input" ]; then
        staged_raw="$raw_input"
    else
        staged_raw=$(agit diff --staged --raw -z --full-index 2>/dev/null || git diff --staged --raw -z --full-index 2>/dev/null || true)
    fi

    local prompt_hash="" reflect_hash=""
    prompt_hash=$(shasum -a 256 "$AI_PROMPT_FILE" 2>/dev/null | awk '{print $1}')
    local ref_f="${AI_REFLECTION_PROMPT_FILE:-$AICOMMIT_DIR/templates/reflection-prompt.txt}"
    reflect_hash=$(shasum -a 256 "$ref_f" 2>/dev/null | awk '{print $1}')

    local state_dir seed_offset="0"
    state_dir=$(get_aicommit_state_dir 2>/dev/null || echo "")
    if [ -n "$state_dir" ] && [ -f "${state_dir}/SEED_OFFSET" ]; then
        seed_offset=$(cat "${state_dir}/SEED_OFFSET" 2>/dev/null || echo "0")
    fi
    local seed="${AI_SEED:-0}:${seed_offset}"

    {
        printf '%s\n' "$staged_raw"
        printf 'model:%s\n' "${AI_MODEL:-$DEFAULT_AI_MODEL}"
        printf 'prompt:%s\n' "$prompt_hash"
        printf 'reflect:%s\n' "$reflect_hash"
        printf 'num_ctx:%s\n' "${AI_NUM_CTX:-16384}"
        printf 'num_predict:%s\n' "${AI_NUM_PREDICT:-400}"
        printf 'tier2:%s\n' "${AI_MAX_LINES_TIER2:-}"
        printf 'tier3:%s\n' "${AI_MAX_LINES_TIER3:-}"
        printf 'reflection_mode:%s\n' "${AI_REFLECTION_MODE:-on-failure}"
        printf 'seed:%s\n' "$seed"
        printf 'keep_alive:%s\n' "${AI_KEEP_ALIVE:--1}"
    } | shasum -a 256 | awk '{print $1}'
}

# Generate commit message — assembles the request and calls Ollama.
# Args: --dry-run (optional), ctx_dir (optional, default run dir)
generate_commit_message() {
    local dry_run=false ctx_dir=""
    case "${1:-}" in
        --dry-run) dry_run=true; ctx_dir="${2:-}" ;;
        *)         ctx_dir="${1:-}" ;;
    esac

    local model="${AI_MODEL:-$DEFAULT_AI_MODEL}"
    local tmp_dir state_dir
    tmp_dir=$(get_aicommit_tmp_dir) || return 1
    state_dir=$(get_aicommit_state_dir) || return 1
    [ -z "$ctx_dir" ] && ctx_dir="$tmp_dir"

    # Restrict permissions for sensitive content
    umask 077

    local changes_file="${ctx_dir}/CHANGES_CONTEXT"
    if [ ! -f "$changes_file" ] || [ ! -s "$changes_file" ]; then
        display_error "Context files not found or empty in $ctx_dir"
        return 1
    fi

    # Shrink the context to fit the token budget before anything else
    _enforce_token_budget "$ctx_dir"

    # Schema-constrained request: system = static rules, user = dynamic context
    local schema_file="${ctx_dir}/SCHEMA.json" request_file="${ctx_dir}/REQUEST.json"
    _build_commit_schema "$schema_file" "$ctx_dir"
    if ! build_ollama_request "$request_file" "$model" "$changes_file" "${AI_PROMPT_FILE}" "$schema_file"; then
        return 1
    fi

    # Audit artifact: what the model effectively sees (also powers --dry-run)
    {
        cat "${AI_PROMPT_FILE}"
        printf '\n\n=== USER CONTEXT ===\n'
        cat "$changes_file"
    } > "${state_dir}/FULL_PROMPT"

    local reflect_prompt_file="${AI_REFLECTION_PROMPT_FILE:-$AICOMMIT_DIR/templates/reflection-prompt.txt}"
    if [ -f "$reflect_prompt_file" ]; then
        {
            cat "$reflect_prompt_file"
            printf '\n\n=== DRAFT COMMIT MESSAGE CANDIDATE ===\n<candidate_message>\n\n'
            printf '=== DETECTED VIOLATIONS / CORRECTIONS REQUIRED ===\n<feedback>\n\n'
            printf '=== ACTUAL CHANGES & FACTS (AUTHORITATIVE GROUND TRUTH) ===\n'
            cat "$changes_file"
        } > "${state_dir}/REFLECTION_PROMPT"
    fi

    if [ "$dry_run" = "true" ]; then
        return 0
    fi

    # Content-addressed result cache (Lever C)
    local ckey="" cdir=""
    ckey=$(get_aicommit_cache_key 2>/dev/null || echo "")
    if [ -n "$ckey" ] && [ -n "$state_dir" ]; then
        cdir="${state_dir}/cache/${ckey}"
        if [ -s "${cdir}/MSG" ]; then
            local cached_msg
            cached_msg=$(cat "${cdir}/MSG" 2>/dev/null)
            if [ -n "$cached_msg" ] && is_strict_conventional_commit "$cached_msg" "$ctx_dir"; then
                if [ -s "${cdir}/RELEASE" ]; then
                    cp "${cdir}/RELEASE" "${ctx_dir}/RELEASE_HINT" 2>/dev/null || true
                fi
                echo "$cached_msg"
                return 0
            fi
        fi
    fi

    # Legacy response cache fallback
    local key
    key=$(shasum -a 256 < "$request_file" | awk '{print $1}')
    if [ -f "${state_dir}/MSG_KEY" ] && [ "$(cat "${state_dir}/MSG_KEY" 2>/dev/null)" = "$key" ] && [ -s "${state_dir}/MSG_CACHE" ]; then
        cat "${state_dir}/MSG_CACHE"
        return 0
    fi

    local resp="${ctx_dir}/RESPONSE" err="${ctx_dir}/OLLAMA_ERROR"
    : > "$resp"; : > "$err"
    if ! invoke_llm "${AI_MODEL:-$DEFAULT_AI_MODEL}" "$request_file" "$resp" "$err" "${AI_TIMEOUT:-120}" "Generating commit message"; then
        return 1
    fi

    local commit_msg raw_resp
    raw_resp=$(cat "$resp" 2>/dev/null || true)
    commit_msg=$(_finalize_candidate "$raw_resp" "$ctx_dir")

    # Persist content-addressed cache atomically
    if [ -n "$ckey" ] && [ -n "$state_dir" ]; then
        local cache_base="${state_dir}/cache"
        [ -d "$cache_base" ] || mkdir -m 700 -p "$cache_base" 2>/dev/null || true
        [ -d "$cdir" ] || mkdir -m 700 -p "$cdir" 2>/dev/null || true
        if [ -d "$cdir" ]; then
            printf '%s\n' "$commit_msg" > "${cdir}/MSG.tmp" && mv "${cdir}/MSG.tmp" "${cdir}/MSG"
            if [ -f "${ctx_dir}/RELEASE_HINT" ]; then
                cp "${ctx_dir}/RELEASE_HINT" "${cdir}/RELEASE.tmp" && mv "${cdir}/RELEASE.tmp" "${cdir}/RELEASE"
            fi
            if [ -f "${ctx_dir}/CHANGES_CONTEXT" ]; then
                cp "${ctx_dir}/CHANGES_CONTEXT" "${cdir}/CHANGES_CONTEXT.tmp" && mv "${cdir}/CHANGES_CONTEXT.tmp" "${cdir}/CHANGES_CONTEXT"
            fi
            if [ -f "${ctx_dir}/SEMVER" ]; then
                cp "${ctx_dir}/SEMVER" "${cdir}/SEMVER.tmp" && mv "${cdir}/SEMVER.tmp" "${cdir}/SEMVER"
            fi
        fi
    fi

    # Persist legacy cache + replayable request atomically (tmp + mv)
    printf '%s' "$key" > "${state_dir}/MSG_KEY.tmp" && mv "${state_dir}/MSG_KEY.tmp" "${state_dir}/MSG_KEY"
    printf '%s\n' "$commit_msg" > "${state_dir}/MSG_CACHE.tmp" && mv "${state_dir}/MSG_CACHE.tmp" "${state_dir}/MSG_CACHE"
    cp "$request_file" "${state_dir}/MSG_REQUEST.tmp" && mv "${state_dir}/MSG_REQUEST.tmp" "${state_dir}/MSG_REQUEST"

    echo "$commit_msg"
}

# --regenerate: replay the last request with a bumped seed so it produces a
# genuinely different candidate instead of a cache hit.
regenerate_commit_message() {
    local state_dir tmp_dir
    state_dir=$(get_aicommit_state_dir) || return 1
    tmp_dir=$(get_aicommit_tmp_dir) || return 1

    local req_src="${state_dir}/MSG_REQUEST"
    [ -f "$req_src" ] || return 1

    local off=0
    off=$(( $(cat "${state_dir}/SEED_OFFSET" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$off" > "${state_dir}/SEED_OFFSET.tmp" && mv "${state_dir}/SEED_OFFSET.tmp" "${state_dir}/SEED_OFFSET"

    local req="${tmp_dir}/REQUEST.regen.json"
    jq --argjson o "$off" '.options.seed = ((.options.seed // 0) + $o)' "$req_src" > "$req" || return 1

    local resp="${tmp_dir}/RESPONSE.regen" err="${tmp_dir}/OLLAMA_ERROR"
    : > "$resp"; : > "$err"
    if ! invoke_llm "${AI_MODEL:-$DEFAULT_AI_MODEL}" "$req" "$resp" "$err" "${AI_TIMEOUT:-120}" "Regenerating commit message"; then
        return 1
    fi

    local raw_resp commit_msg
    raw_resp=$(cat "$resp" 2>/dev/null || true)
    commit_msg=$(_finalize_candidate "$raw_resp" "$tmp_dir")

    # Update cache
    local key
    key=$(shasum -a 256 < "$req" | awk '{print $1}')
    printf '%s' "$key" > "${state_dir}/MSG_KEY.tmp" && mv "${state_dir}/MSG_KEY.tmp" "${state_dir}/MSG_KEY"
    printf '%s\n' "$commit_msg" > "${state_dir}/MSG_CACHE.tmp" && mv "${state_dir}/MSG_CACHE.tmp" "${state_dir}/MSG_CACHE"
    cp "$req" "${state_dir}/MSG_REQUEST.tmp" && mv "${state_dir}/MSG_REQUEST.tmp" "${state_dir}/MSG_REQUEST"

    local ckey cdir
    ckey=$(get_aicommit_cache_key 2>/dev/null || echo "")
    if [ -n "$ckey" ] && [ -n "$state_dir" ]; then
        cdir="${state_dir}/cache/${ckey}"
        [ -d "$cdir" ] || mkdir -m 700 -p "$cdir" 2>/dev/null || true
        if [ -d "$cdir" ]; then
            printf '%s\n' "$commit_msg" > "${cdir}/MSG.tmp" && mv "${cdir}/MSG.tmp" "${cdir}/MSG"
            if [ -f "${tmp_dir}/RELEASE_HINT" ]; then
                cp "${tmp_dir}/RELEASE_HINT" "${cdir}/RELEASE.tmp" && mv "${cdir}/RELEASE.tmp" "${cdir}/RELEASE"
            fi
        fi
    fi

    echo "$commit_msg"
}

# ─── Split-commit group generation ───────────────────────────────────────────

# Split the run's STAGED_DIFF + NUMSTAT into per-group files under groups/<i>/.
# Args: $1=diff_file, $2=numstat_file, $3=index_file (lines "i\tf1\tf2..."), $4=groups_dir
_split_diff_by_groups() {
    local diff_file="$1" numstat_file="$2" index_file="$3" groups_dir="$4"
    awk -v index_file="$index_file" -v outdir="$groups_dir" '
    BEGIN {
        while ((getline l < index_file) > 0) {
            n = split(l, p, "\t")
            for (j = 2; j <= n; j++) if (p[j] != "") g[p[j]] = p[1]
        }
        close(index_file)
        cur = ""
    }
    FNR == NR {
        # first input: the full staged diff
        if ($0 ~ /^diff --git /) {
            a_name = $0; sub(/^diff --git a\//, "", a_name); sub(/ b\/.*$/, "", a_name)
            b_name = $0; sub(/^.* b\//, "", b_name)
            cur = (b_name in g) ? g[b_name] : ((a_name in g) ? g[a_name] : "")
        }
        if (cur != "") print $0 >> (outdir "/" cur "/DIFF")
        next
    }
    {
        # second input: numstat — field 3 is the path (rename lines carry
        # "old => new" syntax that simply will not match; stats only)
        if ($3 in g) print $0 >> (outdir "/" g[$3] "/NUMSTAT")
    }
    ' "$diff_file" "$numstat_file"
}

# Materialize per-group run files and generate every group's commit message
# before any commit happens. Fills the 1-indexed array _AICOMMIT_GRP_MSGS.
# Args: $1=scope_groups (TAB lines), $2=tmp_dir (run dir)
generate_group_messages() {
    local scope_groups="$1" tmp_dir="$2"
    _AICOMMIT_GRP_MSGS=()

    local i=0 group_line gdir
    local groups_root="${tmp_dir}/groups"
    local index_file="${groups_root}/INDEX"
    mkdir -m 700 -p "$groups_root" || return 1
    : > "$index_file"

    # Per-group run dirs + the group index used to split the diff
    while IFS= read -r group_line; do
        _aicommit_split_tab_line "$group_line"
        [ -z "$_aicommit_split_scope" ] && continue
        [ ${#_aicommit_split_files[@]} -eq 0 ] && continue
        i=$((i + 1))
        gdir="${groups_root}/${i}"
        mkdir -m 700 -p "$gdir" || return 1
        {
            printf '%s' "$i"
            printf '\t%s' "${_aicommit_split_files[@]}"
            printf '\n'
        } >> "$index_file"
        printf '%s\n' "${_aicommit_split_files[@]}" > "${gdir}/STAGED_NAMES"
        printf '%s' "$_aicommit_split_scope" > "${gdir}/GROUP_SCOPE"
    done <<< "$scope_groups"

    local n=$i
    [ "$n" -eq 0 ] && return 1

    _split_diff_by_groups "${tmp_dir}/STAGED_DIFF" "${tmp_dir}/NUMSTAT" "$index_file" "$groups_root"

    # Per-group contexts (facts, allowed types, scope candidates land per group)
    for ((i = 1; i <= n; i++)); do
        gdir="${groups_root}/${i}"
        if [ ! -s "${gdir}/DIFF" ]; then
            display_error "No staged changes matched for group $i" "$(cat "${gdir}/STAGED_NAMES" 2>/dev/null)"
            return 1
        fi
        build_ai_context \
            "$(cat "${gdir}/DIFF")" \
            "$(cat "${gdir}/STAGED_NAMES")" \
            "$(cat "${gdir}/NUMSTAT" 2>/dev/null)" \
            "$(cat "${gdir}/GROUP_SCOPE")" \
            "$gdir" || return 1
    done

    # One batched call for all groups when enabled; the shared rules prefix is
    # then processed once instead of n times.
    if [ "$n" -gt 1 ] && [ "${AI_BATCH_MESSAGES:-true}" = "true" ] \
        && [ "${AI_DISABLE_GROUPING:-false}" != "true" ] \
        && validate_backend_prerequisites >/dev/null 2>&1 \
        && _generate_group_messages_batched "$n" "$tmp_dir"; then
        _fill_missing_group_messages "$n" "$tmp_dir" || return 1
        return 0
    fi

    # Sequential fallback — per-group generate (still deterministic per call)
    local m
    for ((i = 1; i <= n; i++)); do
        if ! m=$(generate_commit_message "${groups_root}/${i}"); then
            display_error "Failed to generate commit message for group $i"
            return 1
        fi
        _AICOMMIT_GRP_MSGS[$i]="$m"
    done
    return 0
}

_fill_missing_group_messages() {
    local n="$1" tmp_dir="$2" i m
    for ((i = 1; i <= n; i++)); do
        [ -n "${_AICOMMIT_GRP_MSGS[$i]:-}" ] && continue
        if ! m=$(generate_commit_message "${tmp_dir}/groups/${i}"); then
            display_error "Failed to generate commit message for group $i"
            return 1
        fi
        _AICOMMIT_GRP_MSGS[$i]="$m"
    done
    return 0
}

# Batched per-group generation: one request returns {"commits":[obj per group]}.
# Per-group grounding validation still applies; failures are left empty for
# the sequential filler.
_generate_group_messages_batched() {
    local n="$1" tmp_dir="$2" i
    local user_file="${tmp_dir}/BATCH_USER"
    local schema_file="${tmp_dir}/BATCH_SCHEMA.json" req="${tmp_dir}/BATCH_REQUEST.json"
    local resp="${tmp_dir}/BATCH_RESPONSE" err="${tmp_dir}/BATCH_ERROR"
    local model="${AI_MODEL:-$DEFAULT_AI_MODEL}"

    # Shrink each group's context to fit token budget before building batch
    for ((i = 1; i <= n; i++)); do
        _enforce_token_budget "${tmp_dir}/groups/${i}"
    done

    : > "$user_file"
    for ((i = 1; i <= n; i++)); do
        printf '=== GROUP %d ===\n' "$i" >> "$user_file"
        cat "${tmp_dir}/groups/${i}/CHANGES_CONTEXT" >> "$user_file"
        printf '\n' >> "$user_file"
    done
    printf '\nBATCH MODE: the message above contains %d groups marked "=== GROUP i ===". Return a JSON object {"commits": [...]} with exactly %d commit objects, in group order. Each object describes ONLY its own group.\n' "$n" "$n" >> "$user_file"

    # Union the per-group constraints into the shared batch schema
    {
        for ((i = 1; i <= n; i++)); do
            [ -f "${tmp_dir}/groups/${i}/ALLOWED_TYPES" ] && cat "${tmp_dir}/groups/${i}/ALLOWED_TYPES"
        done
    } | sort -u > "${tmp_dir}/ALLOWED_TYPES"
    {
        for ((i = 1; i <= n; i++)); do
            [ -f "${tmp_dir}/groups/${i}/SCOPE_CANDIDATES" ] && cat "${tmp_dir}/groups/${i}/SCOPE_CANDIDATES"
        done
    } | sort -u > "${tmp_dir}/SCOPE_CANDIDATES"
    _build_commit_schema "$schema_file" "$tmp_dir" "batch" "$n"

    # Keep AI_PROMPT_FILE byte-identical as system prompt to maximize KV cache reuse
    if ! build_ollama_request "$req" "$model" "$user_file" "${AI_PROMPT_FILE}" "$schema_file"; then
        return 1
    fi

    : > "$resp"; : > "$err"
    if ! invoke_llm "$model" "$req" "$resp" "$err" "$(( ${AI_TIMEOUT:-120} * 2 ))" "Generating ${n} commit messages"; then
        return 1
    fi

    local content cnt
    content=$(cat "$resp" 2>/dev/null)
    if command -v extract_json_object >/dev/null 2>&1; then
        content=$(extract_json_object "$content" 2>/dev/null)
    fi
    cnt=$(printf '%s' "$content" | jq '.commits | length' 2>/dev/null) || return 1
    [ "$cnt" = "$n" ] || return 1

    local obj m
    for ((i = 1; i <= n; i++)); do
        obj=$(printf '%s' "$content" | jq -c ".commits[$((i - 1))]" 2>/dev/null)
        [ -z "$obj" ] && continue
        m=$(_finalize_candidate "$obj" "${tmp_dir}/groups/${i}")
        if [ -n "$m" ]; then
            _AICOMMIT_GRP_MSGS[$i]="$m"
        fi
    done
    return 0
}

# Execute the git commit (serialized via the repo lock)
# Args: $1=commit_msg
process_commit() {
    local commit_msg="$1"
    aicommit_acquire_lock || return 1
    printf '%s\n' "$commit_msg" | git commit -F -
    local rc=$?
    aicommit_release_lock
    return $rc
}

# Execute an atomic git commit for a specific subset of staged files
# using git plumbing so unstaged modifications and other staged files are preserved.
# Args: $1=commit_msg, $2..=files_to_commit (repo-root-relative paths, one per arg)
commit_staged_subset() {
    local commit_msg="$1"
    shift
    local commit_files=("$@")

    if [ ${#commit_files[@]} -eq 0 ]; then
        display_error "commit_staged_subset called with no files" "This is a bug — refusing to create an empty commit"
        return 1
    fi

    aicommit_acquire_lock || return 1

    local git_dir
    git_dir=$(git rev-parse --git-dir)
    local tmp_index="${git_dir}/index.aicommit.$$"
    cp "${git_dir}/index" "$tmp_index"

    local has_head=false
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        has_head=true
    fi

    # Find all staged files in real index (root-relative, raw UTF-8 — never quoted)
    local staged_files f="" cf="" is_target=false
    staged_files=$(agit diff --staged -z --name-only | tr '\0' '\n')

    # For files staged in real index that are NOT in commit_files:
    # revert them in tmp_index to match HEAD (or remove if new file).
    # Every step here must succeed — a step that silently no-ops leaves a
    # foreign file in tmp_index, and the commit below would then include
    # changes outside its declared scope with no error raised (see RC5).
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        is_target=false
        for cf in "${commit_files[@]}"; do
            if [ "$f" = "$cf" ]; then
                is_target=true
                break
            fi
        done
        if [ "$is_target" = false ]; then
            if [ "$has_head" = true ] && agit ls-tree HEAD -- "$(to_pathspec "$f")" 2>/dev/null | grep -q .; then
                if ! GIT_INDEX_FILE="$tmp_index" agit restore --staged --source=HEAD -- "$(to_pathspec "$f")" >/dev/null 2>&1; then
                    rm -f "$tmp_index"
                    aicommit_release_lock
                    display_error "Failed to exclude '$f' from subset commit" "git restore --staged failed"
                    return 1
                fi
            else
                if ! GIT_INDEX_FILE="$tmp_index" agit rm --cached -q -- "$(to_pathspec "$f")" >/dev/null 2>&1; then
                    rm -f "$tmp_index"
                    aicommit_release_lock
                    display_error "Failed to exclude '$f' from subset commit" "git rm --cached failed"
                    return 1
                fi
            fi
        fi
    done <<< "$staged_files"

    local tree_sha
    tree_sha=$(GIT_INDEX_FILE="$tmp_index" git write-tree 2>/dev/null)
    rm -f "$tmp_index"

    if [ -z "$tree_sha" ]; then
        aicommit_release_lock
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
        aicommit_release_lock
        display_error "Failed to create git commit tree"
        return 1
    fi

    local current_ref
    current_ref=$(git symbolic-ref HEAD 2>/dev/null || git rev-parse HEAD)
    if ! git update-ref "$current_ref" "$commit_sha"; then
        aicommit_release_lock
        display_error "Failed to update $current_ref to $commit_sha" "The commit object was created but the branch was not advanced"
        return 1
    fi

    # Invoke post-commit hook if present
    if [ -x "${git_dir}/hooks/post-commit" ]; then
        "${git_dir}/hooks/post-commit" 2>/dev/null || true
    fi

    aicommit_release_lock
    return 0
}

# Cleanup ephemeral context files — the entire per-run dir goes away.
# SCOPE_GROUPS/STAGED_FINGERPRINT/FULL_PROMPT/MSG_* deliberately live in the
# shared state dir so a dry-run preview survives until `aicc` reuses it.
cleanup_aicommit_ephemeral() {
    aicommit_cleanup_run_dir
}

# Cleanup everything including the audit prompt and the persisted scope-grouping
# decision. The message cache (MSG_*) self-invalidates by key and stays.
cleanup_aicommit_all() {
    aicommit_cleanup_run_dir
    local state_dir
    state_dir=$(get_aicommit_state_dir 2>/dev/null) || state_dir=""
    [ -n "$state_dir" ] || return 0
    rm -f "${state_dir}/FULL_PROMPT" \
          "${state_dir}/SCOPE_GROUPS" \
          "${state_dir}/STAGED_FINGERPRINT" > /dev/null 2>&1
}
