# Perf Report — v1: firstMatch scan

**Date:** 2026-07-20
**Change:** Replace per-character `prefixMatch` loop with earliest-match scan
using `firstMatch` per pattern; emit text gaps as single slices.
**File:** `Sources/Textual/Internal/MarkdownParser/PatternTokenizer.swift`
**Correctness:** all 11 `PatternTokenizerTests` pass.

## Results (release, median ms, 20 iters)

| Case | Input chars | Baseline | v1 | Speedup |
|------|------------:|---------:|---:|--------:|
| noMatch | 39,000 | 15.34 | 1.53 | **10.0×** |
| emojiSparse | 127,200 | 34.25 | 6.60 | **5.2×** |
| math | 62,400 | 26.96 | 10.16 | **2.7×** |

## What changed

- No-match text is now consumed in a single `firstMatch`-driven scan instead of
  one anchored regex evaluation per character.
- Text between matches is emitted as one `String` slice rather than being
  concatenated one `Character` at a time.
- Priority semantics preserved: patterns iterated in index order; `best` only
  replaced on a strictly-earlier start, so same-position ties keep the
  lower-indexed pattern (e.g. `mathBlock` still beats `mathInline`).
- Added an early break once a candidate match starts exactly at the cursor —
  nothing a lower-priority pattern finds can start earlier.

## Remaining bottleneck

`math` (2 patterns) is now the slowest at ~163 ns/char. Each iteration re-runs
`firstMatch` for *both* patterns over the remaining slice, even though a pattern
whose previous candidate is still ahead of the cursor does not need
recomputing. Next: cache each pattern's next-match and recompute only when the
cursor passes it (k-way merge of sorted match streams).
