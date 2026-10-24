# PLAN: Intent-Based Atomic Commit Grouping & Human-Guided Hints

## Goal

Enable organized, logical, human-, feature-, function-, intent-, and outcome-based grouping of staged changes when running multi-commit chains (`aicc`, `aiccs`, `aiccx`, `aiccsx`, and `aicommit --split`), with support for user-guided intent hints (`aiccs "docs reorganized" "Export bug resolved"`), robust cache keys, and DAG-ordered atomic commits.

## Context

When staging complex multi-file changes (e.g. 260+ files across renames, doc restructuring, asset cleanups, and script updates), previous grouping mechanisms risked falling back to directory buckets (`docs-1...docs-35`, `geojson`, `kml`).
This update provides:
1. Flexible user intent hints (`aiccs "docs reorganized" "Export bug resolved"`).
2. Faceted component summaries to eliminate model information horizon blindness.
3. Pre-clustering guardrails (Edge 2 symbol ceiling $K \le 4$, Edge 3.5 scoped relocation signatures).
4. Full Conventional Commit `type` and intent propagation downstream into commit message generation.
5. Topological DAG sorting to guarantee intermediate tree validity.
6. Exact content-addressed caching (`staged_state_key`, `grouping_state_key`) with always-regroup semantics and mid-run still-staged filtering.

## Files to Touch

| File | Change |
| --- | --- |
| `config/defaults.sh` | Add knobs: `AI_GROUPING_TIMEOUT`, `AI_GROUPING_NUM_PREDICT*`, `AI_GROUPING_MAX_*`, `AI_SYMBOL_MAX_FILES`, `AICOMMIT_GROUPING_ALGO_VERSION` |
| `templates/context-grouping-prompt.txt` | Prompt rewrite with reviewer archetypes, group sizing guidelines (3-8 commits), status tags, and user intent hints section |
| `aicommit.sh` | Ingest positional non-flag arguments and comma-separated tokens as user hints, write `${tmp_dir}/USER_HINTS`, forward to flows |
| `lib/context-analyzer.sh` | Guarded clustering edges, faceted summaries, `staged_status_map`, `grouping_state_key` (including user hints hash), DAG topological sort, type retention |
| `lib/core.sh` | `staged_state_key()`, group-DIFF cache isolation, 3-field `_aicommit_split_tab_line`, `GROUP_TYPE`/`GROUP_INTENT` context injection |
| `lib/split-flow.sh` | Always-regroup on current staged set, mid-run still-staged filtering (`_split_sync_to_staged`), provenance display, formatted group previews with hints |
| `lib/backends.sh` | Dynamic `num_predict` override support in `build_ollama_request` |
| `test/unit/test_cli_hints.bats` | Comprehensive test suite covering Smoke, Negative, Edge, Exception, and Security cases |
| `test/unit/test_context_analyzer.bats` | Unit tests for guarded edges, faceted summarizer, DAG sorter, type retention |
| `test/unit/test_core.bats` | Unit tests for exact staged-state key, group-diff cache isolation, 3-field split tab parsing |
| `test/unit/test_optimization_pipeline.bats` | Pipeline tests for dry-run to real handoff and per-group message generation |

## Verification Checklist

- [ ] Bats unit test suites pass (`test_cli_hints.bats`, `test_context_analyzer.bats`, `test_core.bats`, etc.).
- [ ] Full test runner `./test/run_tests.sh` passes 100%.
- [ ] Smoke tests for positional and comma-separated hints pass.
- [ ] Negative and edge tests pass.
- [ ] Security test cases pass (command injection defense, sensitive file filtering, path traversal protection).
