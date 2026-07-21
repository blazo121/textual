# Perf Report — Round 6: render-path survey (diminishing returns)

**Date:** 2026-07-21
**Goal:** After rounds 1–5, find any remaining framework-level win in the
per-render path.

## What was surveyed

| Area | Finding |
|------|---------|
| `BlockVStack` / `BlockVStackLayout` | Proper SwiftUI `Layout`; spacings computed once in `makeCache`; `sizeThatFits`/`placeSubviews` are O(n). Clean. |
| `OrderedList` / `UnorderedList` | O(n) per level; marker width via preferences. Nested lists re-segment via `blockRuns` (already fast, round 2). Fine. |
| `TextFragment` overlays | `TextSelectionBackground` is a compile-time no-op on iOS. `AttachmentOverlay` + `TextLinkInteraction` install `Text.Layout` preference machinery — needed for links/attachments (typical messages contain links). |
| `content.attachments()` per render | Builds a `Set` each `TextFragment` body eval, but only ~10 µs for a realistic message. Not worth eliminating. |
| `Font.provider()` reflection | Already memoized in an `NSCache` keyed by font hash (`countLimit 100`). Reflection cost is paid once per distinct font. |
| Parse / blockRuns / isMathBlock / TextBuilder | Optimized in rounds 1–5. |

## The one structural item: `AnyView` per block

Every block (`Paragraph`, `Heading`, list item, `CodeBlock`, `TableCell`, …)
wraps its resolved style in `AnyView(style.resolve(configuration:))` — 34 sites.
`AnyView` defeats SwiftUI's structural diffing, so on an incremental update
SwiftUI rebuilds the block subtree instead of diffing it.

Why it is not addressed:

- It is **architecturally required**. Block styles are read from the
  environment as existentials (`any ParagraphStyle`, etc.); an existential's
  `makeBody` return type is opaque, so it must be erased to be returned from the
  generic block view. SwiftUI's own environment-based styles (`.buttonStyle`,
  `.labelStyle`) do the same internally. Removing it would require threading
  every style as a generic parameter through the whole block tree — a large
  redesign.
- Its practical cost is **mostly moot for a host that rebuilds its whole list**
  (e.g. a full UIKit `reloadData()`). Diffing would not help there regardless,
  because every cell is new. It would only matter under incremental/diffed
  updates.

## Conclusion

Textual's parse and render-prep paths are algorithmically sound and, after five
rounds, well optimized. The remaining candidates are either marginal
(microsecond per-render scans, already-cached reflection) or structurally locked
(`AnyView`, unavoidable with environment-based styling). No safe, high-ROI
framework change was made this round.

The highest-leverage remaining opportunity is **on the integration side**, not
in Textual: when a host embeds `StructuredText` in list cells, the view tree is
typically built twice per cell (height measurement + display) and fully rebuilt
on a full list reload. Caching measured heights and/or using incremental/diffed
list updates removes more real work than any further micro-optimization inside
the framework.
