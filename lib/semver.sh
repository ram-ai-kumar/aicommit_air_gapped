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

    # 11. Generic: VERSION or .version file
    if [ -z "$ver" ]; then
        if [ -f "VERSION" ]; then
            ver=$(head -n1 VERSION 2>/dev/null | tr -d '[:space:]' || true)
        elif [ -f ".version" ]; then
            ver=$(head -n1 .version 2>/dev/null | tr -d '[:space:]' || true)
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
# Echoes space- or newline-delimited list of relative paths
detect_version_files() {
    local -a files=()

    # Node.js
    [ -f "package.json" ] && files+=("package.json")
    [ -f "package-lock.json" ] && files+=("package-lock.json")

    # Rust
    [ -f "Cargo.toml" ] && files+=("Cargo.toml")

    # Python
    [ -f "pyproject.toml" ] && files+=("pyproject.toml")
    [ -f "setup.py" ] && files+=("setup.py")
    [ -f "setup.cfg" ] && files+=("setup.cfg")
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find . -maxdepth 3 \( -name "__init__.py" -o -name "_version.py" -o -name "version.py" \) ! -path '*/.*' 2>/dev/null | sed 's|^\./||' | while IFS= read -r pyf; do
        if grep -qE '^[[:space:]]*__version__[[:space:]]*=' "$pyf" 2>/dev/null; then
            echo "$pyf"
        fi
    done)

    # Dart / Flutter
    [ -f "pubspec.yaml" ] && files+=("pubspec.yaml")

    # Ruby / Rails
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find . -maxdepth 2 -name "*.gemspec" ! -path '*/.*' 2>/dev/null | sed 's|^\./||')
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find lib config -maxdepth 3 -name "version.rb" ! -path '*/.*' 2>/dev/null | sed 's|^\./||')

    # PHP
    if [ -f "composer.json" ] && grep -q '"version"' composer.json 2>/dev/null; then
        files+=("composer.json")
    fi

    # .NET
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find . -maxdepth 2 \( -name "*.csproj" -o -name "*.fsproj" -o -name "Directory.Build.props" \) ! -path '*/.*' 2>/dev/null | sed 's|^\./||' | while IFS= read -r pf; do
        if grep -qE '<(Version|PackageVersion)>' "$pf" 2>/dev/null; then
            echo "$pf"
        fi
    done)

    # Java
    [ -f "pom.xml" ] && files+=("pom.xml")
    if [ -f "build.gradle" ] && grep -qE '^[[:space:]]*version[[:space:]]*=' build.gradle 2>/dev/null; then
        files+=("build.gradle")
    fi
    if [ -f "build.gradle.kts" ] && grep -qE '^[[:space:]]*version[[:space:]]*=' build.gradle.kts 2>/dev/null; then
        files+=("build.gradle.kts")
    fi

    # Go
    while IFS= read -r f; do
        [ -n "$f" ] && files+=("$f")
    done < <(find . -maxdepth 3 -name "*version*.go" ! -path '*/.*' 2>/dev/null | sed 's|^\./||' | while IFS= read -r gf; do
        if grep -qE '(var|const)[[:space:]]+(Version|version)[[:space:]]*=' "$gf" 2>/dev/null; then
            echo "$gf"
        fi
    done)

    # Generic
    [ -f "VERSION" ] && files+=("VERSION")
    [ -f ".version" ] && files+=(".version")

    # Output unique list
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
        package.json)
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

        package-lock.json)
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

        Cargo.toml)
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

        pyproject.toml)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /^[[:space:]]*version[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/version[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "version = \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        setup.py)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /version[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/version[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "version=\"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        setup.cfg)
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
            # Python __init__.py / _version.py
            awk -v new="$new_ver" '
                /^[[:space:]]*__version__[[:space:]]*=/ {
                    sub(/__version__[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "__version__ = \"" new "\"")
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        pubspec.yaml)
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

        composer.json)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /"version"[[:space:]]*:[[:space:]]*"/ {
                    sub("\"version\"[[:space:]]*:[[:space:]]*\"[^\"]+\"", "\"version\": \"" new "\"")
                    done = 1
                }
                { print }
            ' "$file" > "$tmp" && mv "$tmp" "$file"
            ;;

        *.csproj|*.fsproj|Directory.Build.props)
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

        pom.xml)
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

        build.gradle|build.gradle.kts)
            awk -v new="$new_ver" '
                BEGIN { done = 0 }
                !done && /^[[:space:]]*version[[:space:]]*=[[:space:]]*["\x27]/ {
                    sub(/version[[:space:]]*=[[:space:]]*["\x27][^"\x27]+["\x27]/, "version = \"" new "\"")
                    done = 1
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

        VERSION|.version)
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
    local files file
    files=$(detect_version_files)

    local -a updated_files=()
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        if update_version_in_file "$file" "$old_ver" "$new_ver"; then
            agit add "$file" 2>/dev/null || git add "$file" 2>/dev/null || true
            updated_files+=("$file")
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
    local prompt_template="${AI_SEMVER_PROMPT_FILE:-$AICOMMIT_DIR/templates/semver-prompt.txt}"

    local tmp_dir
    if command -v get_aicommit_tmp_dir >/dev/null 2>&1; then
        tmp_dir=$(get_aicommit_tmp_dir)
    else
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/aicommit.XXXXXXXX" 2>/dev/null) || return 1
    fi

    local changes_file="${tmp_dir}/SEMVER_CHANGES"
    if [ -n "$changes_input" ] && [ -f "$changes_input" ]; then
        cp "$changes_input" "$changes_file"
    elif [ -n "$changes_input" ]; then
        printf '%s\n' "$changes_input" > "$changes_file"
    elif [ -f "${tmp_dir}/CHANGES_CONTEXT" ] && [ -s "${tmp_dir}/CHANGES_CONTEXT" ]; then
        cp "${tmp_dir}/CHANGES_CONTEXT" "$changes_file"
    else
        agit diff --staged > "$changes_file" 2>/dev/null || git diff --staged > "$changes_file" 2>/dev/null || true
    fi

    if [ ! -s "$changes_file" ]; then
        printf 'Commit message: %s\n' "$commit_msg" > "$changes_file"
    fi

    local prompt_file="${tmp_dir}/SEMVER_PROMPT"
    local response_file="${tmp_dir}/SEMVER_RESPONSE"
    local error_file="${tmp_dir}/SEMVER_ERROR"
    local timeout_secs=${AI_TIMEOUT:-120}

    # Prepare prompt
    if [ -f "$prompt_template" ]; then
        awk '
        /\$\{COMMIT_MESSAGE\}/ {
            print commit_msg
            next
        }
        /\$\{CHANGES_CONTEXT\}/ {
            while ((getline line < changes_file) > 0) print line
            close(changes_file)
            next
        }
        { print }
        ' commit_msg="$commit_msg" changes_file="$changes_file" "$prompt_template" > "$prompt_file"
    else
        cat <<EOF > "$prompt_file"
You are an expert software release engineer specializing in Semantic Versioning (SemVer 2.0.0).
Determine whether the following git changes and commit message require a MAJOR, MINOR, or PATCH version bump:
- MAJOR: Incompatible API changes, breaking changes.
- MINOR: New backward-compatible functionality or features.
- PATCH: Bug fixes, refactoring, dependency updates, docs, or maintenance chores.

Output ONLY inside @@@ delimiters:
@@@
<level> | <brief rationale>
@@@
where <level> is strictly major, minor, or patch.

Commit message:
$commit_msg

Changes to analyze:
$(cat "$changes_file" 2>/dev/null | head -n 150)
EOF
    fi

    local request_file="${tmp_dir}/SEMVER_REQUEST.json"
    if ! build_ollama_request "$request_file" "$model" "$prompt_file"; then
        return 1
    fi
    if ! invoke_llm "$model" "$request_file" "$response_file" "$error_file" "$timeout_secs" "$action_label"; then
        return 1
    fi

    local raw_resp
    raw_resp=$(cat "$response_file" 2>/dev/null || true)
    extract_semver_decision "$raw_resp"
}

