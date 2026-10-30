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

# ─── Multi-Language Vertical Feature Slices & Anti-Horizontal Clustering ─────

@test "vertical slice: Rails feature groups model, controller, view, spec, migration and routes" {
    local files
    files="$(printf 'app/models/subscription.rb\napp/controllers/subscriptions_controller.rb\napp/views/subscriptions/index.html.erb\nspec/models/subscription_spec.rb\ndb/migrate/20261023_create_subscriptions.rb\nconfig/routes.rb')"
    local diff
    diff="$(printf 'diff --git a/config/routes.rb b/config/routes.rb\n--- a/config/routes.rb\n+++ b/config/routes.rb\n@@ -10,1 +10,2 @@\n+  resources :subscriptions\n')"
    run group_staged_files_logically "$files" "$diff"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'subscription\t'
    assert_output_contains "app/models/subscription.rb"
    assert_output_contains "app/controllers/subscriptions_controller.rb"
    assert_output_contains "app/views/subscriptions/index.html.erb"
    assert_output_contains "spec/models/subscription_spec.rb"
    assert_output_contains "db/migrate/20261023_create_subscriptions.rb"
    assert_output_contains "config/routes.rb"
}

@test "vertical slice: anti-horizontal test guard keeps multiple features disjoint without grouping tests together" {
    local files
    files="$(printf 'app/models/subscription.rb\napp/controllers/subscriptions_controller.rb\nspec/models/subscription_spec.rb\napp/models/user.rb\napp/controllers/users_controller.rb\nspec/models/user_spec.rb')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 2 ]
    # Ensure specs stayed with their respective feature slice
    assert_output_contains $'subscription\tapp/controllers/subscriptions_controller.rb\tapp/models/subscription.rb\tspec/models/subscription_spec.rb'
    assert_output_contains $'user\tapp/controllers/users_controller.rb\tapp/models/user.rb\tspec/models/user_spec.rb'
}

@test "vertical slice: Flutter Dart clusters BLoC triad, screen, generated code, and test into feature group" {
    local files
    files="$(printf 'lib/features/auth/bloc/auth_bloc.dart\nlib/features/auth/bloc/auth_state.dart\nlib/features/auth/bloc/auth_event.dart\nlib/features/auth/screens/auth_screen.dart\nlib/features/auth/models/auth.g.dart\ntest/features/auth/auth_bloc_test.dart')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'auth\t'
    assert_output_contains "auth_bloc.dart"
    assert_output_contains "auth_screen.dart"
    assert_output_contains "auth.g.dart"
    assert_output_contains "auth_bloc_test.dart"
}

@test "vertical slice: FastAPI clusters router, schema, service, test, and router registration" {
    local files
    files="$(printf 'app/routers/items.py\napp/schemas/item.py\napp/services/item_service.py\ntests/test_items.py\napp/main.py')"
    local diff
    diff="$(printf 'diff --git a/app/main.py b/app/main.py\n--- a/app/main.py\n+++ b/app/main.py\n@@ -5,1 +5,2 @@\n+app.include_router(items.router, prefix=\"/items\")\n')"
    run group_staged_files_logically "$files" "$diff"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'item\t'
    assert_output_contains "app/routers/items.py"
    assert_output_contains "app/schemas/item.py"
    assert_output_contains "tests/test_items.py"
    assert_output_contains "app/main.py"
}

@test "vertical slice: Rust and Tauri clusters command and integration test" {
    local files
    files="$(printf 'src-tauri/src/commands/download.rs\nsrc-tauri/tests/download_test.rs')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'download\tsrc-tauri/src/commands/download.rs\tsrc-tauri/tests/download_test.rs'
}

@test "vertical slice: Go clusters package files, repositories and handler tests" {
    local files
    files="$(printf 'internal/order/handler.go\ninternal/order/service.go\ninternal/order/repository.go\ninternal/order/handler_test.go')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'order\t'
    assert_output_contains "internal/order/handler.go"
    assert_output_contains "internal/order/handler_test.go"
}

@test "routes: dedicated Rails route file clusters with feature model, controller, and spec" {
    local files
    files="$(printf 'app/models/subscription.rb\napp/controllers/subscriptions_controller.rb\nconfig/routes/subscriptions.rb\nspec/requests/subscriptions_spec.rb')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'subscription\t'
    assert_output_contains "config/routes/subscriptions.rb"
    assert_output_contains "app/models/subscription.rb"
    assert_output_contains "app/controllers/subscriptions_controller.rb"
    assert_output_contains "spec/requests/subscriptions_spec.rb"
}

