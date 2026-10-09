#!/usr/bin/env bats
# Unit Tests — lib/semver.sh (SemVer engine & multi-language versioning)

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── calculate_next_semver ───────────────────────────────────────────────────

@test "calculate_next_semver major increments major and resets minor and patch" {
    run calculate_next_semver "1.2.3" "major"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0.0" ]
}

@test "calculate_next_semver minor increments minor and resets patch" {
    run calculate_next_semver "1.2.3" "minor"
    [ "$status" -eq 0 ]
    [ "$output" = "1.3.0" ]
}

@test "calculate_next_semver patch increments patch" {
    run calculate_next_semver "1.2.3" "patch"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.4" ]
}

@test "calculate_next_semver strips leading v" {
    run calculate_next_semver "v2.5.9" "minor"
    [ "$status" -eq 0 ]
    [ "$output" = "2.6.0" ]
}

@test "calculate_next_semver preserves and increments build numbers in pubspec style" {
    run calculate_next_semver "1.0.0+1" "patch"
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.1+2" ]
}

@test "calculate_next_semver clears prerelease suffix on bump" {
    run calculate_next_semver "1.0.0-beta.1" "patch"
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.1" ]
}

@test "calculate_next_semver returns current version for none" {
    run calculate_next_semver "1.2.3" "none"
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
}

# ─── get_current_version & detect_version_files ──────────────────────────────

@test "get_current_version extracts version from package.json" {
    printf '{\n  "name": "my-app",\n  "version": "2.4.1"\n}\n' > package.json
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "2.4.1" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "package.json"
}

@test "get_current_version extracts version from Cargo.toml" {
    printf '[package]\nname = "rust-pkg"\nversion = "0.7.2"\n' > Cargo.toml
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "0.7.2" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "Cargo.toml"
}

@test "get_current_version extracts version from pyproject.toml" {
    printf '[project]\nname = "py-app"\nversion = "3.1.0"\n' > pyproject.toml
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "3.1.0" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "pyproject.toml"
}

@test "get_current_version extracts version from pubspec.yaml" {
    printf 'name: flutter_app\nversion: 1.5.0+10\n' > pubspec.yaml
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "1.5.0+10" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "pubspec.yaml"
}

@test "get_current_version extracts version from gemspec and version.rb" {
    printf 'Gem::Specification.new do |s|\n  s.name = "my_gem"\n  s.version = "1.8.4"\nend\n' > my_gem.gemspec
    mkdir -p lib/my_gem
    printf 'module MyGem\n  VERSION = "1.8.4"\nend\n' > lib/my_gem/version.rb
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "1.8.4" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "my_gem.gemspec"
    assert_output_contains "lib/my_gem/version.rb"
}

@test "get_current_version extracts version from composer.json" {
    printf '{\n  "name": "vendor/package",\n  "version": "1.0.5"\n}\n' > composer.json
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.5" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "composer.json"
}

@test "get_current_version extracts version from .csproj" {
    printf '<Project Sdk="Microsoft.NET.Sdk">\n  <PropertyGroup>\n    <Version>4.2.0</Version>\n  </PropertyGroup>\n</Project>\n' > MyApp.csproj
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "4.2.0" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "MyApp.csproj"
}

@test "get_current_version extracts version from pom.xml" {
    printf '<project>\n  <groupId>com.example</groupId>\n  <artifactId>demo</artifactId>\n  <version>1.0.2</version>\n</project>\n' > pom.xml
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.2" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "pom.xml"
}

@test "get_current_version extracts version from VERSION file" {
    printf '0.9.1\n' > VERSION
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "0.9.1" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "VERSION"
}

@test "get_current_version extracts version from Go version.go" {
    printf 'package main\n\nconst Version = "1.4.0"\n' > version.go
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "1.4.0" ]

    run detect_version_files
    [ "$status" -eq 0 ]
    assert_output_contains "version.go"
}

@test "get_current_version falls back to highest git tag when no manifest exists" {
    echo "dummy" > dummy.txt
    git add dummy.txt
    git commit -m "initial commit" >/dev/null 2>&1
    git tag v1.9.3
    git tag v2.0.1
    git tag v0.5.0
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "2.0.1" ]
}

