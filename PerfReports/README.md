# Textual — Performance Analysis & Optimization

Session date: 2026-07-20. Base commit: `7b45af8`. Machine: Apple Silicon,
macOS 26.5, Swift 6.3.3. All timings release build, serialized suites, median
of 20 iterations unless noted.

## What Textual is

A SwiftUI text/markdown rendering engine (spiritual successor to MarkdownUI).
Pipeline: markup → `AttributedString` (Foundation) → syntax-extension
post-processing (emoji/math) → styling via environment → SwiftUI `Text` layout.
Syntax highlighting for code blocks runs Prism.js over JavaScriptCore.

## Method

Added micro-benchmarks as Swift Testing suites (kept in the repo), profiled by
isolating sub-stages, optimized the controllable hot paths, and re-measured.
Every version — including rejected ones — is documented.

## Reports

| # | Area | Outcome |
|---|------|---------|
| [00](00-baseline.md) | PatternTokenizer baseline | root-cause: per-char regex |
| [01](01-firstmatch-scan.md) | Tokenizer: firstMatch scan | **2.4–10.2× (shipped)** |
| [02](02-tokenizer-final.md) | Tokenizer: cache attempt | rejected (regression) |
| [03](03-codetokenizer.md) | Prism/JSCore highlighter | rejected (bridge not the bottleneck) |
| [04](04-expand-pipeline.md) | expand: prefilter + fast path | **1.1× hit / 10.9× no-trigger (shipped)** |

## Shipped optimizations (behavior-preserving)

1. **PatternTokenizer rewrite** — replaced a per-character anchored
   `prefixMatch` loop (one regex eval + one `String` alloc per character) with
   an earliest-match `firstMatch` scan emitting text in slices. Priority
   semantics preserved.
   - plain prose: **10.2×** · sparse emoji: **6.1×** · math: **2.4×**

2. **Trigger-character prefilter** — patterns declare the chars they require
   (`:`, `$`); a one-pass `contains` check skips the regex engine for runs that
   can't match. Opt-in per pattern; disabled (safe) for custom patterns.

3. **Whole-document fast path in `expand`** — flatten once to `String`, and if
   no trigger char exists anywhere, return the input untouched instead of
   rebuilding the AttributedString.
   - no-emoji/no-math document: expand **6.18 ms → 0.57 ms (10.9×)**

4. **Precomputed token-type → extension map** — removes a per-token array
   allocation in the hot loop.

## Investigated & rejected (negative results, documented)

- **Tokenizer candidate cache** (k-way merge): the bookkeeping cost more than
  the redundant `firstMatch` scans it removed. Regressed the single-pattern
  case. Reverted.
- **CodeTokenizer string-bridge** (return one delimited string from JS instead
  of an array of dicts): perf-neutral — the cost is Prism's JS `tokenize`
  execution, not the JavaScriptCore marshaling. Reverted; flagged a native
  tokenizer / memoization cache as the real (architectural) lever.

## How to run the benchmarks

```
swift test -c release --filter PatternTokenizerBenchmark
swift test -c release --filter MarkdownParserBenchmark

# CodeTokenizer needs the resource bundle located explicitly under SPM CLI:
DIR="$PWD/.build/arm64-apple-macosx/debug"
PACKAGE_RESOURCE_BUNDLE_PATH="$DIR" swift test --filter CodeTokenizerBenchmark
```

## Highest-value next steps (out of scope for safe micro-opts)

- **CodeTokenizer**: native Swift tokenizer for common languages, or a
  memoization cache keyed by `(code, language)`, to escape the Prism/JSCore
  floor (~12.9 ms for a 5,550-token block; ~27 ms one-time init).
- **`Bundle.textual`** cannot be resolved by `swift test`, so the package's own
  `CodeTokenizerTests` only pass under `xcodebuild`. Worth making headless-test
  friendly.
- The AttributedString append rebuild in `expand` (~3.8 ms) is the remaining
  controllable cost on the hit path; reducing it needs an in-place mutation
  strategy rather than append-to-new.
