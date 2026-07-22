import Foundation
import Testing

@testable import Textual

// MARK: - Overview
//
// Micro-benchmark for the block-building path that turns a parsed
// `AttributedString` into renderable blocks: `BlockRuns` segmentation and the
// per-paragraph `isMathBlock` probe that `BlockContent` runs for every block.
//
// Run with:
//   swift test -c release --filter BlockRunsBenchmark

@Suite(.serialized)
struct BlockRunsBenchmark {
  static let document: String = {
    let unit = """
      # Heading level one

      Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod
      tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim.

      ## Subheading

      A second paragraph with some *emphasis* and **strong** spans plus a
      `code span` to force multiple inline runs inside one block.

      - First list item with text
      - Second list item with more text
        - Nested item one
        - Nested item two
      - Third list item

      > A block quote paragraph that spans a reasonable amount of content so
      > the segmentation has real work to do across several runs.

      | Col A | Col B | Col C |
      |-------|-------|-------|
      | a1    | b1    | c1    |
      | a2    | b2    | c2    |

      Closing paragraph of the section to add more block boundaries here too.

      """
    return String(repeating: unit, count: 40)
  }()

  static func measure(iterations: Int, _ body: () throws -> Void) rethrows -> Double {
    var samples: [Double] = []
    let clock = ContinuousClock()
    for _ in 0..<iterations {
      let start = clock.now
      try body()
      let e = start.duration(to: clock.now)
      samples.append(Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15)
    }
    samples.sort()
    return samples[samples.count / 2]
  }

  @MainActor static func parsed() throws -> AttributedString {
    try AttributedStringMarkdownParser.markdown().attributedString(for: document)
  }

  // Decides whether a content-keyed cache can beat recomputation: a cache
  // lookup must hash the content, so if hashing costs as much as computing
  // blockRuns, caching cannot win. Compares recompute vs the key-building work.
  @MainActor @Test func cacheKeyVsRecompute() throws {
    let parsed = try Self.parsed()
    let sub = parsed[parsed.startIndex..<parsed.endIndex]

    let recompute = try Self.measure(iterations: 50) {
      _ = sub.blockRuns().count
    }

    // Cost of the cheapest correct identity key: hashing the content value.
    let hashKey = try Self.measure(iterations: 50) {
      var hasher = Hasher()
      hasher.combine(AttributedString(sub))
      _ = hasher.finalize()
    }

    // Cost of hashing just the flattened characters (weaker key candidate).
    let hashChars = try Self.measure(iterations: 50) {
      var hasher = Hasher()
      hasher.combine(String(sub.characters[...]))
      _ = hasher.finalize()
    }

    print(
      String(
        format: "BENCH cacheKeyVsRecompute recompute=%.3fms hashValue=%.3fms hashChars=%.3fms",
        recompute, hashKey, hashChars))
  }

  @MainActor @Test func topLevelBlockRuns() throws {
    let parsed = try Self.parsed()
    var count = 0
    for _ in 0..<3 { count = parsed.blockRuns().count }

    let median = try Self.measure(iterations: 50) {
      _ = parsed.blockRuns().count
    }
    print(String(format: "BENCH topLevelBlockRuns blocks=%d median=%.3fms", count, median))
  }

  // Mirrors BlockContent: segment top-level blocks, then recurse into list
  // blocks, and run isMathBlock for every paragraph-like block.
  @MainActor @Test func fullBlockWalk() throws {
    let parsed = try Self.parsed()

    func walk(_ content: AttributedSubstring, parent: PresentationIntent.IntentType?) -> Int {
      var work = 0
      let runs = content.blockRuns(parent: parent)
      for index in runs.indices {
        let run = runs[index]
        let slice = content[run.range]
        switch run.intent?.kind {
        case .paragraph:
          if slice.isMathBlock { work += 1 } else { work += 1 }
        case .orderedList, .unorderedList, .blockQuote, .table:
          work += walk(slice, parent: run.intent)
        default:
          work += 1
        }
      }
      return work
    }

    var work = 0
    for _ in 0..<3 { work = walk(parsed[parsed.startIndex..<parsed.endIndex], parent: nil) }

    let median = try Self.measure(iterations: 30) {
      _ = walk(parsed[parsed.startIndex..<parsed.endIndex], parent: nil)
    }
    print(String(format: "BENCH fullBlockWalk work=%d median=%.3fms", work, median))
  }

  @MainActor @Test func isMathBlockPerParagraph() throws {
    let parsed = try Self.parsed()
    // Collect top-level paragraph slices.
    let runs = parsed.blockRuns()
    var paragraphs: [AttributedSubstring] = []
    for index in runs.indices where runs[index].intent?.kind == .paragraph {
      paragraphs.append(parsed[runs[index].range])
    }

    let median = try Self.measure(iterations: 50) {
      var n = 0
      for p in paragraphs where p.isMathBlock { n += 1 }
      _ = n
    }
    print(
      String(
        format: "BENCH isMathBlockPerParagraph paragraphs=%d median=%.3fms",
        paragraphs.count, median))
  }
}