@test "get_current_version falls back to default 0.1.0 when no files and no tags" {
    run get_current_version
    [ "$status" -eq 0 ]
    [ "$output" = "0.1.0" ]
}

# ─── update_version_in_file ──────────────────────────────────────────────────

@test "update_version_in_file updates package.json and package-lock.json" {
    printf '{\n  "name": "pkg",\n  "version": "1.0.0",\n  "dependencies": {}\n}\n' > package.json
    printf '{\n  "name": "pkg",\n  "version": "1.0.0",\n  "packages": {\n    "": {\n      "name": "pkg",\n      "version": "1.0.0"\n    }\n  }\n}\n' > package-lock.json

    run update_version_in_file "package.json" "1.0.0" "1.1.0"
    [ "$status" -eq 0 ]
    grep -q '"version": "1.1.0"' package.json

    run update_version_in_file "package-lock.json" "1.0.0" "1.1.0"
    [ "$status" -eq 0 ]
    local count
    count=$(grep -c '"version": "1.1.0"' package-lock.json || true)
    [ "$count" -ge 2 ]
}

@test "update_version_in_file updates Cargo.toml" {
    printf '[package]\nname = "test"\nversion = "0.1.0"\nedition = "2021"\n' > Cargo.toml
    run update_version_in_file "Cargo.toml" "0.1.0" "0.2.0"
    [ "$status" -eq 0 ]
    grep -q 'version = "0.2.0"' Cargo.toml
}

@test "update_version_in_file updates pyproject.toml" {
    printf '[project]\nname = "pkg"\nversion = "1.2.0"\n' > pyproject.toml
    run update_version_in_file "pyproject.toml" "1.2.0" "2.0.0"
    [ "$status" -eq 0 ]
    grep -q 'version = "2.0.0"' pyproject.toml
}

@test "update_version_in_file updates pubspec.yaml" {
    printf 'name: app\nversion: 1.0.0+1\n' > pubspec.yaml
    run update_version_in_file "pubspec.yaml" "1.0.0+1" "1.0.1+2"
    [ "$status" -eq 0 ]
    grep -q 'version: 1.0.1+2' pubspec.yaml
}

@test "update_version_in_file updates .gemspec and version.rb" {
    printf 'Gem::Specification.new do |s|\n  s.version = "0.5.0"\nend\n' > my.gemspec
    mkdir -p lib
    printf 'module My\n  VERSION = "0.5.0"\nend\n' > lib/version.rb

    run update_version_in_file "my.gemspec" "0.5.0" "0.6.0"
    [ "$status" -eq 0 ]
    grep -q 's.version = "0.6.0"' my.gemspec

    run update_version_in_file "lib/version.rb" "0.5.0" "0.6.0"
    [ "$status" -eq 0 ]
    grep -q 'VERSION = "0.6.0"' lib/version.rb
}

@test "update_version_in_file updates composer.json" {
    printf '{\n  "version": "1.0.0"\n}\n' > composer.json
    run update_version_in_file "composer.json" "1.0.0" "1.0.1"
    [ "$status" -eq 0 ]
    grep -q '"version": "1.0.1"' composer.json
}

@test "update_version_in_file updates .csproj" {
    printf '<Project>\n  <PropertyGroup>\n    <Version>1.0.0</Version>\n  </PropertyGroup>\n</Project>\n' > app.csproj
    run update_version_in_file "app.csproj" "1.0.0" "1.1.0"
    [ "$status" -eq 0 ]
    grep -q '<Version>1.1.0</Version>' app.csproj
}

@test "update_version_in_file updates pom.xml" {
    printf '<project>\n  <version>1.0.0</version>\n</project>\n' > pom.xml
    run update_version_in_file "pom.xml" "1.0.0" "1.0.1"
    [ "$status" -eq 0 ]
    grep -q '<version>1.0.1</version>' pom.xml
}

@test "update_version_in_file updates VERSION file" {
    printf '1.0.0\n' > VERSION
    run update_version_in_file "VERSION" "1.0.0" "1.0.1"
    [ "$status" -eq 0 ]
    [ "$(cat VERSION)" = "1.0.1" ]
}

