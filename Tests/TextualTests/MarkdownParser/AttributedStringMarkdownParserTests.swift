import Foundation
import Testing

@testable import Textual

struct AttributedStringMarkdownParserTests {
  @MainActor @Test func markdownSoftBreaksRenderAsSpacesByDefault() throws {
    let parser = AttributedStringMarkdownParser.markdown()

    let output = try parser.attributedString(for: "Ahoj\nAko sa mas?")

    #expect(String(output.characters) == "Ahoj Ako sa mas?")
  }

  @MainActor @Test func markdownSoftBreaksCanRenderAsLineBreaks() throws {
    let parser = AttributedStringMarkdownParser.markdown(softBreakMode: .lineBreaks)

    let output = try parser.attributedString(for: "Ahoj\nAko sa mas?")

    #expect(String(output.characters) == "Ahoj\nAko sa mas?")
    #expect(output.runs.allSatisfy { (($0.inlinePresentationIntent?.contains(.softBreak)) == nil) })
  }

  @MainActor @Test func hardLineBreaksRemainUnchanged() throws {
    let parser = AttributedStringMarkdownParser.markdown(softBreakMode: .lineBreaks)

    let output = try parser.attributedString(for: "Ahoj  \nAko sa mas?")

    #expect(String(output.characters) == "Ahoj\nAko sa mas?")
    #expect(
      output.runs.contains { run in
        run.inlinePresentationIntent?.contains(.lineBreak) == true
      }
    )
  }
}
