#!/usr/bin/env bats
# Unit Tests — lib/context-analyzer.sh

setup() {
    source "$(dirname "$BATS_TEST_FILENAME")/../test_helper.sh"
    setup_test_env
}

teardown() {
    cleanup_test_env
}

# ─── is_sensitive_path ───────────────────────────────────────────────────────

@test "is_sensitive_path flags env, keys, secrets, credentials" {
    run is_sensitive_path ".env"
    [ "$status" -eq 0 ]
    run is_sensitive_path ".env.production"
    [ "$status" -eq 0 ]
    run is_sensitive_path "config/settings.key"
    [ "$status" -eq 0 ]
    run is_sensitive_path "mysecrets.txt"
    [ "$status" -eq 0 ]
    run is_sensitive_path "src/app.js"
    [ "$status" -eq 1 ]
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

# ─── infer_file_scope ─────────────────────────────────────────────────────────

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

@test "infer_file_scope identifies core, prompt, and test scopes" {
    run infer_file_scope "aicommit.sh"
    [ "$output" = "core" ]
    run infer_file_scope "lib/core.sh"
    [ "$output" = "core" ]
    run infer_file_scope "templates/prompt.txt"
    [ "$output" = "prompt" ]
    run infer_file_scope "test/unit/test_core.bats"
    [ "$output" = "test" ]
}

# ─── infer_logical_file_context (generic, project-agnostic) ──────────────────

@test "infer_logical_file_context maps generic categories" {
    run infer_logical_file_context "test/unit/test_core.bats"
    [ "$output" = "test" ]
    run infer_logical_file_context "README.md"
    [ "$output" = "docs" ]
    run infer_logical_file_context ".github/workflows/ci.yml"
    [ "$output" = "ci" ]
    run infer_logical_file_context "db/migrate/001_init.sql"
    [ "$output" = "db" ]
    run infer_logical_file_context "lib/core.sh"
    [ "$output" = "core" ]
    run infer_logical_file_context "scripts/deploy.sh"
    [ "$output" = "scripts" ]
}

# ─── cluster_staged_files_deterministic ──────────────────────────────────────

@test "cluster_staged_files_deterministic pairs test files with subjects by stem" {
    local files
    files="$(printf 'lib/core.sh\ntest/unit/test_core.bats\nREADME.md\n.github/workflows/test.yml')"
    run cluster_staged_files_deterministic "$files"
    [ "$status" -eq 0 ]
    # core+test paired; docs and ci remain their own components
    assert_output_contains $'1\t.github/workflows/test.yml'
    assert_output_contains $'2\tREADME.md'
    assert_output_contains $'3\tlib/core.sh\ttest/unit/test_core.bats'
    [ "$(printf '%s' "$output" | count_lines)" -eq 3 ]
}

@test "cluster_staged_files_deterministic binds same-dir singletons together" {
    local files
    files="$(printf 'app/models/product.rb\napp/models/spare.rb\nREADME.md')"
    run cluster_staged_files_deterministic "$files"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | count_lines)" -eq 2 ]
    assert_output_contains $'app/models/product.rb\tapp/models/spare.rb'
}

@test "cluster_staged_files_deterministic joins files sharing a changed symbol" {
    local files diff_file
    files="$(printf 'lib/api.sh\nscripts/client.sh\ntools/unrelated.sh')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'EOF'
diff --git a/lib/api.sh b/lib/api.sh
+authenticate_session() {
+    check_token
+}
diff --git a/scripts/client.sh b/scripts/client.sh
+    authenticate_session --refresh
diff --git a/tools/unrelated.sh b/tools/unrelated.sh
+    echo hi
EOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | count_lines)" -eq 2 ]
    assert_output_contains $'lib/api.sh\tscripts/client.sh'
}

@test "cluster_staged_files_deterministic joins co-changed file pairs" {
    local files cochange
    files="$(printf 'src/auth.js\nsrc/session.js\nother/random.js')"
    cochange="$TEST_TEMP_DIR/COCHANGE"
    printf 'deadbeefsha\nsrc/auth.js\tsrc/session.js\t5\n' > "$cochange"
    run cluster_staged_files_deterministic "$files" "" "$cochange"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | count_lines)" -eq 2 ]
    assert_output_contains $'src/auth.js\tsrc/session.js'
}

@test "cluster_staged_files_deterministic is byte-identical on repeated runs" {
    local files
    files="$(printf 'a/b/one.js\nc/d/two.js\ne/f/three.js\na/b/four.js')"
    local r1 r2
    r1=$(cluster_staged_files_deterministic "$files")
    r2=$(cluster_staged_files_deterministic "$files")
    [ "$r1" = "$r2" ]
}

# ─── group_staged_files_* (deterministic naming) ─────────────────────────────

