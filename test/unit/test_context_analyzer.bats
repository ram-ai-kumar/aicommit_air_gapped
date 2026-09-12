#!/usr/bin/env bats
# Unit Tests — lib/context-analyzer.sh (6 functions)

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── detect_project_type ─────────────────────────────────────────────────────

@test "detect_project_type returns rails/ruby when Gemfile is present" {
    touch Gemfile
    run detect_project_type ""
    [ "$status" -eq 0 ]
    [ "$output" = "rails/ruby" ]
}

@test "detect_project_type returns node/javascript when package.json is present" {
    touch package.json
    run detect_project_type ""
    [ "$status" -eq 0 ]
    [ "$output" = "node/javascript" ]
}

@test "detect_project_type returns python when requirements.txt is present" {
    touch requirements.txt
    run detect_project_type ""
    [ "$status" -eq 0 ]
    [ "$output" = "python" ]
}

@test "detect_project_type returns go when go.mod staged" {
    run detect_project_type "go.mod"
    [ "$status" -eq 0 ]
    [ "$output" = "go" ]
}

@test "detect_project_type returns rust when Cargo.toml staged" {
    run detect_project_type "Cargo.toml"
    [ "$status" -eq 0 ]
    [ "$output" = "rust" ]
}

@test "detect_project_type returns java when pom.xml staged" {
    run detect_project_type "pom.xml"
    [ "$status" -eq 0 ]
    [ "$output" = "java" ]
}