@test "update_version_in_file updates Go version.go" {
    printf 'package main\n\nconst Version = "1.0.0"\n' > version.go
    run update_version_in_file "version.go" "1.0.0" "1.1.0"
    [ "$status" -eq 0 ]
    grep -q 'Version = "1.1.0"' version.go
}

# ─── create_version_tag ──────────────────────────────────────────────────────

@test "create_version_tag creates an annotated git tag" {
    touch dummy.txt
    git add dummy.txt
    git commit -m "initial commit" >/dev/null 2>&1

    run create_version_tag "1.5.0" "Release v1.5.0"
    [ "$status" -eq 0 ]
    run git tag -l
    assert_output_contains "v1.5.0"
}

@test "create_version_tag skips cleanly if tag already exists" {
    touch dummy.txt
    git add dummy.txt
    git commit -m "initial commit" >/dev/null 2>&1
    git tag v1.0.0

    run create_version_tag "1.0.0"
    [ "$status" -eq 0 ]
    assert_output_contains "already exists"
}

# ─── evaluate_commit_semver ──────────────────────────────────────────────────

@test "evaluate_commit_semver returns major for breaking change" {
    run evaluate_commit_semver "feat!: drop legacy authentication"
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "evaluate_commit_semver returns minor for feat" {
    run evaluate_commit_semver "feat(ui): add dark mode toggle"
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "evaluate_commit_semver returns patch for fix" {
    run evaluate_commit_semver "fix(api): fix null pointer in serializer"
    [ "$status" -eq 0 ]
    [ "$output" = "patch" ]
}

@test "evaluate_commit_semver falls back to patch for chore when bump opted in" {
    run evaluate_commit_semver "chore: update dependencies"
    [ "$status" -eq 0 ]
    [ "$output" = "patch" ]
}

@test "evaluate_commit_semver honors explicit level override" {
    run evaluate_commit_semver "chore: update dependencies" "minor"
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

# ─── aicommit CLI with --bump ────────────────────────────────────────────────

@test "aicommit --bump --dry-run previews SemVer plan without changes" {
    printf '{\n  "name": "my-tool",\n  "version": "1.2.0"\n}\n' > package.json
    touch new_feature.js
    git add new_feature.js

    run aicommit --bump --dry-run
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Plan"
    assert_output_contains "Current: 1.2.0"
    assert_output_contains "package.json"
    # Verify package.json wasn't modified in dry run
    grep -q '"version": "1.2.0"' package.json
    # Verify no tag was created
    [ -z "$(git tag -l)" ]
}

@test "aicommit --bump --yes updates package.json, commits, and creates git tag" {
    printf '{\n  "name": "my-tool",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial" >/dev/null 2>&1

    echo "console.log('hello');" > app.js
    git add app.js

    export AI_MODEL="test-model"
    mock_ollama_api 'feat(core): add greeting feature'

    run aicommit --bump --yes
    [ "$status" -eq 0 ]
    assert_output_contains "Tagged release: v1.1.0"
    assert_output_contains "package.json"

    # Verify version was updated in package.json
    grep -q '"version": "1.1.0"' package.json

    # Verify git tag exists
    run git tag -l
    assert_output_contains "v1.1.0"

    # Verify the commit itself contains the package.json update
    run git show --stat HEAD
    assert_output_contains "package.json"
}

@test "aicommit --bump with atomic split creates tag for each atomic commit" {
    printf '{\n  "name": "split-app",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial" >/dev/null 2>&1

    mkdir -p src/auth src/db
    echo "auth code" > src/auth/auth.js
    echo "db code" > src/db/db.js
    git add src/auth/auth.js src/db/db.js

    export AI_MODEL="test-model"
    mock_ollama_api 'feat(scope): add new functionality'

    run aicommit --split --bump --yes
    [ "$status" -eq 0 ]
    assert_output_contains "All atomic commits completed"
    assert_output_contains "Tagged release:"

    # Verify git tags were created
    local tag_count
    tag_count=$(git tag -l | count_lines)
    [ "$tag_count" -ge 2 ]
}

# ─── prompt_semver_decision ──────────────────────────────────────────────────

@test "prompt_semver_decision returns recommended bump on default enter" {
    run prompt_semver_decision "feat: add feature" "1.0.0" <<< ""
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "minor" ]
}

@test "prompt_semver_decision returns patch on option 2" {
    run prompt_semver_decision "feat: add feature" "1.0.0" <<< "2"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "patch" ]
}

@test "prompt_semver_decision returns major on option 4" {
    run prompt_semver_decision "fix: bug fix" "1.0.0" <<< "4"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "major" ]
}

