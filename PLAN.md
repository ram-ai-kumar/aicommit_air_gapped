# Plan: Fix Empty `bin/` Commands, RCA & Comprehensive Test Coverage

## 1. Problem Statement & Root Cause Analysis (RCA)

### Problem
Certain command files in `bin/` (`bin/aics`, `bin/aiccs`, `bin/aicsx`, `bin/aiccsx`) are 0-byte empty files. When users attempt to execute these commands directly as CLI executables, the scripts execute nothing and exit immediately with status 0 without invoking `aicommit`.

### Root Cause
1. **Commit `bee1e0dcd100b7ac0c90a2339ffab5cecabfee4f`**: Added four new shell functions in `aicommit.sh` (`aics`, `aiccs`, `aicsx`, `aiccsx`) for SemVer-enabled commit workflows.
2. **Missing Wrapper Bodies**: During that commit, new file paths were created in `bin/` (`touch bin/aics bin/aiccs bin/aicsx bin/aiccsx` and `chmod 755`) and added to git, but the wrapper contents (invoking `source "$AICOMMIT_DIR/aicommit.sh"` and dispatching to the function) were never written into the files.
3. **Test Gap**: Existing unit and integration tests only tested bash functions by sourcing `aicommit.sh` inside test environments; no tests executed the standalone binaries in `bin/`. Additionally, several helper and library functions lacked direct unit tests.

---

## 2. Scope of Fixes

### A. Fix `bin/` Command Files
Populate each empty wrapper in `bin/` following the existing canonical structure (consistent with `bin/aic`, `bin/aicc`, `bin/aicx`, `bin/aiccx`, `bin/aicommit`):
- `bin/aics` -> calls `aics "$@"`
- `bin/aiccs` -> calls `aiccs "$@"`
- `bin/aicsx` -> calls `aicsx "$@"`
- `bin/aiccsx` -> calls `aiccsx "$@"`
Ensure all 9 files in `bin/` have executable permissions (`chmod 755`).

### B. Shell & Completion Alignments
- Check `init.sh` comments and verify `$AICOMMIT_DIR/bin` export.
- Update `completions/aicommit.bash` to register completions for all 9 commands (`aicommit`, `aic`, `aicc`, `aicx`, `aiccx`, `aics`, `aiccs`, `aicsx`, `aiccsx`).

### C. Expand Test Suite for Complete Command & Function Coverage
1. **Command Execution Tests (`test/unit/test_bin_commands.bats`)**:
   - Verify every file in `bin/` exists, is non-empty, has executable permissions (`-x`), and has valid syntax (`bash -n`).
   - Verify direct execution of every binary in `bin/` (`--help`, dry-run / non-interactive invocations).
   - Test flag forwarding and shortcut behavior for all commands (`aicommit`, `aic`, `aicc`, `aicx`, `aiccx`, `aics`, `aiccs`, `aicsx`, `aiccsx`).
2. **Library Function Unit Tests**:
   - `test/unit/test_core.bats`: Add tests for `agit`, `to_pathspec`, `staged_fingerprint`, `_aicommit_split_tab_line`, `_aicommit_has_split_flag`.
   - `test/unit/test_context_analyzer.bats`: Add tests for `infer_logical_file_context`, `group_staged_files_heuristically`, `cluster_staged_files_with_ai`.
   - `test/unit/test_output_formatter.bats`: Add tests for `display_scope_success`, `display_semver_plan`, `display_tag_success`.
   - `test/unit/test_semver.bats`: Add tests for `apply_semver_file_updates`.
3. **Smoke Tests (`test/contexts/smoke.bats`)**:
   - Update `aicommit.sh sources without error` and `all library functions are available after source` to check `declare -f` for all exported commands and library functions.

---

## 3. Verification Plan
- Run `bash -n bin/*` and verify no syntax errors.
- Run `bats test/unit/test_bin_commands.bats`.
- Run all unit tests: `bats test/unit/*.bats`.
- Run the full test suite runner: `./test/run_tests.sh`.
- Verify total tests passed is green with zero failures.