@test "routes: Flutter dedicated route file clusters with feature screens and bloc" {
    local files
    files="$(printf 'lib/features/auth/bloc/auth_bloc.dart\nlib/features/auth/screens/auth_screen.dart\nlib/routes/auth_routes.dart\ntest/features/auth/auth_bloc_test.dart')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'auth\t'
    assert_output_contains "lib/routes/auth_routes.dart"
    assert_output_contains "lib/features/auth/screens/auth_screen.dart"
    assert_output_contains "lib/features/auth/bloc/auth_bloc.dart"
    assert_output_contains "test/features/auth/auth_bloc_test.dart"
}

@test "routes: Next.js TypeScript App Router route.ts resolves feature from parent directory" {
    local files
    files="$(printf 'app/api/subscriptions/route.ts\nsrc/features/subscriptions/SubscriptionCard.tsx\nsrc/features/subscriptions/subscription.test.ts')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'subscription\t'
    assert_output_contains "app/api/subscriptions/route.ts"
    assert_output_contains "src/features/subscriptions/SubscriptionCard.tsx"
    assert_output_contains "src/features/subscriptions/subscription.test.ts"
}

@test "routes: Go dedicated routes file clusters with feature service and repository" {
    local files
    files="$(printf 'internal/billing/service.go\ninternal/billing/repository.go\ninternal/routes/billing_routes.go\ninternal/billing/service_test.go')"
    run group_staged_files_logically "$files"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 1 ]
    assert_output_contains $'billing\t'
    assert_output_contains "internal/routes/billing_routes.go"
    assert_output_contains "internal/billing/service.go"
    assert_output_contains "internal/billing/service_test.go"
}

@test "routes: dominant feature binding keeps multiple features disjoint when shared routes.rb changes" {
    local files
    files="$(printf 'app/models/subscription.rb\napp/controllers/subscriptions_controller.rb\napp/models/invoice.rb\napp/controllers/invoices_controller.rb\nconfig/routes.rb')"
    local diff
    diff="$(printf 'diff --git a/config/routes.rb b/config/routes.rb\n--- a/config/routes.rb\n+++ b/config/routes.rb\n@@ -10,2 +10,4 @@\n+  resources :subscriptions, only: [:index, :show]\n+  get \"/subscriptions/plans\", to: \"subscriptions#plans\"\n+  resources :invoices, only: [:index]\n')"
    run group_staged_files_logically "$files" "$diff"
    [ "$status" -eq 0 ]
    [ $(printf '%s\n' "$output" | count_lines) -eq 2 ]
    # Ensure subscription and invoice remained separate groups, and routes.rb bound to dominant feature (subscription)
    assert_output_contains $'subscription\t'
    assert_output_contains "config/routes.rb"
    assert_output_contains "app/models/subscription.rb"
    assert_output_contains $'invoice\t'
    assert_output_contains "app/models/invoice.rb"
}

# ─── replicated-edit signature edges (Cycle 2C) ──────────────────────────────

@test "cluster_staged_files_deterministic merges identical added lines across directories" {
    local files diff_file
    files="$(printf 'app/models/a_item.rb\nlib/handlers/b_item.rb\napp/models/c_other.rb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/models/a_item.rb b/app/models/a_item.rb
+        if attributes.slice('name', 'sku').values.any?(&:present?)
+          Spare.ensure_except_update(attributes, 'mrp')
diff --git a/lib/handlers/b_item.rb b/lib/handlers/b_item.rb
+        if attributes.slice('name', 'sku').values.any?(&:present?)
+          Spare.ensure_except_update(attributes, 'mrp')
diff --git a/app/models/c_other.rb b/app/models/c_other.rb
+        completely_different_change.call(args)
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 2 ]
    assert_output_contains $'app/models/a_item.rb\tlib/handlers/b_item.rb'
}

@test "cluster_staged_files_deterministic merges receiver-varied safe-nav edits" {
    local files diff_file
    files="$(printf 'app/views/a/edit.html.erb\napp/views/b/new.html.erb\napp/views/c/show.html.erb\napp/views/d/other.html.erb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/views/a/edit.html.erb b/app/views/a/edit.html.erb
+  | <%= @invoice.financial_year&.name %>
diff --git a/app/views/b/new.html.erb b/app/views/b/new.html.erb
+      <%= @jobcard.financial_year&.name %>
diff --git a/app/views/c/show.html.erb b/app/views/c/show.html.erb
+  <dd><%= @financial_year&.name %></dd>
diff --git a/app/views/d/other.html.erb b/app/views/d/other.html.erb
+  <dd><%= @record.title %></dd>
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 2 ]
    assert_output_contains $'app/views/a/edit.html.erb\tapp/views/b/new.html.erb\tapp/views/c/show.html.erb'
}

# ─── bulk-added test consolidation (Cycle 5) ─────────────────────────────────

