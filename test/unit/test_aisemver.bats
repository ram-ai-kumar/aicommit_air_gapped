#!/usr/bin/env bats
# Unit Tests — ais (aisemver) command & standalone semantic versioning

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── Help & CLI Option Parsing ───────────────────────────────────────────────

@test "ais --help displays standalone semver options" {
    run ais --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: ais [OPTIONS] [major|minor|patch|auto|<version>]"
    assert_output_contains "Standalone Semantic Versioning"
    assert_output_contains "--dry-run"
    assert_output_contains "--no-commit"
    assert_output_contains "--no-tag"
}

@test "aisemver is an alias of ais" {
    run aisemver --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: ais"
}

@test "aisx --help displays help" {
    run aisx --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: ais"
}

# ─── Dry-Run Inspection (0 changes made) ─────────────────────────────────────

@test "aisx previews patch bump without modifying files, staging, or committing" {
    printf '{\n  "name": "preview-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial"

    run aisx patch
    [ "$status" -eq 0 ]
    assert_output_contains "aisemver Dry-Run Preview"
    assert_output_contains "1.0.0 -> 1.0.1"
    assert_output_contains "package.json (1.0.0 -> 1.0.1)"

    # Verify no files were modified
    run git status --porcelain
    [ "$output" = "" ]
    run git tag -l
    [ "$output" = "" ]
}

@test "ais --dry-run previews explicit version target" {
    printf '{\n  "name": "preview-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial"

    run ais --dry-run 2.0.0
    [ "$status" -eq 0 ]
    assert_output_contains "1.0.0 -> 2.0.0"
    run git status --porcelain
    [ "$output" = "" ]
}

# ─── Standalone Bumping: Patch, Minor, Major, and Explicit ───────────────────

@test "ais patch -y bumps patch version, stages, commits, and tags" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.2.3"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais patch -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v1.2.4"

    # Verify manifest content
    run grep '"version": "1.2.4"' package.json
    [ "$status" -eq 0 ]

    # Verify git tag and commit
    run git tag -l
    assert_output_contains "v1.2.4"
    run git log -1 --pretty=%B
    assert_output_contains "chore(release): v1.2.4"

    # Verify CHANGELOG.md was created and populated
    [ -f CHANGELOG.md ]
    run grep '\[1.2.4\]' CHANGELOG.md
    [ "$status" -eq 0 ]
}

@test "ais minor -y bumps minor version and resets patch" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.2.3"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais minor -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v1.3.0"

    run grep '"version": "1.3.0"' package.json
    [ "$status" -eq 0 ]
    run git tag -l
    assert_output_contains "v1.3.0"
}

@test "ais major -y bumps major version and resets minor and patch" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.2.3"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais major -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v2.0.0"

    run grep '"version": "2.0.0"' package.json
    [ "$status" -eq 0 ]
    run git tag -l
    assert_output_contains "v2.0.0"
}

@test "ais with explicit target version sets exact version" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais 3.5.0 -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v3.5.0"

    run grep '"version": "3.5.0"' package.json
    [ "$status" -eq 0 ]
    run git tag -l
    assert_output_contains "v3.5.0"
}

@test "ais --set=X.Y.Z sets exact version" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais --set=4.0.0 -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v4.0.0"

    run grep '"version": "4.0.0"' package.json
    [ "$status" -eq 0 ]
}

# ─── Automatic Bump Evaluation from Commits ──────────────────────────────────

@test "ais --auto -y evaluates minor bump from conventional feat commit" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"
    git tag -a v1.0.0 -m "Release v1.0.0"

    echo "new feature code" > feature.js
    git add feature.js
    git commit -m "feat(ui): add brand new navigation bar"

    run ais --auto -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v1.1.0"

    run grep '"version": "1.1.0"' package.json
    [ "$status" -eq 0 ]
}

@test "ais --auto -y evaluates major bump from breaking change commit" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"
    git tag -a v1.0.0 -m "Release v1.0.0"

    echo "breaking change" > api.js
    git add api.js
    git commit -m "feat!: redesign authentication API with breaking change"

    run ais --auto -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v2.0.0"

    run grep '"version": "2.0.0"' package.json
    [ "$status" -eq 0 ]
}

# ─── Flags & Git Override Controls ───────────────────────────────────────────

@test "ais --no-commit stages changes but does not create git commit or tag" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais patch --no-commit -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer files updated and staged successfully!"
    refute_output_contains "Commit:"
    refute_output_contains "Git tag:"

    # Files should be staged in git
    run git diff --cached --name-only
    assert_output_contains "package.json"
    assert_output_contains "CHANGELOG.md"

    # No tag created
    run git tag -l
    [ "$output" = "" ]
}

