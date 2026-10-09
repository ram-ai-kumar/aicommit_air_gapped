# PLAN: Ollama Structured Output Auto-Fallback & Robust JSON Parsing

## Goal

Automatically handle Ollama environments and models (such as `qwen3.5:4b` on Apple Silicon with Homebrew Ollama) where grammar-constrained structured output is unavailable, falling back seamlessly to prompt-guided JSON generation without user-facing failures, and robustly parsing JSON whether returned raw or wrapped in markdown code fences.

## Context

When using `qwen3.5:4b` on macOS via Homebrew Ollama, the model runs on the MLX runner (`libmlxc.dylib`), which lacks `xgrammar` and rejects any request containing the `format` schema parameter with `{"error": "structured output is unavailable"}`.
However, `qwen3.5:4b` generates high-quality conventional commit JSON in ~1.5s when prompted without the `format` field.

Constraints & Compliance:
- Zero-Trust Security: No hardcoded secrets, safe subshell execution.
- Compatibility: Fully compatible with Bash 3.2+ (macOS default /bin/bash) and Zsh 5.0+. Avoid Bash 4 `declare -A` in libraries.
- Git Conventions: Never run git commit or git push on active repository history.

## Files to Touch

| File                           | Change                                                                                                         |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `PLAN.md`                      | Update project plan with current objectives and checklist                                                      |
| `config/defaults.sh`           | Add `AI_NO_STRUCTURED_OUTPUT="${AI_NO_STRUCTURED_OUTPUT:-false}"`                                              |
| `lib/backends.sh`              | Add `extract_json_object`; support `AI_NO_STRUCTURED_OUTPUT`; auto-retry on `structured output is unavailable` |
| `lib/core.sh`                  | Use `extract_json_object` in `_assemble_commit_message` and `_generate_group_messages_batched`                 |
| `lib/context-analyzer.sh`      | Use `extract_json_object` in `reconcile_grouping_json`                                                         |
| `test/unit/test_backends.bats` | Add tests for `extract_json_object` and structured output fallback retry                                       |
| `test/unit/test_core.bats`     | Add test verifying `_generate_group_messages_batched` handles fenced JSON                                      |

## Steps

1. **Config (`config/defaults.sh`)**:
   - Add default `AI_NO_STRUCTURED_OUTPUT="${AI_NO_STRUCTURED_OUTPUT:-false}"`.
2. **Backend Engine (`lib/backends.sh`)**:
   - Add `extract_json_object`: returns raw JSON object directly, or lifts outermost `{...}` if wrapped in markdown fences/prose.
   - In `build_ollama_request`: skip adding `format` if `AI_NO_STRUCTURED_OUTPUT="true"`.
   - In `invoke_ollama`: if `api_error` matches `structured output is unavailable`, strip `.format`, export `AI_NO_STRUCTURED_OUTPUT=true`, and auto-retry once immediately.
3. **Core & Context Analyzer Integration (`lib/core.sh` & `lib/context-analyzer.sh`)**:
   - In `_assemble_commit_message`: clean raw response with `extract_json_object`.
   - In `_generate_group_messages_batched`: clean response with `extract_json_object` before array length and item extraction.
   - In `reconcile_grouping_json`: clean response with `extract_json_object`.
4. **Automated Tests**:
   - Add unit tests in `test/unit/test_backends.bats` and `test/unit/test_core.bats`.
5. **Verify Test Suite**:
   - Run Bats unit tests and full `./test/run_tests.sh`.

## Tests

- [x] Unit tests for `extract_json_object` with raw JSON and markdown fences pass.
- [x] Unit test for `invoke_ollama` structured output fallback retry passes.
- [x] Unit test for `_generate_group_messages_batched` handling fenced JSON passes.
- [x] Full test runner `./test/run_tests.sh` passes 100%.

## Acceptance Criteria

- [x] `qwen3.5:4b` succeeds without failing on `structured output is unavailable`.
- [x] Subsequent requests in the same session omit `format` when structured output is unavailable.
- [x] Batch and sequential commit messages wrapped in markdown fences parse cleanly.

