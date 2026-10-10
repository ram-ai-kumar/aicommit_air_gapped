# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.3] - 2026-10-11

- refactor(core): add id-based grouping schema and new flow modules

## [0.5.2] - 2026-10-10

- chore(aicommit.sh): add typesetsilent option to suppress local variable

## [0.5.1] - 2026-10-10

- ci(config): update .github/workflows/test.yml

## [0.5.0] - 2026-10-10

- feat(commitgeneration): add reflection step and conventional commit

## [0.4.4] - 2026-10-09

- chore(core-2): add .env* to gitignore

## [0.4.3] - 2026-10-09

- chore(config): update .github/workflows/test.yml and 28 other files

## [0.4.2] - 2026-10-09

- chore(core): remove .env.production

## [0.4.1] - 2026-10-07

- chore(docs): add SemVer 2.0.0 adherence and robust versioning documentation to CHANGELOG.md

## [0.4.0] - 2026-10-07

### Added
- **SemVer Tag Priority**: Authoritative base version resolution (`get_last_version`) strictly prioritizes the highest Git tag (`v*` or `*.*.*`), then committed `HEAD` manifests, preventing double-bumping on retries after failed commits (`d1716ed`).
- **Preserve Higher Staged Versions**: If project manifests in the working tree or staging index contain a version strictly greater than the evaluated target version, manifests are preserved untouched, and the release/tag is issued under the higher version (`resolve_effective_semver`) (`d1716ed`).
- **Automated Changelog Management**: Automatic changelog discovery across various extensions and casings (`CHANGELOG.md`, `changelog.txt`, `HISTORY.md`, etc.), with idempotent bullet insertion under version sections and automatic git staging (`update_changelog`) (`d1716ed`).
- **Resilient Failure Rollback**: Rollback mechanism (`restore_semver_updates`) restoring modified manifests to `HEAD` and removing newly created untracked changelogs upon commit failures (`d1716ed`).
- **SemVer Comparison Utility**: `semver_gt` function handling SemVer 2.0.0 precedence, pre-release suffixes (e.g. `-rc.1`), and build metadata (`d1716ed`).

### Changed
- **Release Plan Display**: Enhanced `display_semver_plan` output formatter with `PRESERVED (higher version in manifests)` status indication and changelog file listing (`d1716ed`).
- **Commit Flow Integration**: Updated interactive single-commit (`aicommit`), atomic split loop (`aicc` / `--split`), and non-interactive (`aics`, `--yes`) execution paths to use `apply_semver_release` and rollback traps (`d1716ed`).

### Testing
- Expanded SemVer unit test suite in `test/unit/test_semver.bats` to 69 tests covering comparison logic, tag priority, fallback to `HEAD`, changelog creation and idempotency, pre-bump preservation, and rollback (`d1716ed`).

## [0.3.2] - 2026-10-05

### Testing
- Added unit tests in `test/unit/test_semver.bats` for .NET (`.csproj`, `.fsproj`) and Ruby/Rails (`.gemspec`, `version.rb`) project detection scenarios (`7a48694`).
- Updated project file detection routines to use `find` for robustness against missing directory structures (`7a48694`).

## [0.3.1] - 2026-10-05

### Testing
- Expanded unit test coverage for logical scope grouping, SemVer application, and `agit` Git helpers (`a519217`).
- Added executable permission and existence verification for all 9 CLI bin commands in smoke tests (`a519217`).
- Implemented unit tests for context analyzer inference across multi-tenancy, auth, and CI contexts (`a519217`).
- Added unit tests for output formatter display helpers (`display_scope_success`, `display_semver_plan`, `display_tag_success`) (`a519217`).

## [0.3.0] - 2026-10-05

