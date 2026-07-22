import Foundation
import Testing

@testable import Textual

// MARK: - Overview
//
// Micro-benchmark for `PatternTokenizer.tokenize`. Not a correctness test; it prints
// timing statistics so we can measure optimizations across versions.
//
// Run with:
//   swift test --filter PatternTokenizerBenchmark
//
// Results are written as a single line to stdout and appended to
// PerfReports/pattern-tokenizer.csv by the harness reader when invoked from the
// bench script. Here we just emit the numbers.

@Suite(.serialized)
struct PatternTokenizerBenchmark {
  /// Builds a large, realistic input: mostly plain prose with sparse emoji shortcodes.
  static func makeInput(paragraphs: Int) -> String {
    let base = """
      Lorem ipsum dolor sit amet, consectetur adipiscing elit :smile: sed do eiusmod \
      tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, \
      quis nostrud exercitation ullamco :heart: laboris nisi ut aliquip ex ea commodo. \
      Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu.

      """
    return String(repeating: base, count: paragraphs)
  }

  static func measure(iterations: Int, _ body: () throws -> Void) rethrows -> (
    minMS: Double, medianMS: Double, meanMS: Double
  ) {
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    let clock = ContinuousClock()
    for _ in 0..<iterations {
      let start = clock.now
      try body()
      let elapsed = start.duration(to: clock.now)
      let ms = Double(elapsed.components.seconds) * 1000
        + Double(elapsed.components.attoseconds) / 1e15
      samples.append(ms)
    }
    samples.sort()
    let min = samples.first ?? 0
    let median = samples[samples.count / 2]
    let mean = samples.reduce(0, +) / Double(samples.count)
    return (min, median, mean)
  }

  @Test func benchmarkEmojiSparse() throws {
    let input = Self.makeInput(paragraphs: 400)
    let tokenizer = PatternTokenizer(patterns: [.emoji])

    // Warmup
    for _ in 0..<3 { _ = try tokenizer.tokenize(input) }

    let stats = try Self.measure(iterations: 20) {
      _ = try tokenizer.tokenize(input)
    }

    let charCount = input.count
    print(
      String(
        format:
          "BENCH emojiSparse chars=%d min=%.3fms median=%.3fms mean=%.3fms",
        charCount, stats.minMS, stats.medianMS, stats.meanMS
      )
    )
  }

  @Test func benchmarkNoMatch() throws {
    // Pure plain text, no emoji: exercises the char-by-char fallback path.
    let input = String(
      repeating:
        "The quick brown fox jumps over the lazy dog and keeps running through fields. ",
      count: 500
    )
    let tokenizer = PatternTokenizer(patterns: [.emoji])

    for _ in 0..<3 { _ = try tokenizer.tokenize(input) }

    let stats = try Self.measure(iterations: 20) {
      _ = try tokenizer.tokenize(input)
    }

    print(
      String(
        format:
          "BENCH noMatch chars=%d min=%.3fms median=%.3fms mean=%.3fms",
        input.count, stats.minMS, stats.medianMS, stats.meanMS
      )
    )
  }

  @Test func benchmarkMath() throws {
    let base = """
      Consider the identity $e^{i\\pi}+1=0$ which is beautiful, and the block form:
      $$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$
      followed by more prose to pad the paragraph out to a reasonable length here.

      """
    let input = String(repeating: base, count: 300)
    let tokenizer = PatternTokenizer(patterns: [.mathBlock, .mathInline])

    for _ in 0..<3 { _ = try tokenizer.tokenize(input) }

    let stats = try Self.measure(iterations: 20) {
      _ = try tokenizer.tokenize(input)
    }

    print(
      String(
        format:
          "BENCH math chars=%d min=%.3fms median=%.3fms mean=%.3fms",
        input.count, stats.minMS, stats.medianMS, stats.meanMS
      )
    )
  }
}
