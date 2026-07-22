import Foundation
import Testing

@testable import Textual

// MARK: - Overview
//
// Probes the cost of Foundation's `AttributedString(markdown:)` itself — the
// opaque, single largest remaining cost in the parse pipeline. Measures option
// sensitivity, attribute-scope sensitivity, and how cost scales with document
// size (to expose the O(n^2) streaming pathology).
//
// Run with:
//   swift test -c release --filter FoundationParseBenchmark

@Suite(.serialized)
struct FoundationParseBenchmark {
  static let unit = """
    ## Heading

    Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod
    tempor incididunt ut labore et dolore magna aliqua with *emphasis* and a
    `code span` plus a [link](https://example.com) to round things out.

    - first list item
    - second list item

    > a short block quote line

    """

  static func doc(_ units: Int) -> String { String(repeating: unit, count: units) }

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

  @MainActor @Test func optionSensitivity() throws {
    let doc = Self.doc(40)

    let textualFull = try Self.measure(iterations: 15) {
      _ = try AttributedString(
        markdown: doc, including: \.textual,
        options: .init(), baseURL: nil)
    }
    let foundationScope = try Self.measure(iterations: 15) {
      _ = try AttributedString(
        markdown: doc, including: \.foundation,
        options: .init(), baseURL: nil)
    }
    let inlineOnly = try Self.measure(iterations: 15) {
      _ = try AttributedString(
        markdown: doc, including: \.textual,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace), baseURL: nil)
    }
    let extendedAttrs = try Self.measure(iterations: 15) {
      _ = try AttributedString(
        markdown: doc, including: \.textual,
        options: .init(allowsExtendedAttributes: true), baseURL: nil)
    }

    print(
      String(
        format:
          "BENCH options textualFull=%.3fms foundationScope=%.3fms inlineOnly=%.3fms extendedAttrs=%.3fms",
        textualFull, foundationScope, inlineOnly, extendedAttrs))
  }

  @MainActor @Test func scaling() throws {
    for units in [10, 20, 40, 80] {
      let doc = Self.doc(units)
      let median = try Self.measure(iterations: 10) {
        _ = try AttributedString(markdown: doc, including: \.textual, options: .init(), baseURL: nil)
      }
      print(
        String(format: "BENCH scaling units=%d chars=%d median=%.3fms", units, doc.count, median))
    }
  }

  // Simulates streaming: a document grown one block at a time, each growth step
  // reparsing the whole document (today's behavior). Reports total time to
  // "stream" the whole document to exhibit the O(n^2) cost.
  @MainActor @Test func streamingWholeDocReparse() throws {
    let blocks = (0..<40).map { _ in Self.unit }
    var assembled = ""
    let clock = ContinuousClock()
    let start = clock.now
    for block in blocks {
      assembled += block
      _ = try AttributedString(
        markdown: assembled, including: \.textual, options: .init(), baseURL: nil)
    }
    let e = start.duration(to: clock.now)
    let ms = Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15
    print(
      String(
        format: "BENCH streamingWholeDocReparse steps=%d finalChars=%d totalMS=%.3fms",
        blocks.count, assembled.count, ms))
  }
}
