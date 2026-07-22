# Perf Report — Round 3: Foundation parse cost + incremental block parsing

**Date:** 2026-07-21
**Goal:** reduce the cost of Foundation's opaque `AttributedString(markdown:)`,
the largest remaining parse cost.
**Build:** `swift test -c release --filter FoundationParseBenchmark`,
`… --filter StreamingParseBenchmark`

## 1. Can the Foundation parse itself be made cheaper? No.

| Variant (40-unit doc, ~11.6k chars) | median |
|-------------------------------------|-------:|
| `\.textual` scope, default options | 4.36 ms |
| `\.foundation` scope | 4.22 ms |
| `allowsExtendedAttributes: true` | 4.07 ms |
| `interpretedSyntax: .inlineOnly…` | 1.74 ms |

- The custom `\.textual` attribute scope costs ~3% over `\.foundation` —
  negligible, not worth changing.
- `allowsExtendedAttributes` makes no meaningful difference.
- `inlineOnly` is 2.5× faster but **drops block structure** (no paragraphs,
  headings, lists) — unusable for `StructuredText`.

Scaling is linear (~0.36 µs/char: 2910 chars → 0.92 ms, 23280 chars → 8.36 ms).
**Conclusion: the Foundation cold parse is irreducible from our side.** No option
or scope change is a free win.

## 2. The real pathology: streaming reparse is O(n²)

Growing a document one block at a time and reparsing the whole thing each step
(today's behavior — the round-2 whole-markup cache misses on every distinct
growing string):

```
BENCH streamingWholeDocReparse steps=40 finalChars=11640 totalMS=80.7ms
```

A single full parse of the final 11.6k document is 4.1 ms; streaming it in 40
steps costs **80.7 ms** — ~20× waste. This is exactly the AI-chat / streaming
Markdown case, and it is quadratic in document length.

## 3. Solution: incremental block-level parsing

Split the document into top-level block chunks, parse each independently, cache
per chunk, and stitch. Appending text only reparses the changed (tail) block.

### Correctness — the hard part, fully validated

Parsing a block in isolation reuses low presentation-intent identity numbers, so
naive concatenation makes adjacent same-kind blocks collide (two paragraphs both
`id 1`) — which would merge them during block segmentation. Fixed by **remapping
every intent identity to a globally-unique value** while preserving within-chunk
grouping (a list's items keep a shared list identity). `PresentationIntent` is
fully reconstructable via `PresentationIntent(kind, identity:, parent:)`.

The splitter is CommonMark-aware:
- fenced code blocks are atomic;
- lists and block quotes are grouped across their internal blank lines (loose
  lists stay one list);
- indented code blocks (blank-separated chunks) stay one block;
- setext headings stay attached (no blank separates them from their text);
- **reference link definitions** (`[label]: url`) are document-scoped and
  cross-block, so their presence disables splitting (safe whole-parse fallback).

Validated by a **differential oracle** comparing the stitched parse to a
whole-document parse (block structure + text + inline attributes), across:
- 15 targeted fixtures,
- ~225 combinatorial block pairs + sampled triples,
- the repository's real README,
- a diverse 9-step streaming sequence (stateful path).

All pass.

### Performance

| Scenario | Whole-reparse | Incremental | Speedup |
|----------|--------------:|------------:|--------:|
| Streaming, stateless (stitch every step) | 81.3 ms | 36.1 ms | 2.25× |
| Streaming, **stateful** (re-remap changed suffix only) | 80.5 ms | 18.6 ms | **4.34×** |
| Cold single parse (chunked vs whole) | 4.05 ms | 5.23 ms | 0.78× (**slower**) |

Only ~5 chunk parses occur across the whole stream (stable blocks are cache
hits) — parsing is nearly eliminated. The residual cost is **`AttributedString`
assembly**: the type is not a rope, so concatenating the accumulated result each
step is O(n), leaving streaming at O(n²) with a tiny constant. ~4.3× is the
practical ceiling for a single-string result.

True O(n) streaming would require rendering from separate per-block strings
(append-only), but `StructuredText` intentionally uses one `AttributedString`
for cross-block text selection — re-architecting that is out of scope.

## 4. Decision: not worth it at real chat scale — REJECTED

The incremental work targets *large* streamed documents. Measured at the actual
target workload (chat messages, ~10 lines typical, ~100 lines large), from
`ChatScaleBenchmark`:

| Scenario | cost |
|----------|-----:|
| Single parse, 10-line (204 chars) | 0.045 ms |
| Single parse, 100-line (2406 chars) | 0.95 ms |
| Streaming 10-line, ~4 chars/token | 1.4 ms total, worst step 0.05 ms |
| Streaming 100-line, ~4 chars/token | 285 ms total, **worst step 1.08 ms** |

The worst single reparse step is ~1 ms — 16× under a 60 fps frame budget, so
streaming causes no dropped frames. The 285 ms on a 100-line message is
cumulative CPU spread across the multi-second stream (~single-digit % CPU), not
a hitch. Incremental parsing would cut that ~4× but yields nothing perceptible.

**Verdict: the streaming/incremental parser is over-engineering for chat-scale
messages and was not productized.** The validated prototype and its benchmarks
were removed; this report retains the full analysis (Foundation parse is
irreducible; the O(n²) streaming shape; the correctness approach and its 4.3×
ceiling) for reference if very large streamed documents ever become a target.

## What actually helps chat

The already-shipped round-2 wins are the relevant ones for a chat UI:

- **Parse memoization** — scrolling a message list re-instantiates each
  `StructuredText`; identical markup now hits the cache (~0 ms) instead of
  reparsing (report 07).
- **isMathBlock / BlockRuns** — cheaper per-render block building as messages
  scroll (report 06).

`FoundationParseBenchmark` and `ChatScaleBenchmark` remain as evidence and
regression guards.
