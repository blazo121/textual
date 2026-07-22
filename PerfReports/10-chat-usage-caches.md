# Perf Report — Round 4: message-list usage (simulator observation)

**Date:** 2026-07-21
**Method:** Observed a representative markdown message-list workload rendered
with Textual in the iOS Simulator (via `xcrun simctl io booted screenshot` and,
later, RocketSim).

## Observed usage

A long, scrolling feed of markdown messages. Formatting in view: bold headings,
nested bullet lists, inline `code` spans (monospace), italics, emoji, links, and
occasional fenced code blocks. Messages are ~10 lines typically, up to ~100.

This is a message-list workload, which stresses things a single-document
benchmark does not: **the same content is parsed and tokenized repeatedly as
cells scroll out of and back into view.**

## Two scrollback costs, both now cached

### 1. Syntax-highlight re-tokenization (Prism / JavaScriptCore)

`HighlightedTextFragment` tokenizes code blocks in `.task(id: content)`. Each
time a cell re-mounts (scroll away and back) the task restarts and re-runs
Prism over JavaScriptCore — ~12 ms per code block — with no cache. In a feed
with code blocks this is repeated JSCore work (CPU/battery, plus a visible
unhighlighted→highlighted flash).

Added an actor-confined memoization cache in `CodeTokenizer` keyed by
`(code, language)` (tokenization is deterministic), bounded at 256 entries with
FIFO eviction.

| | time |
|--|-----:|
| tokenize miss | 2.89 ms (debug sample; ~12 ms for real blocks) |
| tokenize **hit** | **0.002 ms** (~1370×) |

Correctness (`CodeTokenizerCacheTests`): cache hit equals a fresh tokenization,
and different languages are never shared (keyed on both code and language).

### 2. Parse cache size for scrollback

The parse memoization cache (report 07) was `countLimit = 64`. A busy feed has
hundreds of messages, so scrolling back more than 64 distinct messages evicted
entries and forced re-parses. Raised to `256` (NSCache still evicts under memory
pressure regardless), so typical scrollback stays warm.

## Why not more

The Foundation cold parse (first time each message appears) is irreducible
(report 09) and already small at message scale (0.05–0.95 ms). Block building
and first-parse memoization were handled in round 2. The remaining repeated
costs specific to a scrolling feed were the two caches above; both are now ~free
on re-visit.

## On-device observation

Scrolling a representative feed of automated, formatted messages:

- Messages are long, multi-block (several headings + nested lists +
  paragraphs), **heavily inline-formatted** — bold, italic, and many inline
  `code` spans, plus emoji. A short representative message (549 chars) parses to
  **24 runs**; the larger multi-screen messages run ~50–100 runs each.
- Some feeds use **inline code only, no fenced code blocks**, in which case the
  Prism/JavaScriptCore highlighter is not exercised; the CodeTokenizer cache
  pays off in feeds that do post fenced code (e.g. LLM output), and is otherwise
  harmless.
- Feeds have many distinct messages → scrollback benefits from the larger parse
  cache.

### Flagged (later shipped in round 5, see report 11)

`TextBuilder` builds one SwiftUI `Text` per run and reduces them with `+`:
`attributedString.runs.map { Text(AttributedString(slice)) }.reduce(+)`. For the
observed messages that is 24–100 `Text` values (plus per-run sub-`AttributedString`
allocations) rebuilt whenever a cell's body re-evaluates. A single
`Text(attributedString)` renders inline styling (bold/italic/code font)
natively, so only attachment placeholders and per-run link attributes genuinely
require splitting. Coalescing maximal non-attachment/non-link spans into one
`Text(attributedString)` cuts the count substantially.

## Correctness / regression

Full logic suite green (35 tests / 9 suites), plus the new
`CodeTokenizerCacheTests`. No behavior change — both are transparent caches over
deterministic functions.
