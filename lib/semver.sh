#!/usr/bin/env bash
# aicommit — Semantic Versioning (SemVer) Engine
# Evaluates semver bumps, updates multi-language project manifest files, and creates Git tags.

# Resolve the current version from project files or git tags
# Echoes clean semver string (e.g. "1.2.3" or "0.1.0") without leading 'v'
get_current_version() {
    local ver=""

    # 1. Node.js: package.json
    if [ -f "package.json" ]; then
        ver=$(grep -m1 '"version"' package.json 2>/dev/null | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
    fi

    # 2. Rust: Cargo.toml
    if [ -z "$ver" ] && [ -f "Cargo.toml" ]; then
        ver=$(awk '/^\[package\]/{flag=1;next}/^\[/{flag=0}flag && /^version/{print}' Cargo.toml 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true)
    fi

    # 3. Python: pyproject.toml
    if [ -z "$ver" ] && [ -f "pyproject.toml" ]; then
        ver=$(grep -E '^[[:space:]]*version[[:space:]]*=' pyproject.toml 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
    fi

    # 4. Dart / Flutter: pubspec.yaml
    if [ -z "$ver" ] && [ -f "pubspec.yaml" ]; then
        ver=$(grep -E '^[[:space:]]*version:' pubspec.yaml 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*version:[[:space:]]*([^[:space:]]+).*/\1/' || true)
    fi

    # 5. Ruby: *.gemspec or lib/**/version.rb
    if [ -z "$ver" ]; then
        local gemspec
        gemspec=$(find . -maxdepth 2 -name "*.gemspec" ! -path '*/.*' 2>/dev/null | head -n1 || true)
        if [ -n "$gemspec" ] && [ -f "$gemspec" ]; then
            ver=$(grep -E '\.version[[:space:]]*=' "$gemspec" 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
        fi
        if [ -z "$ver" ]; then
            local vrb
            vrb=$(find lib -name "version.rb" ! -path '*/.*' 2>/dev/null | head -n1 || true)
            if [ -n "$vrb" ] && [ -f "$vrb" ]; then
                ver=$(grep -E 'VERSION[[:space:]]*=' "$vrb" 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
            fi
        fi
    fi

    # 6. PHP: composer.json
    if [ -z "$ver" ] && [ -f "composer.json" ]; then
        ver=$(grep -m1 '"version"' composer.json 2>/dev/null | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
    fi

    # 7. .NET: *.csproj / *.fsproj / Directory.Build.props
    if [ -z "$ver" ]; then
        local proj
        proj=$(find . -maxdepth 2 \( -name "*.csproj" -o -name "*.fsproj" -o -name "Directory.Build.props" \) ! -path '*/.*' 2>/dev/null | head -n1 || true)
        if [ -n "$proj" ] && [ -f "$proj" ]; then
            ver=$(grep -E '<(Version|PackageVersion)>' "$proj" 2>/dev/null | head -n1 | sed -E 's/.*<(Version|PackageVersion)>([^<]+)<\/(Version|PackageVersion)>.*/\2/' || true)
        fi
    fi

    # 8. Java: pom.xml or build.gradle
    if [ -z "$ver" ] && [ -f "pom.xml" ]; then
        ver=$(awk '/<version>/{print; exit}' pom.xml 2>/dev/null | sed -E 's/.*<version>([^<]+)<\/version>.*/\1/' || true)
    fi
    if [ -z "$ver" ] && [ -f "build.gradle" ]; then
        ver=$(grep -E '^[[:space:]]*version[[:space:]]*=' build.gradle 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
    fi
    if [ -z "$ver" ] && [ -f "build.gradle.kts" ]; then
        ver=$(grep -E '^[[:space:]]*version[[:space:]]*=' build.gradle.kts 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
    fi

    # 9. Python setup.py / setup.cfg / __version__
    if [ -z "$ver" ] && [ -f "setup.py" ]; then
        ver=$(grep -E 'version[[:space:]]*=' setup.py 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
    fi
    if [ -z "$ver" ] && [ -f "setup.cfg" ]; then
        ver=$(grep -E '^[[:space:]]*version[[:space:]]*=' setup.cfg 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*([^[:space:]]+).*/\1/' || true)
    fi
    if [ -z "$ver" ]; then
        local py_init
        py_init=$(find . -maxdepth 3 \( -name "__init__.py" -o -name "_version.py" -o -name "version.py" \) ! -path '*/.*' 2>/dev/null | head -n1 || true)
        if [ -n "$py_init" ] && [ -f "$py_init" ]; then
            ver=$(grep -E '^[[:space:]]*__version__[[:space:]]*=' "$py_init" 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
        fi
    fi

    # 10. Go: version.go
    if [ -z "$ver" ]; then
        local go_ver
        go_ver=$(find . -maxdepth 3 -name "*version*.go" ! -path '*/.*' 2>/dev/null | head -n1 || true)
        if [ -n "$go_ver" ] && [ -f "$go_ver" ]; then
            ver=$(grep -E '(var|const)[[:space:]]+(Version|version)[[:space:]]*=' "$go_ver" 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
        fi
    fi

    # 11. Deno / JSR
    if [ -z "$ver" ]; then
        for jf in "deno.json" "deno.jsonc" "jsr.json"; do
            if [ -f "$jf" ]; then
                ver=$(grep -m1 '"version"' "$jf" 2>/dev/null | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
                [ -n "$ver" ] && break
            fi
        done
    fi

    # 12. Gradle properties
    if [ -z "$ver" ] && [ -f "gradle.properties" ]; then
        ver=$(grep -E '^[[:space:]]*(version|appVersion)[[:space:]]*=' gradle.properties 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*([^[:space:]]+).*/\1/' || true)
    fi

    # 13. Elixir mix.exs
    if [ -z "$ver" ] && [ -f "mix.exs" ]; then
        ver=$(grep -E 'version:[[:space:]]*["\x27]' mix.exs 2>/dev/null | head -n1 | sed -E 's/.*version:[[:space:]]*["\x27]([^"\x27]+)["\x27].*/\1/' || true)
    fi

    # 14. Helm Chart.yaml
    if [ -z "$ver" ] && [ -f "Chart.yaml" ]; then
        ver=$(grep -E '^version:[[:space:]]*' Chart.yaml 2>/dev/null | head -n1 | sed -E 's/^version:[[:space:]]*([^[:space:]]+).*/\1/' || true)
    fi

    # 15. Generic: VERSION or .version file
    if [ -z "$ver" ]; then
        if [ -f "VERSION" ]; then
            ver=$(head -n1 VERSION 2>/dev/null | tr -d '[:space:]' || true)
        elif [ -f ".version" ]; then
            ver=$(head -n1 .version 2>/dev/null | tr -d '[:space:]' || true)
        fi
    fi

    # 16. Fallback: inspect any detected version file across nested subpackages
    if [ -z "$ver" ]; then
        local first_vfile
        first_vfile=$(detect_version_files 2>/dev/null | head -n1 || true)
        if [ -n "$first_vfile" ] && [ -f "$first_vfile" ]; then
            case "$first_vfile" in
                *package.json|*deno.json*|*jsr.json)
                    ver=$(grep -m1 '"version"' "$first_vfile" 2>/dev/null | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true) ;;
                *Cargo.toml)
                    ver=$(awk '/^\[package\]/{flag=1;next}/^\[/{flag=0}flag && /^version/{print}' "$first_vfile" 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true) ;;
                *pyproject.toml)
                    ver=$(grep -E '^[[:space:]]*version[[:space:]]*=' "$first_vfile" 2>/dev/null | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true) ;;
                *pubspec.yaml)
                    ver=$(grep -E '^[[:space:]]*version:' "$first_vfile" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*version:[[:space:]]*([^[:space:]]+).*/\1/' || true) ;;
                *pom.xml)
                    ver=$(awk '/<version>/{print; exit}' "$first_vfile" 2>/dev/null | sed -E 's/.*<version>([^<]+)<\/version>.*/\1/' || true) ;;
                *VERSION|*.version)
                    ver=$(head -n1 "$first_vfile" 2>/dev/null | tr -d '[:space:]' || true) ;;
            esac
        fi
    fi

    # 12. Fallback to latest Git tag
    if [ -z "$ver" ]; then
        local latest_tag
        latest_tag=$(git tag -l "v*" "*.*.*" 2>/dev/null | grep -E '^v?[0-9]+\.[0-9]+' | sort -V 2>/dev/null | tail -n1 || true)
        if [ -n "$latest_tag" ]; then
            ver="$latest_tag"
        fi
    fi

    # 13. Default initial version
    if [ -z "$ver" ]; then
        ver="${DEFAULT_INITIAL_VERSION:-0.1.0}"
    fi

    # Strip leading 'v' or 'V'
    ver="${ver#v}"
    ver="${ver#V}"

    echo "$ver"
}

# Compare two SemVer strings. Returns 0 if v1 > v2, 1 otherwise.
# Handles v prefix, major.minor.patch, prerelease (-rc.1), and pubspec build numbers (+1).
semver_gt() {
    local v1="$1" v2="$2"
    [ -z "$v1" ] && return 1
    [ -z "$v2" ] && return 0
    [ "$v1" = "$v2" ] && return 1

    v1="${v1#v}"; v1="${v1#V}"
    v2="${v2#v}"; v2="${v2#V}"

    # Extract build metadata (+...)
    local b1="" b2=""
    if [[ "$v1" == *"+"* ]]; then
        b1="${v1#*+}"
        v1="${v1%%+*}"
    fi
    if [[ "$v2" == *"+"* ]]; then
        b2="${v2#*+}"
        v2="${v2%%+*}"
    fi

    # Extract prerelease (-...)
    local pre1="" pre2=""
    if [[ "$v1" == *"-"* ]]; then
        pre1="${v1#*-}"
        v1="${v1%%-*}"
    fi
    if [[ "$v2" == *"-"* ]]; then
        pre2="${v2#*-}"
        v2="${v2%%-*}"
    fi

    local maj1 min1 pat1
    maj1=$(echo "$v1" | awk -F'.' '{print $1}')
    min1=$(echo "$v1" | awk -F'.' '{print $2}')
    pat1=$(echo "$v1" | awk -F'.' '{print $3}')
    maj1="${maj1:-0}"; min1="${min1:-0}"; pat1="${pat1:-0}"

    local maj2 min2 pat2
    maj2=$(echo "$v2" | awk -F'.' '{print $1}')
    min2=$(echo "$v2" | awk -F'.' '{print $2}')
    pat2=$(echo "$v2" | awk -F'.' '{print $3}')
    maj2="${maj2:-0}"; min2="${min2:-0}"; pat2="${pat2:-0}"

    if [ "$maj1" -ne "$maj2" ]; then
        [ "$maj1" -gt "$maj2" ] && return 0 || return 1
    fi
    if [ "$min1" -ne "$min2" ]; then
        [ "$min1" -gt "$min2" ] && return 0 || return 1
    fi
    if [ "$pat1" -ne "$pat2" ]; then
        [ "$pat1" -gt "$pat2" ] && return 0 || return 1
    fi

    # Core versions are equal. Normal release has higher precedence than prerelease.
    # e.g., 1.0.0 > 1.0.0-rc.1
    if [ -z "$pre1" ] && [ -n "$pre2" ]; then
        return 0
    fi
    if [ -n "$pre1" ] && [ -z "$pre2" ]; then
        return 1
    fi
    if [ -n "$pre1" ] && [ -n "$pre2" ]; then
        if [ "$pre1" != "$pre2" ]; then
            local higher_pre
            higher_pre=$(printf '%s\n%s\n' "$pre1" "$pre2" | sort -V 2>/dev/null | tail -n1)
            [ "$higher_pre" = "$pre1" ] && return 0 || return 1
        fi
    fi

    # If core and prerelease are equal, check build numbers if numeric (e.g. pubspec +2 > +1)
    if [ -n "$b1" ] && [ -n "$b2" ]; then
        if [[ "$b1" =~ ^[0-9]+$ ]] && [[ "$b2" =~ ^[0-9]+$ ]]; then
            [ "$b1" -gt "$b2" ] && return 0 || return 1
        fi
    fi

    return 1
}

# Extract committed version manifest directly from git HEAD
get_version_from_git_head() {
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        return 1
    fi

    local ver=""
    # 1. package.json
    if git cat-file -e "HEAD:package.json" 2>/dev/null; then
        ver=$(git show "HEAD:package.json" 2>/dev/null | grep -m1 '"version"' | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
    fi

    # 2. Cargo.toml
    if [ -z "$ver" ] && git cat-file -e "HEAD:Cargo.toml" 2>/dev/null; then
        ver=$(git show "HEAD:Cargo.toml" 2>/dev/null | awk '/^\[package\]/{flag=1;next}/^\[/{flag=0}flag && /^version/{print}' | head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true)
    fi

    # 3. pyproject.toml
    if [ -z "$ver" ] && git cat-file -e "HEAD:pyproject.toml" 2>/dev/null; then
        ver=$(git show "HEAD:pyproject.toml" 2>/dev/null | grep -E '^[[:space:]]*version[[:space:]]*=' | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
    fi

    # 4. pubspec.yaml
    if [ -z "$ver" ] && git cat-file -e "HEAD:pubspec.yaml" 2>/dev/null; then
        ver=$(git show "HEAD:pubspec.yaml" 2>/dev/null | grep -E '^[[:space:]]*version:' | head -n1 | sed -E 's/^[[:space:]]*version:[[:space:]]*([^[:space:]]+).*/\1/' || true)
    fi

    # 5. composer.json
    if [ -z "$ver" ] && git cat-file -e "HEAD:composer.json" 2>/dev/null; then
        ver=$(git show "HEAD:composer.json" 2>/dev/null | grep -m1 '"version"' | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
    fi

    # 6. VERSION or .version
    if [ -z "$ver" ]; then
        if git cat-file -e "HEAD:VERSION" 2>/dev/null; then
            ver=$(git show "HEAD:VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
        elif git cat-file -e "HEAD:.version" 2>/dev/null; then
            ver=$(git show "HEAD:.version" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
        fi
    fi

    # 7. Ruby gemspec or version.rb
    if [ -z "$ver" ]; then
        local rb_file
        rb_file=$(git ls-tree -r --name-only HEAD 2>/dev/null | grep -E '\.gemspec$' | head -n1 || true)
        if [ -n "$rb_file" ]; then
            ver=$(git show "HEAD:$rb_file" 2>/dev/null | grep -E '\.version[[:space:]]*=' | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
        fi
        if [ -z "$ver" ]; then
            rb_file=$(git ls-tree -r --name-only HEAD 2>/dev/null | grep -E '(^|/)version\.rb$' | head -n1 || true)
            if [ -n "$rb_file" ]; then
                ver=$(git show "HEAD:$rb_file" 2>/dev/null | grep -E 'VERSION[[:space:]]*=' | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
            fi
        fi
    fi

    # 8. .NET proj
    if [ -z "$ver" ]; then
        local net_file
        net_file=$(git ls-tree -r --name-only HEAD 2>/dev/null | grep -E '\.(csproj|fsproj)$' | head -n1 || true)
        if [ -n "$net_file" ]; then
            ver=$(git show "HEAD:$net_file" 2>/dev/null | grep -E '<(Version|PackageVersion)>' | head -n1 | sed -E 's/.*<(Version|PackageVersion)>([^<]+)<\/(Version|PackageVersion)>.*/\2/' || true)
        fi
    fi

    # 9. Java pom.xml or gradle
    if [ -z "$ver" ] && git cat-file -e "HEAD:pom.xml" 2>/dev/null; then
        ver=$(git show "HEAD:pom.xml" 2>/dev/null | awk '/<version>/{print; exit}' | sed -E 's/.*<version>([^<]+)<\/version>.*/\1/' || true)
    fi
    if [ -z "$ver" ] && git cat-file -e "HEAD:build.gradle" 2>/dev/null; then
        ver=$(git show "HEAD:build.gradle" 2>/dev/null | grep -E '^[[:space:]]*version[[:space:]]*=' | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
    fi

    # 10. Go version.go
    if [ -z "$ver" ]; then
        local go_file
        go_file=$(git ls-tree -r --name-only HEAD 2>/dev/null | grep -E '(^|/)version\.go$' | head -n1 || true)
        if [ -n "$go_file" ]; then
            ver=$(git show "HEAD:$go_file" 2>/dev/null | grep -E '(var|const)[[:space:]]+(Version|version)[[:space:]]*=' | head -n1 | sed -E 's/.*=[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/' || true)
        fi
    fi

    if [ -n "$ver" ]; then
        ver="${ver#v}"; ver="${ver#V}"
        echo "$ver"
        return 0
    fi
    return 1
}

# Resolve authoritative baseline ("last") version for SemVer calculation.
# Hierarchy:
# 1. Highest Git tag (v* or *.*.*)
# 2. Committed manifests in HEAD (get_version_from_git_head)
# 3. Working tree manifests (get_current_version)
# 4. DEFAULT_INITIAL_VERSION (0.1.0)
get_last_version() {
    local highest_tag=""
    local tag clean_cand
    local raw_tags
    raw_tags=$(git tag -l "v*" "*.*.*" 2>/dev/null || true)
    if [ -n "$raw_tags" ]; then
        while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            clean_cand="${tag#v}"; clean_cand="${clean_cand#V}"
            [[ "$clean_cand" =~ ^[0-9]+\.[0-9]+ ]] || continue
            if [ -z "$highest_tag" ]; then
                highest_tag="$clean_cand"
            elif semver_gt "$clean_cand" "$highest_tag"; then
                highest_tag="$clean_cand"
            fi
        done <<< "$raw_tags"
    fi

    if [ -n "$highest_tag" ]; then
        echo "$highest_tag"
        return 0
    fi

    # Fallback to committed HEAD manifests
    local head_ver
    if head_ver=$(get_version_from_git_head 2>/dev/null) && [ -n "$head_ver" ]; then
        echo "$head_ver"
        return 0
    fi

    # Fallback to working tree manifests (e.g. before initial commit)
    local cur_ver
    cur_ver=$(get_current_version)
    echo "$cur_ver"
}


# Calculate the next semver given a current version and bump level
# Args: $1=current_version (e.g. "1.2.3"), $2=bump_level ("major"|"minor"|"patch"|"none")
calculate_next_semver() {
    local cur="$1" bump="$2"
    cur="${cur#v}"
    cur="${cur#V}"

    # Extract build/prerelease suffix if present
    local build_suffix=""
    if [[ "$cur" == *"+"* ]]; then
        build_suffix="+${cur#*+}"
        cur="${cur%%+*}"
    fi
    local prerelease_suffix=""
    if [[ "$cur" == *"-"* ]]; then
        prerelease_suffix="-${cur#*-}"
        cur="${cur%%-*}"
    fi

    local major minor patch
    major=$(echo "$cur" | awk -F'.' '{print $1}')
    minor=$(echo "$cur" | awk -F'.' '{print $2}')
    patch=$(echo "$cur" | awk -F'.' '{print $3}')

    major="${major:-0}"
    minor="${minor:-0}"
    patch="${patch:-0}"

    case "$bump" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            prerelease_suffix=""
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            prerelease_suffix=""
            ;;
        patch)
            patch=$((patch + 1))
            prerelease_suffix=""
            ;;
        *)
            # none or unrecognized - return current version
            echo "${cur}${prerelease_suffix}${build_suffix}"
            return 0
            ;;
    esac

    # Handle build number increment for Dart pubspec if numeric
    if [ -n "$build_suffix" ]; then
        local b_num="${build_suffix#+}"
        if [[ "$b_num" =~ ^[0-9]+$ ]]; then
            build_suffix="+$((b_num + 1))"
        fi
    fi

    echo "${major}.${minor}.${patch}${prerelease_suffix}${build_suffix}"
}

# Detect all files containing version declarations in the current repo
# Searches root and nested directories (up to depth 4, excluding caches/builds/deps)
# Echoes space- or newline-delimited list of relative paths
detect_version_files() {
    local -a files=()

    # 1. Direct root checks (fast path)
    [ -f "package.json" ] && grep -q '"version"' package.json 2>/dev/null && files+=("package.json")
    [ -f "package-lock.json" ] && grep -q '"version"' package-lock.json 2>/dev/null && files+=("package-lock.json")
    [ -f "deno.json" ] && grep -q '"version"' deno.json 2>/dev/null && files+=("deno.json")
    [ -f "deno.jsonc" ] && grep -q '"version"' deno.jsonc 2>/dev/null && files+=("deno.jsonc")
    [ -f "jsr.json" ] && grep -q '"version"' jsr.json 2>/dev/null && files+=("jsr.json")
    [ -f "Cargo.toml" ] && grep -qE '^[[:space:]]*version[[:space:]]*=' Cargo.toml 2>/dev/null && files+=("Cargo.toml")
    [ -f "pyproject.toml" ] && grep -qE '^[[:space:]]*version[[:space:]]*=' pyproject.toml 2>/dev/null && files+=("pyproject.toml")
    [ -f "setup.py" ] && grep -qE 'version[[:space:]]*=' setup.py 2>/dev/null && files+=("setup.py")
    [ -f "setup.cfg" ] && grep -qE 'version[[:space:]]*=' setup.cfg 2>/dev/null && files+=("setup.cfg")
    [ -f "pubspec.yaml" ] && grep -qE '^[[:space:]]*version[[:space:]]*:' pubspec.yaml 2>/dev/null && files+=("pubspec.yaml")
    [ -f "composer.json" ] && grep -q '"version"' composer.json 2>/dev/null && files+=("composer.json")
    [ -f "pom.xml" ] && grep -q '<version>' pom.xml 2>/dev/null && files+=("pom.xml")
    [ -f "build.gradle" ] && grep -qE '^[[:space:]]*(version|versionName)[[:space:]]*[= ]' build.gradle 2>/dev/null && files+=("build.gradle")
    [ -f "build.gradle.kts" ] && grep -qE '^[[:space:]]*(version|versionName)[[:space:]]*[= ]' build.gradle.kts 2>/dev/null && files+=("build.gradle.kts")
    [ -f "gradle.properties" ] && grep -qE '^[[:space:]]*(version|appVersion)[[:space:]]*=' gradle.properties 2>/dev/null && files+=("gradle.properties")
    [ -f "mix.exs" ] && grep -qE 'version:[[:space:]]*["\x27]' mix.exs 2>/dev/null && files+=("mix.exs")
    [ -f "Chart.yaml" ] && grep -qE '^(version|appVersion):' Chart.yaml 2>/dev/null && files+=("Chart.yaml")
    [ -f "CMakeLists.txt" ] && grep -qE '(VERSION[[:space:]]+[0-9.]+|PROJECT_VERSION)' CMakeLists.txt 2>/dev/null && files+=("CMakeLists.txt")
    [ -f "Package.swift" ] && grep -qE 'version:[[:space:]]*["\x27]' Package.swift 2>/dev/null && files+=("Package.swift")
    [ -f "VERSION" ] && [ -s "VERSION" ] && files+=("VERSION")
    [ -f ".version" ] && [ -s ".version" ] && files+=(".version")

    # 2. Nested manifest scan (depth 2 to 4, prune non-project folders)
    local raw_found
    raw_found=$(find . -maxdepth 4 \( -name .git -o -name node_modules -o -name vendor -o -name target -o -name build -o -name dist -o -name .venv -o -name venv -o -name env -o -name __pycache__ -o -name .tox -o -name .mypy_cache -o -name .pytest_cache -o -name .cache -o -name Pods -o -name .gradle -o -name .idea -o -name .vscode \) -prune -o -type f \( \
        -name "package.json" -o -name "package-lock.json" -o -name "deno.json" -o -name "deno.jsonc" -o -name "jsr.json" -o \
        -name "Cargo.toml" -o -name "pyproject.toml" -o -name "setup.py" -o -name "setup.cfg" -o \
        -name "pubspec.yaml" -o -name "composer.json" -o -name "pom.xml" -o -name "build.gradle" -o \
        -name "build.gradle.kts" -o -name "gradle.properties" -o -name "mix.exs" -o -name "Chart.yaml" -o \
        -name "CMakeLists.txt" -o -name "Package.swift" -o -name "*.gemspec" -o -name "*.csproj" -o \
        -name "*.fsproj" -o -name "Directory.Build.props" -o -name "*.pbxproj" -o -name "VERSION" -o -name ".version" \
    \) -print 2>/dev/null | sed 's|^\./||')

    if [ -n "$raw_found" ]; then
        local nf
        while IFS= read -r nf; do
            [ -z "$nf" ] && continue
            case "$nf" in
                package.json|*/package.json)
                    grep -q '"version"' "$nf" 2>/dev/null && files+=("$nf") ;;
                package-lock.json|*/package-lock.json)
                    grep -q '"version"' "$nf" 2>/dev/null && files+=("$nf") ;;
                deno.json|*/deno.json|deno.jsonc|*/deno.jsonc|jsr.json|*/jsr.json)
                    grep -q '"version"' "$nf" 2>/dev/null && files+=("$nf") ;;
                Cargo.toml|*/Cargo.toml)
                    grep -qE '^[[:space:]]*version[[:space:]]*=' "$nf" 2>/dev/null && files+=("$nf") ;;
                pyproject.toml|*/pyproject.toml)
                    grep -qE '^[[:space:]]*version[[:space:]]*=' "$nf" 2>/dev/null && files+=("$nf") ;;
                setup.py|*/setup.py)
                    grep -qE 'version[[:space:]]*=' "$nf" 2>/dev/null && files+=("$nf") ;;
                setup.cfg|*/setup.cfg)
                    grep -qE 'version[[:space:]]*=' "$nf" 2>/dev/null && files+=("$nf") ;;
                pubspec.yaml|*/pubspec.yaml)
                    grep -qE '^[[:space:]]*version[[:space:]]*:' "$nf" 2>/dev/null && files+=("$nf") ;;
                composer.json|*/composer.json)
                    grep -q '"version"' "$nf" 2>/dev/null && files+=("$nf") ;;
                pom.xml|*/pom.xml)
                    grep -q '<version>' "$nf" 2>/dev/null && files+=("$nf") ;;
                build.gradle|*/build.gradle|build.gradle.kts|*/build.gradle.kts)
                    grep -qE '^[[:space:]]*(version|versionName)[[:space:]]*[= ]' "$nf" 2>/dev/null && files+=("$nf") ;;
                gradle.properties|*/gradle.properties)
                    grep -qE '^[[:space:]]*(version|appVersion)[[:space:]]*=' "$nf" 2>/dev/null && files+=("$nf") ;;
                mix.exs|*/mix.exs)
                    grep -qE 'version:[[:space:]]*["\x27]' "$nf" 2>/dev/null && files+=("$nf") ;;
                Chart.yaml|*/Chart.yaml)
                    grep -qE '^(version|appVersion):' "$nf" 2>/dev/null && files+=("$nf") ;;
                CMakeLists.txt|*/CMakeLists.txt)
                    grep -qE '(VERSION[[:space:]]+[0-9.]+|PROJECT_VERSION)' "$nf" 2>/dev/null && files+=("$nf") ;;
                Package.swift|*/Package.swift)
                    grep -qE 'version:[[:space:]]*["\x27]' "$nf" 2>/dev/null && files+=("$nf") ;;
                *.gemspec)
                    grep -qE '\.version[[:space:]]*=' "$nf" 2>/dev/null && files+=("$nf") ;;
                *.csproj|*.fsproj|Directory.Build.props|*/Directory.Build.props)
                    grep -qE '<(Version|PackageVersion)>' "$nf" 2>/dev/null && files+=("$nf") ;;
                *.pbxproj)
                    grep -qE 'MARKETING_VERSION[[:space:]]*=' "$nf" 2>/dev/null && files+=("$nf") ;;
                VERSION|*/VERSION|.version|*/.version)
                    [ -s "$nf" ] && files+=("$nf") ;;
            esac
        done <<< "$raw_found"
    fi

    # 3. Source code version files (Python __init__.py/_version.py, Ruby version.rb, Go *version*.go)
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find . -maxdepth 4 \( -name .git -o -name node_modules -o -name vendor -o -name target -o -name build -o -name dist -o -name .venv -o -name venv -o -name env -o -name __pycache__ \) -prune -o -type f \( -name "__init__.py" -o -name "_version.py" -o -name "version.py" \) -print 2>/dev/null | sed 's|^\./||' | while IFS= read -r pyf; do
        if grep -qE '^[[:space:]]*(__version__|VERSION)[[:space:]]*=' "$pyf" 2>/dev/null; then
            echo "$pyf"
        fi
    done)

    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find . -maxdepth 4 \( -name .git -o -name node_modules -o -name vendor \) -prune -o -type f -name "version.rb" -print 2>/dev/null | sed 's|^\./||' | while IFS= read -r rbf; do
        if grep -qE 'VERSION[[:space:]]*=' "$rbf" 2>/dev/null; then
            echo "$rbf"
        fi
    done)

    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find . -maxdepth 4 \( -name .git -o -name node_modules -o -name vendor -o -name target -o -name build \) -prune -o -type f -name "*version*.go" -print 2>/dev/null | sed 's|^\./||' | while IFS= read -r gf; do
        if grep -qE '(var|const)[[:space:]]+(Version|version)[[:space:]]*=' "$gf" 2>/dev/null; then
            echo "$gf"
        fi
    done)

    # Output unique sorted list
    if [ ${#files[@]} -gt 0 ]; then
        printf '%s\n' "${files[@]}" | sort -u
    fi
}

# Update version in a specific file safely using awk
# Args: $1=file, $2=old_version, $3=new_version
update_version_in_file() {
    local file="$1" old_ver="$2" new_ver="$3"
    [ ! -f "$file" ] && return 1

    local tmp="${file}.tmp.$$"

    case "$file" in
        package.json|*/package.json|deno.json|*/deno.json|deno.jsonc|*/deno.jsonc|jsr.json|*/jsr.json)
            # Replace the first occurrence of "version": "..."
            awk -v old="$old_ver" -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /"version"[[:space:]]*:[[:space:]]*"/ {
                    sub("\"version\"[[:space:]]*:[[:space:]]*\"[^\"]+\"", "\"version\": \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        package-lock.json|*/package-lock.json)
            # In package-lock.json, update top-level version and packages[""] version
            awk -v new="$new_ver" '
                BEGIN { count = 0 }
                count < 2 && /"version"[[:space:]]*:[[:space:]]*"/ {
                    sub("\"version\"[[:space:]]*:[[:space:]]*\"[^\"]+\"", "\"version\": \"" new "\"")
                    count++
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        Cargo.toml|*/Cargo.toml)
            # Replace version under [package]
            awk -v new="$new_ver" '
                BEGIN { in_pkg = 0; done = 0 }
                /^\[package\]/ { in_pkg = 1; print; next }
                /^\[/ { in_pkg = 0 }
                in_pkg && !done && /^[[:space:]]*version[[:space:]]*=/ {
                    sub(/version[[:space:]]*=[[:space:]]*"[^"]+"/, "version = \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        pyproject.toml|*/pyproject.toml)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /^[[:space:]]*version[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/version[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "version = \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        setup.py|*/setup.py)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /version[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/version[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "version=\"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        setup.cfg|*/setup.cfg)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /^[[:space:]]*version[[:space:]]*=/ {
                    sub(/version[[:space:]]*=[[:space:]]*[^[:space:]]+/, "version = " new)
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        *.py)
            # Python __init__.py / _version.py / version.py
            awk -v new="$new_ver" '
                /^[[:space:]]*(__version__|VERSION)[[:space:]]*=/ {
                    sub(/(__version__|VERSION)[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "__version__ = \"" new "\"")
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        pubspec.yaml|*/pubspec.yaml)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /^[[:space:]]*version:[[:space:]]*/ {
                    sub(/version:[[:space:]]*[^[:space:]]+/, "version: " new)
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        *.gemspec)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /\.version[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/\.version[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, ".version = \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        *version.rb)
            awk -v new="$new_ver" '
                /VERSION[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/VERSION[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "VERSION = \"" new "\"")
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        composer.json|*/composer.json)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /"version"[[:space:]]*:[[:space:]]*"/ {
                    sub("\"version\"[[:space:]]*:[[:space:]]*\"[^\"]+\"", "\"version\": \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        *.csproj|*.fsproj|Directory.Build.props|*/Directory.Build.props)
            awk -v new="$new_ver" '
                /<Version>[^<]+<\/Version>/ {
                    sub(/<Version>[^<]+<\/Version>/, "<Version>" new "</Version>")
                }
                /<PackageVersion>[^<]+<\/PackageVersion>/ {
                    sub(/<PackageVersion>[^<]+<\/PackageVersion>/, "<PackageVersion>" new "</PackageVersion>")
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        pom.xml|*/pom.xml)
            # Replace root <version> (first occurrence)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /<version>[^<]+<\/version>/ {
                    sub(/<version>[^<]+<\/version>/, "<version>" new "</version>")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        build.gradle|*/build.gradle|build.gradle.kts|*/build.gradle.kts)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /^[[:space:]]*version[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/version[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "version = \"" new "\"")
                    done = 1
                }
                !done && /^[[:space:]]*versionName[[:space:]]*[= ]/ {
                    sub(/versionName[[:space:]]*[= ]*["\x27][^"\x27]+["\x27]/, "versionName \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        gradle.properties|*/gradle.properties)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /^[[:space:]]*(version|appVersion)[[:space:]]*=/ {
                    sub(/=[[:space:]]*[^[:space:]]+/, "= " new)
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        mix.exs|*/mix.exs)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /version:[[:space:]]*["\x27][^"\x27]+["\x27]/ {
                    sub(/version:[[:space:]]*["\x27][^"\x27]+["\x27]/, "version: \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        Chart.yaml|*/Chart.yaml)
            awk -v new="$new_ver" '
                /^[[:space:]]*version:[[:space:]]*/ {
                    sub(/version:[[:space:]]*[^[:space:]]+/, "version: " new)
                }
                /^[[:space:]]*appVersion:[[:space:]]*/ {
                    sub(/appVersion:[[:space:]]*["\x27]?[^"\x27[:space:]]+["\x27]?/, "appVersion: \"" new "\"")
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        CMakeLists.txt|*/CMakeLists.txt)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /project\([[:space:]]*[^)]*VERSION[[:space:]]+[0-9.]+/ {
                    sub(/VERSION[[:space:]]+[0-9.]+/, "VERSION " new)
                    done = 1
                }
                !done && /set\([[:space:]]*(PROJECT_VERSION|[A-Za-z_]+_VERSION)[[:space:]]+["\x27]?[0-9.]+["\x27]?\)/ {
                    sub(/["\x27]?[0-9.]+["\x27]?\)/, "\"" new "\")")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        Package.swift|*/Package.swift)
            awk -v new="$new_ver" '
                /version:[[:space:]]*["\x27][^"\x27]+["\x27]/ {
                    sub(/version:[[:space:]]*["\x27][^"\x27]+["\x27]/, "version: \"" new "\"")
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        *.pbxproj)
            awk -v new="$new_ver" '
                /MARKETING_VERSION[[:space:]]*=[[:space:]]*[^;]+;/ {
                    sub(/MARKETING_VERSION[[:space:]]*=[[:space:]]*[^;]+;/, "MARKETING_VERSION = " new ";")
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        *version*.go)
            awk -v new="$new_ver" '
                /(var|const)[[:space:]]+(Version|version)[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/(Version|version)[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "Version = \"" new "\"")
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        VERSION|.version|*/VERSION|*/.version)
            printf '%s\n' "$new_ver" > "$file"
            ;;

        *)
            # Generic fallback: if old_ver is present in file, replace first occurrence
            if [ -n "$old_ver" ] && grep -qF "$old_ver" "$file" 2>/dev/null; then
                awk -v old="$old_ver" -v new="$new_ver" '
                    BEGIN { done = 0 }
                    !done && $0 ~ old {
                        sub(old, new)
                        done = 1
                    }
                    { print }
                ' "$file" > "$tmp" && mv "$tmp" "$file"
            fi
            ;;
    esac

    rm -f "$tmp" 2>/dev/null || true
    return 0
}

# Update all detected version files and stage them via git add
# Args: $1=old_version, $2=new_version
# Echoes list of updated files
apply_semver_file_updates() {
    local old_ver="$1" new_ver="$2"
    [ -z "$new_ver" ] || [ "$old_ver" = "$new_ver" ] && return 0

    local files file
    files=$(detect_version_files)

    local -a updated_files=()
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        if update_version_in_file "$file" "$old_ver" "$new_ver"; then
            agit add "$file" 2>/dev/null || git add "$file" 2>/dev/null || true
            if [ -n "$(agit diff --staged -z --name-only -- "$file" 2>/dev/null | tr '\0' '\n')" ]; then
                updated_files+=("$file")
            fi
        fi
    done <<< "$files"

    if [ ${#updated_files[@]} -gt 0 ]; then
        printf '%s\n' "${updated_files[@]}"
    fi
}

# Create annotated Git tag for the specified version
# Args: $1=version, $2=tag_message (optional)
create_version_tag() {
    local version="$1"
    local msg="${2:-Release v${version}}"
    local prefix="${AI_SEMVER_TAG_PREFIX:-v}"
    local tag_name="${prefix}${version#v}"

    if git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
        echo "⚠️  Git tag '$tag_name' already exists — skipping tag creation"
        return 0
    fi

    if git tag -a "$tag_name" -m "$msg" 2>/dev/null; then
        return 0
    else
        # Fallback to lightweight tag if annotated fails
        git tag "$tag_name" 2>/dev/null || return 1
    fi
}

# Extract SemVer decision from AI response
# Args: $1=raw_output
# Echoes: "major", "minor", or "patch" (or returns 1 if unable to extract)
extract_semver_decision() {
    local raw_output="$1"
    [ -z "$raw_output" ] && return 1

    # Strip carriage returns and terminal backspaces/escapes
    local cleaned
    cleaned=$(printf '%s' "$raw_output" | tr -d '\r')
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

    # Strip thinking blocks
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

    # Extract between @@@ delimiters if present
    local delimited
    delimited=$(printf '%s\n' "$cleaned" | awk '
        /^@@@([[:space:]]*)$/ { count++; next }
        count == 1 { print }
        count >= 2 { exit }
    ')
    [ -n "$(printf '%s' "$delimited" | tr -d '[:space:]')" ] && cleaned="$delimited"

    # Search lines for decision
    local line cand word
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if echo "$line" | grep -q '|'; then
            cand=$(echo "$line" | cut -d'|' -f1 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]`*')
            if [[ "$cand" =~ ^(major|minor|patch)$ ]]; then
                echo "$cand"
                return 0
            fi
        fi
        word=$(echo "$line" | tr '[:upper:]' '[:lower:]' | tr -d '[:punct:]' | awk '{print $1}')
        if [[ "$word" =~ ^(major|minor|patch)$ ]]; then
            echo "$word"
            return 0
        fi
    done <<< "$cleaned"

    return 1
}

# Use the same AI/LLM to calculate the applicable semver bump based on commit message & changes
# Args: $1=commit_msg, $2=changes_input (optional), $3=action_label (optional)
# Echoes: "major", "minor", or "patch" (or returns 1 on failure)
ai_evaluate_semver() {
    local commit_msg="$1"
    local changes_input="${2:-}"
    local action_label="${3:-Calculating SemVer bump}"

    # Verify LLM prerequisites — the API is the source of truth (the installed
    # ollama CLI can lag the server, so pgrep/CLI checks are unreliable).
    if ! command -v invoke_llm >/dev/null 2>&1 || ! command -v _ollama_curl >/dev/null 2>&1; then
        return 1
    fi
    if ! _ollama_curl "$(_ollama_host)/api/version" >/dev/null 2>&1; then
        return 1
    fi

    local model="${AI_MODEL:-$DEFAULT_AI_MODEL}"
    local tmp_dir state_dir
    if command -v get_aicommit_tmp_dir >/dev/null 2>&1; then
        tmp_dir=$(get_aicommit_tmp_dir 2>/dev/null)
    fi
    [ -z "$tmp_dir" ] && tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/aicommit.XXXXXXXX" 2>/dev/null) || true
    state_dir=$(get_aicommit_state_dir 2>/dev/null || echo "")

    # Lever C: Check cache
    if [ -n "$tmp_dir" ] && [ -s "${tmp_dir}/SEMVER" ]; then
        local cached_val
        cached_val=$(cat "${tmp_dir}/SEMVER" 2>/dev/null | tr -d '[:space:]')
        if [[ "$cached_val" =~ ^(major|minor|patch)$ ]]; then
            echo "$cached_val"
            return 0
        fi
    fi
    local cdir=""
    if command -v get_aicommit_cache_key >/dev/null 2>&1 && [ -n "$state_dir" ]; then
        local ckey
        ckey=$(get_aicommit_cache_key 2>/dev/null || echo "")
        if [ -n "$ckey" ]; then
            cdir="${state_dir}/cache/${ckey}"
            if [ -s "${cdir}/SEMVER" ]; then
                local cached_val
                cached_val=$(cat "${cdir}/SEMVER" 2>/dev/null | tr -d '[:space:]')
                if [[ "$cached_val" =~ ^(major|minor|patch)$ ]]; then
                    echo "$cached_val"
                    return 0
                fi
            fi
        fi
    fi

    # Determine context dir
    local ctx_dir="$tmp_dir"
    if [ -n "$changes_input" ] && [ -d "$changes_input" ] && [ -f "${changes_input}/CHANGES_CONTEXT" ]; then
        ctx_dir="$changes_input"
    elif [ -n "$changes_input" ] && [ -f "$changes_input" ]; then
        cp "$changes_input" "${tmp_dir}/CHANGES_CONTEXT"
    fi

    # Ensure CHANGES_CONTEXT exists and is bounded (never send unbounded raw diff)
    if [ ! -s "${ctx_dir}/CHANGES_CONTEXT" ]; then
        if [ -n "$changes_input" ] && [ ! -f "$changes_input" ]; then
            printf '%s\n' "$changes_input" | head -n 150 > "${tmp_dir}/CHANGES_CONTEXT"
        else
            local staged_files numstat_data
            staged_files=$(git diff --staged --name-only 2>/dev/null || true)
            numstat_data=$(git diff --staged --numstat 2>/dev/null || true)
            if [ -n "$staged_files" ] && command -v build_ai_context >/dev/null 2>&1; then
                build_ai_context "" "$staged_files" "$numstat_data" "" "$tmp_dir" 10 40 >/dev/null 2>&1 || true
            fi
        fi
        [ -s "${tmp_dir}/CHANGES_CONTEXT" ] && ctx_dir="$tmp_dir"
    fi

    if [ ! -s "${ctx_dir}/CHANGES_CONTEXT" ]; then
        printf 'Commit message: %s\n' "$commit_msg" > "${tmp_dir}/CHANGES_CONTEXT"
        ctx_dir="$tmp_dir"
    fi

    local tail_file="${tmp_dir}/SEMVER_TAIL"
    cat <<EOF > "$tail_file"
=== SEMVER EVALUATION ===
Commit message:
$commit_msg

Determine whether the changes and commit message require a MAJOR, MINOR, or PATCH version bump under SemVer 2.0.0:
- MAJOR: Incompatible API changes, breaking changes.
- MINOR: New backward-compatible functionality or features.
- PATCH: Bug fixes, refactoring, dependency updates, docs, or maintenance chores.

Output ONLY inside @@@ delimiters:
@@@
<level> | <brief rationale>
@@@
where <level> is strictly major, minor, or patch.
EOF

    local request_file="${tmp_dir}/SEMVER_REQUEST.json"
    local response_file="${tmp_dir}/SEMVER_RESPONSE"
    local error_file="${tmp_dir}/SEMVER_ERROR"
    local timeout_secs=${AI_TIMEOUT:-120}

    # Lever B: Use shared-prefix follow-up request with num_predict=64
    if ! AI_NUM_PREDICT=64 build_followup_request "$request_file" "$ctx_dir" "$tail_file"; then
        if ! build_ollama_request "$request_file" "$model" "$tail_file" "${AI_PROMPT_FILE}"; then
            return 1
        fi
    fi

    if ! invoke_llm "$model" "$request_file" "$response_file" "$error_file" "$timeout_secs" "$action_label"; then
        return 1
    fi

    local raw_resp decision
    raw_resp=$(cat "$response_file" 2>/dev/null || true)
    decision=$(extract_semver_decision "$raw_resp")
    if [ -n "$decision" ] && [[ "$decision" =~ ^(major|minor|patch)$ ]]; then
        printf '%s\n' "$decision" > "${tmp_dir}/SEMVER" 2>/dev/null || true
        if [ -n "${cdir:-}" ] && [ -d "$cdir" ]; then
            printf '%s\n' "$decision" > "${cdir}/SEMVER" 2>/dev/null || true
        fi
        echo "$decision"
        return 0
    fi
    return 1
}

# Evaluates the semver bump level for a commit message
# Args: $1=commit_msg, $2=explicit_level (optional: "major"|"minor"|"patch"|"ai"|"auto"), $3=hint_or_context (optional), $4=ctx_dir (optional)
evaluate_commit_semver() {
    local commit_msg="$1"
    local explicit_level="${2:-}"
    local hint_or_context="${3:-}"
    local ctx_dir="${4:-}"

    if [ -n "$explicit_level" ] && [ "$explicit_level" != "auto" ] && [ "$explicit_level" != "ai" ]; then
        case "$explicit_level" in
            major|minor|patch) echo "$explicit_level"; return 0 ;;
            custom:*) echo "$explicit_level"; return 0 ;;
        esac
    fi

    # Explicit AI evaluation requested
    if [ "$explicit_level" = "ai" ]; then
        local ai_bump
        ai_bump=$(ai_evaluate_semver "$commit_msg" "$hint_or_context" 2>/dev/null || true)
        if [ -n "$ai_bump" ] && [[ "$ai_bump" =~ ^(major|minor|patch)$ ]]; then
            echo "$ai_bump"
            return 0
        fi
    fi

    local bump="none"
    bump=$(suggest_semver_bump "$commit_msg")
    if [ "$bump" != "none" ] && [ -n "$bump" ]; then
        echo "$bump"
        return 0
    fi

    # Check for valid hint (passed directly, as file path, or in ctx_dir / run_dir)
    local hint=""
    if [ -n "$hint_or_context" ]; then
        if [ -f "$hint_or_context" ]; then
            local first_line
            first_line=$(head -1 "$hint_or_context" 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z')
            case "$first_line" in
                major|minor|patch|none) hint="$first_line" ;;
            esac
        else
            case "$(printf '%s' "$hint_or_context" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" in
                major|minor|patch|none) hint="$(printf '%s' "$hint_or_context" | tr -d '[:space:]' | tr 'A-Z' 'a-z')" ;;
            esac
        fi
    fi
    if [ -z "$hint" ] && [ -n "$ctx_dir" ] && [ -f "${ctx_dir}/RELEASE_HINT" ]; then
        local first_line
        first_line=$(head -1 "${ctx_dir}/RELEASE_HINT" 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z')
        case "$first_line" in
            major|minor|patch|none) hint="$first_line" ;;
        esac
    fi
    if [ -z "$hint" ] && command -v get_aicommit_tmp_dir >/dev/null 2>&1; then
        local tmp_d
        tmp_d=$(get_aicommit_tmp_dir 2>/dev/null)
        if [ -n "$tmp_d" ] && [ -f "${tmp_d}/RELEASE_HINT" ]; then
            local first_line
            first_line=$(head -1 "${tmp_d}/RELEASE_HINT" 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z')
            case "$first_line" in
                major|minor|patch|none) hint="$first_line" ;;
            esac
        fi
    fi

    if [ -n "$hint" ] && [ "$hint" != "none" ]; then
        echo "$hint"
        return 0
    fi

    # If conventional commit heuristic is inconclusive (none/empty), use AI/LLM if needed!
    if [ "${AI_SEMVER_USE_AI:-true}" = "true" ]; then
        local ai_bump
        ai_bump=$(ai_evaluate_semver "$commit_msg" "$hint_or_context" 2>/dev/null || true)
        if [ -n "$ai_bump" ] && [[ "$ai_bump" =~ ^(major|minor|patch)$ ]]; then
            echo "$ai_bump"
            return 0
        fi
    fi
    # Default bump fallback when AI is unavailable or inconclusive
    echo "${AI_SEMVER_DEFAULT_BUMP:-patch}"
}

# Interactive SemVer decision menu for interactive sessions
# Args: $1=commit_msg, $2=current_ver, $3=initial_level (optional)
# Outputs: chosen bump level ("major", "minor", "patch", "custom:VERSION", or "skip") to stdout
prompt_semver_decision() {
    local commit_msg="$1"
    local cur_ver="$2"
    local initial_level="${3:-}"

    local rec_level
    rec_level=$(evaluate_commit_semver "$commit_msg" "$initial_level")
    local rec_next
    rec_next=$(calculate_next_semver "$cur_ver" "$rec_level")

    local patch_next minor_next major_next
    patch_next=$(calculate_next_semver "$cur_ver" "patch")
    minor_next=$(calculate_next_semver "$cur_ver" "minor")
    major_next=$(calculate_next_semver "$cur_ver" "major")

    local v_files
    v_files=$(detect_version_files)
    local v_files_str
    if [ -n "$v_files" ]; then
        v_files_str=$(printf '%s' "$v_files" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
    else
        v_files_str="(none — Git tag only)"
    fi

    local rec_upper
    rec_upper=$(echo "$rec_level" | tr '[:lower:]' '[:upper:]')

    cat <<EOF >&2

🏷️  aisemver — SemVer Release Decision:
   Current version: $cur_ver
   Manifest files:  $v_files_str

   Select bump level:
   1) Recommended: $rec_upper -> $rec_next
   2) PATCH -> $patch_next (bug fix / maintenance)
   3) MINOR -> $minor_next (feature / backward-compatible)
   4) MAJOR -> $major_next (breaking change)
   5) Custom version string
   6) Skip SemVer (commit without version bump)
   7) Ask AI to analyze changes & calculate SemVer (or enter 'a' / 'ai')

EOF
    printf "   Select option [1-7, default: 1]: " >&2

    local choice=""
    if ! read -r choice; then
        echo "" >&2
        echo "$rec_level"
        return 0
    fi
    echo "" >&2
    choice=$(echo "$choice" | tr -d '[:space:]')
    choice=${choice:-1}

    case "$choice" in
        1|rec|recommended)
            echo "$rec_level"
            ;;
        2|patch|p|PATCH)
            echo "patch"
            ;;
        3|minor|m|MINOR)
            echo "minor"
            ;;
        4|major|M|MAJOR)
            echo "major"
            ;;
        5|custom|c)
            printf "   Enter target version (e.g. 1.2.0-rc.1): " >&2
            local custom_ver=""
            if read -r custom_ver; then
                custom_ver=$(echo "$custom_ver" | tr -d '[:space:]')
                if [ -n "$custom_ver" ]; then
                    echo "custom:$custom_ver"
                    return 0
                fi
            fi
            echo "$rec_level"
            ;;
        6|skip|none|n|cancel)
            echo "skip"
            ;;
        7|a|ai|AI|ask)
            printf "   🤖 Asking AI to analyze changes and calculate SemVer...\n" >&2
            local ai_level
            ai_level=$(ai_evaluate_semver "$commit_msg" "" "Calculating SemVer bump")
            if [ -n "$ai_level" ] && [[ "$ai_level" =~ ^(major|minor|patch)$ ]]; then
                local ai_next
                ai_next=$(calculate_next_semver "$cur_ver" "$ai_level")
                printf "   🤖 AI calculated SemVer: %s -> %s\n" "$(echo "$ai_level" | tr '[:lower:]' '[:upper:]')" "$ai_next" >&2
                echo "$ai_level"
            else
                printf "   ⚠️  AI evaluation unavailable — falling back to recommended: %s\n" "$rec_level" >&2
                echo "$rec_level"
            fi
            ;;
        *)
            echo "$rec_level"
            ;;
    esac
}

# Detect existing changelog filename preserving actual filesystem casing
detect_changelog_file() {
    local candidates=(
        "CHANGELOG.md" "CHANGELOG.markdown" "CHANGELOG.txt" "CHANGELOG.rst" "CHANGELOG"
        "changelog.md" "changelog.markdown" "changelog.txt" "changelog.rst" "changelog"
        "HISTORY.md" "history.md" "HISTORY.txt" "HISTORY.rst" "HISTORY" "history"
        "RELEASES.md" "releases.md" "NEWS.md" "news.md"
    )
    local existing_files cand
    existing_files=$(find . -maxdepth 1 -type f 2>/dev/null | sed 's|^\./||')
    for cand in "${candidates[@]}"; do
        if printf '%s\n' "$existing_files" | grep -qx "$cand"; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

# Generate categorized Keep a Changelog release notes from conventional commits since last tag
# Args: $1=target_ver, $2=custom_msg (optional), $3=last_tag (optional)
# Echoes markdown formatted notes
generate_changelog_release_notes() {
    local target_ver="$1" custom_msg="${2:-}" last_tag="${3:-}"
    local -a breaking=() feat=() fix=() perf=() docs=() maint=() other=()

    # Determine git log range
    if [ -z "$last_tag" ]; then
        last_tag=$(git tag -l "v*" "*.*.*" 2>/dev/null | grep -E '^v?[0-9]+\.[0-9]+' | sort -V 2>/dev/null | tail -n1 || true)
    fi

    local range="HEAD"
    if [ -n "$last_tag" ] && git rev-parse -q --verify "$last_tag" >/dev/null 2>&1; then
        range="${last_tag}..HEAD"
    fi

    local log_lines=""
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
        log_lines=$(git log "$range" --oneline --no-merges 2>/dev/null || true)
    fi

    if [ -n "$log_lines" ]; then
        local line subj
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            subj="${line#* }"
            [ -z "$subj" ] && continue

            # Filter out version bump / release commits
            if printf '%s\n' "$subj" | grep -qE '^(chore\(release\):|Version updated|Release v?[0-9])'; then
                continue
            fi

            if printf '%s\n' "$subj" | grep -qE 'BREAKING[ -]CHANGE:|^[a-z]+(\([^)]+\))?!:'; then
                breaking+=("- ${subj}")
            elif printf '%s\n' "$subj" | grep -qE '^feat(\([^)]+\))?:'; then
                feat+=("- ${subj}")
            elif printf '%s\n' "$subj" | grep -qE '^fix(\([^)]+\))?:'; then
                fix+=("- ${subj}")
            elif printf '%s\n' "$subj" | grep -qE '^perf(\([^)]+\))?:'; then
                perf+=("- ${subj}")
            elif printf '%s\n' "$subj" | grep -qE '^docs(\([^)]+\))?:'; then
                docs+=("- ${subj}")
            elif printf '%s\n' "$subj" | grep -qE '^(refactor|chore|test|ci|style|build)(\([^)]+\))?:'; then
                maint+=("- ${subj}")
            else
                other+=("- ${subj}")
            fi
        done <<< "$log_lines"
    fi

    local -a sections=()
    if [ -n "$custom_msg" ]; then
        sections+=("- ${custom_msg}")
    fi

    if [ ${#breaking[@]} -gt 0 ]; then
        sections+=("### Breaking Changes" "$(printf '%s\n' "${breaking[@]}")")
    fi
    if [ ${#feat[@]} -gt 0 ]; then
        sections+=("### Added" "$(printf '%s\n' "${feat[@]}")")
    fi
    if [ ${#fix[@]} -gt 0 ]; then
        sections+=("### Fixed" "$(printf '%s\n' "${fix[@]}")")
    fi
    if [ ${#perf[@]} -gt 0 ]; then
        sections+=("### Performance" "$(printf '%s\n' "${perf[@]}")")
    fi
    if [ ${#docs[@]} -gt 0 ]; then
        sections+=("### Documentation" "$(printf '%s\n' "${docs[@]}")")
    fi
    if [ ${#maint[@]} -gt 0 ]; then
        sections+=("### Maintenance" "$(printf '%s\n' "${maint[@]}")")
    fi
    if [ ${#other[@]} -gt 0 ] && [ ${#feat[@]} -eq 0 ] && [ ${#fix[@]} -eq 0 ]; then
        sections+=("### Changes" "$(printf '%s\n' "${other[@]}")")
    fi

    if [ ${#sections[@]} -eq 0 ]; then
        echo "- Release v${target_ver}"
    else
        local s
        for s in "${sections[@]}"; do
            printf '%s\n\n' "$s"
        done | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba'
    fi
}

# Update or create project changelog idempotently
# Args: $1=version, $2=commit_msg_or_notes, $3=date (optional: YYYY-MM-DD)
# Echoes changelog filename
update_changelog() {
    local version="$1"
    local commit_msg="$2"
    local rel_date=""
    local stage_changelog=true

    if [ "$3" = "false" ]; then
        stage_changelog=false
        rel_date="$(date +%Y-%m-%d)"
    elif [ "$3" = "true" ]; then
        stage_changelog=true
        rel_date="$(date +%Y-%m-%d)"
    elif [ -n "$3" ]; then
        rel_date="$3"
        [ "$4" = "false" ] && stage_changelog=false
    else
        rel_date="$(date +%Y-%m-%d)"
    fi

    if [ "${AI_SEMVER_CHANGELOG:-true}" != "true" ]; then
        return 0
    fi

    local clean_ver="${version#v}"; clean_ver="${clean_ver#V}"
    [ -z "$clean_ver" ] && return 1

    local cl_file
    if ! cl_file=$(detect_changelog_file 2>/dev/null) || [ -z "$cl_file" ]; then
        cl_file="${AI_SEMVER_CHANGELOG_FILE:-CHANGELOG.md}"
    fi

    local content="$commit_msg"
    local first_line
    if [[ "$content" == "-"* ]] || [[ "$content" == "###"* ]]; then
        first_line=$(printf '%s\n' "$content" | grep -m1 '^[[:space:]]*-' | sed -E 's/^[[:space:]]*-[[:space:]]*//' || true)
        [ -z "$first_line" ] && first_line="Release v${clean_ver}"
    else
        first_line=$(printf '%s\n' "$content" | head -n 1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        [ -z "$first_line" ] && first_line="Release v${clean_ver}"
        content="- ${first_line}"
    fi
    local bullet="$content"

    if [ ! -f "$cl_file" ]; then
        cat <<EOF > "$cl_file"
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [${clean_ver}] - ${rel_date}

${bullet}
EOF
        if [ "$stage_changelog" = "true" ]; then
            agit add "$cl_file" 2>/dev/null || git add "$cl_file" 2>/dev/null || true
        fi
        echo "$cl_file"
        return 0
    fi

    # Clean up any stale temp/notes files from previous interrupted runs
    rm -f "${cl_file}.tmp."*".notes" "${cl_file}.tmp."* 2>/dev/null || true

    local tmp="${cl_file}.tmp.$$.$RANDOM"
    local notes_tmp
    if [ -n "${_AICOMMIT_RUN_DIR:-}" ] && [ -d "${_AICOMMIT_RUN_DIR}" ]; then
        notes_tmp="${_AICOMMIT_RUN_DIR}/cl_notes.$$.$RANDOM.tmp"
    else
        notes_tmp="${TMPDIR:-/tmp}/aicommit_cl_notes.$$.$RANDOM.tmp"
    fi
    printf '%s\n' "$bullet" > "$notes_tmp"

    local awk_rc=0
    awk -v ver="$clean_ver" -v rel_date="$rel_date" -v notes_file="$notes_tmp" -v line_match="$first_line" '
        function print_notes() {
            while ((getline nl < notes_file) > 0) print nl
            close(notes_file)
        }
        BEGIN {
            target_found = 0
            in_target_section = 0
            bullet_found = 0
            inserted_new = 0
        }
        # Detect section header for target version
        $0 ~ ("^## \\[?v?" ver "(\\]| -|:|[[:space:]]|$)") {
            target_found = 1
            in_target_section = 1
            print $0
            next
        }
        # Transition out of target section when next ## header arrives
        in_target_section && /^## / {
            if (!bullet_found) {
                print_notes()
                print ""
                bullet_found = 1
            }
            in_target_section = 0
        }
        in_target_section {
            if (index($0, line_match) > 0) {
                bullet_found = 1
            }
        }
        # If Unreleased header exists and target not found, insert new version right under Unreleased
        !target_found && !inserted_new && /^## \[[Uu]nreleased\]/ {
            print $0
            print ""
            print "## [" ver "] - " rel_date
            print ""
            print_notes()
            print ""
            inserted_new = 1
            next
        }
        # Prepend new section before the first existing release header if not target_found
        !target_found && !inserted_new && /^## / {
            print "## [" ver "] - " rel_date
            print ""
            print_notes()
            print ""
            inserted_new = 1
        }
        { print }
        END {
            if (target_found && in_target_section && !bullet_found) {
                print_notes()
            } else if (!target_found && !inserted_new) {
                print ""
                print "## [" ver "] - " rel_date
                print ""
                print_notes()
            }
        }
    ' "$cl_file" > "$tmp" || awk_rc=$?

    # Immediately remove temporary notes file
    rm -f "$notes_tmp" 2>/dev/null || true

    if [ "$awk_rc" -ne 0 ] || [ ! -f "$tmp" ]; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    if ! mv "$tmp" "$cl_file"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    if [ "$stage_changelog" = "true" ]; then
        agit add "$cl_file" 2>/dev/null || git add "$cl_file" 2>/dev/null || true
    fi
    echo "$cl_file"
    return 0
}

# Revert staged and modified version files and remove untracked changelog on commit failure
# Args: $1=files (newline-separated list of file paths)
restore_semver_updates() {
    local files="$1"
    [ -z "$files" ] && return 0
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if git rev-parse --verify "HEAD:$f" >/dev/null 2>&1; then
            agit restore --staged --worktree -- "$f" 2>/dev/null || git restore --staged --worktree -- "$f" 2>/dev/null || true
        else
            agit rm -f --cached -- "$f" 2>/dev/null || git rm -f --cached -- "$f" 2>/dev/null || true
            rm -f "$f" 2>/dev/null || true
        fi
    done <<< "$files"
}

# Check if working tree has a higher version than the evaluated next version.
# Returns 0 (success/true) if working tree is strictly higher and echoes working tree version.
# Returns 1 (false) otherwise and echoes evaluated next version.
resolve_effective_semver() {
    local evaluated_next="$1"
    local file_ver
    file_ver=$(get_current_version)
    if semver_gt "$file_ver" "$evaluated_next"; then
        echo "$file_ver"
        return 0
    fi
    echo "$evaluated_next"
    return 1
}

# Prepare and apply SemVer release: version files updates, changelog additions, and git staging.
# If target_ver is higher than evaluated_next, manifests are left untouched and staged as-is.
# Otherwise, manifests are updated via apply_semver_file_updates.
# Changelog is updated for target_ver and staged.
# Echoes list of updated/staged files.
apply_semver_release() {
    local cur_ver="$1" target_ver="$2" commit_msg="$3" evaluated_next="${4:-$target_ver}"
    local -a files_updated=()

    if ! semver_gt "$target_ver" "$evaluated_next"; then
        local m_files
        m_files=$(apply_semver_file_updates "$cur_ver" "$target_ver")
        if [ -n "$m_files" ]; then
            while IFS= read -r f; do
                [ -n "$f" ] && files_updated+=("$f")
            done <<< "$m_files"
        fi
    else
        # When preserved, ensure modified manifests are staged into the commit
        local v_files
        v_files=$(detect_version_files)
        if [ -n "$v_files" ]; then
            while IFS= read -r f; do
                if [ -n "$f" ]; then
                    agit add "$f" 2>/dev/null || git add "$f" 2>/dev/null || true
                    if [ -n "$(agit diff --staged -z --name-only -- "$f" 2>/dev/null | tr '\0' '\n')" ]; then
                        files_updated+=("$f")
                    fi
                fi
            done <<< "$v_files"
        fi
    fi

    # Update changelog
    if [ "${AI_SEMVER_CHANGELOG:-true}" = "true" ]; then
        local cl_file
        cl_file=$(update_changelog "$target_ver" "$commit_msg")
        if [ -n "$cl_file" ] && [ -n "$(agit diff --staged -z --name-only -- "$cl_file" 2>/dev/null | tr '\0' '\n')" ]; then
            files_updated+=("$cl_file")
        fi
    fi

    if [ ${#files_updated[@]} -gt 0 ]; then
        printf '%s\n' "${files_updated[@]}" | sort -u
    fi
}

# ─── Standalone SemVer Engine (ais / aisemver) ─────────────────────────────────

# Standalone Semantic Versioning bump command implementation
_aisemver_main() {
    [ -n "$ZSH_VERSION" ] && setopt localoptions localtraps shwordsplit nonomatch nomonitor nonotify typesetsilent

    local dry_run=false verbose=false
    local auto_yes=false
    if [ "${AI_SEMVER_MODE:-}" = "non_interactive" ]; then
        auto_yes=true
    elif [ "${AI_SEMVER_MODE:-}" = "interactive" ]; then
        auto_yes=false
    elif [[ "${0:-}" == *"bin/ais" ]] || [[ "${0:-}" == *"bin/aisx" ]]; then
        auto_yes=true
    fi

    local commit_opt=true tag_opt=true stage_opt=true changelog_opt=true
    local bump_arg="" set_ver="" auto_eval=false custom_msg=""
    local -a positional=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                echo "Usage: ais [OPTIONS] [major|minor|patch|auto|<version>] [\"release note\"]"
                echo "       aisemver [OPTIONS] [major|minor|patch|auto|<version>] [\"release note\"]"
                echo "       aisx [OPTIONS] [major|minor|patch|auto|<version>] [\"release note\"]"
                echo ""
                echo "Standalone Semantic Versioning (SemVer) bump & changelog engine."
                echo "Updates version declarations across project manifests (Node, Deno, Python,"
                echo "Rust, Go, Dart/Flutter, Java/Kotlin, .NET, Swift, Elixir, CMake, Helm) and"
                echo "maintains CHANGELOG.md without requiring an AI commit of staged code changes."
                echo ""
                echo "CLI Tools:"
                echo "  ais                Fast SemVer bump across manifests & changelog (safe defaults, CI/CD pipelines)"
                echo "  aisx               Dry-run inspection preview of SemVer bump (safe defaults, CI/CD pipelines, 0 changes made)"
                echo "  aisemver           Interactive SemVer bump (prompts user for bump level & release confirmation)"
                echo ""
                echo "Arguments:"
                echo "  major|minor|patch  Explicit bump increment level"
                echo "  auto               Auto-evaluate bump level from git history"
                echo "  <version>          Explicit target version string (e.g. 1.2.3 or v2.0.0)"
                echo "  \"release note\"    Optional release summary / note for changelog and commit"
                echo ""
                echo "Options:"
                echo "  --help, -h         Show this help message and exit"
                echo "  --dry-run, -d      Preview version transition and changelog (0 changes written)"
                echo "  --verbose, -v      Show detailed file discovery, pattern matching, and git actions"
                echo "  --yes, -y          Non-interactive mode (accept all safe defaults without prompt)"
                echo "  --interactive, -i  Interactive mode (prompt user for choices)"
                echo "  --bump=<level>     Explicit bump level (major, minor, patch, auto)"
                echo "  --semver=<level>   Synonym for --bump"
                echo "  --set=<version>    Set exact version string"
                echo "  --auto             Evaluate bump level automatically from git commits since last tag"
                echo "  --message, -m <msg> Custom release note / summary"
                echo "  --commit           Create Git release commit (default: true)"
                echo "  --no-commit        Do not create Git release commit"
                echo "  --tag              Create annotated Git tag for new version (default: true)"
                echo "  --no-tag           Do not create Git tag"
                echo "  --stage            Stage modified version files and changelog with git add (default: true)"
                echo "  --no-stage         Do not stage modified files into git index"
                echo "  --changelog        Update project changelog (default: true)"
                echo "  --no-changelog     Do not update changelog"
                echo ""
                echo "Examples:"
                echo "  ais                           Non-interactive bump with safe defaults (patch/auto, for CI/CD)"
                echo "  ais patch                     Fast bump patch version (for CI/CD pipelines)"
                echo "  ais minor -m \"New auth API\"   Fast bump minor with custom release note (for CI/CD)"
                echo "  aisx                          Fast non-interactive dry-run preview (0 changes written, for CI/CD)"
                echo "  aisemver                      Fully interactive release session (prompts for level & confirm)"
                return 0
                ;;
            --dry-run|-d)        dry_run=true ;;
            --verbose|-v)        verbose=true ;;
            --yes|-y)            auto_yes=true ;;
            --interactive|-i)    auto_yes=false ;;
            --auto)              auto_eval=true ;;
            --bump=*)            bump_arg="${1#--bump=}" ;;
            --semver=*)          bump_arg="${1#--semver=}" ;;
            --set=*)             set_ver="${1#--set=}" ;;
            --message=*)         custom_msg="${1#--message=}" ;;
            -m)                  shift; custom_msg="${1:-}" ;;
            --commit)            commit_opt=true ;;
            --no-commit)         commit_opt=false; tag_opt=false ;;
            --tag)               tag_opt=true ;;
            --no-tag)            tag_opt=false ;;
            --stage)             stage_opt=true ;;
            --no-stage)          stage_opt=false; commit_opt=false; tag_opt=false ;;
            --changelog)         changelog_opt=true ;;
            --no-changelog)      changelog_opt=false ;;
            *)                   positional+=("$1") ;;
        esac
        shift
    done

    # Process positional arguments
    local pos
    for pos in "${positional[@]}"; do
        case "$pos" in
            major|minor|patch)
                bump_arg="$pos"
                ;;
            auto)
                auto_eval=true
                ;;
            v[0-9]*|[0-9]*.[0-9]*)
                set_ver="${pos#v}"; set_ver="${set_ver#V}"
                ;;
            *)
                if [ -z "$custom_msg" ]; then
                    custom_msg="$pos"
                else
                    custom_msg="${custom_msg} ${pos}"
                fi
                ;;
        esac
    done

    # Resolve baseline current version
    local cur_ver
    cur_ver=$(get_last_version)
    cur_ver="${cur_ver#v}"; cur_ver="${cur_ver#V}"

    # Determine bump level or exact version
    local target_ver="" bump_level=""
    if [ -n "$set_ver" ]; then
        target_ver="$set_ver"
        bump_level="custom"
    elif [ -n "$bump_arg" ]; then
        bump_level="$bump_arg"
        target_ver=$(calculate_next_semver "$cur_ver" "$bump_level")
    elif [ "$auto_eval" = "true" ] || [ "$auto_yes" = "true" ]; then
        # Evaluate from git history since last tag, or fallback to patch (safe defaults for CI/CD)
        local last_tag git_commits
        last_tag=$(git tag -l "v*" "*.*.*" 2>/dev/null | grep -E '^v?[0-9]+\.[0-9]+' | sort -V 2>/dev/null | tail -n1 || true)
        local range="HEAD"
        [ -n "$last_tag" ] && range="${last_tag}..HEAD"
        git_commits=$(git log "$range" --format="%s" 2>/dev/null || true)
        if printf '%s\n' "$git_commits" | grep -qE 'BREAKING[ -]CHANGE:|^[a-z]+(\([^)]+\))?!:'; then
            bump_level="major"
        elif printf '%s\n' "$git_commits" | grep -qE '^feat(\([^)]+\))?:'; then
            bump_level="minor"
        elif printf '%s\n' "$git_commits" | grep -qE '^fix(\([^)]+\))?:'; then
            bump_level="patch"
        else
            bump_level="${AI_SEMVER_DEFAULT_BUMP:-patch}"
        fi
        target_ver=$(calculate_next_semver "$cur_ver" "$bump_level")
    fi

    # Interactive prompt for aisemver if no target version was specified
    if [ -z "$target_ver" ]; then
        if [ "$auto_yes" = "true" ]; then
            bump_level="${AI_SEMVER_DEFAULT_BUMP:-patch}"
            target_ver=$(calculate_next_semver "$cur_ver" "$bump_level")
        else
            # Interactive decision menu
            local patch_ver minor_ver major_ver
            patch_ver=$(calculate_next_semver "$cur_ver" "patch")
            minor_ver=$(calculate_next_semver "$cur_ver" "minor")
            major_ver=$(calculate_next_semver "$cur_ver" "major")

            local v_files
            v_files=$(detect_version_files)
            local v_files_str
            if [ -n "$v_files" ]; then
                v_files_str=$(printf '%s' "$v_files" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
            else
                v_files_str="(none — Git tag only)"
            fi

            # Recommended bump evaluation
            local last_tag git_commits rec_bump="patch" rec_reason="fix/maintenance"
            last_tag=$(git tag -l "v*" "*.*.*" 2>/dev/null | grep -E '^v?[0-9]+\.[0-9]+' | sort -V 2>/dev/null | tail -n1 || true)
            local range="HEAD"
            [ -n "$last_tag" ] && range="${last_tag}..HEAD"
            git_commits=$(git log "$range" --format="%s" 2>/dev/null || true)
            if printf '%s\n' "$git_commits" | grep -qE 'BREAKING[ -]CHANGE:|^[a-z]+(\([^)]+\))?!:'; then
                rec_bump="major"; rec_reason="breaking change"
            elif printf '%s\n' "$git_commits" | grep -qE '^feat(\([^)]+\))?:'; then
                rec_bump="minor"; rec_reason="new feature"
            elif printf '%s\n' "$git_commits" | grep -qE '^fix(\([^)]+\))?:'; then
                rec_bump="patch"; rec_reason="bug fix"
            fi
            local rec_next
            rec_next=$(calculate_next_semver "$cur_ver" "$rec_bump")
            local rec_upper
            rec_upper=$(echo "$rec_bump" | tr '[:lower:]' '[:upper:]')

            echo ""
            echo "🏷️  aisemver — Semantic Versioning Release"
            echo "────────────────────────────────────────────"
            echo "   Current version: $cur_ver"
            echo "   Manifest files:  $v_files_str"
            echo ""
            echo "Select bump level:"
            echo "  [1] Recommended: $rec_upper ($cur_ver -> $rec_next, $rec_reason) [Default]"
            echo "  [2] Patch  ($cur_ver -> $patch_ver)"
            echo "  [3] Minor  ($cur_ver -> $minor_ver)"
            echo "  [4] Major  ($cur_ver -> $major_ver)"
            echo "  [5] Custom version"
            echo "  [6] Dry run preview"
            echo "  [7] Cancel / Abort"
            echo ""
            printf "Choice [1-7, default: 1]: "

            local choice=""
            if ! read -r choice; then
                echo "❌ No input available to select version bump (stdin closed)" >&2
                return 1
            fi
            choice=$(echo "$choice" | tr -d '[:space:]')
            choice=${choice:-1}

            case "$choice" in
                1|rec|recommended)
                    bump_level="$rec_bump"
                    target_ver="$rec_next"
                    ;;
                2|patch|p|PATCH)
                    bump_level="patch"
                    target_ver="$patch_ver"
                    ;;
                3|minor|m|MINOR)
                    bump_level="minor"
                    target_ver="$minor_ver"
                    ;;
                4|major|M|MAJOR)
                    bump_level="major"
                    target_ver="$major_ver"
                    ;;
                5|custom|c)
                    printf "Enter target version (e.g. 1.3.0): "
                    read -r target_ver
                    target_ver=$(echo "$target_ver" | tr -d '[:space:]')
                    target_ver="${target_ver#v}"; target_ver="${target_ver#V}"
                    bump_level="custom"
                    if [ -z "$target_ver" ]; then
                        echo "❌ Invalid version string"; return 1
                    fi
                    ;;
                6|dry-run|preview)
                    dry_run=true
                    bump_level="$rec_bump"
                    target_ver="$rec_next"
                    ;;
                *)
                    echo "❌ Operation cancelled"
                    return 0
                    ;;
            esac
        fi
    fi

    # Strip any leading 'v'
    target_ver="${target_ver#v}"; target_ver="${target_ver#V}"

    # Detect files to update
    local v_files_list
    v_files_list=$(detect_version_files)

    local cl_file=""
    if [ "$changelog_opt" = "true" ]; then
        if ! cl_file=$(detect_changelog_file 2>/dev/null) || [ -z "$cl_file" ]; then
            cl_file="${AI_SEMVER_CHANGELOG_FILE:-CHANGELOG.md}"
        fi
    fi

    local tag_name="${AI_SEMVER_TAG_PREFIX:-v}${target_ver}"
    local rel_commit_msg="${custom_msg:-chore(release): v${target_ver}}"

    # Dry-run preview
    if [ "$dry_run" = "true" ]; then
        echo ""
        echo "🔍 aisemver Dry-Run Preview (0 changes made)"
        echo "────────────────────────────────────────────"
        echo "   Current version: $cur_ver"
        echo "   Target version:  $target_ver ($bump_level)"
        echo "   Git tag:         $tag_name $([ "$tag_opt" = "true" ] && echo "(enabled)" || echo "(disabled)")"
        echo "   Release commit:  $rel_commit_msg $([ "$commit_opt" = "true" ] && echo "(enabled)" || echo "(disabled)")"
        echo "   Git staging:     $([ "$stage_opt" = "true" ] && echo "enabled" || echo "disabled")"
        echo ""
        echo "📝 Manifest files to be updated:"
        if [ -n "$v_files_list" ]; then
            while IFS= read -r vf; do
                [ -n "$vf" ] && echo "   • $vf ($cur_ver -> $target_ver)"
            done <<< "$v_files_list"
        else
            echo "   (none found — tag only)"
        fi
        echo ""
        if [ -n "$cl_file" ]; then
            echo "📄 Changelog target: $cl_file"
            local preview_notes
            preview_notes=$(generate_changelog_release_notes "$target_ver" "$custom_msg")
            echo "   Preview notes:"
            printf '%s\n' "$preview_notes" | sed 's/^/     /'
        fi
        echo ""
        return 0
    fi

    # Interactive confirmation prompt for aisemver
    if [ "$dry_run" != "true" ] && [ "$auto_yes" != "true" ]; then
        echo ""
        echo "🏷️  aisemver — Release Confirmation"
        echo "────────────────────────────────────"
        echo "   Current: $cur_ver"
        echo "   Bump:    $bump_level"
        echo "   Target:  $target_ver"
        echo "   Git tag: $tag_name $([ "$tag_opt" = "true" ] && echo "(enabled)" || echo "(disabled)")"
        echo "   Commit:  $rel_commit_msg $([ "$commit_opt" = "true" ] && echo "(enabled)" || echo "(disabled)")"
        if [ -n "$v_files_list" ]; then
            local vf_str
            vf_str=$(printf '%s' "$v_files_list" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
            echo "   Files:   $vf_str"
        else
            echo "   Files:   (none — tag only)"
        fi
        [ -n "$cl_file" ] && echo "   Changelog: $cl_file"
        echo ""
        printf "Proceed with SemVer release? ([Y]/n/e to edit message): "

        local confirm_resp=""
        if ! read -r confirm_resp; then
            echo "❌ No input available for release confirmation (stdin closed)" >&2
            return 1
        fi
        confirm_resp=$(echo "$confirm_resp" | tr -d '[:space:]')
        case "$confirm_resp" in
            y|Y|yes|YES|"")
                # Confirmed
                ;;
            e|E|edit)
                printf "Enter release commit message [default: %s]: " "$rel_commit_msg"
                local edit_msg=""
                if read -r edit_msg && [ -n "$edit_msg" ]; then
                    rel_commit_msg="$edit_msg"
                    custom_msg="$edit_msg"
                fi
                ;;
            *)
                echo "❌ SemVer release cancelled."
                return 0
                ;;
        esac
    fi

    # Perform updates
    local -a updated_files=()
    if [ -n "$v_files_list" ]; then
        local vf
        while IFS= read -r vf; do
            [ -z "$vf" ] && continue
            if update_version_in_file "$vf" "$cur_ver" "$target_ver"; then
                updated_files+=("$vf")
                [ "$verbose" = "true" ] && echo "   Updated: $vf"
            fi
        done <<< "$v_files_list"
    fi

    # Update changelog
    if [ "$changelog_opt" = "true" ] && [ -n "$cl_file" ]; then
        local rel_notes
        rel_notes=$(generate_changelog_release_notes "$target_ver" "$custom_msg")
        if update_changelog "$target_ver" "$rel_notes" "$stage_opt"; then
            updated_files+=("$cl_file")
            [ "$verbose" = "true" ] && echo "   Updated changelog: $cl_file"
        fi
    fi

    # Git operations
    local is_git=false
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        is_git=true
    fi

    if [ "$is_git" = "true" ] && [ ${#updated_files[@]} -gt 0 ]; then
        if [ "$stage_opt" = "true" ]; then
            agit add "${updated_files[@]}" 2>/dev/null || git add "${updated_files[@]}" 2>/dev/null || true
            [ "$verbose" = "true" ] && echo "   Staged ${#updated_files[@]} file(s)"
        fi

        if [ "$commit_opt" = "true" ]; then
            if git commit -m "$rel_commit_msg" 2>/dev/null; then
                [ "$verbose" = "true" ] && echo "   Created commit: $rel_commit_msg"
                if [ "$tag_opt" = "true" ]; then
                    if create_version_tag "$target_ver" "Release v${target_ver}"; then
                        [ "$verbose" = "true" ] && echo "   Created Git tag: $tag_name"
                    fi
                fi
            else
                echo "⚠️  Failed to create release commit" >&2
            fi
        fi
    fi

    # Final summary display
    echo ""
    if [ "$commit_opt" = "true" ] && [ "$is_git" = "true" ]; then
        echo "✅ SemVer Release Successful!"
        echo "   Version:    $cur_ver -> $target_ver ($bump_level)"
        if [ ${#updated_files[@]} -gt 0 ]; then
            local files_str
            files_str=$(printf '%s' "${updated_files[*]}" | tr ' ' ',' | sed 's/,/, /g')
            echo "   Files:      $files_str"
        fi
        echo "   Commit:     $rel_commit_msg"
        if [ "$tag_opt" = "true" ]; then
            echo "   Git tag:    $tag_name"
        fi
    elif [ "$stage_opt" = "true" ] && [ "$is_git" = "true" ]; then
        echo "✅ SemVer files updated and staged successfully!"
        echo "   Version:    $cur_ver -> $target_ver ($bump_level)"
        if [ ${#updated_files[@]} -gt 0 ]; then
            local files_str
            files_str=$(printf '%s' "${updated_files[*]}" | tr ' ' ',' | sed 's/,/, /g')
            echo "   Files:      $files_str"
        fi
    else
        echo "✅ SemVer files updated successfully (unstaged)!"
        echo "   Version:    $cur_ver -> $target_ver ($bump_level)"
        if [ ${#updated_files[@]} -gt 0 ]; then
            local files_str
            files_str=$(printf '%s' "${updated_files[*]}" | tr ' ' ',' | sed 's/,/, /g')
            echo "   Files:      $files_str"
        fi
    fi
    echo ""
    return 0
}