### Added
- Standalone CLI command wrappers in `bin/` (`481d6c0`):
  - `aicommit`: Interactive commit assistant
  - `aic`: Quick non-interactive all-in-one commit (`--yes --no-split`)
  - `aicc`: Quick non-interactive atomic split commit (`--yes --split`)
  - `aicx`: Verbose dry-run inspection for single commit
  - `aiccx`: Verbose dry-run inspection for atomic split commits
  - `aics`: Quick commit with SemVer bump and Git tagging
  - `aiccs`: Quick categorized split commit with SemVer bumps
  - `aicsx`: Dry-run inspection with SemVer evaluation preview
  - `aiccsx`: Split dry-run inspection with SemVer evaluation preview
- Extended Bash and Zsh shell completion scripts to support all new command aliases (`481d6c0`).

### Documentation
- Updated `init.sh` documentation with command wrapper mappings and shortcut descriptions (`481d6c0`).

## [0.2.0] - 2026-10-04

### Added
- **Polyglot SemVer Engine**: Core Semantic Versioning engine (`lib/semver.sh`) automatically detecting version strings across 9 ecosystems: Node.js (`package.json`, `package-lock.json`), Rust (`Cargo.toml`), Python (`pyproject.toml`, `setup.py`), Flutter / Dart (`pubspec.yaml`), Ruby (`.gemspec`, `version.rb`), PHP (`composer.json`), .NET (`.csproj`), Java (`pom.xml`, Gradle), and Go (`version.go`) (`bee1e0d`).
- **Automated SemVer Calculation**: `calculate_next_semver` and `evaluate_commit_semver` to analyze Conventional Commit headers and git diffs against SemVer 2.0.0 rules (Major, Minor, Patch) (`bee1e0d`).
- **Interactive SemVer Selection**: CLI prompts (`s`, `s=<level>`, `a` for AI evaluation) allowing manual or LLM-driven version bump selection (`bee1e0d`).
- **Automated Git Tagging**: `create_version_tag` for generating annotated git tags upon successful commit (`bee1e0d`).

### Documentation
- Added `docs/TECHNICAL_ARCHITECTURE.md` and `docs/plans/semver_bump_plan.md` (`bee1e0d`).

### Testing
- Implemented foundational SemVer test suite in `test/unit/test_semver.bats` covering version detection and updates across all supported ecosystems (`bee1e0d`).

## [0.1.0] - 2026-10-04

### Added
- **SemVer Post-Commit Suggestion**: Added SemVer bump hints suggesting next version after successful commits (`53083df`).
- **Atomic Commit Splitting**: Multi-scope staging analysis (`--split` / `aicc`) inferring logical file groupings and generating atomic commits per scope (`062eb13`).
- **Reasoning Model Thinking Suppression**: Added dynamic thinking tag suppression (`<think>...</think>`) for Ollama reasoning models (`b66c1ec`).
- **Granite AI Model Integration**: Switched AI model to `granite4.1:8b` and restricted supported backends to Ollama (`c414813`).
- **BDD Testing Framework**: Initialized Cucumber-Ruby BDD testing framework and developer workflow step definitions (`8262d37`, `f612325`).
- **Model Fallback Logic**: Enhanced model fallback tests and backend logic prioritizing available local models (`67876f6`).
- **BATS Test Suite**: Implemented comprehensive BATS test suite across smoke, unit, integration, edge, negative, exception, compliance, and security categories with circuit breaker settings (`dc9202d`).
- **Backend Abstraction**: Introduced `lib/backends.sh` for unified LLM backend management across Ollama, Llama.cpp, and LocalAI (`a6755af`).
- **Initial CLI & Prompt Pipeline**: Core interactive and auto-commit entry points, context assembly from git diffs and numstat, and prompt templates (`ab94f37`).