@test "cluster_staged_files_deterministic pairs a newly added test with its staged subject" {
    local files diff_file
    files="$(printf 'app/models/estimate_item.rb\ntest/controllers/estimate_items_controller_test.rb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/models/estimate_item.rb b/app/models/estimate_item.rb
+        Spare.ensure_except_update(attributes, 'mrp')
diff --git a/test/controllers/estimate_items_controller_test.rb b/test/controllers/estimate_items_controller_test.rb
new file mode 100644
+    test 'creates item' do
+      assert_response :success
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    # New test pairs with its staged same-stem subject (estimate_item)
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 1 ]
    assert_output_contains $'app/models/estimate_item.rb\ttest/controllers/estimate_items_controller_test.rb'
}

@test "cluster_staged_files_deterministic keeps unpaired newly added tests bucketed" {
    local files diff_file
    files="$(printf 'app/models/order.rb\ntest/controllers/invoice_controller_test.rb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/models/order.rb b/app/models/order.rb
+        Order.recalculate_totals(scope)
diff --git a/test/controllers/invoice_controller_test.rb b/test/controllers/invoice_controller_test.rb
new file mode 100644
+    test 'creates invoice' do
+      assert_response :success
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    # No shared stem — the new test stays in its own coverage group
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 2 ]
}

@test "cluster_staged_files_deterministic still pairs modified tests with subjects" {
    local files diff_file
    files="$(printf 'app/models/estimate_item.rb\ntest/models/estimate_item_test.rb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/models/estimate_item.rb b/app/models/estimate_item.rb
+        Spare.ensure_except_update(attributes, 'mrp')
diff --git a/test/models/estimate_item_test.rb b/test/models/estimate_item_test.rb
+      assert_equal 2, item.quantity
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 1 ]
    assert_output_contains $'app/models/estimate_item.rb\ttest/models/estimate_item_test.rb'
}

@test "cluster_staged_files_deterministic buckets unpaired added tests by layer" {
    local files diff_file
    files="$(printf 'app/models/d.rb\ntest/controllers/a_controller_test.rb\ntest/controllers/b_controller_test.rb\ntest/models/c_test.rb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/models/d.rb b/app/models/d.rb
+        unrelated_model_change = true
diff --git a/test/controllers/a_controller_test.rb b/test/controllers/a_controller_test.rb
new file mode 100644
+    test 'a works' do
diff --git a/test/controllers/b_controller_test.rb b/test/controllers/b_controller_test.rb
new file mode 100644
+    test 'b works' do
diff --git a/test/models/c_test.rb b/test/models/c_test.rb
new file mode 100644
+    test 'c works' do
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 3 ]
    assert_output_contains $'test/controllers/a_controller_test.rb\ttest/controllers/b_controller_test.rb'
}

@test "cluster_staged_files_deterministic splits oversized test bucket at AI_MAX_GROUP_SIZE" {
    local files diff_file
    files="$(printf 'test/controllers/a_test.rb\ntest/controllers/b_test.rb\ntest/controllers/c_test.rb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/test/controllers/a_test.rb b/test/controllers/a_test.rb
new file mode 100644
+    test 'a works' do
diff --git a/test/controllers/b_test.rb b/test/controllers/b_test.rb
new file mode 100644
+    test 'b works' do
diff --git a/test/controllers/c_test.rb b/test/controllers/c_test.rb
new file mode 100644
+    test 'c works' do
DEOF
    AI_MAX_GROUP_SIZE=2
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 2 ]
    assert_output_contains $'test/controllers/a_test.rb\ttest/controllers/b_test.rb'
}

@test "cluster_staged_files_deterministic treats test_*.py route module as subject, not test" {
    local files diff_file
    files="$(printf 'app/api/routes/test_personas.py\ntests/api/routes/test_test_personas.py')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/api/routes/test_personas.py b/app/api/routes/test_personas.py
new file mode 100644
+from fastapi import APIRouter
+router = APIRouter(prefix="/test-personas")
+@router.get("")
+async def list_test_personas():
+    return {"data": []}
diff --git a/tests/api/routes/test_test_personas.py b/tests/api/routes/test_test_personas.py
new file mode 100644
+import pytest
+def test_personas_hidden(client):
+    assert client.get("/x").status_code == 404
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    # Route module is a subject (no test markers), pytest file pairs via `persona` stem
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 1 ]
    assert_output_contains $'app/api/routes/test_personas.py\ttests/api/routes/test_test_personas.py'
}

@test "cluster_staged_files_deterministic sniffs ambiguous test_*.py with test markers" {
    local files diff_file
    files="$(printf 'src/utils/test_helpers.py\nsrc/models/widget.py')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/src/utils/test_helpers.py b/src/utils/test_helpers.py
new file mode 100644
+import pytest
+def test_fixture_works():
+    assert True
diff --git a/src/models/widget.py b/src/models/widget.py
+    widget.render()
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    # test_helpers.py has pytest markers → classified test → stays separate
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 2 ]
}

