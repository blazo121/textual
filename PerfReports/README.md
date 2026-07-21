# Textual — Performance Analysis & Optimization

Single entry point for this performance work. Read this file to understand the
surface, what was changed, what worked, what didn't, and the measured gains.
Each line links to a detailed per-version report (`00`–`12`).

- **Machine:** Apple Silicon (arm64), macOS 26.5, Swift 6.3.3.
- **Base commit:** `7b45af8`.
- **Method:** micro-benchmarks added as Swift Testing suites (kept in the repo),
  each hot path isolated and profiled, optimized, re-measured. Rendering changes
  validated on the iOS simulator against pixel-exact snapshot references.
  Timings are release build, serialized suites, median unless noted.

---

## 1. The surface — what Textual is and how it renders

A SwiftUI text/markdown rendering engine (spiritual successor to MarkdownUI).
A string flows through this pipeline before pixels appear:

```
markup String
  └─ AttributedString(markdown:)         Foundation parse            (opaque, irreducible)
  └─ PatternProcessor.expand             emoji/math syntax extensions
       └─ PatternTokenizer               scan runs for :emoji: / $math$
  └─ StructuredText.BlockContent
       └─ BlockRuns                      segment into block-level runs
       └─ Block (per block)              paragraph / heading / list / code / table …
            └─ isMathBlock               classify paragraph
            └─ TextFragment
                 └─ TextBuilder          AttributedString → SwiftUI.Text
                 └─ CodeTokenizer        Prism.js over JavaScriptCore (code blocks)
       └─ style resolution               environment styles (AnyView per block)
```

Two independently-cacheable entry points sit on top: `StructuredText.init`
(parses eagerly) and the per-cell render when embedded in a scrolling list.

---

## 2. Performance: start → now

Per-stage medians, release build. "Start" = base commit `7b45af8`; "Now" =
after all shipped changes. Each stage is the isolated cost of that step.

| Stage (benchmark) | Start | Now | Gain | Report |
|---|--:|--:|--:|:--:|
| Tokenize plain prose, 39 k chars | 8.83 ms | 0.87 ms | **10.2×** | [01](01-firstmatch-scan.md) |
| Tokenize sparse emoji, 127 k | 28.36 ms | 4.65 ms | **6.1×** | [01](01-firstmatch-scan.md) |
| Tokenize math, 62 k | 22.0 ms | 9.22 ms | **2.4×** | [01](01-firstmatch-scan.md) |
| `expand`, no emoji/math in doc (32 k) | 6.18 ms | 0.57 ms | **10.9×** | [04](04-expand-pipeline.md) |
| `isMathBlock` per paragraph (×120) | 0.585 ms | 0.24 ms | **2.44×** | [06](06-block-building-results.md) |
| Block build + walk (mixed doc) | 2.13 ms | 1.43 ms | **1.49×** | [06](06-block-building-results.md) |
| `StructuredText.init`, same markup re-created | 2.31 ms | 0.001 ms | **~2300×** | [07](07-parse-memoization.md) |
| Code re-tokenize on scrollback (per block) | ~12 ms | ~0 ms | **~1370×** | [10](10-chat-usage-caches.md) |
| `Text` values built per render (23-run msg) | 23 | 3 | **7.7× fewer** | [11](11-textbuilder-coalescing.md) |

Not everything moved: **Foundation `AttributedString(markdown:)` is
irreducible** (~0.36 µs/char, linear; no options/scope help) and remains the
floor of a cold parse — see [09](09-foundation-parse-and-incremental.md).

### What this means in practice
- Repeated renders / scrollback (the dominant real cost in list UIs) are now
  near-free: parse, code tokenization, and `Text` construction are all cached or
  collapsed.
- A first (cold) render of a message is dominated by Foundation's parse, which
  is small at message scale (0.05–0.95 ms for 10–100-line messages,
  [10](10-chat-usage-caches.md)).

---

## 3. How we improved speed (techniques by pipeline stage)

- **Scan, don't re-scan (tokenizer).** Replaced a per-character anchored
  `prefixMatch` loop with an earliest-match `firstMatch` scan; text emitted in
  slices, not char-by-char. Added a trigger-char prefilter (`:` / `$`) so runs
  that can't match skip the regex engine entirely. [01](01-firstmatch-scan.md), [04](04-expand-pipeline.md)
- **Whole-document fast path.** If no trigger char exists anywhere, `expand`
  returns the input untouched instead of rebuilding the AttributedString. [04](04-expand-pipeline.md)
- **Stop allocating on the hot path.** `isMathBlock` early-exits instead of
  building a `Set<AnyAttachment>` per paragraph; `BlockRuns` stores boundary
  indices instead of retaining and re-subscripting the runs collection. [06](06-block-building-results.md)
- **Memoize deterministic work.** Parse output is cached by
  `(config fingerprint, input)`; code tokenization by `(code, language)`. Both
  keyed so different configurations never collide. [07](07-parse-memoization.md), [10](10-chat-usage-caches.md)
- **Coalesce SwiftUI Text.** Emit one `Text` per attachment/link run and merge
  every maximal span of plain styled runs into a single `Text(AttributedString)`
  (which renders bold/italic/code/background natively). [11](11-textbuilder-coalescing.md)

---

## 4. What we did — shipped, and why it was good

All behavior-preserving; correctness covered by unit and (for rendering)
pixel-exact snapshot tests.