@test "group_staged_files_heuristically returns empty for empty input" {
    run group_staged_files_heuristically ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "group_staged_files_heuristically names deterministic components" {
    local files
    files="$(printf 'lib/core.sh\ntest/unit/test_core.bats\nREADME.md\n.github/workflows/test.yml')"
    run group_staged_files_heuristically "$files"
    [ "$status" -eq 0 ]
    assert_output_contains $'ci\t.github/workflows/test.yml'
    assert_output_contains $'docs\tREADME.md'
    assert_output_contains $'core\tlib/core.sh\ttest/unit/test_core.bats'
}

@test "group_staged_files_by_scope clusters disjoint files into named groups" {
    local files
    files="$(printf 'eslint.config.js\npnpm-workspace.yaml\nscripts/validate-html.js\nscripts/validate-markdown.js\nsrc/components/Schema.astro\npublic/.well-known/acme-challenge/sample')"
    run group_staged_files_by_scope "$files"
    [ "$status" -eq 0 ]
    # scripts/* pair shares a leaf dir; the rest are singletons
    assert_output_contains $'scripts\tscripts/validate-html.js\tscripts/validate-markdown.js'
    assert_output_contains $'config\teslint.config.js'
    assert_output_contains $'seo\tpublic/.well-known/acme-challenge/sample'
}

@test "group_staged_files_logically pairs model tests with subjects" {
    local files
    files="$(printf 'config/initializers/apartment.rb\ntest/integration/tenant_switching_test.rb\napp/models/product.rb\napp/models/spare.rb\ndocs/plans/index.md')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    # app/models pair joins via leaf dir; the rest stay separate
    assert_output_contains $'app/models/product.rb\tapp/models/spare.rb'
    assert_output_contains $'docs/plans/index.md'
}

@test "group_staged_files_logically returns a single named group for one file" {
    run group_staged_files_logically "README.md"
    [ "$status" -eq 0 ]
    assert_output_contains $'docs\tREADME.md'
}

@test "group_staged_files_logically covers every staged file exactly once" {
    local files
    files="$(printf 'a/one.js\nb/two.js\nc/three.md\nd/four.yml')"
    local groups
    groups=$(group_staged_files_logically "$files")
    local seen
    seen=$(printf '%s\n' "$groups" | cut -f2- | tr '\t' '\n' | sort)
    [ "$seen" = "$(printf '%s\n' "$files" | sort)" ]
}

# ─── reconcile_grouping_json ─────────────────────────────────────────────────

@test "reconcile_grouping_json assigns every staged file exactly once" {
    local staged="app/models/product.rb\napp/models/spare.rb\nconfig/initializers/devise.rb\nmissed_file.txt"
    local comp="1\tapp/models/product.rb\tapp/models/spare.rb
2\tconfig/initializers/devise.rb
3\tmissed_file.txt"
    local raw='{"groups":[
      {"name":"product models","type":"feat","files":["app/models/product.rb","app/models/spare.rb","hallucinated_file.rb"]},
      {"name":"auth config","type":"feat","files":["config/initializers/devise.rb"]}]}'
    run reconcile_grouping_json "$raw" "$(printf '%b' "$staged")" "$comp"
    [ "$status" -eq 0 ]
    assert_output_contains $'product models\tapp/models/product.rb\tapp/models/spare.rb'
    assert_output_contains $'auth config\tconfig/initializers/devise.rb'
    refute_output_contains "hallucinated_file.rb"
    # the dropped file is re-attached to its deterministic component
    assert_output_contains "missed_file.txt"
}

@test "reconcile_grouping_json rejects non-JSON output" {
    run reconcile_grouping_json "garbage @@@ ui | app.js @@@" "app.js" "1\tapp.js"
    [ "$status" -eq 1 ]
}

# ─── name_groups_with_ai ─────────────────────────────────────────────────────

@test "name_groups_with_ai returns 1 when prompt template missing" {
    export AI_GROUPING_PROMPT_FILE="/nonexistent/template.txt"
    run name_groups_with_ai "1\tapp.js" "app.js"
    [ "$status" -eq 1 ]
}

@test "name_groups_with_ai calls the API with schema-constrained request" {
    export AI_ENABLE_LLM_GROUPING="true"
    export AI_MODEL="test-model"
    mock_ollama_api '{"groups":[{"name":"auth flow","type":"feat","files":["app.js"]}]}'
    run name_groups_with_ai "1\tapp.js" "app.js"
    [ "$status" -eq 0 ]
    assert_output_contains "auth flow"
}

# ─── count_staged_scopes ─────────────────────────────────────────────────────

@test "count_staged_scopes counts distinct components" {
    local files
    files="$(printf 'eslint.config.js\nscripts/validate-html.js\nscripts/validate-markdown.js\nsrc/components/Schema.astro')"
    run count_staged_scopes "$files"
    [ "$status" -eq 0 ]
    # scripts pair joins; eslint + Schema are singletons → 3
    [ "$output" -eq 3 ]
}

# ─── build_cochange_cache ────────────────────────────────────────────────────

@test "build_cochange_cache emits pairs committed together at least twice" {
    mkdir -p src
    echo a > src/a.js
    echo b > src/b.js
    git add src/a.js src/b.js
    git commit -qm "first" || true
    echo a2 > src/a.js
    echo b2 > src/b.js
    git add src/a.js src/b.js
    git commit -qm "second" || true
    local state_dir
    state_dir=$(get_aicommit_state_dir)
    run build_cochange_cache "$state_dir"
    [ "$status" -eq 0 ]
    grep -q "src/a.js" "${state_dir}/COCHANGE"
    awk -F'\t' '$1=="src/a.js" && $2=="src/b.js" && $3>=2 {found=1} END{exit !found}' "${state_dir}/COCHANGE"
}