# Evaluates the semver bump level for a commit message
# Args: $1=commit_msg, $2=explicit_level (optional: "major"|"minor"|"patch"|"ai"|"auto"), $3=changes_context (optional)
evaluate_commit_semver() {
    local commit_msg="$1"
    local explicit_level="${2:-}"
    local changes_context="${3:-}"

    if [ -n "$explicit_level" ] && [ "$explicit_level" != "auto" ] && [ "$explicit_level" != "ai" ]; then
        case "$explicit_level" in
            major|minor|patch) echo "$explicit_level"; return 0 ;;
            custom:*) echo "$explicit_level"; return 0 ;;
        esac
    fi

    # Explicit AI evaluation requested
    if [ "$explicit_level" = "ai" ]; then
        local ai_bump
        ai_bump=$(ai_evaluate_semver "$commit_msg" "$changes_context" 2>/dev/null || true)
        if [ -n "$ai_bump" ] && [[ "$ai_bump" =~ ^(major|minor|patch)$ ]]; then
            echo "$ai_bump"
            return 0
        fi
    fi

    local bump="none"
    bump=$(suggest_semver_bump "$commit_msg")

    # If conventional commit heuristic is inconclusive (none/empty), use AI/LLM if needed!
    if [ "$bump" = "none" ] || [ -z "$bump" ]; then
        if [ "${AI_SEMVER_USE_AI:-true}" = "true" ]; then
            local ai_bump
            ai_bump=$(ai_evaluate_semver "$commit_msg" "$changes_context" 2>/dev/null || true)
            if [ -n "$ai_bump" ] && [[ "$ai_bump" =~ ^(major|minor|patch)$ ]]; then
                echo "$ai_bump"
                return 0
            fi
        fi
        # Default bump fallback when AI is unavailable or inconclusive
        echo "${AI_SEMVER_DEFAULT_BUMP:-patch}"
    else
        echo "$bump"
    fi
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

