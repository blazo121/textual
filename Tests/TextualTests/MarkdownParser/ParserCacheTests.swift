import Foundation
import Testing

@testable import Textual

// Correctness guarantees for the memoization cache in
// AttributedStringMarkdownParser: cached output must equal freshly-parsed
// output, and different configurations must never share a cache entry.
@MainActor
struct ParserCacheTests {
  private let doc = """
    # Title

    A paragraph with *emphasis*, `code`, and a [link](https://example.com).

    Line one
    Line two

    - item a
    - item b
    """

  @Test func cachedEqualsUncached() throws {
    // The factory parser memoizes; the public initializer does not.
    let cached = AttributedStringMarkdownParser.markdown()
    let uncached = AttributedStringMarkdownParser(baseURL: nil)

    let a = try cached.attributedString(for: doc)  // miss -> fills cache
    let b = try cached.attributedString(for: doc)  // hit
    let reference = try uncached.attributedString(for: doc)

    #expect(a == reference)
    #expect(b == reference)
  }

  @Test func softBreakModeNotCrossContaminated() throws {
    // Same markup, different soft-break handling must produce different output
    // and must not be served from the same cache entry.
    let spaces = AttributedStringMarkdownParser.markdown(softBreakMode: .spaces)
    let breaks = AttributedStringMarkdownParser.markdown(softBreakMode: .lineBreaks)

    let withSpaces = try spaces.attributedString(for: doc)
    let withBreaks = try breaks.attributedString(for: doc)

    let referenceBreaks = try AttributedStringMarkdownParser(
      baseURL: nil, softBreakMode: .lineBreaks
    ).attributedString(for: doc)

    #expect(withSpaces != withBreaks)
    #expect(withBreaks == referenceBreaks)
  }

  @Test func baseURLNotCrossContaminated() throws {
    let markdown = "[link](path/page.html)"
    let a = AttributedStringMarkdownParser.markdown(baseURL: URL(string: "https://a.example.com/"))
    let b = AttributedStringMarkdownParser.markdown(baseURL: URL(string: "https://b.example.com/"))

    let ra = try a.attributedString(for: markdown)
    let rb = try b.attributedString(for: markdown)

    // Links resolve against different base URLs, so the outputs differ.
    #expect(ra != rb)
  }

  @Test func inlineAndBlockNotCrossContaminated() throws {
    let markdown = "First\n\nSecond"
    let block = try AttributedStringMarkdownParser.markdown().attributedString(for: markdown)
    let inline = try AttributedStringMarkdownParser.inlineMarkdown().attributedString(for: markdown)

    // Inline-only parsing does not create separate paragraph blocks.
    #expect(block != inline)
  }
}
