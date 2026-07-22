# Perf Report — Round 2: parse memoization (biggest real-world win)

**Date:** 2026-07-21
**File:** `Sources/Textual/MarkdownParser/AttributedStringMarkdownParser.swift`
**Correctness:** `ParserCacheTests` (new, 4), `AttributedStringMarkdownParserTests`, full logic suite pass.

## The finding

`StructuredText.init` parses eagerly:

```swift
self._attributedString = State(
  initialValue: (try? parser.attributedString(for: markup)) ?? .init()
)
```

`State.init(initialValue:)` takes a plain (non-autoclosure) value, so the
argument `parser.attributedString(for: markup)` is **evaluated on every call to
`StructuredText.init`**. SwiftUI keeps the value only on first creation and
discards it thereafter — but the parse has already run. SwiftUI re-instantiates
view structs on every enclosing `body` evaluation, so in any dynamic UI (a list
of messages, a scrolling feed, a view that updates state) the *same* markup is
reparsed on every update.

Measured cost of constructing `StructuredText(markdown:)`:

| Document | Per-init cost (before) |
|----------|-----------------------:|
| 10,280 chars | 2.31 ms |
| (scales linearly — ~7 ms for 33k) | |

Parsing in `init` is deliberate: a recent fix parses synchronously so content
exists on the first layout pass for out-of-band `sizeThatFits` measurement.
So the parse cannot simply be deferred — but it *can* be memoized.

## The change

Added a bounded, main-actor-confined memoization cache to
`AttributedStringMarkdownParser`. Parsing is deterministic in
`(configuration, input)`, so identical inputs reparsed with the same
configuration are served from the cache.

Safety is by construction — the cache is used **only when the full
configuration is known and fingerprintable**:

- The public initializer takes caller-supplied `options` that are opaque and
  not introspectable, so it sets `cacheFingerprint = nil` (never cached).
- The `.markdown(...)` / `.inlineMarkdown(...)` factories know their fixed
  options and encode `baseURL`, soft-break mode, and inline-vs-block into the
  fingerprint.
- Any syntax extensions disable the cache regardless (their replacement
  closures cannot be fingerprinted).

The cache key is `fingerprint + "\u{1}" + input` as an `NSString`, so different
configurations can never collide and the input is matched by exact string
equality. `MarkupParser` is `@MainActor`, so no locking is needed. Cache is
`NSCache` with `countLimit = 64` (bounded, automatically evicts under pressure).

## Results

| Case | Before | After | Speedup |
|------|-------:|------:|--------:|
| `StructuredText(markdown:)` repeated init, same markup (10k) | 2.31 ms | **0.001 ms** | **~2300×** (warm) |
| First (cold) init | 2.31 ms | 2.31 ms | unchanged |
| Round-1 parse benches (use extensions → cache disabled) | 17.6 / 4.4 ms | 17.6 / 4.4 ms | unchanged (verified) |

The first parse of a given markup still costs full price; every subsequent
re-instantiation with identical markup and configuration is effectively free.
This removes the dominant real-world Markdown-parsing cost in dynamic SwiftUI
layouts.

## Correctness guarantees (tested)

`ParserCacheTests` verifies:
- cached output equals freshly-parsed (uncached) output;
- `.spaces` vs `.lineBreaks` soft-break modes are **not** cross-contaminated;
- different `baseURL`s are not cross-contaminated;
- inline vs block parsing are not cross-contaminated.
