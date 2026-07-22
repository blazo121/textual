# Perf Report — Round 5: TextBuilder run coalescing (on-device validated)

**Date:** 2026-07-21
**File:** `Sources/Textual/Internal/TextFragment/TextBuilder.swift`
**Validated on:** iPhone 17 simulator (iOS 26.5) — snapshot suite + live app.

## Motivation (from observed chat usage)

Chat messages are heavily inline-formatted (bold, italic, many inline `code`
spans). Each inline-style boundary is a separate `AttributedString` run, and
`TextBuilder` built **one SwiftUI `Text` per run** plus one sub-`AttributedString`
allocation per run, then combined them with `reduce(Text("") + …)`. For a real
representative message that is dozens of `Text` values (and a deep concatenation
chain) rebuilt on every body evaluation while scrolling.

## Change

Only attachment runs (sized placeholders tagged `AttachmentAttribute`) and link
runs (tagged `LinkAttribute` for `TextLinkInteraction`) need their own `Text`.
Every other run carries only styling — bold/italic/code font, foreground and
background color — which a single `Text(AttributedString(_:))` renders natively
across many runs. So the builder now coalesces each maximal span of plain styled
runs into one `Text`, emitting attachment/link runs individually.

## Result

For a representative message: **23 runs → 3 `Text` values (7.7×)**;
the multi-screen messages (~50–100 runs) collapse to a handful. Fewer `Text`
values and sub-`AttributedString` allocations per render, per visible cell during
scroll, and no more deep `+` nesting (which previously risked a stack overflow —
see the 2,500-run guard test).

## On-device validation

- **Snapshot + logic suite on the iOS simulator: 198 tests / 34 suites pass, 0
  mismatches.** The snapshot tests render the full pipeline
  (`StructuredText → BlockContent → Paragraph → TextFragment → TextBuilder`) and
  pixel-compare against references for headings, inline styles (emphasis, code,
  strikethrough, links), lists, tables, code blocks, quotes, and math. Rendering
  is **pixel-identical** to before.
- **`renderingManyAttributedRunsDoesNotOverflowStack` (2,500 runs)** passes —
  now collapses to ~1 `Text`.
- **Live `TextualDemo`** on the simulator: a real-world GitHub README renders
  correctly (heading, inline `code`, blue links, block quote, mixed inline
  formatting); tapping a link is handled (interaction preserved).

## Interaction with custom block resolvers

A paragraph can be rendered by a custom `BlockResolver` (e.g. one that draws
paragraphs containing a custom inline attribute with its own view) instead of
the default `Paragraph` → `TextFragment` → `TextBuilder` path. In that case the
resolver builds its own `Text`, so this coalescing does not affect it. The
change only touches paragraphs that fall through to the default renderer.

Validation was performed on the iOS simulator via the package snapshot suite and
the bundled `TextualDemo` app.