@test "detect_project_type returns unknown for generic files" {
    run detect_project_type "src/main.c"
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "detect_project_type prefers Gemfile over package.json" {
    touch Gemfile package.json
    run detect_project_type ""
    [ "$output" = "rails/ruby" ]
}

# ─── analyze_change_concentration ────────────────────────────────────────────

@test "analyze_change_concentration returns |0|0 for empty input" {
    run analyze_change_concentration ""
    [ "$status" -eq 0 ]
    assert_output_contains "|0|0"
}

@test "analyze_change_concentration returns 100 percent for single file" {
    run analyze_change_concentration "src/main.sh"
    [ "$status" -eq 0 ]
    assert_output_contains "|100"
}

@test "analyze_change_concentration identifies top directory" {
    local files
    files="$(printf 'lib/core.sh\nlib/utils.sh\nlib/helpers.sh\nsrc/main.sh')"
    run analyze_change_concentration "$files"
    [ "$status" -eq 0 ]
    assert_output_contains "lib"
}

# ─── detect_new_files_ratio ──────────────────────────────────────────────────

@test "detect_new_files_ratio returns zeros when no staged files" {
    run detect_new_files_ratio ""
    [ "$status" -eq 0 ]
    [ "$output" = "0|0|0" ]
}

@test "detect_new_files_ratio detects newly added file" {
    echo "content" > new_file.sh
    git add new_file.sh
    local staged
    staged=$(git diff --staged --name-only)
    run detect_new_files_ratio "$staged"
    [ "$status" -eq 0 ]
    # Format: new|total|percent — with 1 new file, should contain "1|"
    assert_output_contains "1|"
}

# ─── detect_upgrade_pattern ──────────────────────────────────────────────────

@test "detect_upgrade_pattern returns dependency_upgrade for dep+lockfile" {
    local files
    files="$(printf 'package.json\npackage-lock.json')"
    run detect_upgrade_pattern "$files"
    [ "$status" -eq 0 ]
    [ "$output" = "dependency_upgrade" ]
}

@test "detect_upgrade_pattern returns migration for db/migrate path" {
    local files
    files="db/migrate/001_create_users.rb"
    run detect_upgrade_pattern "$files"
    [ "$status" -eq 0 ]
    [ "$output" = "migration" ]
}

@test "detect_upgrade_pattern returns none for pure source changes" {
    local files
    files="$(printf 'src/main.sh\nlib/core.sh')"
    run detect_upgrade_pattern "$files"
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "detect_upgrade_pattern returns framework_upgrade for dep+config changes" {
    local files
    files="$(printf 'package.json\nconfig/app.yml')"
    run detect_upgrade_pattern "$files"
    [ "$status" -eq 0 ]
    [ "$output" = "framework_upgrade" ]
}

# ─── categorize_staged_files ─────────────────────────────────────────────────

@test "categorize_staged_files produces FILE CATEGORIES header" {
    run categorize_staged_files "src/app.sh" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    assert_output_contains "FILE CATEGORIES"
}

@test "categorize_staged_files classifies source files" {
    local files
    files="$(printf 'src/main.sh\nlib/core.sh')"
    run categorize_staged_files "$files" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    assert_output_contains "Functional Source"
}

@test "categorize_staged_files classifies test files" {
    local files
    files="$(printf 'tests/test_core.sh\nsrc/app.sh')"
    run categorize_staged_files "$files" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    assert_output_contains "Tests"
}

@test "categorize_staged_files classifies documentation files" {
    local files
    files="$(printf 'README.md\ndocs/guide.md')"
    run categorize_staged_files "$files" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    assert_output_contains "Documentation"
}

@test "categorize_staged_files classifies config files" {
    local files
    files="$(printf 'config/app.yml\nsettings.json')"
    run categorize_staged_files "$files" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    assert_output_contains "Configuration"
}

@test "categorize_staged_files excludes .env files from output" {
    local files
    files="$(printf '.env\n.env.production\nsrc/app.sh')"
    run categorize_staged_files "$files" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    refute_output_contains ".env"
}

@test "categorize_staged_files classifies infra files" {
    local files
    files="$(printf '.github/workflows/ci.yml\nDockerfile')"
    run categorize_staged_files "$files" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    assert_output_contains "Infrastructure"
}

@test "categorize_staged_files handles empty input" {
    run categorize_staged_files "" "$TEST_TEMP_DIR"
    [ "$status" -eq 0 ]
    assert_output_contains "FILE CATEGORIES"
}

# ─── build_enhanced_context ──────────────────────────────────────────────────

@test "build_enhanced_context returns ENHANCED CONTEXT header" {
    echo "content" > app.js
    git add app.js
    local staged changes
    staged=$(git diff --staged --name-only)
    changes=$(git diff --staged)
    run build_enhanced_context "$staged" "$changes"
    [ "$status" -eq 0 ]
    assert_output_contains "ENHANCED CONTEXT"
}

@test "build_enhanced_context includes Project Type line" {
    echo "content" > app.js
    git add app.js
    local staged changes
    staged=$(git diff --staged --name-only)
    changes=$(git diff --staged)
    run build_enhanced_context "$staged" "$changes"
    assert_output_contains "Project Type"
}

@test "build_enhanced_context includes Focus Directory line" {
    echo "content" > app.js
    git add app.js
    local staged changes
    staged=$(git diff --staged --name-only)
    changes=$(git diff --staged)
    run build_enhanced_context "$staged" "$changes"
    assert_output_contains "Focus Directory"
}

# ─── Scope Inference and Grouping ─────────────────────────────────────────────

@test "infer_file_scope identifies config files" {
    run infer_file_scope "eslint.config.js"
    [ "$output" = "config" ]
    run infer_file_scope "pnpm-workspace.yaml"
    [ "$output" = "config" ]
}

@test "infer_file_scope identifies scripts" {
    run infer_file_scope "scripts/validate-html.js"
    [ "$output" = "scripts" ]
    run infer_file_scope "bin/deploy.sh"
    [ "$output" = "scripts" ]
}

@test "infer_file_scope identifies seo and schema files" {
    run infer_file_scope "src/components/Schema.astro"
    [ "$output" = "seo" ]
    run infer_file_scope "public/.well-known/acme-challenge/test"
    [ "$output" = "seo" ]
}

@test "group_staged_files_by_scope clusters files into distinct scopes" {
    local files
    files="$(printf 'eslint.config.js\npnpm-workspace.yaml\nscripts/validate-html.js\nscripts/validate-markdown.js\nsrc/components/Schema.astro\npublic/.well-known/acme-challenge/sample')"
    run group_staged_files_by_scope "$files"
    [ "$status" -eq 0 ]
    assert_output_contains "config|eslint.config.js,pnpm-workspace.yaml"
    assert_output_contains "scripts|scripts/validate-html.js,scripts/validate-markdown.js"
    assert_output_contains "seo|src/components/Schema.astro,public/.well-known/acme-challenge/sample"
}

@test "count_staged_scopes counts distinct scopes correctly" {
    local files
    files="$(printf 'eslint.config.js\npnpm-workspace.yaml\nscripts/validate-html.js\nscripts/validate-markdown.js\nsrc/components/Schema.astro')"
    run count_staged_scopes "$files"
    [ "$status" -eq 0 ]
    [ "$output" -eq 3 ]
}