| # | Change | Why it's good | Report |
|---|--------|---------------|:--:|
| 1 | PatternTokenizer `firstMatch` scan + slice emit | one linear scan vs one regex + one alloc per char | [01](01-firstmatch-scan.md) |
| 2 | Trigger-char prefilter (`:`/`$`) | plain runs skip the regex engine | [04](04-expand-pipeline.md) |
| 3 | `expand` whole-doc fast path + precomputed token-type map | no rebuild when nothing to expand | [04](04-expand-pipeline.md) |
| 4 | `isMathBlock` early-exit (no Set alloc) | per-paragraph allocation removed | [06](06-block-building-results.md) |
| 5 | `BlockRuns` contiguous ranges | drops retained runs + re-subscripting | [06](06-block-building-results.md) |
| 6 | Parse memoization in `AttributedStringMarkdownParser` | eager reparse on every SwiftUI re-init eliminated | [07](07-parse-memoization.md) |
| 7 | `CodeTokenizer` cache by `(code, language)` | avoids repeated Prism/JSCore on scrollback | [10](10-chat-usage-caches.md) |
| 8 | Parse cache `countLimit` 64 → 256 | keeps long-list scrollback warm | [10](10-chat-usage-caches.md) |
| 9 | `TextBuilder` run coalescing | fewer `Text`/allocations per render; kills deep concat nesting | [11](11-textbuilder-coalescing.md) |

---

## 5. What was bad — investigated and rejected (negative results)

Kept here so nobody re-tries them without the evidence.

| Idea | Why rejected | Report |
|------|--------------|:--:|
| Tokenizer candidate cache (k-way merge) | bookkeeping cost > redundant scans removed; regressed the single-pattern case | [02](02-tokenizer-final.md) |
| CodeTokenizer JS→string bridge | perf-neutral — the cost is Prism's JS execution, not JSCore marshaling | [03](03-codetokenizer.md) |
| Block-segmentation cache (content-keyed) | a *safe* key (hashing the AttributedString) costs more than recomputing; identity cache blocked by attachment-resolution index hazard, top-level only | [08](08-segmentation-cache-rejected.md) |
| Incremental/streaming block parse | 4.3× on huge streamed docs, but over-engineered at message scale (worst step ~1 ms, no jank); bounded by AttributedString assembly | [09](09-foundation-parse-and-incremental.md) |
| Removing `AnyView` per block | architecturally required by environment-based styling; SwiftUI's own styles do the same; near-zero payoff under full-list reloads | [12](12-render-path-survey.md) |

---

## 6. What's left (out of scope / low ROI)

- **Foundation cold parse** is the remaining floor — not ours to optimize.
- Render-path micro-scans (`attachments()`, etc.) are ~10 µs — not worth it;
  `Font.provider()` reflection is already NSCache-memoized. [12](12-render-path-survey.md)
- **Biggest remaining lever is integration-side, not in Textual:** a host that
  embeds `StructuredText` in list cells typically builds the tree twice per cell
  (measure + display) and rebuilds all cells on a full list reload. Caching
  measured heights and using incremental/diffed list updates removes more real
  work than any further micro-opt inside the framework. [12](12-render-path-survey.md)

---

## 7. Report index

| # | Area | Outcome |
|---|------|---------|
| [00](00-baseline.md) | PatternTokenizer baseline | root-cause: per-char regex |
| [01](01-firstmatch-scan.md) | Tokenizer: firstMatch scan | **2.4–10.2× (shipped)** |
| [02](02-tokenizer-final.md) | Tokenizer: cache attempt | rejected (regression) |
| [03](03-codetokenizer.md) | Prism/JSCore highlighter | rejected (bridge not the bottleneck) |
| [04](04-expand-pipeline.md) | expand: prefilter + fast path | **1.1× hit / 10.9× no-trigger (shipped)** |
| [05](05-block-building-baseline.md) | block-building baseline | root-cause: per-para Set alloc |
| [06](06-block-building-results.md) | isMathBlock + BlockRuns | **2.4× / 1.5× (shipped)** |
| [07](07-parse-memoization.md) | StructuredText reparse-on-init | **~2300× warm repeated init (shipped)** |
| [08](08-segmentation-cache-rejected.md) | block-segmentation cache | rejected (index hazard, modest gain) |
| [09](09-foundation-parse-and-incremental.md) | Foundation parse + streaming | irreducible parse; streaming rejected |
| [10](10-chat-usage-caches.md) | message-list usage (simulator) | **CodeTokenizer cache ~1370× scrollback; parse cache 64→256 (shipped)** |
| [11](11-textbuilder-coalescing.md) | TextBuilder run coalescing | **7.7× fewer Text values/render; pixel-identical (shipped)** |
| [12](12-render-path-survey.md) | render-path survey | no safe high-ROI win left; lever is integration-side |

---

## 8. How to run the benchmarks

```
swift test -c release --filter PatternTokenizerBenchmark
swift test -c release --filter MarkdownParserBenchmark
swift test -c release --filter BlockRunsBenchmark
swift test -c release --filter FoundationParseBenchmark
swift test -c release --filter ChatScaleBenchmark

# CodeTokenizer needs the resource bundle located explicitly under SPM CLI:
DIR="$PWD/.build/arm64-apple-macosx/debug"
PACKAGE_RESOURCE_BUNDLE_PATH="$DIR" swift test --filter CodeTokenizerBenchmark

# Rendering (snapshot) validation runs on the iOS simulator:
xcodebuild test -scheme Textual -destination 'platform=iOS Simulator,name=iPhone 17'
```
