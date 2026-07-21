# Perf Report — v2: expand pipeline (trigger prefilter + doc fast path)

**Date:** 2026-07-20
**Files:**
- `Sources/Textual/Internal/MarkdownParser/PatternTokenizer.swift`
- `Sources/Textual/Internal/MarkdownParser/PatternProcessor.swift`

**Correctness:** `PatternTokenizerTests` (11), `PatternProcessorTests`,
`AttributedStringMarkdownParserTests` (3) all pass.
**Numbers:** release, isolated suite (each suite run alone to avoid cross-suite
parallel contention), median of 20 iters.

## Where the parse time goes (33,300-char doc, emoji+math enabled)

Established with instrumented sub-benchmarks:

| Stage | median | note |
|-------|-------:|------|
| full parse (`attributedString(for:)`) | 18.8 ms | |
| Foundation `AttributedString(markdown:)` | 7.4 ms | opaque, not ours |
| our `expand` post-pass | **11.6 ms** | **62% of total — ours to fix** |
| — of which: run-walk + append rebuild | 3.8 ms | |
| — of which: String extraction (780 runs) | 0.5 ms | |
| — of which: tokenize (780 runs × 3 patterns) | ~4.5 ms | |
| — of which: firstMatching + per-token append | ~2.8 ms | |

`expand` was the single largest controllable cost — larger than Foundation's
own markdown parse.

## Changes

### 1. Trigger-character prefilter (`PatternTokenizer`)

Each built-in `Pattern` now declares the characters without which its regex
cannot match (`:` for emoji, `$` for math). When *every* pattern in a tokenizer
declares triggers, `tokenize` first does one cheap `contains(where:)` scan and
returns a single text token immediately if no trigger is present — skipping the
regex engine for plain prose runs. Patterns with no declared triggers (custom
user patterns) disable the prefilter, so behavior is unchanged for them.

### 2. Whole-document fast path (`PatternProcessor.expand`)

Before rebuilding the AttributedString, flatten it to a `String` **once** and
scan for any trigger. If none is present, return the input untouched — skipping
the entire per-run rebuild. (First attempt scanned `AttributedString.characters`
directly and cost 6 ms; its per-element traversal walks attribute storage. A
one-shot `String(...)` extraction + `String.contains` is ~10× cheaper.)

### 3. Precomputed token-type → extension map

`firstMatching` allocated an array (`patterns.map(\.tokenType)`) per non-text
token. Replaced with a `[TokenType: SyntaxExtension]` dictionary built once in
`init`.

## Results

| Case | Before | After | Speedup |
|------|-------:|------:|--------:|
| tokenize `noMatch` (plain, 39k) | 0.87 ms | 0.64 ms | 1.36× |
| `extractAndTokenize` (780 runs) | 5.04 ms | 3.95 ms | 1.28× |
| `expandOnly` (trigger doc, 33k) | 11.6 ms | 10.5 ms | 1.10× |
| **`expandNoTriggersOnly` (no `:`/`$`, 32k)** | **6.18 ms** | **0.57 ms** | **10.9×** |

## Impact summary

- **Documents that enable extensions but contain no emoji/math** (a very common
  defensive configuration) now skip the entire expand rebuild: expand drops
  from ~6 ms to ~0.6 ms.
- **Documents that do contain emoji/math** get a smaller but free ~10% expand
  win from the per-run prefilter and the lookup map; the extra one-shot
  flatten on the hit path is within measurement noise.
- The Foundation markdown parse (7.4 ms) and the AttributedString append
  rebuild (3.8 ms) are the remaining floor and are not cheaply compressible
  without changing output semantics.
