import Foundation

/// A ``MarkupParser`` implementation backed by Foundation’s Markdown support.
///
/// This parser leverages Foundation’s Markdown support and preserves structure via
/// presentation intents.
///
/// This parser can process its output to expand custom emoji and math expressions into
/// inline attachments.
public struct AttributedStringMarkdownParser: MarkupParser {
  public enum SoftBreakMode: Hashable, Sendable {
    case spaces
    case lineBreaks
  }

  private let baseURL: URL?
  private let options: AttributedString.MarkdownParsingOptions
  private let processor: PatternProcessor
  private let softBreakMode: SoftBreakMode

  public init(
    baseURL: URL?,
    options: AttributedString.MarkdownParsingOptions = .init(),
    syntaxExtensions: [SyntaxExtension] = [],
    softBreakMode: SoftBreakMode = .spaces
  ) {
    self.baseURL = baseURL
    self.options = options
    self.processor = PatternProcessor(syntaxExtensions: syntaxExtensions)
    self.softBreakMode = softBreakMode
  }

  public func attributedString(for input: String) throws -> AttributedString {
    let output = try processor.expand(
      AttributedString(
        markdown: input,
        including: \.textual,
        options: options,
        baseURL: baseURL
      )
    )

    return switch softBreakMode {
    case .spaces:
      output
    case .lineBreaks:
      preservingSoftBreaks(in: output)
    }
  }

  private func preservingSoftBreaks(in attributedString: AttributedString) -> AttributedString {
    var output = AttributedString()

    for run in attributedString.runs {
      guard let inlinePresentationIntent = run.inlinePresentationIntent,
        inlinePresentationIntent.contains(.softBreak)
      else {
        output.append(attributedString[run.range])
        continue
      }

      var attributes = run.attributes
      let remainingIntent = inlinePresentationIntent.subtracting(.softBreak)
      attributes.inlinePresentationIntent = remainingIntent.isEmpty ? nil : remainingIntent

      output.append(AttributedString("\n", attributes: attributes))
    }

    return output
  }
}

extension MarkupParser where Self == AttributedStringMarkdownParser {
  /// Creates a Markdown parser configured for inline-only syntax.
  public static func inlineMarkdown(
    baseURL: URL? = nil,
    syntaxExtensions: [AttributedStringMarkdownParser.SyntaxExtension] = []
  ) -> Self {
    .init(
      baseURL: baseURL,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace),
      syntaxExtensions: syntaxExtensions
    )
  }

  /// Creates a Markdown parser configured for full-document syntax.
  public static func markdown(
    baseURL: URL? = nil,
    syntaxExtensions: [AttributedStringMarkdownParser.SyntaxExtension] = [],
    softBreakMode: AttributedStringMarkdownParser.SoftBreakMode = .spaces
  ) -> Self {
    .init(
      baseURL: baseURL,
      syntaxExtensions: syntaxExtensions,
      softBreakMode: softBreakMode
    )
  }
}
