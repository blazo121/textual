import Foundation
import Testing

@testable import Textual

// Measures parse cost at realistic chat-message sizes (~10 lines typical,
// ~100 lines large) to check whether streaming/incremental work is warranted.
@Suite(.serialized)
@MainActor
struct ChatScaleBenchmark {
  static func parse(_ s: String) throws -> AttributedString {
    try AttributedString(markdown: s, including: \.textual, options: .init(), baseURL: nil)
  }

  static let tenLineMessage = """
    Sure — here's a quick summary:

    - First point worth mentioning
    - Second point with a bit more detail
    - Third point to wrap it up

    Let me know if you want me to expand on any of these, and I can go deeper.
    """

  static let hundredLineMessage: String = {
    var parts: [String] = ["# Detailed answer\n"]
    for i in 1...12 {
      parts.append(
        """
        ## Section \(i)

        A paragraph explaining section \(i) with some *emphasis*, a bit of
        `inline code`, and a [reference](https://example.com) to look at.

        - point one for section \(i)
        - point two for section \(i)

        """)
    }
    return parts.joined(separator: "\n")
  }()

  static func median(_ n: Int, _ body: () throws -> Void) rethrows -> Double {
    var xs: [Double] = []
    let clock = ContinuousClock()
    for _ in 0..<n {
      let s = clock.now
      try body()
      let e = s.duration(to: clock.now)
      xs.append(Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15)
    }
    xs.sort()
    return xs[xs.count / 2]
  }

  @Test func singleParse() throws {
    let ten = Self.tenLineMessage
    let hundred = Self.hundredLineMessage
    for _ in 0..<3 { _ = try Self.parse(ten); _ = try Self.parse(hundred) }
    let t = try Self.median(20) { _ = try Self.parse(ten) }
    let h = try Self.median(20) { _ = try Self.parse(hundred) }
    print(
      String(
        format: "BENCH chatSingleParse tenLine(%dchars)=%.3fms hundredLine(%dchars)=%.3fms",
        ten.count, t, hundred.count, h))
  }

  // Token-by-token streaming of one message: reparse the whole growing message
  // on every token. Reports total wall time and the worst single-step cost (the
  // number that would cause a dropped frame if too high).
  @Test func streamingOneMessage() throws {
    for (label, message) in [("tenLine", Self.tenLineMessage), ("hundredLine", Self.hundredLineMessage)] {
      // Approximate tokens as ~4-character increments.
      let chars = Array(message)
      var assembled = ""
      var total = 0.0
      var worst = 0.0
      let clock = ContinuousClock()
      var i = 0
      while i < chars.count {
        let end = min(i + 4, chars.count)
        assembled += String(chars[i..<end])
        i = end
        let s = clock.now
        _ = try Self.parse(assembled)
        let e = s.duration(to: clock.now)
        let ms = Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15
        total += ms
        worst = max(worst, ms)
      }
      print(
        String(
          format: "BENCH chatStreaming %@ steps=%d total=%.1fms worstStep=%.3fms",
          label, (chars.count + 3) / 4, total, worst))
    }
  }
}
