# Perf Report — Round 2: block-building results

**Date:** 2026-07-21
**Files:** `Sources/Textual/Internal/Helpers/AttributedString.swift`
**Correctness:** `BlockRunsTests`, `IsMathBlockTests` (new, 5), full logic suite pass.
**Numbers:** release, isolated suite, median of 30–50 iters.

## Changes

### 1. `isMathBlock` — no per-paragraph Set allocation

`Block.defaultBlock` calls `content.isMathBlock` for every paragraph to choose
between `MathBlock` and `Paragraph`. The old implementation called
`attachments()` → `uniqueValues(for: \.textual.attachment)`, building a
`Set<AnyAttachment>` for every paragraph just to test `count == 1` — including
the overwhelmingly common attachment-free paragraph.

Rewrote it as a single run scan with early exits: bail on the second distinct
attachment, and only reach the string extraction / trim when exactly one
block-math attachment is present. No allocation on the common path.

### 2. `BlockRuns` — contiguous ranges, no run re-subscripting

`BlockRuns` segments the parsed string into block-level runs. It previously
retained the entire `AttributedString.Runs` collection and, in
`subscript(position:)`, recomputed each block's range by subscripting the runs
collection twice (`runs[boundary.index]`, `runs.index(before:)`,
`runs[lastRunIndex]`).

Because blocks are contiguous, each block's upper bound equals the next
boundary's lower bound, and the final block ends at the content's `endIndex`.
Now each boundary stores its lower bound directly; `subscript` derives ranges
with no access to the runs collection, and the collection is no longer retained.

## Results (40-unit mixed document)

| Case | Baseline | After | Speedup |
|------|---------:|------:|--------:|
| isMathBlockPerParagraph (120 paras) | 0.585 ms | 0.240 ms | **2.44×** |
| fullBlockWalk (recursive + isMathBlock) | 2.127 ms | 1.43 ms | **1.49×** |
| topLevelBlockRuns (init only) | 0.470 ms | ~0.50 ms | ~flat |

`topLevelBlockRuns` measures `init` + `.count` only (never calls `subscript`),
so it does not see the `subscript` simplification and is within noise. The
representative workload — `fullBlockWalk`, which mirrors `BlockContent`
iterating blocks and running `isMathBlock` — improves ~1.5×.
