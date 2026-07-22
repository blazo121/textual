import Foundation
import Testing

@testable import Textual

// MARK: - Overview
//
// End-to-end benchmark for `AttributedStringMarkdownParser.attributedString(for:)`.
// Splits the cost between Foundation's `AttributedString(markdown:)` (opaque, not
// ours to optimize) and our `PatternProcessor.expand` post-pass (which drives
// `PatternTokenizer`). Confirms the tokenizer optimization in the real pipeline.
//
// Run with:
//   swift test -c release --filter MarkdownParserBenchmark

@Suite(.serialized)
struct MarkdownParserBenchmark {
  static let document: String = {
    let unit = """
      ## Section :smile:

      Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod
      tempor incididunt :heart: ut labore et dolore magna aliqua. Consider the
      identity $e^{i\\pi}+1=0$ which is elegant. Ut enim ad minim veniam quis.

      - First item with a `code span` and more text to fill the line out nicely
      - Second item :doge: referencing something and continuing onward here too

      A display equation follows the list:

      $$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$

      More closing prose to give the parser a realistic amount of plain content.

      """
    return String(repeating: unit, count: 60)
  }()

  static let emoji: Set<Emoji> = [
    Emoji(shortcode: "smile", url: URL(string: "https://example.com/smile.png")!),
    Emoji(shortcode: "heart", url: URL(string: "https://example.com/heart.png")!),
    Emoji(shortcode: "doge", url: URL(string: "https://example.com/doge.png")!),
  ]

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

  @MainActor @Test func endToEndWithExtensions() throws {
    let parser = AttributedStringMarkdownParser.markdown(
      syntaxExtensions: [.emoji(Self.emoji), .math]
    )
    let doc = Self.document
    for _ in 0..<3 { _ = try parser.attributedString(for: doc) }

    let median = try Self.measure(iterations: 20) {
      _ = try parser.attributedString(for: doc)
    }
    print(String(format: "BENCH parseWithExtensions chars=%d median=%.3fms", doc.count, median))
  }

  @MainActor @Test func parseNoTriggers() throws {
    // Extensions enabled but the document contains no `:` or `$`, so the
    // whole-document fast path should skip the rebuild entirely.
    let plain = String(
      repeating: """
        ## Heading

        Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod
        tempor incididunt ut labore et dolore magna aliqua with `code` inline.

        - one item of prose that goes on for a little while to fill the line
        - two more prose that also continues onward without any special marks

        """, count: 60)
    let parser = AttributedStringMarkdownParser.markdown(
      syntaxExtensions: [.emoji(Self.emoji), .math]
    )
    for _ in 0..<3 { _ = try parser.attributedString(for: plain) }

    let median = try Self.measure(iterations: 20) {
      _ = try parser.attributedString(for: plain)
    }
    print(String(format: "BENCH parseNoTriggers chars=%d median=%.3fms", plain.count, median))
  }

  @MainActor @Test func expandNoTriggersOnly() throws {
    // The document has no `:`/`$`; isolate the expand cost, which should be
    // dominated by the single whole-document trigger scan (fast path).
    let plain = String(
      repeating:
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor. ",
      count: 400)
    let options = AttributedString.MarkdownParsingOptions()
    let parsed = try AttributedString(
      markdown: plain, including: \.textual, options: options, baseURL: nil)
    let processor = AttributedStringMarkdownParser.PatternProcessor(
      syntaxExtensions: [.emoji(Self.emoji), .math]
    )
    for _ in 0..<3 { _ = try processor.expand(parsed) }

    let median = try Self.measure(iterations: 20) {
      _ = try processor.expand(parsed)
    }
    print(String(format: "BENCH expandNoTriggersOnly chars=%d median=%.3fms", plain.count, median))
  }

  @MainActor @Test func foundationParseOnly() throws {
    let doc = Self.document
    let options = AttributedString.MarkdownParsingOptions()
    for _ in 0..<3 {
      _ = try AttributedString(markdown: doc, including: \.textual, options: options, baseURL: nil)
    }

    let median = try Self.measure(iterations: 20) {
      _ = try AttributedString(markdown: doc, including: \.textual, options: options, baseURL: nil)
    }
    print(String(format: "BENCH foundationParseOnly chars=%d median=%.3fms", doc.count, median))
  }

  @MainActor @Test func runWalkOnly() throws {
    // Isolates the cost of iterating runs and rebuilding an AttributedString by
    // appending each run slice — i.e. `expand` with tokenization removed.
    let doc = Self.document
    let options = AttributedString.MarkdownParsingOptions()
    let parsed = try AttributedString(
      markdown: doc, including: \.textual, options: options, baseURL: nil)
    var runCount = 0
    for _ in parsed.runs { runCount += 1 }

    let median = try Self.measure(iterations: 20) {
      var out = AttributedString()
      for run in parsed.runs { out.append(parsed[run.range]) }
      _ = out
    }
    print(String(format: "BENCH runWalkOnly runs=%d median=%.3fms", runCount, median))
  }

  @MainActor @Test func extractStringsOnly() throws {
    let doc = Self.document
    let options = AttributedString.MarkdownParsingOptions()
    let parsed = try AttributedString(
      markdown: doc, including: \.textual, options: options, baseURL: nil)

    let median = try Self.measure(iterations: 20) {
      var total = 0
      for run in parsed.runs {
        let s = String(parsed[run.range].characters[...])
        total += s.count
      }
      _ = total
    }
    print(String(format: "BENCH extractStringsOnly median=%.3fms", median))
  }

  @MainActor @Test func extractAndTokenize() throws {
    let doc = Self.document
    let options = AttributedString.MarkdownParsingOptions()
    let parsed = try AttributedString(
      markdown: doc, including: \.textual, options: options, baseURL: nil)
    let tokenizer = PatternTokenizer(patterns: [.emoji, .mathBlock, .mathInline])

    let median = try Self.measure(iterations: 20) {
      for run in parsed.runs {
        let s = String(parsed[run.range].characters[...])
        _ = try? tokenizer.tokenize(s)
      }
    }
    print(String(format: "BENCH extractAndTokenize median=%.3fms", median))
  }

  @MainActor @Test func expandOnly() throws {
    let doc = Self.document
    let options = AttributedString.MarkdownParsingOptions()
    let parsed = try AttributedString(
      markdown: doc, including: \.textual, options: options, baseURL: nil)
    let processor = AttributedStringMarkdownParser.PatternProcessor(
      syntaxExtensions: [.emoji(Self.emoji), .math]
    )
    for _ in 0..<3 { _ = try processor.expand(parsed) }

    let median = try Self.measure(iterations: 20) {
      _ = try processor.expand(parsed)
    }
    print(String(format: "BENCH expandOnly median=%.3fms", median))
  }
}
