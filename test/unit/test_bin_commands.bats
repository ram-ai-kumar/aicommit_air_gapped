#!/usr/bin/env bats
# Unit Tests — bin/ CLI command wrappers & executables

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── File Existence, Non-Emptiness & Permissions ─────────────────────────────

@test "all 12 bin commands exist, are non-empty, and executable" {
    local commands=("aicommit" "aic" "aicc" "aicx" "aiccx" "aics" "aiccs" "aicsx" "aiccsx" "ais" "aisemver" "aisx")
    for cmd in "${commands[@]}"; do
        local bin_path="$AICOMMIT_DIR/bin/$cmd"
        [ -f "$bin_path" ] || { echo "Missing bin file: $bin_path"; return 1; }
        [ -s "$bin_path" ] || { echo "Empty bin file (0 bytes): $bin_path"; return 1; }
        [ -x "$bin_path" ] || { echo "Not executable: $bin_path"; return 1; }
    done
}

@test "all 12 bin commands have valid bash syntax" {
    local commands=("aicommit" "aic" "aicc" "aicx" "aiccx" "aics" "aiccs" "aicsx" "aiccsx" "ais" "aisemver" "aisx")
    for cmd in "${commands[@]}"; do
        run bash -n "$AICOMMIT_DIR/bin/$cmd"
        [ "$status" -eq 0 ]
    done
}

# ─── Direct CLI Execution: Help & Flag Forwarding ────────────────────────────

@test "bin/aicommit executes directly and displays help" {
    run "$AICOMMIT_DIR/bin/aicommit" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/aic executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aic" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/aicc executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aicc" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/aicx executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aicx" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/aiccx executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aiccx" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/aics executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aics" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/aiccs executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aiccs" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/aicsx executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aicsx" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/aiccsx executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aiccsx" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: aicommit [OPTIONS]"
}

@test "bin/ais executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/ais" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: ais"
}

@test "bin/aisemver executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aisemver" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: ais"
}

@test "bin/aisx executes directly and displays help when --help passed" {
    run "$AICOMMIT_DIR/bin/aisx" --help
    [ "$status" -eq 0 ]
    assert_output_contains "Usage: ais"
}

# ─── Direct CLI Execution: Dry-Run Workflows ─────────────────────────────────

@test "bin/aicx executes dry-run preview with 0 changes made" {
    echo "console.log('aicx');" > app.js
    git add app.js
    run "$AICOMMIT_DIR/bin/aicx"
    [ "$status" -eq 0 ]
    assert_output_contains "Dry run"
    # Verify no commits were made
    run git log -1
    [ "$status" -ne 0 ]
}

@test "bin/aiccx executes split dry-run preview with 0 changes made" {
    echo "console.log('aiccx');" > app.js
    echo "# aiccx docs" > README.md
    git add app.js README.md
    run "$AICOMMIT_DIR/bin/aiccx"
    [ "$status" -eq 0 ]
    assert_output_contains "Dry run"
    # Verify no commits were made
    run git log -1
    [ "$status" -ne 0 ]
}

@test "bin/aicsx executes dry-run preview with SemVer evaluation" {
    printf '{\n  "name": "aicsx-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    echo "console.log('aicsx');" > app.js
    git add package.json app.js
    run "$AICOMMIT_DIR/bin/aicsx"
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Plan"
    # Verify no commits or tags were made
    run git tag -l
    [ "$output" = "" ]
}

@test "bin/aiccsx executes split dry-run preview with SemVer evaluation" {
    printf '{\n  "name": "aiccsx-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    echo "console.log('aiccsx');" > app.js
    git add package.json app.js
    run "$AICOMMIT_DIR/bin/aiccsx"
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Plan"
}

# ─── Direct CLI Execution: Non-Interactive Commits via Mock LLM ──────────────

@test "bin/aic executes non-interactive all-in-one commit" {
    mock_ollama_api 'feat: bin aic commit'
    echo "console.log('aic test');" > app.js
    git add app.js
    run "$AICOMMIT_DIR/bin/aic"
    [ "$status" -eq 0 ]
    assert_output_contains "Committed!"
    run git log -1 --pretty=%B
    assert_output_contains "feat: bin aic commit"
}

@test "bin/aicc executes non-interactive split commit" {
    mock_ollama_api 'docs: update readme'
    echo "# Readme" > README.md
    git add README.md
    run "$AICOMMIT_DIR/bin/aicc"
    [ "$status" -eq 0 ]
    assert_output_contains "Committed"
}

@test "bin/aics executes non-interactive commit with SemVer bump and git tag" {
    mock_ollama_api 'feat: bin aics test'
    printf '{\n  "name": "aics-bin-pkg",\n  "version": "1.0.0"\n}\n' > package.json
    echo "console.log('aics bin');" > app.js
    git add package.json app.js
    run "$AICOMMIT_DIR/bin/aics"
    [ "$status" -eq 0 ]
    assert_output_contains "Tagged release: v1.1.0"
    run git tag -l
    assert_output_contains "v1.1.0"
}

@test "bin/aiccs executes non-interactive split commit with SemVer bump" {
    mock_ollama_api 'fix: bin aiccs bug'
    printf '{\n  "name": "aiccs-bin-pkg",\n  "version": "2.0.0"\n}\n' > package.json
    echo "fix content" > app.js
    git add package.json app.js
    run "$AICOMMIT_DIR/bin/aiccs"
    [ "$status" -eq 0 ]
    assert_output_contains "Tagged release: v2.0.1"
    run git tag -l
    assert_output_contains "v2.0.1"
}

@test "bin/aisx executes standalone SemVer dry-run preview with 0 changes made" {
    printf '{\n  "name": "aisx-bin-pkg",\n  "version": "1.4.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial commit"
    run "$AICOMMIT_DIR/bin/aisx" patch
    [ "$status" -eq 0 ]
    assert_output_contains "aisemver Dry-Run Preview"
    assert_output_contains "1.4.0 -> 1.4.1"
    # Verify no commits or tags were made and file was not modified
    run git status --porcelain
    [ "$output" = "" ]
    run git tag -l
    [ "$output" = "" ]
}

@test "bin/ais executes standalone SemVer bump non-interactively with tag and commit" {
    printf '{\n  "name": "ais-bin-pkg",\n  "version": "3.1.0"\n}\n' > package.json
    git add package.json
    git commit -m "chore: initial pkg"
    run "$AICOMMIT_DIR/bin/ais" minor -y
    [ "$status" -eq 0 ]
    assert_output_contains "SemVer Release Successful!"
    assert_output_contains "v3.2.0"
    run git tag -l
    assert_output_contains "v3.2.0"
    run git log -1 --pretty=%B
    assert_output_contains "chore(release): v3.2.0"
    # Verify package.json updated
    run grep '"version": "3.2.0"' package.json
    [ "$status" -eq 0 ]
    # Verify CHANGELOG.md updated
    [ -f CHANGELOG.md ]
    run grep '\[3.2.0\]' CHANGELOG.md
    [ "$status" -eq 0 ]
}
