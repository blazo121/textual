import Foundation
import Testing

@testable import Textual

// MARK: - Overview
//
// Micro-benchmark for `CodeTokenizer.tokenize(code:language:)` — Prism.js syntax
// highlighting over JavaScriptCore. Measures per-call latency (the actor and its
// JSContext are created once and reused, as in production via `.shared`).
//
// Run with:
//   swift test -c release --filter CodeTokenizerBenchmark

@Suite(.serialized)
struct CodeTokenizerBenchmark {
  static let sample: String = {
    let unit = """
      struct Point: Hashable, Codable {
        var x: Double
        var y: Double

        func distance(to other: Point) -> Double {
          let dx = x - other.x
          let dy = y - other.y
          return (dx * dx + dy * dy).squareRoot()  // Euclidean
        }
      }

      extension Array where Element == Point {
        var centroid: Point {
          let sum = reduce(Point(x: 0, y: 0)) { acc, p in
            Point(x: acc.x + p.x, y: acc.y + p.y)
          }
          let n = Double(count)
          return Point(x: sum.x / n, y: sum.y / n)
        }
      }

      """
    return String(repeating: unit, count: 30)
  }()

  static func measure(iterations: Int, _ body: () async -> Void) async -> (
    minMS: Double, medianMS: Double, meanMS: Double
  ) {
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    let clock = ContinuousClock()
    for _ in 0..<iterations {
      let start = clock.now
      await body()
      let elapsed = start.duration(to: clock.now)
      let ms = Double(elapsed.components.seconds) * 1000
        + Double(elapsed.components.attoseconds) / 1e15
      samples.append(ms)
    }
    samples.sort()
    return (samples.first ?? 0, samples[samples.count / 2], samples.reduce(0, +) / Double(samples.count))
  }

  @Test
  @available(watchOS, unavailable)
  func benchmarkTokenize() async throws {
    let tokenizer = try #require(CodeTokenizer())
    let code = Self.sample

    // Warmup (also primes Prism grammar for swift)
    for _ in 0..<3 { _ = await tokenizer.tokenize(code: code, language: "swift") }

    var tokenCount = 0
    let stats = await Self.measure(iterations: 30) {
      let tokens = await tokenizer.tokenize(code: code, language: "swift")
      tokenCount = tokens.count
    }

    print(
      String(
        format: "BENCH codeTokenize chars=%d tokens=%d min=%.3fms median=%.3fms mean=%.3fms",
        code.count, tokenCount, stats.minMS, stats.medianMS, stats.meanMS
      )
    )
  }

  @Test
  @available(watchOS, unavailable)
  func benchmarkInit() async throws {
    // Cost of building the JSContext and evaluating the 138 KB Prism bundle.
    let clock = ContinuousClock()
    var samples: [Double] = []
    for _ in 0..<5 {
      let start = clock.now
      _ = CodeTokenizer()
      let e = start.duration(to: clock.now)
      samples.append(Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15)
    }
    samples.sort()
    print(String(format: "BENCH codeInit min=%.3fms median=%.3fms", samples.first ?? 0, samples[samples.count / 2]))
  }
}