🏷️  SemVer Release Decision:
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

# Update or create project changelog idempotently
# Args: $1=version, $2=commit_msg, $3=date (optional: YYYY-MM-DD)
# Echoes changelog filename
update_changelog() {
    local version="$1"
    local commit_msg="$2"
    local rel_date="${3:-$(date +%Y-%m-%d)}"

    if [ "${AI_SEMVER_CHANGELOG:-true}" != "true" ]; then
        return 0
    fi

    local clean_ver="${version#v}"; clean_ver="${clean_ver#V}"
    [ -z "$clean_ver" ] && return 1

    local cl_file
    if ! cl_file=$(detect_changelog_file 2>/dev/null) || [ -z "$cl_file" ]; then
        cl_file="${AI_SEMVER_CHANGELOG_FILE:-CHANGELOG.md}"
    fi

    local first_line
    first_line=$(printf '%s\n' "$commit_msg" | head -n 1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -z "$first_line" ] && first_line="Release v${clean_ver}"
    local bullet="- ${first_line}"

    if [ ! -f "$cl_file" ]; then
        cat <<EOF > "$cl_file"
# Changelog

All notable changes to this project will be documented in this file.

## [${clean_ver}] - ${rel_date}

${bullet}
EOF
        agit add "$cl_file" 2>/dev/null || git add "$cl_file" 2>/dev/null || true
        echo "$cl_file"
        return 0
    fi

    local tmp="${cl_file}.tmp.$$"
    awk -v ver="$clean_ver" -v rel_date="$rel_date" -v bullet="$bullet" -v line_match="$first_line" '
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
                print bullet
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
        # Prepend new section before the first existing release header if not target_found
        !target_found && !inserted_new && /^## / {
            print "## [" ver "] - " rel_date
            print ""
            print bullet
            print ""
            inserted_new = 1
        }
        { print }
        END {
            if (target_found && in_target_section && !bullet_found) {
                print bullet
            } else if (!target_found && !inserted_new) {
                print ""
                print "## [" ver "] - " rel_date
                print ""
                print bullet
            }
        }
    ' "$cl_file" > "$tmp" && mv "$tmp" "$cl_file"

    agit add "$cl_file" 2>/dev/null || git add "$cl_file" 2>/dev/null || true
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
                    files_updated+=("$f")
                fi
            done <<< "$v_files"
        fi
    fi

    # Update changelog
    if [ "${AI_SEMVER_CHANGELOG:-true}" = "true" ]; then
        local cl_file
        cl_file=$(update_changelog "$target_ver" "$commit_msg")
        if [ -n "$cl_file" ]; then
            files_updated+=("$cl_file")
        fi
    fi

    if [ ${#files_updated[@]} -gt 0 ]; then
        printf '%s\n' "${files_updated[@]}" | sort -u
    fi
}


