import Foundation
import Testing

@testable import Textual

// Correctness + speedup for the CodeTokenizer memoization cache. Requires the
// resource bundle; under `swift test` point PACKAGE_RESOURCE_BUNDLE_PATH at the
// built .bundle's parent directory (see PerfReports/03-codetokenizer.md).
struct CodeTokenizerCacheTests {
  static let sample = String(
    repeating: """
      struct Point: Hashable {
        var x: Double
        var y: Double
        func distance(to other: Point) -> Double {
          let dx = x - other.x
          return (dx * dx).squareRoot()
        }
      }

      """, count: 20)

  @Test
  @available(watchOS, unavailable)
  func cachedEqualsUncached() async throws {
    let tokenizer = try #require(CodeTokenizer())
    let first = await tokenizer.tokenize(code: Self.sample, language: "swift")  // miss
    let second = await tokenizer.tokenize(code: Self.sample, language: "swift")  // hit
    #expect(first == second)
    #expect(!first.isEmpty)
  }

  @Test
  @available(watchOS, unavailable)
  func differentLanguageNotShared() async throws {
    let tokenizer = try #require(CodeTokenizer())
    let asSwift = await tokenizer.tokenize(code: "let x = 1", language: "swift")
    let asPython = await tokenizer.tokenize(code: "let x = 1", language: "python")
    // Different grammars produce different tokenization; cache must key on both.
    #expect(asSwift != asPython)
  }

  @Test
  @available(watchOS, unavailable)
  func cacheHitIsFasterThanMiss() async throws {
    let tokenizer = try #require(CodeTokenizer())
    let clock = ContinuousClock()

    // Cold miss (also primes the swift grammar).
    _ = await tokenizer.tokenize(code: Self.sample, language: "swift")

    // Warm hits.
    var hitTotal = Duration.zero
    for _ in 0..<10 {
      let start = clock.now
      _ = await tokenizer.tokenize(code: Self.sample, language: "swift")
      hitTotal += start.duration(to: clock.now)
    }
    let hitMS =
      (Double(hitTotal.components.seconds) * 1000
        + Double(hitTotal.components.attoseconds) / 1e15) / 10

    // A fresh miss on distinct content of the same size.
    let distinct = Self.sample + "\n// unique\n"
    let missStart = clock.now
    _ = await tokenizer.tokenize(code: distinct, language: "swift")
    let missE = missStart.duration(to: clock.now)
    let missMS =
      Double(missE.components.seconds) * 1000 + Double(missE.components.attoseconds) / 1e15

    print(String(format: "BENCH codeTokenizerCache hit=%.4fms miss=%.4fms", hitMS, missMS))
    #expect(hitMS < missMS)
  }
}
