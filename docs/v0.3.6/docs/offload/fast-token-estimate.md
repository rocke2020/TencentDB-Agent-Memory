# Fast Token Estimator

## TL;DR

`src/offload/fast-token-estimate.ts` is a cheap, character-class-based estimator used before expensive `tiktoken` counting in the context-offload `assemble()` path. In this repo, CJK Han text is effectively estimated by a built-in fallback constant (`1.3` tokens per recognized Han character) plus a small adjacent-run discount; there is no required runtime token-table file.

## Implementation

The estimator exports `fastEstimateTokens(text)` and `fastEstimateMessages(messages, jsonReplacer?)`. It does one pass over the input after a short Latin-language pre-scan, classifies code units by script/category, adds tuned coefficients, and rounds the final total.

### `fastEstimateTokens(text)`

`fastEstimateTokens` returns `0` for empty input and otherwise returns at least `1`. It uses arithmetic over `charCodeAt` values; it does not run BPE, split by regex, or call `tiktoken`.

The main categories are:

- **Latin words**: scans contiguous Latin letters, with apostrophe support. English-like words use length buckets (`<=4`, `<=8`, `<=13`, longer); accented/non-English Latin words use higher buckets after a 50K-char accent pre-scan.
- **CJK Han**: recognizes U+4E00..U+9FFF, U+3400..U+4DBF, and U+F900..U+FAFF. In this repo's normal runtime path, each recognized Han char contributes `1.3` tokens before adjacent-run discounts (`run>=4` uses `0.94`, `run>=2` uses `0.97`).
- **Kana**: scans adjacent Hiragana/Katakana and uses run-length coefficients.
- **Hangul, Cyrillic, Arabic, Greek**: uses per-character or per-run coefficients.
- **Digits**: scans number runs and has separate handling for comma and decimal groupings.
- **Whitespace and punctuation**: spaces/tabs are skipped, newlines count as `1.0`, fullwidth punctuation counts as `1.0`, ASCII punctuation counts as `0.6`.
- **Other Unicode**: counts as `2.5` tokens per code unit.

The source still contains an obsolete CJK-table loader path. This repo has no `token_count/` directory, no tracked table artifact, and no git-history evidence that the table was ever shipped here, so the loader is dead code in normal checkout/package usage. The effective behavior is the fallback described above.

### `fastEstimateMessages(messages, jsonReplacer?)`

`fastEstimateMessages` serializes each message with `JSON.stringify`, sums `fastEstimateTokens` over those strings, and adds `Math.ceil(messages.length * 0.5)` for JSON array overhead. This intentionally estimates serialized message shape rather than only message content.

## Runtime Usage

The runtime caller is `src/offload/index.ts` inside `assemble()`. The estimator is used as a triage gate before `buildTiktokenContextSnapshot` / precise `tiktoken` counting, so obviously-small contexts can avoid the slow path.

The main uses are:

- **Raw trace estimate**: `_rawMsgTokens = fastEstimateMessages(workMessages)` before fast-path re-apply. This is for debug logging/tracing.
- **L3 compression triage**: `fastEst = fastEstimateMessages(workMessages) + systemTokensEstimate + promptLengthEstimate`.
- **Boundary incremental estimate**: after a boundary delete, new tail messages are estimated with `fastEstimateMessages` and added to the cached post-aggressive token count.

The key safety knob is `FAST_EST_SAFETY_MARGIN = 0.85`. `assemble()` only skips precise counting when `fastEst < aggressiveThreshold * 0.85`, which means the estimate must be at least 15% below the aggressive-compression threshold. For example, if `aggressiveThreshold` is `100_000`, the fast-skip cutoff is `85_000`; `fastEst=84_000` skips precise `tiktoken`, while `fastEst=90_000` is too close to the boundary and falls back to a precise count unless the tail-accumulate path will do its own precise recount later.

## Benchmark

`src/offload/benchmark-token-estimate.ts` is a standalone benchmark script, not a Vitest suite. It compares `fastEstimateTokens` against `js-tiktoken` `cl100k_base` on optional corpus files plus two synthetic agent workloads.

The script looks for optional corpus files under `token_count/corpus/` and skips them when absent. It always adds:

- `json_messages`: repeated JSON message/tool-result payloads.
- `mixed_code_zh`: repeated TypeScript plus Chinese comments/text.

For each case, it prints chars, precise tiktoken count, estimate, error percentage, timing, and speedup.

## Tests

`src/offload/fast-token-estimate.test.ts` covers the current CJK fallback behavior. It verifies the expected rounded estimates for basic CJK and the Han ranges recognized by the current implementation.

## Filesystem Dependencies

There is no required runtime filesystem dependency for the estimator in this repo. The CJK table loader path in source is obsolete/dead code because the table artifact is not present or tracked. The benchmark can optionally read corpus files if a local `token_count/corpus/` directory exists.

## Design Notes

The estimator targets rough `cl100k_base`-style behavior, but it is intentionally a decision heuristic rather than an authoritative tokenizer. Runtime paths that need exact token math still fall back to `tiktoken`.
