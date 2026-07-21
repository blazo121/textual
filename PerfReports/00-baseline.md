# Perf Report — Baseline (v0)

**Date:** 2026-07-20
**Commit base:** 7b45af8
**Build:** `swift test -c release --filter PatternTokenizerBenchmark`
**Machine:** Apple Silicon (arm64), macOS 26.5, Swift 6.3.3

## Scope

`PatternTokenizer.tokenize(_:)` — the post-parse scanner that splits an
`AttributedString` run into text / emoji / math tokens for syntax-extension
expansion (custom emoji, LaTeX math). Runs on every non-preformatted run of
every parsed document when any syntax extension is enabled.

## Baseline numbers

| Case | Input chars | min | median | mean | ns/char (median) |
|------|------------:|----:|-------:|-----:|-----------------:|
| noMatch (plain prose) | 39,000 | 12.53 | 15.34 | 15.36 | ~393 |
| math (inline+block) | 62,400 | 25.52 | 26.96 | 27.33 | ~432 |
| emojiSparse | 127,200 | 30.98 | 34.25 | 36.71 | ~269 |

## Root-cause analysis

Current algorithm (`PatternTokenizer.tokenize`) is O(n · patterns) in regex
invocations plus O(n) small allocations:

1. **Per-character regex scan.** For every character position that is not the
   start of a match, the loop calls `pattern.regex.prefixMatch(...)` for *each*
   pattern. A 39,000-char plain paragraph with zero emoji still fires 39,000
   anchored regex evaluations — each with its own engine setup cost. This is
   the dominant cost.

2. **Per-character string building.** The no-match branch does
   `String(input[currentIndex])` (a fresh `String` allocation per char) and
   `tokens[last].content += content` (amortized-but-repeated `String` growth),
   plus `input.index(after:)` UTF-8 grapheme stepping per char.

3. **Dead branch.** `prefixMatch` is anchored at the slice start, so
   `match.range.lowerBound` always equals `currentIndex`; the "add any text
   before the match" block can never execute. All text accrues through the slow
   per-char path.

## Optimization plan

Replace per-position `prefixMatch` with per-pattern `firstMatch` over the
remaining slice: find the earliest match across all patterns (ties broken by
pattern order, preserving current priority semantics), emit the gap as a single
text token, emit the match token, advance the cursor. This turns the whole
tokenize into ~one linear regex scan per pattern instead of one scan per
character, and emits text in slices instead of char-by-char.

Expected: large win on `noMatch` (one scan vs 39k), solid win on sparse cases.
Target: correctness unchanged (all 11 existing `PatternTokenizerTests` pass).
