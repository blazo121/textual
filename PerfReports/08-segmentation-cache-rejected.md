# Perf Report — Round 2 follow-up: block-segmentation caching (REJECTED)

**Date:** 2026-07-21
**Status:** Investigated with measurements, plumbing REJECTED. Parser-side
experimental code reverted; the decisive benchmark (`cacheKeyVsRecompute`) is
kept as evidence.

## Question

After the parse cache (report 07) removed the dominant per-recreation cost,
`BlockContent.body` still recomputes `content.blockRuns(parent:)` — the block
segmentation — on every render. Can that be cached too?

## Measurement 1 — content-keyed cache is a dead end

A cache keyed by content needs a key derived from the content:

```
BENCH cacheKeyVsRecompute recompute=0.493ms hashValue=3.196ms hashChars=0.016ms
```

- Hashing the `AttributedString` value (the correct key): **3.2 ms — 6× slower
  than recomputing (0.49 ms).**
- Hashing only flattened characters: fast (0.016 ms) but **unsafe** —
  `blockRuns` depends on `presentationIntent`, not characters. `"# Hi"` and
  `"Hi"` both flatten to `"Hi"` (header vs paragraph), so a chars key collides
  and returns the wrong blocks.

Any content-derived key that is *safe* costs ≈ the work it would save. Only an
identity-based (object-identity) cache can win.

## Measurement 2 — identity cache-hit is ~free

Storing the segmentation alongside the parse-cache entry (keyed by the already
cheap `markup + fingerprint`, not content) gives a genuine identity cache:

```
BENCH cachedSegmentation recompute=0.488ms cacheHit=0.001ms
```

Cache-hit is ~0 (≈488×). So the ceiling is real.

## Why the plumbing is rejected anyway

Using the cached segmentation inside `BlockContent` runs into three problems:

1. **Attachment resolution invalidates the indices.** `WithAttachments`
   resolves image/emoji URLs and writes attachment attributes into ranges,
   which splits runs. The `AttributedString` that `BlockContent` actually
   renders is therefore a *different* instance with *different* run boundaries
   than the parsed original. `BlockRuns` stores `AttributedString.Index`
   values from the original — using them against the resolved string is
   unsafe. Safe only for documents with no images/emoji.

2. **Top-level only.** Nested lists, tables, and block quotes re-segment
   substrings that `BlockContent` builds during recursion; those substrings
   have no cheap cache key, so ~0.9 ms of the 1.43 ms full walk still
   recomputes.

3. **Safe guarding is invasive.** Restricting reuse to the attachment-free,
   pre-resolution original means threading an "is-original" signal through
   `StructuredText → WithAttachments → BlockContent`, plus a new `BlockContent`
   parameter and a `StructuredText` `@State` field.

## Verdict

Reward: ~0.5 ms per recreation, top-level only, attachment-free documents only.
Cost: cross-layer plumbing plus a real index-validity hazard that needs
rendering validation. The parse cache already eliminated the dominant cost, so
this is firmly in diminishing-returns territory. **Not shipped.** The
experimental parser-side segmentation cache was reverted; the parse cache
remains as the shipped win.