@test "ais --no-tag creates release commit without creating git tag" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais patch --no-tag -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "Commit:     chore(release): v1.0.1"
    refute_output_contains "Git tag:"

    run git tag -l
    [ "$output" = "" ]
    run git log -1 --pretty=%B
    assert_output_contains "chore(release): v1.0.1"
}

@test "ais --no-stage updates files on disk without staging them in git" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais patch --no-stage -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer files updated successfully (unstaged)!"

    # Manifest updated
    run grep '"version": "1.0.1"' package.json
    [ "$status" -eq 0 ]

    # But not staged in git
    run git diff --cached --name-only
    [ "$output" = "" ]
    run git diff --name-only
    assert_output_contains "package.json"
}

@test "ais --no-changelog bumps manifests without modifying or creating CHANGELOG.md" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais patch --no-changelog -y
    [ "$status" -eq 0 ]
    [ ! -f CHANGELOG.md ]

    run grep '"version": "1.0.1"' package.json
    [ "$status" -eq 0 ]
}

# ─── Changelog Categorization & Unreleased Section ───────────────────────────

@test "ais categorizes conventional commits under Keep a Changelog headers" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"
    git tag -a v1.0.0 -m "Release v1.0.0"

    echo "feature" > feat.txt
    git add feat.txt
    git commit -m "feat(auth): add OAuth2 provider login"

    echo "fix" > fix.txt
    git add fix.txt
    git commit -m "fix(db): resolve database connection leak"

    echo "perf" > perf.txt
    git add perf.txt
    git commit -m "perf(cache): optimize redis cache eviction"

    run ais minor -y
    [ "$status" -eq 0 ]

    [ -f CHANGELOG.md ]
    run cat CHANGELOG.md
    assert_output_contains "### Added"
    assert_output_contains "add OAuth2 provider login"
    assert_output_contains "### Fixed"
    assert_output_contains "resolve database connection leak"
    assert_output_contains "### Performance"
    assert_output_contains "optimize redis cache eviction"
}

@test "ais converts existing ## [Unreleased] section in CHANGELOG.md" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    cat <<'EOF' > CHANGELOG.md
# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Pre-existing unreleased feature description.

## [1.0.0] - 2026-01-01
- Initial release.
EOF
    git add package.json CHANGELOG.md
    git commit -m "chore: init with existing changelog"
    git tag -a v1.0.0 -m "v1.0.0"

    run ais minor -y
    [ "$status" -eq 0 ]

    run cat CHANGELOG.md
    assert_output_contains "## [Unreleased]"
    assert_output_contains "## [1.1.0] - "
    assert_output_contains "Pre-existing unreleased feature description."
    assert_output_contains "## [1.0.0] - 2026-01-01"
}

@test "ais -m uses custom message in changelog notes" {
    printf '{\n  "name": "test-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: init"

    run ais patch -m "Urgent hotfix for memory leak in worker pool" -y
    [ "$status" -eq 0 ]

    run cat CHANGELOG.md
    assert_output_contains "Urgent hotfix for memory leak in worker pool"
}

# ─── Polyglot & Multi-Language Manifest Detection & Bumping ──────────────────

@test "ais updates polyglot workspace with Node, Python, Rust, and Go simultaneously" {
    # 1. Root package.json
    printf '{\n  "name": "root-monorepo",\n  "version": "1.0.0"\n}\n' > package.json
    # 2. Python subpackage
    mkdir -p backend
    cat <<'EOF' > backend/pyproject.toml
[project]
name = "backend-api"
version = "1.0.0"
dependencies = []
EOF
    # 3. Rust subpackage
    mkdir -p core
    cat <<'EOF' > core/Cargo.toml
[package]
name = "core-engine"
version = "1.0.0"
edition = "2021"
EOF
    # 4. Go service
    mkdir -p services/auth
    cat <<'EOF' > services/auth/version.go
package auth

const Version = "1.0.0"
EOF
    # 5. Ignored dependency directory (should NOT be updated)
    mkdir -p node_modules/external-dep
    printf '{\n  "name": "external-dep",\n  "version": "1.0.0"\n}\n' > node_modules/external-dep/package.json

    git add .
    git commit -m "chore: init polyglot repo"

    run ais minor -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v1.1.0"

    # Verify all 4 manifests were bumped to 1.1.0
    run grep '"version": "1.1.0"' package.json
    [ "$status" -eq 0 ]

    run grep 'version = "1.1.0"' backend/pyproject.toml
    [ "$status" -eq 0 ]

    run grep 'version = "1.1.0"' core/Cargo.toml
    [ "$status" -eq 0 ]

    run grep 'const Version = "1.1.0"' services/auth/version.go
    [ "$status" -eq 0 ]

    # Verify node_modules was pruned and left untouched at 1.0.0
    run grep '"version": "1.0.0"' node_modules/external-dep/package.json
    [ "$status" -eq 0 ]
}

