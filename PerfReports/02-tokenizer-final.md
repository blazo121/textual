# Perf Report — PatternTokenizer FINAL (v1 kept, v2 rejected)

**Date:** 2026-07-20
**Status:** SHIPPED v1. v2 (candidate cache) measured and rejected.
**All numbers serialized** (`@Suite(.serialized)`) to remove parallel-test
CPU contention. Median of 20 iterations, release build.

## Apples-to-apples: baseline vs v1 (both serialized)

| Case | Input chars | Baseline | v1 | Speedup |
|------|------------:|---------:|---:|--------:|
| noMatch (plain prose) | 39,000 | 8.83 | 0.87 | **10.2×** |
| emojiSparse | 127,200 | 28.36 | 4.65 | **6.1×** |
| math (inline+block) | 62,400 | 22.00 | 9.22 | **2.4×** |

Baseline re-measured serialized by temporarily restoring the original file
from `git HEAD`, so this comparison is fair (same test harness, same machine
state, no parallel contamination).

## v1 — what shipped

Rewrote `tokenize` from a per-character anchored `prefixMatch` loop into an
earliest-match scan:

- For each pattern, `firstMatch` over the remaining slice; keep the earliest
  start (ties → lower pattern index, preserving `mathBlock` > `mathInline`).
- Emit the text gap before a match as **one** `String` slice.
- Early-break once a candidate starts exactly at the cursor.
- When no pattern matches the remaining slice, dump the rest as one text token.

Eliminates: one regex evaluation per character, one `String` allocation per
character, and per-character grapheme stepping.

## v2 — candidate cache (REJECTED)

Tried caching each pattern's next match (k-way merge of sorted match streams)
to avoid re-scanning patterns whose match is still ahead of the cursor.

Measured result: **regression.** noMatch 0.87 → 2.36ms, emojiSparse slightly
worse, math unchanged. The enum bookkeeping + per-iteration invalidation loop
cost more than the redundant `firstMatch` scans it removed — especially in the
single-pattern case where there is no redundancy to eliminate. Reverted.

Lesson: `firstMatch` on Swift `Regex` is cheap enough that avoiding re-scans is
not worth per-iteration state management for realistic pattern counts (1–2).

## Remaining bottleneck & why it's left alone

`math` at ~148 ns/char is now regex-engine-bound: two alternation-heavy
patterns (`(?s)\$\$(.+?)\$\$`, `\$(?!\$)((?:\\\$|[^$\n])+)\$`) each scan the
prose between matches looking for `$`. Squeezing further needs
pattern-specific knowledge (e.g. a memchr-style fast scan to the next `$`
before running the regex), which does not belong in a generic tokenizer.
That's a change for the pattern authors, not the scanner.