### Fixed
- **Output Formatter Variable Conflict**: Resolved Zsh read-only variable conflict in output formatter (`8bd636e`).
- **Staged Parsing & Permissions**: Robustified staged change parsing and refined install file permissions (`20cc19e`).
- **Global Git Hooks Isolation**: Disabled global git hooks during automated commits and improved logical grouping prompt templates (`6d69e3f`).
- **Model Loadability Errors**: Removed noisy error messages for model loadability check failures (`ce6703b`).
- **Standard Error Redirection**: Ensured error messages are consistently printed to stderr in `aicommit.sh` and `lib/output-formatter.sh` (`668b70b`).

### Changed
- **Verbose Output Diagnostics**: Updated display helpers to show staged file diagnostics only when `--verbose` is specified (`0b7f511`).
- **Split Confirmation Display**: Enhanced split confirmation display with file grouping previews (`67d148b`, `e073d05`).
- **Dynamic AI Model Configuration**: Replaced hardcoded model values with dynamic `get_default_ai_model()` lookup and enforced 72-character Conventional Commit header limits (`97ca0ae`, `2723f4d`, `954f593`, `1b7f9d3`, `960e6a4`).
- **Prompt Rules Refinement**: Updated prompt template rules for conventional commits and reasoning block extraction (`eb9fb79`).
- **Default AI Model Upgrades**: Updated default AI model to `qwen3.5-9b-unsloth` (`4bb2001`) and previously `qwen2.5-coder` (`7b97f66`, `5e303f0`).
- **Core File Paths & Installer Logic**: Refined script logic and file paths in `lib/core.sh` and `scripts/install.sh` (`2e468e9`).
- **Commit Confirmation Flow**: Improved commit confirmation UI and simplified response handling in `aicommit.sh` and `lib/output-formatter.sh` (`2a16758`, `5d7e307`).
- **Directory Security & Permissions**: Restricted temporary directory and file creation permissions to owner-only (`0700`) and enhanced configuration validation (`3030890`, `ff9e07b`).
- **Step Definition Consolidation**: Reorganized, consolidated, and specialized Cucumber step definitions and test workflows (`058a079`, `0b4913b`, `ea8491f`, `b1f5bc4`, `05f2bd2`, `617363e`).
- **Model Loadability & Error Handling**: Refactored `lib/backends.sh` to improve model loadability checking and preferred model prioritization (`2d0bf25`, `06fd214`, `3e7a460`).
- **Installer & Numstat Handling**: Enhanced installer with repository sync script, resolved integer overflow in numstat parsing, and improved Ollama error handling (`062fedf`).
- **Progress Message Timer**: Persisted elapsed generation timer in terminal output history for improved user feedback (`f08481e`, `eae5b3c`).
- **Context Analyzer & Templates**: Enhanced context analysis in `lib/context-analyzer.sh` and updated prompt template in `templates/prompt.txt` (`d173f62`).

### Testing
- Added integration test for dry-run verbose output and quiet default behavior (`b73a22b`).
- Added unit test for `display_split_confirmation` file preview (`a167f03`).
- Added integration and unit tests for commit message splitting and scope clustering (`f6b8c16`).
- Cleaned up redundant and outdated model fallback tests and updated smoke tests (`f78d867`).
- Added unit and integration tests across all test contexts (`dc9202d`).

### Documentation
- Reorganized technical documentation and consolidated roadmap items into specialized sections (`035e1a7`, `e8709bd`, `d955a98`).
- Added `SECURITY_BY_DESIGN.md` detailing security architecture, threat models, and sensitive file exclusions (`.env*`, `.key`) (`2945fee`).
- Updated project description, configuration options, timeout settings, and roadmap details (`7de0d8a`, `457dd24`).
- Documented LLM timeout, retry logic, and error handling specifications in `TODO.md` (`e4a9fc5`).
- Expanded README commit message guidelines and Conventional Commit benefits (`d3c4b59`).
- Updated GitHub repository URLs, installation paths, and configuration file references (`046c279`, `e9223df`, `2c38b00`, `ba8ec4c`).
- Initial project README, technical architecture, roadmap, and MIT license documentation (`ab94f37`).