# ─── CI/CD Non-Interactive Defaults vs Interactive Prompting ──────────────────

@test "ais works without -y and without prompt using safe defaults in CI/CD pipelines" {
    printf '{\n  "name": "cicd-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial"
    git tag -a v1.0.0 -m "Release v1.0.0"

    echo "fix bug" > fix.js
    git add fix.js
    git commit -m "fix(core): resolve null pointer exception"

    # ais runs without -y and without prompt (non-interactive default for CI/CD)
    run ais
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v1.0.1"
    run grep '"version": "1.0.1"' package.json
    [ "$status" -eq 0 ]
    run git tag -l
    assert_output_contains "v1.0.1"
}

@test "ais patch works without -y and without prompt in CI/CD pipelines" {
    printf '{\n  "name": "cicd-patch-pkg",\n  "version": "2.1.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial"

    run ais patch
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v2.1.1"
    run grep '"version": "2.1.1"' package.json
    [ "$status" -eq 0 ]
}

@test "aisx works without -y and without prompt using safe defaults in CI/CD pipelines" {
    printf '{\n  "name": "cicd-aisx-pkg",\n  "version": "1.5.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial"

    run aisx
    [ "$status" -eq 0 ]
    assert_output_contains "aisemver Dry-Run Preview"
    assert_output_contains "1.5.0 -> 1.5.1"

    # Verify no files were modified or tagged
    run git status --porcelain
    [ "$output" = "" ]
    run git tag -l
    [ "$output" = "" ]
}

@test "aisemver prompts user for bump level and confirmation before release" {
    printf '{\n  "name": "interactive-aisemver-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial"

    # Provide option 2 (patch) and confirmation 'y' via stdin
    run aisemver <<< $'2\ny'
    [ "$status" -eq 0 ]
    assert_output_contains "aisemver — Semantic Versioning Release"
    assert_output_contains "aisemver — Release Confirmation"
    assert_output_contains "Proceed with SemVer release?"
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v1.0.1"

    run grep '"version": "1.0.1"' package.json
    [ "$status" -eq 0 ]
    run git tag -l
    assert_output_contains "v1.0.1"
}

@test "aisemver prompts user and aborts cleanly when user cancels confirmation" {
    printf '{\n  "name": "interactive-abort-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial"

    # Provide option 2 (patch) then 'n' to abort confirmation
    run aisemver <<< $'2\nn'
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer release cancelled"

    # Verify no changes were made
    run git status --porcelain
    [ "$output" = "" ]
    run git tag -l
    [ "$output" = "" ]
}

@test "aisemver with -y bypasses prompts and applies release" {
    printf '{\n  "name": "aisemver-yes-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial"

    run aisemver patch -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v1.0.1"
    run grep '"version": "1.0.1"' package.json
    [ "$status" -eq 0 ]
}

@test "aicommit interactive session supports typing aisemver at confirmation prompt" {
    printf '{\n  "name": "aicommit-aisemver-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "initial" >/dev/null 2>&1

    echo "console.log('test');" > app.js
    git add app.js

    export AI_MODEL="test-model"
    mock_ollama_api 'feat: add brand new test feature'

    # Send 'aisemver' to invoke SemVer decision, then '1' for recommended bump (minor)
    run aicommit <<< $'aisemver\n1'
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"
    assert_output_contains "Tagged release: v1.1.0"
    run grep '"version": "1.1.0"' package.json
    [ "$status" -eq 0 ]
    [ "$(git tag -l 'v1.1.0')" = "v1.1.0" ]
}

@test "aicommit interactive session supports typing ais at confirmation prompt" {
    printf '{\n  "name": "aicommit-ais-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    git add package.json
    git commit -m "initial" >/dev/null 2>&1

    echo "console.log('test ais');" > app.js
    git add app.js

    export AI_MODEL="test-model"
    mock_ollama_api 'fix: fix broken test bug'

    # Send 'ais' to invoke SemVer decision, then '1' for recommended bump (patch)
    run aicommit <<< $'ais\n1'
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"
    assert_output_contains "Tagged release: v1.0.1"
    run grep '"version": "1.0.1"' package.json
    [ "$status" -eq 0 ]
    [ "$(git tag -l 'v1.0.1')" = "v1.0.1" ]
}