@test "prompt_semver_decision returns skip on option 6" {
    run prompt_semver_decision "feat: add feature" "1.0.0" <<< "6"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "skip" ]
}

# ─── Shorthand Abbreviation Commands (non-interactive / CI/CD) ───────────────

@test "aics commits all-in-one non-interactively with SemVer bump and tag" {
    printf '{\n  "name": "aics-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "initial" >/dev/null 2>&1

    echo "console.log('aics');" > app.js
    git add app.js

    export AI_MODEL="test-model"
    mock_ollama_api 'feat: quick aics feature'

    run aics
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"
    assert_output_contains "Tagged release: v1.1.0"
    grep -q '"version": "1.1.0"' package.json
    [ "$(git tag -l 'v1.1.0')" = "v1.1.0" ]
}

@test "aiccs commits split scopes non-interactively with SemVer per atomic commit" {
    printf '{\n  "name": "aiccs-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "initial" >/dev/null 2>&1

    mkdir -p scripts docs
    echo "console.log('script');" > scripts/run.js
    echo "# Docs" > docs/README.md
    git add scripts/run.js docs/README.md

    export AI_MODEL="test-model"
    mock_ollama_api 'feat(scope): test scope'

    run aiccs
    [ "$status" -eq 0 ]
    assert_output_contains "All atomic commits completed!"
    assert_output_contains "Tagged release:"
    local tag_count
    tag_count=$(git tag -l | count_lines)
    [ "$tag_count" -ge 2 ]
}

# ─── Interactive SemVer Selection in aicommit ────────────────────────────────

@test "aicommit interactive session allows user to choose SemVer bump with 's'" {
    printf '{\n  "name": "interactive-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "initial" >/dev/null 2>&1

    echo "console.log('interactive');" > app.js
    git add app.js

    export AI_MODEL="test-model"
    mock_ollama_api 'feat: add interactive feature'

    # Send 's' to choose SemVer, then '1' for recommended bump (minor)
    run aicommit <<< $'s\n1'
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"
    assert_output_contains "Tagged release: v1.1.0"
    grep -q '"version": "1.1.0"' package.json
    [ "$(git tag -l 'v1.1.0')" = "v1.1.0" ]
}

@test "aicommit interactive session allows user to select custom bump level with 's=major'" {
    printf '{\n  "name": "interactive-pkg2",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "initial" >/dev/null 2>&1

    echo "console.log('interactive2');" > app.js
    git add app.js

    export AI_MODEL="test-model"
    mock_ollama_api 'fix: small bug fix'

    # Send 's=major' directly at prompt
    run aicommit <<< "s=major"
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"
    assert_output_contains "Tagged release: v2.0.0"
    grep -q '"version": "2.0.0"' package.json
    [ "$(git tag -l 'v2.0.0')" = "v2.0.0" ]
}

# ─── AI-Driven SemVer Evaluation ─────────────────────────────────────────────

