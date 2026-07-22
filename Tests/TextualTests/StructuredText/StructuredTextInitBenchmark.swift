import Foundation
import SwiftUI
import Testing

@testable import Textual

// MARK: - Overview
//
// Measures the cost of constructing `StructuredText`. SwiftUI re-instantiates
// view structs frequently (on every enclosing body evaluation), and the
// initializer parses the markup eagerly to populate `@State`. If parsing runs
// on every init, repeated construction with identical markup is pure waste.
//
// Run with:
//   swift test -c release --filter StructuredTextInitBenchmark

@Suite(.serialized)
struct StructuredTextInitBenchmark {
  static let document: String = {
    let unit = """
      ## Section

      Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod
      tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim.

      - one list item
      - two list item

      Closing paragraph text to round the block out to a realistic length.

      """
    return String(repeating: unit, count: 40)
  }()

  static func measure(iterations: Int, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    let clock = ContinuousClock()
    for _ in 0..<iterations {
      let start = clock.now
      body()
      let e = start.duration(to: clock.now)
      samples.append(Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15)
    }
    samples.sort()
    return samples[samples.count / 2]
  }

  @MainActor @Test func repeatedInitSameMarkup() {
    let doc = Self.document
    // Warmup
    for _ in 0..<3 { _ = StructuredText(markdown: doc) }

    let median = Self.measure(iterations: 30) {
      _ = StructuredText(markdown: doc)
    }
    print(String(format: "BENCH structuredTextInit chars=%d median=%.3fms", doc.count, median))
  }
}
