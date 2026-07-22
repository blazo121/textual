import Foundation
import Testing

@testable import Textual

@MainActor
struct IsMathBlockTests {
  private func parse(_ markdown: String) throws -> AttributedString {
    try AttributedStringMarkdownParser.markdown(syntaxExtensions: [.math])
      .attributedString(for: markdown)
  }

  @Test func blockMathIsDetected() throws {
    let parsed = try parse("$$E = mc^2$$")
    // The whole document is a single block-math paragraph.
    #expect(parsed.isMathBlock)
  }

  @Test func plainParagraphIsNotMathBlock() throws {
    let parsed = try parse("Just some ordinary paragraph text with no math.")
    #expect(!parsed.isMathBlock)
  }

  @Test func inlineMathIsNotBlock() throws {
    let parsed = try parse("Euler said $e^{i\\pi}+1=0$ here.")
    #expect(!parsed.isMathBlock)
  }

  @Test func textPlusBlockMathIsNotMathBlock() throws {
    // A block-math attachment surrounded by real text is not a pure math block.
    let parsed = try parse("Prefix text $$x+1$$")
    #expect(!parsed.isMathBlock)
  }

  @Test func emptyIsNotMathBlock() throws {
    let parsed = AttributedString()
    #expect(!parsed.isMathBlock)
  }
}