@test "extract_semver_decision parses delimited response with rationale" {
    local raw="@@@
minor | added new authentication endpoint
@@@"
    run extract_semver_decision "$raw"
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "extract_semver_decision parses response with thinking block" {
    local raw="<think>Analyzing git diff... this introduces a breaking API change</think>
@@@
major | incompatible parameter removed
@@@"
    run extract_semver_decision "$raw"
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "extract_semver_decision parses plain word case-insensitively" {
    run extract_semver_decision "PATCH"
    [ "$status" -eq 0 ]
    [ "$output" = "patch" ]
}

@test "extract_semver_decision returns 1 on empty or invalid response" {
    run extract_semver_decision "I am not sure what version to bump"
    [ "$status" -eq 1 ]
}

@test "ai_evaluate_semver calls invoke_llm and returns extracted decision" {
    export AI_MODEL="test-model"
    mock_ollama_api '@@@
minor | new feature added
@@@'

    run ai_evaluate_semver "chore: update internal modules" ""
    [ "$status" -eq 0 ]
    [ "$output" = "minor" ]
}

@test "evaluate_commit_semver invokes AI when conventional commit heuristic is inconclusive" {
    export AI_MODEL="test-model"
    mock_ollama_api '@@@
major | breaking refactor
@@@'
    export AI_SEMVER_USE_AI="true"

    # Conventional commit 'refactor:' returns 'none' from suggest_semver_bump.
    # Therefore, AI evaluation is invoked and returns 'major'.
    run evaluate_commit_semver "refactor: restructure public API modules"
    [ "$status" -eq 0 ]
    [ "$output" = "major" ]
}

@test "evaluate_commit_semver honors explicit level 'ai'" {
    export AI_MODEL="test-model"
    mock_ollama_api '@@@
patch | minor maintenance
@@@'

    run evaluate_commit_semver "feat: some feature" "ai"
    [ "$status" -eq 0 ]
    [ "$output" = "patch" ]
}

@test "prompt_semver_decision asks AI when option 7 is selected" {
    export AI_MODEL="test-model"
    mock_ollama_api '@@@
minor | backward compatible addition
@@@'

    run prompt_semver_decision "refactor: internal changes" "1.0.0" <<< "7"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "minor" ]
}

@test "aicommit interactive session allows user to calculate SemVer via AI using 'a'" {
    printf '{\n  "name": "ai-semver-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "initial" >/dev/null 2>&1

    echo "console.log('ai-semver');" > app.js
    git add app.js

    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in */api/*) url="$a" ;; esac; done
case "$url" in
    */api/version)  echo '{"version":"0.40.1"}' ;;
    */api/tags)     echo '{"models":[{"name":"test-model"}]}' ;;
    */api/show|*/api/generate) echo '{}' ;;
    */api/chat)
        # First call generates the commit message; second calculates the bump
        if [ -f "$TEST_TEMP_DIR/first_run_done" ]; then
            jq -n --arg c '@@@
minor | new feature detected
@@@' '{message:{role:"assistant",content:$c}}'
        else
            touch "$TEST_TEMP_DIR/first_run_done"
            jq -n --arg c 'refactor(core): optimize engine performance' \
                '{message:{role:"assistant",content:$c}}'
        fi
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export AI_MODEL="test-model"

    # Send 'a' to calculate SemVer via AI
    run aicommit <<< "a"
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"
    assert_output_contains "Tagged release: v1.1.0"
    grep -q '"version": "1.1.0"' package.json
    [ "$(git tag -l 'v1.1.0')" = "v1.1.0" ]
}

# ─── apply_semver_file_updates ───────────────────────────────────────────────

@test "apply_semver_file_updates updates and stages detected version files" {
    printf '{\n  "name": "semver-apply-test",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial commit"

    run apply_semver_file_updates "1.0.0" "1.1.0"
    [ "$status" -eq 0 ]
    assert_output_contains "package.json"
    grep -q '"version": "1.1.0"' package.json

    # Check git staged status
    run git diff --staged --name-only
    [ "$status" -eq 0 ]
    assert_output_contains "package.json"
}

# ─── semver_gt ───────────────────────────────────────────────────────────────

@test "semver_gt accurately compares semantic versions and prereleases" {
    run semver_gt "1.1.0" "1.0.1"
    [ "$status" -eq 0 ]

    run semver_gt "2.0.0" "1.9.9"
    [ "$status" -eq 0 ]

    run semver_gt "1.0.1" "1.0.1"
    [ "$status" -eq 1 ]

    run semver_gt "1.0.0" "1.1.0"
    [ "$status" -eq 1 ]

    run semver_gt "1.0.0" "1.0.0-rc.1"
    [ "$status" -eq 0 ]

    run semver_gt "1.0.0-rc.1" "1.0.0"
    [ "$status" -eq 1 ]
}

# ─── get_last_version ────────────────────────────────────────────────────────

@test "get_last_version prioritizes highest git tag over modified working tree manifests" {
    printf '{\n  "name": "tag-pri-test",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial commit"
    git tag v1.0.0

    # Modify working tree to 1.0.1 (simulating failed prior commit)
    printf '{\n  "name": "tag-pri-test",\n  "version": "1.0.1"\n}\n' > package.json

    run get_last_version
    [ "$status" -eq 0 ]
    [ "$output" = "1.0.0" ]
}

