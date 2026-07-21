# Perf Report — CodeTokenizer (Prism-over-JavaScriptCore)

**Date:** 2026-07-20
**Status:** Investigated, optimization REJECTED (negative result). Benchmark kept.
**Numbers:** debug build (release cannot resolve the resource bundle under
`swift test` — see note), JSCore engine speed is build-config-independent.
Serialized suite, median of 30 iters (tokenize) / 5 (init).

## Harness note

`swift test` (SPM CLI) cannot locate `textual_Textual.bundle`, so
`CodeTokenizer()` returns `nil` and even the repo's own `CodeTokenizerTests`
fail unless run via `xcodebuild`. Workaround for benchmarking:

```
DIR="$PWD/.build/arm64-apple-macosx/debug"
PACKAGE_RESOURCE_BUNDLE_PATH="$DIR" swift test --filter CodeTokenizer
```

(`PACKAGE_RESOURCE_BUNDLE_PATH` is honored only in DEBUG by `Bundle.textual`;
it must point at the *directory containing* the `.bundle`.)

## Baseline

| Metric | Value |
|--------|------:|
| init (eval 138 KB Prism bundle, once, on `.shared`) | ~27.3 ms |
| tokenize 14,130 chars → 5,550 tokens | ~12.9 ms (~2.3 µs/token) |

## Hypothesis and what was tried

Hypothesis: the `result.toArray() as? [[String: String]]` call deep-converts
5,550 JS objects into an `NSArray` of `NSDictionary` across the JavaScriptCore
bridge, one dictionary per token — expected to dominate.

Change: added `tokenizeCodeString` to the Prism bundle returning a single
delimited string (`U+001F` between type/content, `U+001E` between tokens); Swift
split it once instead of bridging N dictionaries.

## Result: REJECTED — no measurable speedup

| | Baseline (array) | String bridge |
|--|-----------------:|--------------:|
| tokenize median | 12.87 ms | 12.65 ms |

The difference is within run-to-run noise. **The bridge is not the
bottleneck** — the cost is Prism's `tokenize` JavaScript execution itself.
Bridging 5,550 dictionaries is cheap relative to the JS engine work. Correctness
was fine (existing tests passed with the string variant), but a perf-neutral
change that adds a second JS entry point and a fragile control-character
protocol is not worth the complexity. Reverted.

## Where the time actually goes & recommendations

- **~12.9 ms is Prism JS execution**, not marshaling. No Swift-side trick
  removes it; it is the floor of running Prism over JavaScriptCore.
- Real wins would require: (a) a **native Swift tokenizer** for the common
  languages (removes JSCore entirely), or (b) a **memoization cache** keyed by
  `(code, language)` so identical snippets across views tokenize once. Today
  `HighlightedTextFragment` keys `.task(id: content)`, so re-tokenization only
  happens on content change within a single view — a shared cache would help
  documents that repeat snippets or re-mount views.
- **init 27 ms** is paid once (actor is a `.shared` singleton) and runs off the
  main actor, so it is not on the critical UI path. Splitting the 138 KB
  monolith into per-language lazy grammars could cut it, but the payoff is a
  one-time cost — low priority.

## Verdict

CodeTokenizer's latency is inherent to the Prism/JSCore approach. Flagged for
the maintainers as the highest-value *architectural* target (native tokenizer
or cache), but out of scope for a safe, behavior-preserving micro-optimization.