@test "cluster_staged_files_deterministic does not glue __init__.py files across packages" {
    local files diff_file
    files="$(printf 'app/models/__init__.py\napp/services/__init__.py\napp/models/order.rb\napp/services/pricing.rb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/models/__init__.py b/app/models/__init__.py
+from .order import Order
diff --git a/app/services/__init__.py b/app/services/__init__.py
+from .pricing import Pricing
diff --git a/app/models/order.rb b/app/models/order.rb
+    Order.total
diff --git a/app/services/pricing.rb b/app/services/pricing.rb
+    Pricing.compute
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    # __init__ files are package markers — they must not merge unrelated dirs
    [ "$(printf '%s\n' "$output" | count_lines)" -ge 2 ]
    ! printf '%s\n' "$output" | grep -q $'app/models/__init__.py\tapp/services/__init__.py'
}

@test "cluster_staged_files_deterministic keeps dir-derived features inside their own tree" {
    local files diff_file
    files="$(printf 'backend/app/public_api/admin.py\nfrontend/src/routes/admin/index.tsx\nfrontend/src/routes/admin/route.tsx')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/backend/app/public_api/admin.py b/backend/app/public_api/admin.py
+    admin_registry.unregister()
diff --git a/frontend/src/routes/admin/index.tsx b/frontend/src/routes/admin/index.tsx
+    export const Route = createFileRoute("/admin")()
diff --git a/frontend/src/routes/admin/route.tsx b/frontend/src/routes/admin/route.tsx
+    export const Route = createFileRoute("/admin")()
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    # `admin` dir-walkback feature must not bridge backend/app ↔ frontend/src
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 2 ]
    assert_output_contains $'frontend/src/routes/admin/index.tsx\tfrontend/src/routes/admin/route.tsx'
}

@test "cluster_staged_files_deterministic ignores ubiquitous CRUD symbol names" {
    local files diff_file
    files="$(printf 'app/services/data_admin/repository.py\napp/services/commerce.py')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/services/data_admin/repository.py b/app/services/data_admin/repository.py
deleted file mode 100644
-    def delete(self, row):
-        session.delete(row)
-    def update(self, row):
-        session.commit()
diff --git a/app/services/commerce.py b/app/services/commerce.py
+    await session.delete(order)
+    await session.commit()
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    # `delete`/`update`/`commit` carry no pairing signal → 2 groups
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 2 ]
}

# ─── symbol/dir-union noise dampeners ────────────────────────────────────────

@test "cluster_staged_files_deterministic ignores helper defs defined inside test files" {
    local files diff_file
    files="$(printf 'app/models/a.rb\nlib/z/b.rb\ntest/controllers/a_controller_test.rb\ntest/controllers/b_controller_test.rb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/models/a.rb b/app/models/a.rb
+        make_widget(attributes)
diff --git a/lib/z/b.rb b/lib/z/b.rb
+        unrelated_b_change = true
diff --git a/test/controllers/a_controller_test.rb b/test/controllers/a_controller_test.rb
new file mode 100644
+    def make_widget(attrs)
+      Widget.create!(attrs)
diff --git a/test/controllers/b_controller_test.rb b/test/controllers/b_controller_test.rb
new file mode 100644
+      make_widget(name: 'x')
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 3 ]
    assert_output_contains $'test/controllers/a_controller_test.rb\ttest/controllers/b_controller_test.rb'
}

@test "cluster_staged_files_deterministic does not sweep same-dir strays into a multi-dir component" {
    local files diff_file
    files="$(printf 'app/models/m.rb\napp/models/u.rb\napp/views/x/a.html.erb\napp/views/x/b.html.erb')"
    diff_file="$TEST_TEMP_DIR/diff.txt"
    cat > "$diff_file" <<'DEOF'
diff --git a/app/models/m.rb b/app/models/m.rb
+    self.total = items.reload.sum(&:amount)
diff --git a/app/models/u.rb b/app/models/u.rb
+    self.other = something.else(:entirely)
diff --git a/app/views/x/a.html.erb b/app/views/x/a.html.erb
+    self.other = items.reload.sum(&:total)
diff --git a/app/views/x/b.html.erb b/app/views/x/b.html.erb
+    self.more = items.reload.sum(&:qty)
DEOF
    run cluster_staged_files_deterministic "$files" "$diff_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | count_lines)" -eq 2 ]
    assert_output_contains $'app/models/m.rb\tapp/views/x/a.html.erb\tapp/views/x/b.html.erb'
    assert_output_contains $'\tapp/models/u.rb'
}