@test "get_last_version falls back to committed HEAD manifests when no tags exist" {
    printf '{\n  "name": "head-fallback-test",\n  "version": "0.5.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial commit without tags"

    # Modify working tree to 0.5.1
    printf '{\n  "name": "head-fallback-test",\n  "version": "0.5.1"\n}\n' > package.json

    run get_last_version
    [ "$status" -eq 0 ]
    [ "$output" = "0.5.0" ]
}

@test "get_last_version falls back to working tree manifests before initial commit" {
    # Working tree before any commit
    printf '{\n  "name": "uncommitted-test",\n  "version": "0.2.0"\n}\n' > package.json

    run get_last_version
    [ "$status" -eq 0 ]
    [ "$output" = "0.2.0" ]
}

# ─── detect_changelog_file & update_changelog ───────────────────────────────

@test "detect_changelog_file detects existing changelog filename variants" {
    run detect_changelog_file
    [ "$status" -ne 0 ]

    touch HISTORY.md
    run detect_changelog_file
    [ "$status" -eq 0 ]
    [ "$output" = "HISTORY.md" ]
    rm -f HISTORY.md

    touch changelog.txt
    run detect_changelog_file
    [ "$status" -eq 0 ]
    [ "$output" = "changelog.txt" ]
    rm -f changelog.txt
}

@test "update_changelog creates new CHANGELOG.md and stages with git when none exists" {
    git init -q
    run update_changelog "1.1.0" "feat: add user profile authentication" "2026-10-07"
    [ "$status" -eq 0 ]
    [ -f "CHANGELOG.md" ]
    grep -q "## \[1.1.0\] - 2026-10-07" CHANGELOG.md
    grep -q -- "- feat: add user profile authentication" CHANGELOG.md

    # Verify staged with git
    run git diff --staged --name-only
    [ "$status" -eq 0 ]
    assert_output_contains "CHANGELOG.md"
}

@test "update_changelog idempotently appends to existing version section" {
    cat <<EOF > CHANGELOG.md
# Changelog

## [1.1.0] - 2026-10-07

- feat: initial feature
EOF
    git add CHANGELOG.md
    git commit -qm "add changelog"

    # Add second entry to same version
    run update_changelog "1.1.0" "fix: resolve token expiration" "2026-10-07"
    [ "$status" -eq 0 ]
    grep -q -- "- feat: initial feature" CHANGELOG.md
    grep -q -- "- fix: resolve token expiration" CHANGELOG.md

    # Idempotent retry: running again with same message does not duplicate bullet
    run update_changelog "1.1.0" "fix: resolve token expiration" "2026-10-07"
    [ "$status" -eq 0 ]
    [ $(grep -c -- "- fix: resolve token expiration" CHANGELOG.md) -eq 1 ]
}

# ─── resolve_effective_semver & apply_semver_release ─────────────────────────

@test "resolve_effective_semver detects when working tree version is strictly higher" {
    printf '{\n  "name": "effective-test",\n  "version": "2.0.0"\n}\n' > package.json

    run resolve_effective_semver "1.0.1"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0.0" ]

    run resolve_effective_semver "2.0.0"
    [ "$status" -eq 1 ]
    [ "$output" = "2.0.0" ]

    run resolve_effective_semver "2.1.0"
    [ "$status" -eq 1 ]
    [ "$output" = "2.1.0" ]
}

@test "apply_semver_release preserves higher version in manifests and updates changelog" {
    printf '{\n  "name": "preserve-test",\n  "version": "2.0.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial commit"

    # Evaluated target is 1.0.1, but effective target is 2.0.0
    run apply_semver_release "1.0.0" "2.0.0" "fix: minor fix" "1.0.1"
    [ "$status" -eq 0 ]

    # package.json remains 2.0.0 untouched
    grep -q '"version": "2.0.0"' package.json
    # changelog created and has 2.0.0
    grep -q "## \[2.0.0\]" CHANGELOG.md
    grep -q -- "- fix: minor fix" CHANGELOG.md
}

# ─── restore_semver_updates ──────────────────────────────────────────────────

