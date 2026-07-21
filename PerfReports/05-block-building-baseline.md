# Perf Report — Round 2 Baseline: block-building path

**Date:** 2026-07-21
**Base:** commit `829b4b3` (round-1 optimizations already in place)
**Build:** `swift test -c release --filter BlockRunsBenchmark`
**Machine:** Apple Silicon (arm64), macOS 26.5, Swift 6.3.3

## Scope

After `attributedString(for:)` produces the parsed `AttributedString` (round 1),
`StructuredText` turns it into renderable blocks:

- `BlockContent.body` calls `content.blockRuns(parent:)` to segment the string
  into block-level runs by `PresentationIntent` boundaries.
- For each block, `Block.defaultBlock` switches on the intent kind; every
  paragraph runs `content.isMathBlock` to decide between `MathBlock` and
  `Paragraph`.
- List / quote / table blocks recurse via `blockRuns(parent:)`.

All of this is pure Swift (no SwiftUI layout) and runs on the first render pass,
so it is part of the perceived "parse" cost.

## Baseline numbers (40-unit mixed document)

| Case | Count | median |
|------|------:|-------:|
| topLevelBlockRuns | 320 blocks | 0.470 ms |
| fullBlockWalk (recursive + isMathBlock) | 480 items | 2.127 ms |
| isMathBlockPerParagraph | 120 paragraphs | 0.585 ms |

## Root-cause candidates

1. **`isMathBlock` allocates a `Set<AnyAttachment>` per paragraph.** It calls
   `attachments()` → `uniqueValues(for: \.textual.attachment)`, which walks all
   runs and inserts into a `Set` just to test `count == 1`. For the common case
   (a paragraph with no attachment) this builds and throws away an empty set on
   every paragraph. ~4.9 µs/paragraph. Target: early-exit scan, no allocation.

2. **`BlockRuns.init`** computes `presentationIntent?.intent(before:)` per run
   and appends boundaries. Top-level (`parent == nil`) reduces to
   `components.last` per run — cheap — but nested segmentation runs
   `components.firstIndex(of:)`. Measure whether it's worth touching after (1).

## Plan

Optimize `isMathBlock` first (clearest allocation win, directly measured),
re-measure `isMathBlockPerParagraph` and `fullBlockWalk`, then reassess
`BlockRuns`.