@test "restore_semver_updates restores modified manifests and removes untracked changelog" {
    printf '{\n  "name": "restore-test",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial commit"

    # Modify package.json and create CHANGELOG.md
    printf '{\n  "name": "restore-test",\n  "version": "1.0.1"\n}\n' > package.json
    echo "# New Changelog" > CHANGELOG.md
    git add package.json CHANGELOG.md

    local files_to_restore="package.json
CHANGELOG.md"

    run restore_semver_updates "$files_to_restore"
    [ "$status" -eq 0 ]

    grep -q '"version": "1.0.0"' package.json
    [ ! -f "CHANGELOG.md" ]
}

@test "restore_semver_updates restores newline-separated files in bash" {
    printf '{\n  "name": "restore-test-nl",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial commit"

    # Modify package.json and create CHANGELOG.md
    printf '{\n  "name": "restore-test-nl",\n  "version": "1.0.1"\n}\n' > package.json
    echo "# New Changelog" > CHANGELOG.md
    git add package.json CHANGELOG.md

    local files_list="package.json
CHANGELOG.md"

    run restore_semver_updates "$files_list"
    [ "$status" -eq 0 ]

    grep -q '"version": "1.0.0"' package.json
    [ ! -f "CHANGELOG.md" ]
}

@test "restore_semver_updates reverts newline-separated files in zsh" {
    which zsh >/dev/null 2>&1 || skip "zsh not installed"
    printf '{\n  "name": "restore-test-zsh",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial commit"

    # Modify package.json and create CHANGELOG.md
    printf '{\n  "name": "restore-test-zsh",\n  "version": "1.0.1"\n}\n' > package.json
    echo "# New Changelog" > CHANGELOG.md
    git add package.json CHANGELOG.md

    local files_list="package.json
CHANGELOG.md"

    run zsh -c "
        export AICOMMIT_DIR='$AICOMMIT_DIR'
        source '$AICOMMIT_DIR/aicommit.sh'
        files=\"\$1\"
        restore_semver_updates \"\$files\"
    " _ "$files_list"
    [ "$status" -eq 0 ]

    grep -q '"version": "1.0.0"' package.json
    [ ! -f "CHANGELOG.md" ]
}

# ─── End-to-End Scenarios ────────────────────────────────────────────────────

@test "aicommit failed commit retry relies on git tag to avoid double bumping" {
    printf '{\n  "name": "retry-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial release"
    git tag v1.0.0

    # Simulate previous failed attempt that left package.json modified to 1.0.1
    printf '{\n  "name": "retry-pkg",\n  "version": "1.0.1"\n}\n' > package.json
    echo "console.log('retry');" > app.js
    git add app.js

    export AI_MODEL="test-model"
    mock_ollama_api 'fix: resolve null pointer exception'

    # Retry commit with --bump --yes
    run aicommit --bump --yes
    [ "$status" -eq 0 ]
    assert_output_contains "Tagged release: v1.0.1"
    refute_output_contains "v1.0.2"
    grep -q '"version": "1.0.1"' package.json
    [ "$(git tag -l 'v1.0.1')" = "v1.0.1" ]
    [ -z "$(git tag -l 'v1.0.2')" ]
}

@test "aicommit preserves manually pre-bumped higher version and updates changelog" {
    printf '{\n  "name": "prebump-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -qm "initial release"
    git tag v1.0.0

    # Developer manually pre-bumps to 2.0.0 in working tree
    printf '{\n  "name": "prebump-pkg",\n  "version": "2.0.0"\n}\n' > package.json
    echo "console.log('breaking');" > index.js
    git add package.json index.js

    export AI_MODEL="test-model"
    mock_ollama_api 'fix: patch fix under pre-bumped major'

    # Commit with --bump --yes. Even though message is fix (which evaluates to 1.0.1),
    # 2.0.0 must be preserved and changelog updated for 2.0.0.
    run aicommit --bump --yes
    [ "$status" -eq 0 ]
    assert_output_contains "Tagged release: v2.0.0"
    grep -q '"version": "2.0.0"' package.json
    grep -q "## \[2.0.0\]" CHANGELOG.md
    grep -q -- "- fix: patch fix under pre-bumped major" CHANGELOG.md
    [ "$(git tag -l 'v2.0.0')" = "v2.0.0" ]
}



